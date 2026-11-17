// Real NSURLSession -> production protocol/manager -> production JSCore runtime.
// All sources and URLs are self-authored. A deny transport observes every
// unexpected native/backend request; this fixture never fetches media or scripts.
{
[self test:@"v6_native_qmc_parse_uses_highest_JS_quality_and_falls_back" body:^NSDictionary *{
    __block FMXManager *manager; __block NSURL *directory;
    Main(^{ manager=[(id)NSClassFromString(@"FMXManager") shared]; directory=[manager directory]; });
    NSString *filename=@"V6QualityRoutingFixture.js";
    NSString *script=@"const seen={};lx.on('request',p=>{const m=p.info.musicInfo,id=m.songmid,q=p.info.type;const keys=Object.keys(m).sort().join(',');if(p.source!=='tx'||p.action!=='musicUrl'||keys!=='_types,name,singer,songmid,source,types'||JSON.stringify(p).includes('PRIVATE_FIXTURE'))return Promise.reject(Error('metadata isolation failed'));(seen[id]||(seen[id]=[])).push(q);if(id==='all-fail')return Promise.reject(Error('authored per-quality failure'));if(id==='down'&&(q==='flac24bit'||q==='flac'))return Promise.reject(Error('authored high-quality failure'));const route=id==='audit'?seen['all-fail'].join('_'):seen[id].join('_');return Promise.resolve('https://fixture.invalid/v6/'+id+'/'+route);});lx.send('inited',{sources:{tx:{type:'music',actions:['musicUrl'],qualitys:['128k','320k','flac','flac24bit']}}});";
    NSError *writeError=nil;
    Check([script writeToURL:[directory URLByAppendingPathComponent:filename] atomically:YES encoding:NSUTF8StringEncoding error:&writeError],writeError.localizedDescription);
    InstallSearchFixtureTransport();
    @synchronized(SmokeSearchTransport.class) { SmokeSearchResponse=^NSDictionary *(NSURLRequest *request){ return nil; }; }
    @try {
        Main(^{ [manager activate:@{@"file":filename,@"name":@"Authored quality routing fixture"}]; });
        Check(Until(^BOOL{ return [manager.selectedFile isEqual:filename] && manager.runtime.manifest[@"sources"][@"tx"]!=nil; },8),@"Quality fixture is enabled through production manager");
        __block LXSourceRuntime *runtime; Main(^{runtime=manager.runtime;});
        NSMutableArray *results=NSMutableArray.array;
        for(NSString *identifier in @[@"highest",@"down",@"all-fail",@"audit"]) {
            NSMutableURLRequest *request=[NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"https://aacert.com/ms/api.php?action=parse&_t=6"] cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:6];
            request.HTTPMethod=@"POST";
            [request setValue:@"application/x-www-form-urlencoded" forHTTPHeaderField:@"Content-Type"];
            [request setValue:@"PRIVATE_FIXTURE_COOKIE" forHTTPHeaderField:@"Cookie"];
            [request setValue:@"Bearer PRIVATE_FIXTURE_AUTH" forHTTPHeaderField:@"Authorization"];
            NSString *body=[NSString stringWithFormat:@"server=qq&id=%@&level=hires&qmc=1&title=Fixture&singer=Authored&src_cookie=PRIVATE_FIXTURE_SOURCE_COOKIE&src_api=PRIVATE_FIXTURE_API&key=PRIVATE_FIXTURE_KEY",identifier];
            request.HTTPBody=[body dataUsingEncoding:NSUTF8StringEncoding];
            Check([NSClassFromString(@"FMExtensionProtocol") canInitWithRequest:request],@"qmc-marked original parse request enters the production handler");
            NSDictionary *payload=FetchSearchFixture(request);
            if([identifier isEqual:@"all-fail"]) {
                Check([payload[@"code"] integerValue]==502 && !payload[@"data"][@"url"],@"All qualities fail explicitly without returning a native preview URL");
            } else {
                NSString *suffix=[identifier isEqual:@"highest"]?@"flac24bit":([identifier isEqual:@"down"]?@"flac24bit_flac_320k":@"flac24bit_flac_320k_128k");
                NSString *expected=[NSString stringWithFormat:@"https://fixture.invalid/v6/%@/%@",identifier,suffix];
                Check([payload[@"code"] integerValue]==200 && [payload[@"data"][@"url"] isEqual:expected],@"Highest-first quality order and one attempt per quality are observed inside the real script");
                Check([payload[@"data"][@"quality"] isEqual:@"未知"] && payload[@"data"][@"qmc"]==NSNull.null,@"Plain returned URL does not claim the requested quality or preserve original QMC metadata");
            }
            __block NSString *status; Main(^{status=manager.playbackStatus;});
            for(NSString *privateValue in @[@"PRIVATE_FIXTURE",@"fixture.invalid",@"https://",@"all-fail"])
                Check(![status containsString:privateValue],@"Status does not expose credentials, song IDs or URLs");
            [results addObject:@{@"scenario":identifier,@"code":payload[@"code"] ?: @0}];
        }
        __block NSUInteger nativeRequests=0;
        @synchronized(SmokeSearchTransport.class) { nativeRequests=SmokeSearchRequests.count; }
        Check(nativeRequests==0,@"No parse request falls through or retries the native backend");
        Check(Until(^BOOL{ return manager.runtime==runtime && runtime.manifest!=nil; },2),@"Per-quality failures do not disable the responsive source");
        return @{@"scenarios":results,@"qmc_request_uses_JS":@YES,@"highest_first":@YES,@"all_qualities_attempted_once":@YES,@"unverified_quality_label":@"未知",@"native_origin_requests":@(nativeRequests),@"credential_metadata_allowlist":@YES,@"real_network_used":@NO};
    } @finally {
        Main(^{ [manager disable]; });
        RestoreSearchFixtureTransport();
        [NSFileManager.defaultManager removeItemAtURL:[directory URLByAppendingPathComponent:filename] error:nil];
    }
}];
}
