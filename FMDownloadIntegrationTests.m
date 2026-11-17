// Authored host delegate + real Foundation task/HTTP/file-save boundary.
// This verifies the adapter, not the original app's Swift runtime on a phone.
#import "FMDownloadIntegration.h"
#import "FMDownloadTestFixtures.inc"

@interface FMAuthoredDownloadDelegate : NSObject <NSURLSessionDownloadDelegate>
@property(nonatomic,strong) NSURL *directory;
@property(nonatomic,strong) NSOperationQueue *queue;
@property(nonatomic,strong) NSMutableDictionary *records;
@property(nonatomic,strong) NSLock *lock;
@property(nonatomic,copy) void (^onProgress)(NSURLSessionDownloadTask *);
- (NSDictionary *)record:(NSUInteger)identifier;
@end
@implementation FMAuthoredDownloadDelegate
- (instancetype)init {if((self=[super init])){_lock=NSLock.new;_records=NSMutableDictionary.new;}return self;}
- (NSDictionary *)record:(NSUInteger)identifier {[_lock lock];NSDictionary *value=[_records[@(identifier)] copy]?:@{};[_lock unlock];return value;}
- (NSMutableDictionary *)mutableRecord:(NSUInteger)identifier {NSMutableDictionary *value=_records[@(identifier)];if(!value){value=NSMutableDictionary.new;_records[@(identifier)]=value;}return value;}
- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)task didWriteData:(int64_t)bytes totalBytesWritten:(int64_t)written totalBytesExpectedToWrite:(int64_t)expected {
    [_lock lock];NSMutableDictionary *record=[self mutableRecord:task.taskIdentifier];record[@"progress"]=@([record[@"progress"] integerValue]+1);
    record[@"progressQueue"]=@(NSOperationQueue.currentQueue==self.queue);[_lock unlock];
    if(self.onProgress)self.onProgress(task);
}
- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)task didFinishDownloadingToURL:(NSURL *)location {
    NSError *error=nil;NSURL *destination=[self.directory URLByAppendingPathComponent:[NSString stringWithFormat:@"%lu.wav",(unsigned long)task.taskIdentifier]];
    BOOL valid=[NSFileManager.defaultManager fileExistsAtPath:location.path];
    BOOL moved=[NSFileManager.defaultManager moveItemAtURL:location toURL:destination error:&error];
    [_lock lock];NSMutableDictionary *record=[self mutableRecord:task.taskIdentifier];record[@"saved"]=@([record[@"saved"] integerValue]+(moved?1:0));
    record[@"registered"]=@([record[@"registered"] integerValue]+(moved?1:0));record[@"validTemporaryFile"]=@(valid);
    record[@"finishQueue"]=@(NSOperationQueue.currentQueue==self.queue);record[@"response"]=task.response?:NSNull.null;
    record[@"state"]=@(task.state);record[@"currentURL"]=task.currentRequest.URL?:NSNull.null;
    if(moved)record[@"data"]=[NSData dataWithContentsOfURL:destination];if(error)record[@"saveError"]=error;[_lock unlock];
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    [_lock lock];NSMutableDictionary *record=[self mutableRecord:task.taskIdentifier];record[@"completed"]=@([record[@"completed"] integerValue]+1);
    record[@"completionQueue"]=@(NSOperationQueue.currentQueue==self.queue);record[@"error"]=error?:NSNull.null;
    record[@"taskError"]=task.error?:NSNull.null;[_lock unlock];
}
@end
@interface FMUnrelatedDownloadDelegate : FMAuthoredDownloadDelegate @end
@implementation FMUnrelatedDownloadDelegate @end

static NSURLSession *Session(FMAuthoredDownloadDelegate *delegate,NSURL *directory) {
    [NSFileManager.defaultManager createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:nil];delegate.directory=directory;
    delegate.queue=NSOperationQueue.new;delegate.queue.maxConcurrentOperationCount=3;
    NSURLSessionConfiguration *config=NSURLSessionConfiguration.ephemeralSessionConfiguration;config.timeoutIntervalForRequest=3;config.timeoutIntervalForResource=10;
    return [NSURLSession sessionWithConfiguration:config delegate:delegate delegateQueue:delegate.queue];
}
static BOOL Finished(FMAuthoredDownloadDelegate *delegate,NSURLSessionTask *task) {return [[delegate record:task.taskIdentifier][@"completed"] integerValue]>0;}
static BOOL Saved(FMAuthoredDownloadDelegate *delegate,NSURLSessionTask *task,NSData *expected) {
    NSDictionary *record=[delegate record:task.taskIdentifier];return [record[@"saved"] integerValue]==1 && [record[@"registered"] integerValue]==1 && [record[@"completed"] integerValue]==1 && [record[@"data"] isEqual:expected] && record[@"error"]==NSNull.null;
}
static void Register(FMDownloadHTTPFixture *server,NSString *carrier,NSString *track,NSArray *qualities,NSDictionary *routes,NSMutableArray *attempts,NSUInteger *factoryCalls) {
    FMDownloadIntegrationRegisterURL([server URL:carrier],track,^FMQualityResolver *{
        if(factoryCalls)(*factoryCalls)++;return Resolver(server,qualities,routes,attempts,^BOOL{return YES;});
    },^BOOL{return YES;});
}
int main(int argc,const char *argv[]) {@autoreleasepool {
    rows=NSMutableArray.array;
    NSURL *root=[NSFileManager.defaultManager.temporaryDirectory URLByAppendingPathComponent:[@"FMNativeDownloadTests-" stringByAppendingString:NSUUID.UUID.UUIDString] isDirectory:YES];
    FMDownloadHTTPFixture *server=FMDownloadHTTPFixture.new;
    FMAuthoredDownloadDelegate *delegate=FMAuthoredDownloadDelegate.new;
    NSURLSession *session=Session(delegate,[root URLByAppendingPathComponent:@"native-library"]);
    // Existing sessions must be discovered as well as lazily created sessions.
    Check(FMDownloadIntegrationInstallForTesting(FMAuthoredDownloadDelegate.class),@"test_only_native_delegate_hooks_install");
    FMDownloadIntegrationSourceTransition();
    NSMutableArray *attempts=NSMutableArray.array;NSUInteger factoryCalls=0;
    Register(server,@"carrier-ladder.wav",@"tx:authored-1",@[@"flac",@"320k",@"128k"],@{@"flac":@"bad-native.wav",@"320k":@"interrupt-native.wav",@"128k":@"native-good.wav"},attempts,&factoryCalls);
    NSUInteger beforeRequests=server.requests;
    NSURLSessionDownloadTask *task=[session downloadTaskWithURL:[server URL:@"carrier-ladder.wav"]];NSUInteger identifier=task.taskIdentifier;
    Check(task.state==NSURLSessionTaskStateSuspended && factoryCalls==0,@"carrier_keeps_native_identity_and_stays_suspended_until_host_resumes");
    [task resume];Check(Wait(^BOOL{return Finished(delegate,task);},20),@"native_download_real_http_quality_ladder_completes");
    Check(task.taskIdentifier==identifier && Saved(delegate,task,server.audio) && factoryCalls==1 && [attempts isEqual:@[@"flac",@"320k",@"128k"]],@"real_media_adopted_and_native_library_registered_once");
    NSDictionary *record=[delegate record:identifier];
    Check([record[@"validTemporaryFile"] boolValue] && [record[@"finishQueue"] boolValue] && [record[@"completionQueue"] boolValue] && [record[@"progressQueue"] boolValue],@"callbacks_keep_original_delegate_queue_and_valid_file_lifetime");
    Check([record[@"response"] isKindOfClass:NSHTTPURLResponse.class] && [[record[@"response"] URL] isEqual:[server URL:@"native-good.wav"]] && [record[@"currentURL"] isEqual:[server URL:@"native-good.wav"]] && task.state==NSURLSessionTaskStateCompleted && !task.error,@"native_task_getters_report_final_real_response_and_terminal_state");
    Check(server.requests-beforeRequests==3,@"suspended_carrier_never_downloads_original_url");
    [task resume];[task cancel];Pump(.1);Check([[delegate record:identifier][@"completed"] integerValue]==1,@"late_carrier_cancel_and_repeated_resume_cannot_duplicate_completion");

    [attempts removeAllObjects];factoryCalls=0;
    Register(server,@"carrier-cancel.wav",@"tx:cancel",@[@"320k",@"128k"],@{@"320k":@"slow-native-cancel.wav",@"128k":@"unused-native-cancel.wav"},attempts,&factoryCalls);
    __block BOOL canceled=NO;delegate.onProgress=^(NSURLSessionDownloadTask *value){if(!canceled){canceled=YES;[value cancel];}};
    task=[session downloadTaskWithURL:[server URL:@"carrier-cancel.wav"]];[task resume];
    Check(Wait(^BOOL{return Finished(delegate,task);},10),@"native_carrier_cancel_completes");
    record=[delegate record:task.taskIdentifier];Check([record[@"error"] isKindOfClass:NSError.class] && [record[@"error"] code]==NSURLErrorCancelled && [record[@"saved"] integerValue]==0 && attempts.count==1,@"cancel_does_not_lower_quality_or_register_partial_file");delegate.onProgress=nil;

    [attempts removeAllObjects];factoryCalls=0;
    Register(server,@"carrier-pause.wav",@"tx:pause",@[@"320k",@"128k"],@{@"320k":@"slow-native-pause.wav",@"128k":@"unused-native-pause.wav"},attempts,&factoryCalls);
    __block BOOL paused=NO;delegate.onProgress=^(NSURLSessionDownloadTask *value){if(!paused){paused=YES;[value suspend];}};
    task=[session downloadTaskWithURL:[server URL:@"carrier-pause.wav"]];[task resume];
    Check(Wait(^BOOL{return paused && task.state==NSURLSessionTaskStateSuspended;},8),@"native_carrier_pause_reaches_real_download");
    Pump(.8);Check(!Finished(delegate,task) && attempts.count==1,@"paused_carrier_does_not_commit_or_consume_lower_quality");delegate.onProgress=nil;[task resume];
    Check(Wait(^BOOL{return Finished(delegate,task);},12) && Saved(delegate,task,server.audio) && attempts.count==1,@"native_carrier_resume_saves_same_quality_once");

    [attempts removeAllObjects];factoryCalls=0;
    Register(server,@"carrier-source.wav",@"tx:old-source",@[@"320k",@"128k"],@{@"320k":@"slow-native-source.wav",@"128k":@"unused-native-source.wav"},attempts,&factoryCalls);
    __block BOOL changed=NO;delegate.onProgress=^(NSURLSessionDownloadTask *value){if(!changed){changed=YES;FMDownloadIntegrationSourceTransition();}};
    task=[session downloadTaskWithURL:[server URL:@"carrier-source.wav"]];[task resume];
    Check(Wait(^BOOL{return Finished(delegate,task);},10),@"source_transition_reaches_native_completion");record=[delegate record:task.taskIdentifier];
    Check([record[@"error"] isKindOfClass:NSError.class] && [record[@"error"] code]==NSURLErrorCancelled && [record[@"saved"] integerValue]==0 && attempts.count==1,@"old_source_cannot_commit_or_retry_after_transition");delegate.onProgress=nil;

    [attempts removeAllObjects];factoryCalls=0;
    Register(server,@"carrier-queued-source.wav",@"tx:queued-old-source",@[@"128k"],@{@"128k":@"native-queued-source.wav"},attempts,&factoryCalls);
    delegate.queue.suspended=YES;
    task=[session downloadTaskWithURL:[server URL:@"carrier-queued-source.wav"]];[task resume];
    Check(Wait(^BOOL{return task.state==NSURLSessionTaskStateCompleted;},10) && !Finished(delegate,task),@"real_download_completion_can_wait_for_original_delegate_queue");
    FMDownloadIntegrationSourceTransition();delegate.queue.suspended=NO;
    Check(Wait(^BOOL{return Finished(delegate,task);},10),@"queued_native_completion_finishes_after_source_transition");record=[delegate record:task.taskIdentifier];
    Check([record[@"error"] isKindOfClass:NSError.class] && [record[@"error"] code]==NSURLErrorCancelled && [record[@"saved"] integerValue]==0 && [record[@"completed"] integerValue]==1,@"source_change_after_transfer_before_delegate_delivery_never_saves_stale_media");

    NSMutableArray *firstAttempts=NSMutableArray.array,*secondAttempts=NSMutableArray.array;NSUInteger firstFactory=0,secondFactory=0;
    Register(server,@"carrier-a.wav",@"tx:parallel-a",@[@"flac",@"128k"],@{@"flac":@"bad-parallel-native.wav",@"128k":@"shared-parallel-native.wav"},firstAttempts,&firstFactory);
    Register(server,@"carrier-b.wav",@"tx:parallel-b",@[@"flac",@"128k"],@{@"flac":@"shared-parallel-native.wav",@"128k":@"unused-parallel-native.wav"},secondAttempts,&secondFactory);
    NSURLSessionDownloadTask *first=[session downloadTaskWithURL:[server URL:@"carrier-a.wav"]],*second=[session downloadTaskWithURL:[server URL:@"carrier-b.wav"]];[first resume];[second resume];
    Check(Wait(^BOOL{return Finished(delegate,first)&&Finished(delegate,second);},20) && Saved(delegate,first,server.audio) && Saved(delegate,second,server.audio) && first.taskIdentifier!=second.taskIdentifier && firstFactory==1 && secondFactory==1 && firstAttempts.count==2 && secondAttempts.count==1,@"parallel_native_downloads_isolate_sessions_identifiers_and_registration");

    [attempts removeAllObjects];factoryCalls=0;
    Register(server,@"ambiguous-native.wav",@"tx:ambiguous-a",@[@"128k"],@{@"128k":@"unused-ambiguous.wav"},attempts,&factoryCalls);
    Register(server,@"ambiguous-native.wav",@"tx:ambiguous-b",@[@"128k"],@{@"128k":@"unused-ambiguous.wav"},attempts,&factoryCalls);
    task=[session downloadTaskWithURL:[server URL:@"ambiguous-native.wav"]];[task resume];
    Check(Wait(^BOOL{return Finished(delegate,task);},10) && Saved(delegate,task,server.audio) && factoryCalls==0,@"cross_track_url_collision_fails_closed_without_claiming_native_download");

    FMUnrelatedDownloadDelegate *other=FMUnrelatedDownloadDelegate.new;NSURLSession *unrelated=Session(other,[root URLByAppendingPathComponent:@"unrelated-library"]);
    Register(server,@"unrelated-native.wav",@"tx:unrelated",@[@"128k"],@{@"128k":@"unused-unrelated.wav"},attempts,&factoryCalls);
    NSURLSessionDownloadTask *unrelatedTask=[unrelated downloadTaskWithURL:[server URL:@"unrelated-native.wav"]];[unrelatedTask resume];
    Check(Wait(^BOOL{return Finished(other,unrelatedTask);},10) && Saved(other,unrelatedTask,server.audio) && factoryCalls==0,@"other_delegate_downloads_are_never_owned_even_with_registered_url");
    __block BOOL completionVariantDone=NO;__block BOOL completionVariantValid=NO;
    Register(server,@"completion-native.wav",@"tx:completion",@[@"128k"],@{@"128k":@"unused-completion.wav"},attempts,&factoryCalls);
    NSURLSessionDownloadTask *completionVariant=[session downloadTaskWithURL:[server URL:@"completion-native.wav"] completionHandler:^(NSURL *file,NSURLResponse *response,NSError *error){completionVariantValid=!error && [[NSData dataWithContentsOfURL:file] isEqual:server.audio];completionVariantDone=YES;}];[completionVariant resume];
    Check(Wait(^BOOL{return completionVariantDone;},10) && completionVariantValid && factoryCalls==0,@"completion_handler_and_artwork_download_variant_remains_native");

    for(NSUInteger i=0;i<100;i++)Register(server,[NSString stringWithFormat:@"bounded-%lu.wav",(unsigned long)i],[NSString stringWithFormat:@"tx:bounded-%lu",(unsigned long)i],@[@"128k"],@{@"128k":@"unused-bounded.wav"},attempts,NULL);
    Check([FMDownloadIntegrationDiagnostics()[@"registrations"] integerValue]<=64,@"url_registration_cache_is_bounded");
    Check(Wait(^BOOL{return [FMDownloadIntegrationDiagnostics()[@"active"] integerValue]==0;},5),@"completed_bindings_release_task_session_and_delegate_ownership");
    __block BOOL inspectedCarrierTasks=NO;__block NSUInteger carrierTasks=NSUIntegerMax;
    [session getAllTasksWithCompletionHandler:^(NSArray<NSURLSessionTask *> *tasks){carrierTasks=tasks.count;inspectedCarrierTasks=YES;}];
    Check(Wait(^BOOL{return inspectedCarrierTasks;},5) && carrierTasks==0,@"foundation_releases_suspended_carriers_after_terminal_cleanup");
    NSDictionary *diagnostics=FMDownloadIntegrationDiagnostics();
    NSDictionary *report=@{@"passed":@(failures==0),@"failures":@(failures),@"cases":rows,@"counters":diagnostics,@"evidence":@{@"real_http_requests":@(server.requests),@"real_foundation_download_tasks":@YES,@"host_delegate_is_authored_fixture":@YES,@"original_app_runtime_verified":@NO,@"external_network_used":@NO}};
    if(argc>1)[[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:nil] writeToFile:[NSString stringWithUTF8String:argv[1]] atomically:YES];
    [session invalidateAndCancel];[unrelated invalidateAndCancel];[server stop];[NSFileManager.defaultManager removeItemAtURL:root error:nil];
    printf("%s native download integration (%lu checks)\n",failures?"FAILED":"DONE",(unsigned long)rows.count);return failures?1:0;
}}
