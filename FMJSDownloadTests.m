#import "FMDownloadTestFixtures.inc"

int main(int argc,const char *argv[]) { @autoreleasepool {
    rows=NSMutableArray.array;
    NSURL *root=[[NSURL fileURLWithPath:NSTemporaryDirectory() isDirectory:YES] URLByAppendingPathComponent:[@"FMJSDownloadTests-" stringByAppendingString:NSUUID.UUID.UUIDString] isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:root withIntermediateDirectories:YES attributes:nil error:nil];
    FMDownloadHTTPFixture *server=FMDownloadHTTPFixture.new;
    NSArray *qualities=@[@"flac24bit",@"flac",@"320k",@"128k"];
    NSMutableArray *attempts=NSMutableArray.array;__block NSUInteger callbacks=0;__block NSError *lastError=nil;__block NSString *actualQuality=nil;__block NSData *saved=nil;__block NSURL *temporary=nil;
    FMJSDownloadCompletion collect=^(NSURL *file,NSHTTPURLResponse *response,NSString *quality,NSError *error){
        ++callbacks;lastError=error;actualQuality=quality;temporary=file;saved=file?[NSData dataWithContentsOfURL:file]:nil;
    };
    FMJSDownloadCoordinator *download=Download(Resolver(server,qualities,@{@"flac24bit":@"missing.wav",@"flac":@"bad.wav",@"320k":@"interrupt.wav",@"128k":@"good.wav"},attempts,^BOOL{return YES;}),root,^BOOL{return YES;});
    [download startWithProgress:nil completion:collect];
    Check(Wait(^BOOL{return callbacks==1;},20),@"real_http_ladder_finishes");
    NSDictionary *ladder=download.diagnostics;
    Check(!lastError && [saved isEqual:server.audio] && [actualQuality isEqual:@"128k"] && [attempts isEqual:qualities],@"404_invalid_audio_interrupted_transfer_then_valid_lower_file");
    Check([ladder[@"attempts"] integerValue]==4 && [ladder[@"transfer_failures"] integerValue]>=1 && [ladder[@"validation_failures"] integerValue]>=2 && [ladder[@"successes"] integerValue]==1,@"production_counters_confirm_real_transfer_and_decode_failures");
    Check(![NSFileManager.defaultManager fileExistsAtPath:temporary.path] && Empty(root),@"successful_callback_file_and_failed_candidates_are_cleaned");
    [download cancel];[download resume];Pump(.04);Check(callbacks==1,@"completed_download_ignores_cancel_resume_and_finishes_once");

    callbacks=0;saved=nil;[attempts removeAllObjects];
    download=Download(Resolver(server,@[@"flac",@"128k"],@{@"flac":@"short.wav",@"128k":@"good2.wav"},attempts,^BOOL{return YES;}),root,^BOOL{return YES;});
    [download startWithProgress:nil completion:collect];
    Check(Wait(^BOOL{return callbacks==1;},12) && !lastError && [saved isEqual:server.audio] && [download.diagnostics[@"validation_failures"] integerValue]==1,@"accurate_http_length_but_truncated_wav_container_retries_lower");

    callbacks=0;saved=nil;[attempts removeAllObjects];
    download=Download(Resolver(server,@[@"320k",@"128k"],@{@"320k":@"html.wav",@"128k":@"good3.wav"},attempts,^BOOL{return YES;}),root,^BOOL{return YES;});
    [download startWithProgress:nil completion:collect];
    Check(Wait(^BOOL{return callbacks==1;},12) && !lastError && [saved isEqual:server.audio] && [actualQuality isEqual:@"128k"],@"html_success_status_is_not_saved_as_audio");

    callbacks=0;saved=nil;[attempts removeAllObjects];
    download=Download(Resolver(server,@[@"flac",@"320k",@"128k"],@{@"flac":@"bad-same.wav",@"320k":@"bad-same.wav",@"128k":@"good4.wav"},attempts,^BOOL{return YES;}),root,^BOOL{return YES;});
    [download startWithProgress:nil completion:collect];
    Check(Wait(^BOOL{return callbacks==1;},12) && !lastError && attempts.count==3 && [download.diagnostics[@"attempts"] integerValue]==2,@"duplicate_failed_url_is_not_downloaded_twice");

    callbacks=0;saved=nil;[attempts removeAllObjects];
    download=Download(Resolver(server,qualities,@{@"flac24bit":@"missing2.wav",@"flac":@"html2.wav",@"320k":@"bad2.wav",@"128k":@"short2.wav"},attempts,^BOOL{return YES;}),root,^BOOL{return YES;});
    [download startWithProgress:nil completion:collect];
    Check(Wait(^BOOL{return callbacks==1;},20) && lastError && !saved && attempts.count==4 && Empty(root),@"all_quality_failures_finish_once_without_partial_file");
    [download cancel];Pump(.04);Check(callbacks==1,@"exhaustion_callback_is_not_duplicated");

    callbacks=0;saved=nil;[attempts removeAllObjects];__block FMJSDownloadCoordinator *active=nil;
    active=Download(Resolver(server,@[@"320k",@"128k"],@{@"320k":@"slow-cancel.wav",@"128k":@"good-cancel.wav"},attempts,^BOOL{return YES;}),root,^BOOL{return YES;});
    [active startWithProgress:^(int64_t bytes,int64_t total,NSString *q){if(bytes>0)[active cancel];} completion:collect];
    Check(Wait(^BOOL{return callbacks==1;},8) && lastError.code==NSURLErrorCancelled && attempts.count==1 && !saved && Empty(root),@"real_transfer_cancel_stops_without_lower_quality_or_file");
    Pump(.1);Check(callbacks==1,@"late_transfer_completion_after_cancel_is_ignored");

    callbacks=0;saved=nil;[attempts removeAllObjects];__block BOOL current=YES;
    active=Download(Resolver(server,@[@"320k",@"128k"],@{@"320k":@"slow-source.wav",@"128k":@"good-source.wav"},attempts,^BOOL{return current;}),root,^BOOL{return current;});
    [active startWithProgress:^(int64_t bytes,int64_t total,NSString *q){if(bytes>0)current=NO;} completion:collect];
    Check(Wait(^BOOL{return callbacks==1;},8) && lastError.code==NSURLErrorCancelled && attempts.count==1 && !saved && Empty(root),@"source_change_cancels_real_transfer_and_cannot_commit_old_source");

    callbacks=0;saved=nil;[attempts removeAllObjects];__block BOOL paused=NO;
    active=Download(Resolver(server,@[@"320k",@"128k"],@{@"320k":@"slow-pause.wav",@"128k":@"good-pause.wav"},attempts,^BOOL{return YES;}),root,^BOOL{return YES;});
    [active startWithProgress:^(int64_t bytes,int64_t total,NSString *q){if(bytes>0&&!paused){paused=YES;[active suspend];[active suspend];}} completion:collect];
    Check(Wait(^BOOL{return paused;},8),@"real_download_can_suspend_after_received_bytes");
    Pump(.8);Check(callbacks==0 && attempts.count==1,@"suspended_download_does_not_commit_or_consume_lower_quality");
    [active resume];
    Check(Wait(^BOOL{return callbacks==1;},12) && !lastError && [saved isEqual:server.audio] && [actualQuality isEqual:@"320k"] && attempts.count==1,@"resume_finishes_same_quality_with_complete_original_bytes");

    __block NSUInteger parallelCallbacks=0;__block NSData *firstData=nil,*secondData=nil;__block NSError *parallelError=nil;
    NSUInteger beforeParallel=server.requests;
    NSMutableArray *a=NSMutableArray.array,*b=NSMutableArray.array;
    FMJSDownloadCoordinator *first=Download(Resolver(server,@[@"flac",@"128k"],@{@"flac":@"bad-parallel.wav",@"128k":@"shared.wav"},a,^BOOL{return YES;}),root,^BOOL{return YES;});
    FMJSDownloadCoordinator *second=Download(Resolver(server,@[@"flac",@"128k"],@{@"flac":@"shared.wav",@"128k":@"unused.wav"},b,^BOOL{return YES;}),root,^BOOL{return YES;});
    [first startWithProgress:nil completion:^(NSURL *file,NSHTTPURLResponse *r,NSString *q,NSError *e){++parallelCallbacks;firstData=file?[NSData dataWithContentsOfURL:file]:nil;if(e)parallelError=e;}];
    [second startWithProgress:nil completion:^(NSURL *file,NSHTTPURLResponse *r,NSString *q,NSError *e){++parallelCallbacks;secondData=file?[NSData dataWithContentsOfURL:file]:nil;if(e)parallelError=e;}];
    Check(Wait(^BOOL{return parallelCallbacks==2;},16) && !parallelError && [firstData isEqual:server.audio] && [secondData isEqual:server.audio] && a.count==2 && b.count==1 && Empty(root),@"same_url_concurrent_downloads_have_independent_quality_sessions_and_files");
    Check(server.requests-beforeParallel==3,@"same_url_downloads_reach_server_instead_of_reusing_automatic_cache");

    callbacks=0;[attempts removeAllObjects];
    download=Download(Resolver(server,@[@"128k"],@{@"128k":@"adopt.wav"},attempts,^BOOL{return YES;}),root,^BOOL{return YES;});
    NSURL *adopted=[root URLByAppendingPathComponent:@"host-saved.wav"];
    [download startWithProgress:nil completion:^(NSURL *file,NSHTTPURLResponse *response,NSString *quality,NSError *error){
        ++callbacks;lastError=error;
        if(file)[NSFileManager.defaultManager moveItemAtURL:file toURL:adopted error:&lastError];
    }];
    Check(Wait(^BOOL{return callbacks==1;},12) && !lastError && [[NSData dataWithContentsOfURL:adopted] isEqual:server.audio],@"host_can_synchronously_adopt_success_without_duplicate_registration");
    [NSFileManager.defaultManager removeItemAtURL:adopted error:nil];
    Check(Empty(root),@"all_operation_temporary_files_cleaned");
    NSDictionary *report=@{@"passed":@(failures==0),@"failures":@(failures),@"cases":rows,
        @"evidence":@{@"external_network_used":@NO,@"original_app_runtime_verified":@NO,@"real_http_requests":@(server.requests),
            @"actual_decode_validation":@YES,@"synthetic_download_completions":@NO,@"same_url_independent_sessions":@YES,@"ladder":ladder}};
    if(argc>1){NSData *json=[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:nil];[json writeToFile:[NSString stringWithUTF8String:argv[1]] atomically:YES];}
    [server stop];[NSFileManager.defaultManager removeItemAtURL:root error:nil];
    printf("%s FMJSDownload real HTTP tests (%lu checks)\n",failures?"FAILED":"DONE",(unsigned long)rows.count);
    return failures?1:0;
} }
