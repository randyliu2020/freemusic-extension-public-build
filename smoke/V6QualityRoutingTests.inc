// Real NSURLSession -> production protocol/manager -> production JSCore runtime.
// All sources and URLs are self-authored. The final HTTP transport observes each
// real JS bridge request and denies every unexpected native/backend request.
// Attempt history is kept at that boundary, not in an isolated worker's globals.
{
[self test:@"v6_native_qmc_parse_uses_highest_JS_quality_and_falls_back" body:^NSDictionary *{
    __block FMXManager *manager; __block NSURL *directory;
    Main(^{ manager=[(id)NSClassFromString(@"FMXManager") shared]; directory=[manager directory]; });
    NSString *filename=@"V6QualityRoutingFixture.js";
    NSString *script=
        @"let invocations=0;const allowed=['_types','albumId','albumMid','albumName','hash','id','img','interval','name','singer','songId','songmid','source','strMediaMid','typeUrl','types'];"
        @"const required=['_types','id','name','singer','songmid','source','typeUrl','types'];const qualityFields=['type','hash','size','ext','bitrate','fileSize'];"
        @"lx.on('request',p=>{const m=p.info.musicInfo,id=m.songmid,q=p.info.type;"
        @"if(++invocations!==1)return Promise.reject(Error('quality attempt reused a worker'));"
        @"if(p.source!=='tx'||p.action!=='musicUrl'||m.source!=='tx'||m.id!==id||required.some(k=>!Object.prototype.hasOwnProperty.call(m,k))||Object.keys(m).some(k=>!allowed.includes(k))||JSON.stringify(p).includes('PRIVATE_FIXTURE'))return Promise.reject(Error('metadata isolation failed'));"
        @"if(!Array.isArray(m.types)||!m._types||typeof m._types!=='object'||Array.isArray(m._types)||!m.typeUrl||Object.keys(m.typeUrl).length||m.name!=='Fixture'||m.singer!=='Authored')return Promise.reject(Error('metadata shape failed'));"
        @"const qualities=m.types.concat(Object.values(m._types));if(qualities.some(item=>!item||typeof item!=='object'||Object.keys(item).some(k=>!qualityFields.includes(k))))return Promise.reject(Error('quality metadata isolation failed'));"
        @"if(id==='highest'&&(m.albumName!=='Fixture Album'||m.albumId!=='42'||m.albumMid!=='fixture-album-mid'||m.strMediaMid!=='fixture-media-mid'||m.songId!=='123'||m.interval!=='02:05'||m.types.length!==1||!m._types.flac||m._types.flac.size!==123456))return Promise.reject(Error('metadata enrichment failed'));"
        @"m.singer='PRIVATE_FIXTURE_MUTATION';m.types.push({type:'PRIVATE_FIXTURE_MUTATION'});"
        @"return new Promise((resolve,reject)=>lx.request('https://fixture.invalid/v7-quality-attempt?scenario='+encodeURIComponent(id)+'&quality='+encodeURIComponent(q)+'&invocation='+invocations,{},(error,response)=>{"
        @"if(error)return reject(error);const body=response&&response.body;if(!body||body.ok!==true)return reject(Error('authored per-quality failure'));resolve(body.url);}));});"
        @"const routed={type:'music',actions:['musicUrl'],qualitys:['128k','320k','flac','flac24bit']};"
        @"lx.send('inited',{sources:{tx:routed,wy:routed}});";
    NSError *writeError=nil;
    Check([script writeToURL:[directory URLByAppendingPathComponent:filename] atomically:YES encoding:NSUTF8StringEncoding error:&writeError],writeError.localizedDescription);
    InstallSearchFixtureTransport();
    // Runtime deliberately clears protocolClasses on its private configuration.
    // Insert this test transport at the session boundary, after that clearing,
    // without changing its headers, cookie isolation, timeout or production handler.
    Method sessionFactory=class_getClassMethod(NSURLSession.class,@selector(sessionWithConfiguration:delegate:delegateQueue:));
    IMP previousSessionFactory=method_getImplementation(sessionFactory);
    IMP fixtureSessionFactory=imp_implementationWithBlock(^NSURLSession *(id receiver,NSURLSessionConfiguration *configuration,id delegate,NSOperationQueue *queue){
        if([NSStringFromClass(object_getClass(delegate)) isEqual:@"LXHTTPDelegate"]){
            configuration=[configuration copy];NSMutableArray *classes=[configuration.protocolClasses mutableCopy] ?: NSMutableArray.array;
            [classes removeObject:SmokeSearchTransport.class];NSUInteger index=[classes indexOfObject:NSClassFromString(@"FMExtensionProtocol")];
            [classes insertObject:SmokeSearchTransport.class atIndex:index==NSNotFound?0:index+1];configuration.protocolClasses=classes;
        }
        return ((id(*)(id,SEL,id,id,id))previousSessionFactory)(receiver,@selector(sessionWithConfiguration:delegate:delegateQueue:),configuration,delegate,queue);
    });
    method_setImplementation(sessionFactory,fixtureSessionFactory);
    @synchronized(SmokeSearchTransport.class) { SmokeSearchResponse=^NSDictionary *(NSURLRequest *request){
        if(![request.URL.host isEqual:@"fixture.invalid"] || ![request.URL.path isEqual:@"/v7-quality-attempt"] || ![request.HTTPMethod isEqual:@"GET"] || ![NSURLProtocol propertyForKey:@"FMX.internalRequest" inRequest:request])return nil;
        NSDictionary *query=SmokeQuery(request);NSString *identifier=query[@"scenario"],*quality=query[@"quality"];
        if(![@[@"highest",@"down",@"all-fail",@"audit"] containsObject:identifier] || ![@[@"flac24bit",@"flac",@"320k",@"128k"] containsObject:quality] || ![query[@"invocation"] isEqual:@"1"])return nil;
        if([[request.allHTTPHeaderFields description] containsString:@"PRIVATE_FIXTURE"] || request.HTTPBody.length)return nil;
        BOOL success=![identifier isEqual:@"all-fail"] && !([identifier isEqual:@"down"] && [@[@"flac24bit",@"flac"] containsObject:quality]);
        return @{@"ok":@(success),@"url":[NSString stringWithFormat:@"https://fixture.invalid/v7-quality/%@/%@",identifier,quality]};
    }; }
    SEL workerSelector = @selector(resolveIsolatedMusicURLForSource:musicInfo:quality:timeout:completion:);
    Class runtimeClass = NSClassFromString(@"LXSourceRuntime");
    Method workerMethod = class_getInstanceMethod(runtimeClass, workerSelector);
    IMP previousWorker = NULL, workerProbe = NULL;
    __block NSUInteger workerStarts = 0;
    NSUInteger (^workerCount)(void) = ^NSUInteger{ @synchronized(runtimeClass) { return workerStarts; } };
    @try {
        Check(workerMethod != NULL, @"Observe the actual boundary that starts an isolated JS resolution");
        previousWorker = method_getImplementation(workerMethod);
        IMP original = previousWorker;
        workerProbe = imp_implementationWithBlock(^NSString *(id receiver, NSString *source, NSDictionary *musicInfo,
                                                               NSString *quality, NSTimeInterval timeout, LXSourceURLCompletion completion) {
            @synchronized(runtimeClass) { workerStarts++; }
            typedef NSString *(*Resolve)(id, SEL, NSString *, NSDictionary *, NSString *, NSTimeInterval, LXSourceURLCompletion);
            return ((Resolve)original)(receiver, workerSelector, source, musicInfo, quality, timeout, completion);
        });
        method_setImplementation(workerMethod, workerProbe);
        Main(^{ [manager activate:@{@"file":filename,@"name":@"Authored quality routing fixture"}]; });
        Check(Until(^BOOL{ return [manager.selectedFile isEqual:filename] && manager.runtime.manifest[@"sources"][@"tx"]!=nil; },8),@"Quality fixture is enabled through production manager");
        void (*observeMetadata)(id)=(void(*)(id))dlsym(self.extensionHandle,"FMTrackMetadataObserveResponse");
        Check(observeMetadata!=NULL,@"Production track metadata observation export is present");
        observeMetadata(@{@"server":@"qq",@"id":@"highest",@"title":@"Fixture",@"singer":@"Authored",@"album":@"Fixture Album",@"albumId":@42,@"albumMid":@"fixture-album-mid",@"strMediaMid":@"fixture-media-mid",@"songId":@123,@"duration":@125,@"types":@[@{@"type":@"flac",@"size":@123456,@"ext":@"flac",@"auth":@"PRIVATE_FIXTURE_QUALITY"}],@"src_cookie":@"PRIVATE_FIXTURE_CACHED_COOKIE",@"src_api":@"PRIVATE_FIXTURE_CACHED_API"});
        __block LXSourceRuntime *runtime; Main(^{runtime=manager.runtime;});
        NSMutableArray *results=NSMutableArray.array;
        NSMutableURLRequest *replayRequest = nil;
        for(NSString *identifier in @[@"highest",@"down",@"all-fail",@"audit"]) {
            NSMutableURLRequest *request=[NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"https://aacert.com/ms/api.php?action=parse&_t=6"] cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:6];
            request.HTTPMethod=@"POST";
            [request setValue:@"application/x-www-form-urlencoded" forHTTPHeaderField:@"Content-Type"];
            [request setValue:@"PRIVATE_FIXTURE_COOKIE" forHTTPHeaderField:@"Cookie"];
            [request setValue:@"Bearer PRIVATE_FIXTURE_AUTH" forHTTPHeaderField:@"Authorization"];
            NSString *body=[NSString stringWithFormat:@"server=qq&id=%@&level=hires&qmc=1&title=Fixture&singer=Authored&src_cookie=PRIVATE_FIXTURE_SOURCE_COOKIE&src_api=PRIVATE_FIXTURE_API&key=PRIVATE_FIXTURE_KEY",identifier];
            request.HTTPBody=[body dataUsingEncoding:NSUTF8StringEncoding];
            Check([NSClassFromString(@"FMExtensionProtocol") canInitWithRequest:request],@"qmc-marked original parse request enters the production handler");
            if ([identifier isEqual:@"highest"]) replayRequest = [request mutableCopy];
            NSDictionary *payload=FetchSearchFixture(request);
            if([identifier isEqual:@"all-fail"]) {
                Check([payload[@"code"] integerValue]==502 && !payload[@"data"][@"url"],@"All qualities fail explicitly without returning a native preview URL");
            } else {
                NSString *quality=[identifier isEqual:@"down"]?@"320k":@"flac24bit";
                NSString *expected=[NSString stringWithFormat:@"https://fixture.invalid/v7-quality/%@/%@",identifier,quality];
                Check([payload[@"code"] integerValue]==200 && [payload[@"data"][@"url"] isEqual:expected],@"The production isolated worker returns the expected successful quality candidate");
                Check([payload[@"data"][@"quality"] isEqual:@"未知"] && payload[@"data"][@"qmc"]==NSNull.null,@"Plain returned URL does not claim the requested quality or preserve original QMC metadata");
            }
            __block NSString *status; Main(^{status=manager.playbackStatus;});
            for(NSString *privateValue in @[@"PRIVATE_FIXTURE",@"fixture.invalid",@"https://",@"all-fail"])
                Check(![status containsString:privateValue],@"Status does not expose credentials, song IDs or URLs");
            [results addObject:@{@"scenario":identifier,@"code":payload[@"code"] ?: @0}];
        }
        NSArray *requests;@synchronized(SmokeSearchTransport.class) { requests=[SmokeSearchRequests copy]; }
        NSUInteger nativeRequests=0;NSMutableDictionary *attempts=NSMutableDictionary.dictionary;
        for(NSDictionary *request in requests){
            NSURL *URL=[NSURL URLWithString:request[@"url"]];
            if(![URL.host isEqual:@"fixture.invalid"] || ![URL.path isEqual:@"/v7-quality-attempt"]){nativeRequests++;continue;}
            NSDictionary *query=SmokeQuery([NSURLRequest requestWithURL:URL]);NSString *identifier=query[@"scenario"];
            Check([request[@"marked_internal"] boolValue] && [request[@"method"] isEqual:@"GET"] && [query[@"invocation"] isEqual:@"1"],@"Every observed attempt traverses the real private JS HTTP bridge in a fresh worker");
            if(!attempts[identifier])attempts[identifier]=NSMutableArray.array;[attempts[identifier] addObject:query[@"quality"] ?: @"missing"];
        }
        NSDictionary *expectedAttempts=@{@"highest":@[@"flac24bit"],@"down":@[@"flac24bit",@"flac",@"320k"],@"all-fail":@[@"flac24bit",@"flac",@"320k",@"128k"],@"audit":@[@"flac24bit"]};
        Check([attempts isEqual:expectedAttempts] && requests.count==9,@"Actual JS HTTP attempts prove highest-first order, one attempt per quality, complete exhaustion and a later independent success");
        Check(workerCount() == requests.count, @"Positive control observes all nine online JS resolutions at the worker boundary");
        Check(nativeRequests==0,@"No parse request falls through or retries the native backend");
        Check(Until(^BOOL{ return manager.runtime==runtime && runtime.manifest!=nil; },2),@"Per-quality failures do not disable the responsive source");
        NSUInteger (^requestCount)(void) = ^NSUInteger{
            @synchronized (SmokeSearchTransport.class) { return SmokeSearchRequests.count; }
        };
        NSString *addressA = @"https://fixture.invalid/v7-quality/highest/flac24bit";
        NSUInteger beforeReplay = requestCount();
        Check([FetchSearchFixture(replayRequest)[@"data"][@"url"] isEqual:addressA] &&
              requestCount() == beforeReplay, @"Same source and quality replay uses the saved URL without JS network traffic");
        // Exercise the actual protocol/manager/cache together. Only the
        // original binary's player receiver is represented by the Swift fixture.
        FMReplayCache *store=[(id)NSClassFromString(@"FMReplayCache") sharedCache];
        __block NSString *audioKey;
        Main(^{audioKey=[store keyForNamespace:manager.replayNamespace platform:@"tx" trackID:@"highest" quality:@"flac24bit"];});
        NSURL *authored=SmokeWriteQualityWave();
        BOOL published=[store publishVerifiedAudio:authored fileExtension:@"wav" forKey:audioKey expectedAddress:[NSURL URLWithString:addressA]];
        [NSFileManager.defaultManager removeItemAtURL:authored error:nil];
        NSURL *cachedFile=[store audioForKey:audioKey];
        Check(published && cachedFile.isFileURL && ![cachedFile isEqual:authored], @"Store owns the complete authored media after its input file is removed");
        void (*configureNative)(void *,void *)=dlsym(self.extensionHandle,"FMAdaptivePlaybackTestConfigureNative");
        NSDictionary *(*adaptiveState)(void)=dlsym(self.extensionHandle,"FMAdaptivePlaybackDiagnostics");
        void (*selectionWillChange)(id)=dlsym(self.extensionHandle,"FMAdaptivePlaybackSelectionWillChange");
        void *setup=dlsym(self.swiftUIFixtureHandle,"FMAdaptiveFixtureSetupNative");
        void *failure=dlsym(self.swiftUIFixtureHandle,"FMAdaptiveFixtureFailureNative");
        void *(*create)(void)=dlsym(self.swiftUIFixtureHandle,"FMAdaptiveFixtureCreate");
        void (*start)(void *,void *)=dlsym(self.swiftUIFixtureHandle,"FMAdaptiveFixtureStart");
        void *(*copyPlayer)(void *)=dlsym(self.swiftUIFixtureHandle,"FMAdaptiveFixtureCopyPlayer");
        void (*stop)(void *)=dlsym(self.swiftUIFixtureHandle,"FMAdaptiveFixtureStop");
        Check(configureNative&&adaptiveState&&selectionWillChange&&setup&&failure&&create&&start&&copyPlayer&&stop,@"Swift player receiver and production adaptive registration are available");
        __block id receiver;
        __block AVPlayer *player;
        __block NSUInteger previousBindings;
        __block double secondsAfterSeek=0;
        NSUInteger beforeFile=requestCount(), fileRequests=NSNotFound;
        NSDictionary *localPlaylistEvidence = nil;
        @try {
            Main(^{
                configureNative(setup,failure);
                receiver=CFBridgingRelease(create());
                previousBindings=[adaptiveState()[@"bound"] unsignedIntegerValue];
            });
            NSDictionary *fileResponse=FetchSearchFixture(replayRequest);
            NSURL *resolved=[NSURL URLWithString:fileResponse[@"data"][@"url"] ?: @""];
            Check([fileResponse[@"code"] integerValue]==200 && resolved.isFileURL &&
                  [resolved isEqual:cachedFile],@"Original parse request returns the store's published file URL through the production manager");
            Main(^{
                start((__bridge void *)receiver,(__bridge void *)resolved);
                player=CFBridgingRelease(copyPlayer((__bridge void *)receiver));
                AVAsset *asset=player.currentItem.asset;
                Check([asset isKindOfClass:AVURLAsset.class] && [((AVURLAsset *)asset).URL isEqual:cachedFile] &&
                      [adaptiveState()[@"bound"] unsignedIntegerValue]==previousBindings+1,@"The registered file URL binds to the real AVPlayerItem");
            });
            Check(Until(^BOOL{return player.currentItem.status==AVPlayerItemStatusReadyToPlay &&
                CMTimeGetSeconds(player.currentTime)>0.1;},8),@"Audio playback advances from the cached file");
            __block BOOL didSeek=NO;
            Main(^{
                [player pause];
                [player seekToTime:CMTimeMake(9,4) toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero completionHandler:^(BOOL finished){
                    dispatch_async(dispatch_get_main_queue(),^{didSeek=finished;});
                }];
            });
            Check(Until(^BOOL{return didSeek && fabs(CMTimeGetSeconds(player.currentTime)-2.25)<0.1;},5),@"Seeking reaches the requested position in the local file");
            Main(^{[player play];});
            Check(Until(^BOOL{
                secondsAfterSeek=CMTimeGetSeconds(player.currentTime);
                return player.currentItem.status==AVPlayerItemStatusReadyToPlay && secondsAfterSeek>2.45;
            },6),@"The local AVPlayer clock advances again after seeking");
            fileRequests=requestCount()-beforeFile;
            Check(fileRequests==0,@"No JS musicUrl HTTP or native origin request during local resolution, play and seek");
            localPlaylistEvidence = SmokeLocalPlaylistRoutes(manager, store, observeMetadata, replayRequest,
                                                            workerCount, requestCount, ^{
                Main(^{ selectionWillChange(receiver); });
            }, ^(NSURL *localFile) {
                Main(^{
                    NSUInteger before = [adaptiveState()[@"bound"] unsignedIntegerValue];
                    start((__bridge void *)receiver, (__bridge void *)localFile);
                    player = CFBridgingRelease(copyPlayer((__bridge void *)receiver));
                    AVAsset *asset = player.currentItem.asset;
                    Check([asset isKindOfClass:AVURLAsset.class] && [((AVURLAsset *)asset).URL isEqual:localFile] &&
                          [adaptiveState()[@"bound"] unsignedIntegerValue] == before + 1,
                          @"Each playlist selection binds the resolved local audio to a new real AVPlayerItem");
                });
                Check(Until(^BOOL{ return player.currentItem.status == AVPlayerItemStatusReadyToPlay; },8),
                      @"The real AVPlayerItem reports each local candidate ready");
            });
        } @finally {
            Main(^{if(receiver)stop((__bridge void *)receiver);configureNative(NULL,NULL);player=nil;receiver=nil;});
        }
        NSString *otherName = @"V9ReplayOther.js";
        NSURL *otherFile = [directory URLByAppendingPathComponent:otherName];
        NSString *otherScript = @"lx.on('request',()=>Promise.resolve('https://fixture.invalid/source-b'));lx.send('inited',{sources:{tx:{type:'music',actions:['musicUrl'],qualitys:['flac24bit']}}});";
        Check([otherScript writeToURL:otherFile atomically:YES encoding:NSUTF8StringEncoding error:nil], @"Write second authored source");
        @try {
            Main(^{ [manager activate:@{@"file":otherName, @"name":otherName}]; });
            Check(Until(^BOOL{return [manager.selectedFile isEqual:otherName] && manager.runtime.manifest != nil;},8), @"Source B is selected");
            Check(![store audioForKey:audioKey],@"Changing the source immediately revokes the old complete file key");
            Check([FetchSearchFixture(replayRequest)[@"data"][@"url"] isEqual:@"https://fixture.invalid/source-b"], @"Source B resolves its own URL for the identical song and quality");
            Main(^{ [manager activate:@{@"file":filename, @"name":filename}]; });
            Check(Until(^BOOL{return [manager.selectedFile isEqual:filename] && manager.runtime.manifest != nil;},8), @"Return to source A");
            NSUInteger beforeReturn = requestCount();
            Check([FetchSearchFixture(replayRequest)[@"data"][@"url"] isEqual:addressA] &&
                  requestCount() == beforeReturn + 1, @"Returning A after B requires a fresh JS address");
        } @finally { [NSFileManager.defaultManager removeItemAtURL:otherFile error:nil]; }
        return @{@"local_playlist_routing":localPlaylistEvidence, @"same_source_replay_without_js":@YES, @"source_switch_gets_own_url":@YES,
                 @"protocol_file_url_bound_to_avplayer":@YES, @"local_media_seek_seconds":@(secondsAfterSeek),
                 @"local_replay_transport_requests":@(fileRequests), @"old_complete_file_revoked_on_switch":@YES,
                 @"switching_back_resolves_again":@YES, @"scenarios":results,@"qmc_request_uses_JS":@YES,@"highest_first":@YES,@"all_qualities_attempted_once":@YES,@"unverified_quality_label":@"未知",@"native_origin_requests":@(nativeRequests),@"credential_metadata_allowlist":@YES,@"enriched_album_media_quality_metadata":@YES,@"isolated_workers":@YES,@"observed_JS_HTTP_attempts":attempts,@"observed_JS_HTTP_requests":@(requests.count-nativeRequests),@"real_network_used":@NO};
    } @finally {
        Main(^{ [manager disable]; });
        if (workerProbe) { method_setImplementation(workerMethod,previousWorker); imp_removeBlock(workerProbe); }
        method_setImplementation(sessionFactory,previousSessionFactory);imp_removeBlock(fixtureSessionFactory);
        RestoreSearchFixtureTransport();
        [NSFileManager.defaultManager removeItemAtURL:[directory URLByAppendingPathComponent:filename] error:nil];
    }
}];
}
