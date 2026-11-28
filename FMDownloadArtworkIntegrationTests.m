#import "FMDownloadArtworkIntegration.h"
#import "FMDownloadArtwork.h"
#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>

static NSMutableArray *checks;
static NSMutableArray<NSString *> *requests;
static NSData *fixturePNG;
static BOOL offline;
static void Check(BOOL ok,NSString *name) {
    if(!ok){NSLog(@"FAILED %@",name);exit(1);}
    [checks addObject:name];
}
static NSUInteger CountRequests(void) { @synchronized(requests){return requests.count;} }
static BOOL Saw(NSString *suffix) { @synchronized(requests){for(NSString *path in requests)if([path hasSuffix:suffix])return YES;return NO;} }
static BOOL Wait(BOOL(^done)(void),NSTimeInterval seconds) {
    NSDate *end=[NSDate dateWithTimeIntervalSinceNow:seconds];
    while(!done() && end.timeIntervalSinceNow>0)[NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
    return done();
}
@interface FMDANetworkFixture : NSURLProtocol @end
@implementation FMDANetworkFixture
+ (BOOL)canInitWithRequest:(NSURLRequest *)request {return YES;}
+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request {return request;}
- (void)startLoading {
    NSString *path=self.request.URL.path ?: @"";
    BOOL blocked;
    @synchronized(requests){[requests addObject:path];blocked=offline;}
    if(blocked){[self.client URLProtocol:self didFailWithError:[NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorNotConnectedToInternet userInfo:nil]];return;}
    void (^reply)(void)=^{
        NSHTTPURLResponse *response=[[NSHTTPURLResponse alloc]initWithURL:self.request.URL statusCode:200 HTTPVersion:@"HTTP/1.1"
            headerFields:@{@"Content-Type":@"image/jpg",@"Content-Length":[@(fixturePNG.length) stringValue]}];
        [self.client URLProtocol:self didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageNotAllowed];
        [self.client URLProtocol:self didLoadData:fixturePNG];[self.client URLProtocolDidFinishLoading:self];
    };
    if([path hasSuffix:@"/disappear.jpg"])dispatch_after(dispatch_time(DISPATCH_TIME_NOW,1*NSEC_PER_SEC),dispatch_get_global_queue(QOS_CLASS_DEFAULT,0),reply);
    else reply();
}
- (void)stopLoading {}
@end
static NSData *Picture(void) {
    CGColorSpaceRef space=CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx=CGBitmapContextCreate(NULL,48,32,8,0,space,kCGImageAlphaNoneSkipLast);
    CGContextSetRGBFillColor(ctx,0.2,0.7,0.35,1);CGContextFillRect(ctx,CGRectMake(0,0,48,32));
    CGImageRef image=CGBitmapContextCreateImage(ctx);NSMutableData *data=NSMutableData.data;
    CGImageDestinationRef out=CGImageDestinationCreateWithData((__bridge CFMutableDataRef)data,CFSTR("public.png"),1,NULL);
    CGImageDestinationAddImage(out,image,NULL);BOOL success=CGImageDestinationFinalize(out);
    CGImageRelease(image);CGContextRelease(ctx);CGColorSpaceRelease(space);CFRelease(out);
    return success ? data : nil;
}
static NSData *Wave(void) {
    // 100 ms of 8 kHz, mono, signed 16-bit PCM silence.
    unsigned char header[44]={'R','I','F','F',0x64,0x06,0,0,'W','A','V','E','f','m','t',' ',16,0,0,0,1,0,1,0,
        0x40,0x1f,0,0,0x80,0x3e,0,0,2,0,16,0,'d','a','t','a',0x40,0x06,0,0};
    NSMutableData *data=[NSMutableData dataWithBytes:header length:44];[data increaseLengthBy:1600];return data;
}
static NSDictionary *Track(NSString *server,NSString *identifier,NSString *name) {
    NSString *host=[server isEqual:@"qq"]?@"y.qq.com":@"p3.music.126.net";
    return @{@"server":server,@"id":identifier,@"title":@"Authored test track",@"singer":@"Author",
             @"cover":[NSString stringWithFormat:@"https://%@/fixtures/%@.jpg",host,name]};
}
static NSURL *Child(NSURL *root,NSString *name){return [root URLByAppendingPathComponent:name];}
static NSData *WriteIndex(NSArray *rows,NSURL *URL){
    NSData *data=[NSJSONSerialization dataWithJSONObject:rows options:NSJSONWritingSortedKeys error:nil];
    if(![data writeToURL:URL options:NSDataWritingAtomic error:nil])abort();return data;
}
int main(int argc,const char *argv[]) { @autoreleasepool {
    checks=NSMutableArray.array;requests=NSMutableArray.array;fixturePNG=Picture();
    NSURL *root=Child([NSURL fileURLWithPath:NSTemporaryDirectory() isDirectory:YES],NSUUID.UUID.UUIDString);
    NSURL *support=Child(root,@"Library/Application Support"),*documents=Child(root,@"Documents");
    NSURL *downloads=Child(documents,@"Downloads"),*assets=Child(support,@"DownloadAssets"),*index=Child(support,@"downloaded_tracks.json");
    NSFileManager *files=NSFileManager.defaultManager;
    for(NSURL *dir in @[downloads,assets])[files createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:nil error:nil];
    NSData *wave=Wave();
    NSMutableArray *rows=NSMutableArray.array;
    for(NSUInteger i=100;i<138;i++){
        NSString *identifier=[@(i) stringValue];[rows addObject:Track(@"wy",identifier,identifier)];
        [wave writeToURL:Child(downloads,[NSString stringWithFormat:@"wy_%@.wav",identifier]) atomically:YES];
    }
    [rows addObject:Track(@"qq",@"100",@"original-qq")];[wave writeToURL:Child(downloads,@"qq_100.wav") atomically:YES];
    NSURL *keep=Child(assets,@"qq_100_cover.jpg");
    [fixturePNG writeToURL:keep atomically:YES];
    [NSData.data writeToURL:Child(assets,@"wy_101_cover.jpg") atomically:YES];
    [rows addObject:Track(@"wy",@"140",@"unregistered-file")]; // No audio for this row.
    [wave writeToURL:Child(downloads,@"wy_141.wav") atomically:YES]; // No native row for this file.
    NSData *originalIndex=WriteIndex(rows,index);
    NSURLSessionConfiguration *configuration=NSURLSessionConfiguration.ephemeralSessionConfiguration;
    configuration.protocolClasses=@[FMDANetworkFixture.class];
    FMDownloadArtwork *store=[[FMDownloadArtwork alloc]initWithDirectory:Child(support,@"TestArtwork") downloads:downloads configuration:configuration];
    FMDownloadArtworkIntegration *integration=[[FMDownloadArtworkIntegration alloc]initWithSupport:support documents:documents store:store];
    [integration start];[integration refresh];
    Check(Wait(^BOOL{
        if (![files fileExistsAtPath:Child(assets,@"wy_100_cover.jpg").path]) return NO;
        for(NSUInteger i=100;i<138;i++)
            if(![FMDownloadArtwork isUsableJPEGAtURL:Child(assets,[NSString stringWithFormat:@"wy_%lu_cover.jpg",(unsigned long)i])])return NO;
        return YES;
    },45),@"historical_native_rows_beyond_32_drained");
    BOOL good=YES;
    for(NSUInteger i=100;i<138;i++)good &= [FMDownloadArtwork isUsableJPEGAtURL:Child(assets,[NSString stringWithFormat:@"wy_%lu_cover.jpg",(unsigned long)i])];
    Check(good,@"all_38_new_sidecars_are_complete_decodable_jpegs_including_corrupt_prior");
    Check([[NSData dataWithContentsOfURL:keep] isEqual:fixturePNG] && !Saw(@"original-qq.jpg"),@"same_id_native_qq_png_retained_byte_for_byte");
    Check(CountRequests()==38 && !Saw(@"unregistered-file.jpg") && ![files fileExistsAtPath:Child(assets,@"wy_141_cover.jpg").path],@"missing_audio_or_missing_registration_skipped");
    Check([[NSData dataWithContentsOfURL:index] isEqual:originalIndex],@"original_native_library_json_never_rewritten");
    [rows addObject:Track(@"wy",@"142",@"new")];[wave writeToURL:Child(downloads,@"wy_142.wav") atomically:YES];
    WriteIndex(rows,index); // Force native-style atomic replacement, without another refresh.
    Check(Wait(^BOOL{return [FMDownloadArtwork isUsableJPEGAtURL:Child(assets,@"wy_142_cover.jpg")];},10),@"new_download_observed_after_native_atomic_index_replacement");
    [rows addObject:Track(@"wy",@"143",@"disappear")];[wave writeToURL:Child(downloads,@"wy_143.wav") atomically:YES];
    WriteIndex(rows,index);
    Check(Wait(^BOOL{return Saw(@"/disappear.jpg");},10),@"late_reply_started_for_registered_audio");
    [rows removeLastObject];WriteIndex(rows,index);[files removeItemAtURL:Child(downloads,@"wy_143.wav") error:nil];
    [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:1.6]];
    Check(![files fileExistsAtPath:Child(assets,@"wy_143_cover.jpg").path],@"removed_track_never_resurrected_by_late_result");
    @synchronized(requests){offline=YES;}
    NSUInteger before=CountRequests();
    [integration refresh];[integration refresh];[integration refresh];
    [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.7]];
    NSUInteger offlineAdditional=CountRequests()-before;
    Check(offlineAdditional==0 && [FMDownloadArtwork isUsableJPEGAtURL:Child(assets,@"wy_100_cover.jpg")],
          @"repeat_refresh_offline_no_network_same_native_list_and_player_sidecar");
    // Use the original three MusicFileStorage directories and both index URLs.
    // These are authored files. No device data is needed for the filesystem race.
    NSURL *legacyRoot=Child(root,@"fresh-install");
    NSURL *support2=Child(legacyRoot,@"Library/Application Support"),*documents2=Child(legacyRoot,@"Documents");
    NSURL *docs2=Child(documents2,@"Downloads"),*assets2=Child(support2,@"DownloadAssets");
    NSURL *caches2=Child(legacyRoot,@"Library/Caches"),*music2=Child(caches2,@"MusicCache");
    NSURL *oldIndex=Child(caches2,@"downloaded_tracks.json"),*newIndex=Child(support2,@"downloaded_tracks.json");
    for(NSURL *dir in @[docs2,assets2,music2])Check([files createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:nil error:nil],@"legacy_fixture_directory");
    NSData *bad=[@"broken-first-slot" dataUsingEncoding:NSUTF8StringEncoding];
    NSURL *first=Child(docs2,@"wy_201_cover.jpg"),*last=Child(music2,@"wy_201_cover.jpg");
    [bad writeToURL:first atomically:YES];[fixturePNG writeToURL:last atomically:YES];
    [wave writeToURL:Child(music2,@"wy_201.wav") atomically:YES];
    NSData *caf=[[NSData alloc]initWithBase64EncodedString:@"Y2FmZgABAABkZXNjAAAAAAAAACBAv0AAAAAAAGxwY20AAAACAAAAAgAAAAEAAAABAAAAEGNoYW4AAAAAAAAADABkAAEAAAAAAAAAAGRhdGEAAAAAAAAAVAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA==" options:0];
    [caf writeToURL:Child(assets2,@"wy_202_playback.caf") atomically:YES];
    [fixturePNG writeToURL:Child(music2,@"wy_202_cover.jpg") atomically:YES];
    NSMutableDictionary *stale=[Track(@"wy",@"201",@"old") mutableCopy];
    stale[@"cover"]=@"file:///private/OLD-APP-COMMON/Documents/Downloads/wy_201_cover.jpg";
    NSMutableArray *legacyRows=[@[stale,Track(@"wy",@"202",@"cached"),Track(@"wy",@"203",@"late-file")] mutableCopy];
    NSData *oldBytes=WriteIndex(legacyRows,oldIndex);
    FMDownloadArtwork *legacyStore=[[FMDownloadArtwork alloc]initWithDirectory:Child(support2,@"FMDownloadArtwork-v1") downloads:docs2 configuration:configuration];
    FMDownloadArtworkIntegration *legacyIntegration=[[FMDownloadArtworkIntegration alloc]initWithSupport:support2 documents:documents2 store:legacyStore];
    NSMutableDictionary *delivered=NSMutableDictionary.dictionary; __block BOOL mainOnly=YES;
    id observer=[NSNotificationCenter.defaultCenter addObserverForName:FMDownloadArtworkDidRecoverNotification object:nil queue:nil
        usingBlock:^(NSNotification *note){
            mainOnly &= NSThread.isMainThread;
            NSString *key=note.userInfo[@"trackKey"];
            if(key)delivered[key]=note.userInfo;
        }];
    [legacyIntegration start];
    Check(Wait(^BOOL{return delivered[@"wy_201"] && delivered[@"wy_202"] && [legacyIntegration.status[@"wyMissingAudio"] integerValue]==1;},10),@"legacy_index_discovered_without_primary_and_status_counts_missing_audio");
    Check([[NSData dataWithContentsOfURL:first] isEqual:fixturePNG] && [[NSData dataWithContentsOfURL:last] isEqual:fixturePNG],@"nonempty_corrupt_first_candidate_repaired_offline_from_exact_legacy_cache_good_copy_preserved");
    Check([[NSData dataWithContentsOfURL:Child(assets2,@"wy_202_cover.jpg")] isEqual:fixturePNG],@"legacy_cache_only_picture_saved_to_permanent_native_folder_for_registered_decoded_caf");
    NSDictionary *event=delivered[@"wy_201"];
    Check(mainOnly && [event[@"server"] isEqual:@"wy"] && [event[@"id"] isEqual:@"201"] &&
          [event[@"coverURL"] isEqual:first] && [event[@"expectedCover"] isEqual:stale[@"cover"]],@"main_thread_refresh_supplies_current_container_url_and_expected_original_index_cover");
    Check([[NSData dataWithContentsOfURL:oldIndex] isEqual:oldBytes] && ![files fileExistsAtPath:newIndex.path] &&
          [[NSData dataWithContentsOfURL:Child(music2,@"wy_201.wav")] isEqual:wave] && CountRequests()==before,@"offline_recovery_never_rewrites_either_index_or_audio");
    [fixturePNG writeToURL:Child(music2,@"wy_203_cover.jpg") atomically:YES];
    [wave writeToURL:Child(music2,@"wy_203.wav") atomically:YES];
    Check(Wait(^BOOL{return delivered[@"wy_203"] && [legacyIntegration.status[@"wyUsable"] integerValue]==3;},10),@"metadata_before_audio_rescanned_when_only_legacy_audio_directory_changes");
    Check([legacyIntegration.status[@"wyRegistered"] integerValue]==3 &&
          [legacyIntegration.status[@"wyMissingAudio"] integerValue]==0 && [legacyIntegration.status[@"wyPending"] integerValue]==0,@"disjoint_private_status_counts_after_recovery");
    // The real loader decodes the legacy index only when the new file is absent.
    // A valid empty list, a malformed current file, and in-flight deletion are
    // deliberately distinct. Do not resurrect an old registered song.
    WriteIndex(@[],newIndex);
    Check(Wait(^BOOL{return [legacyIntegration.status[@"scanned"] boolValue] && [legacyIntegration.status[@"wyRegistered"] integerValue]==0;},10),@"empty_primary_index_supersedes_nonempty_legacy_without_merging_deleted_tracks");
    [files removeItemAtURL:first error:nil];
    [bad writeToURL:newIndex atomically:YES];
    [legacyIntegration refresh];
    Check(Wait(^BOOL{return ![legacyIntegration.status[@"scanned"] boolValue];},10) &&
          ![files fileExistsAtPath:first.path],@"malformed_primary_never_falls_back_to_stale_legacy_list");
    NSURL *newFile=Child(music2,@"wy_207.aifc");
    NSData *aifc=[[NSData alloc]initWithBase64EncodedString:@"Rk9STQAAAJBBSUZDRlZFUgAAAASigFFAQ09NTQAAABgAAQAAACgAEEAL+gAAAAAAAABzb3d0AABTU05EAAAAWAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=" options:0];
    [aifc writeToURL:newFile atomically:YES];
    @synchronized(requests){offline=NO;}
    WriteIndex(@[Track(@"wy",@"207",@"new-legacy-root")],newIndex);
    Check(Wait(^BOOL{return [FMDownloadArtwork isUsableJPEGAtURL:Child(assets2,@"wy_207_cover.jpg")];},10) &&
          Saw(@"/new-legacy-root.jpg"),@"registered_original_extension_can_fetch_art_when_audio_only_in_legacy_root");
    Check(![files fileExistsAtPath:first.path] && [[NSData dataWithContentsOfURL:oldIndex] isEqual:oldBytes],@"primary_and_legacy_conflict_never_restores_removed_legacy_song");
    NSMutableData *overBudget=[fixturePNG mutableCopy];[overBudget increaseLengthBy:8*1024*1024];
    NSURL *uninspected=Child(docs2,@"wy_208_cover.jpg");
    [overBudget writeToURL:uninspected atomically:YES];[wave writeToURL:Child(docs2,@"wy_208.wav") atomically:YES];
    [fixturePNG writeToURL:Child(music2,@"wy_208_cover.jpg") atomically:YES];
    WriteIndex(@[Track(@"wy",@"208",@"above-budget")],newIndex);
    Check(Wait(^BOOL{return [legacyIntegration.status[@"wyFailed"] integerValue]==1;},10) &&
          [[NSData dataWithContentsOfURL:uninspected] isEqual:overBudget],@"uninspected_large_original_is_preserved_and_reported_without_overwrite");
    [NSNotificationCenter.defaultCenter removeObserver:observer];
    NSDictionary *report=@{@"passed":@YES,@"checks":checks,@"evidence":@{@"historical_rows_repaired":@38,
            @"native_existing_png_preserved":@YES,@"native_index_replacement_observed":@YES,
            @"unchanged_index_during_repair":@YES,@"offline_additional_requests":@(offlineAdditional),@"native_cover_locations":@3,
            @"legacy_index_primary_precedence":@YES,@"registered_legacy_audio_allowed":@YES,
            @"earlier_corrupt_cover_repaired":@YES,@"main_queue_refresh":@YES,@"late_audio_observed":@YES}};
    if(argc>1){NSData *json=[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:nil];
        if(![json writeToFile:[NSString stringWithUTF8String:argv[1]] atomically:YES])return 1;}
    [files removeItemAtURL:root error:nil];printf("DONE download artwork registration and sidecar tests\n");return 0;
} }
