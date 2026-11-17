#import "FMJSDownloadCoordinator.h"
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <math.h>
#import <stdio.h>
#import <string.h>
#import <objc/runtime.h>

NSString * const FMJSDownloadErrorDomain = @"FMJSDownload";
static const uint64_t FMJSMaximumFileBytes = 1024ULL * 1024ULL * 1024ULL;
static void FMJDMain(dispatch_block_t block) { if (NSThread.isMainThread) block(); else dispatch_async(dispatch_get_main_queue(), block); }
static NSError *FMJDError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:FMJSDownloadErrorDomain code:code userInfo:@{NSLocalizedDescriptionKey:message}];
}
static NSError *FMJDCancelled(void) { return [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorCancelled userInfo:nil]; }
static NSError *FMJDValidationError(NSError *error,NSString *stage) {
    error=error ?: FMJDError(FMJSDownloadInvalidAudio,@"Audio validation failed");
    NSMutableDictionary *info=[error.userInfo mutableCopy] ?: NSMutableDictionary.dictionary;
    info[@"FMJSValidationStage"]=stage;
    return [NSError errorWithDomain:error.domain code:error.code userInfo:info];
}
static NSString *FMJDHeader(NSHTTPURLResponse *response,NSString *name) {
    for(id key in response.allHeaderFields) if([[key description] caseInsensitiveCompare:name]==NSOrderedSame) return [response.allHeaderFields[key] description];
    return nil;
}

/// Validation really reads decoded audio from the completed local file. It does
/// not trust the extension, MIME type or source's requested quality label.
@interface FMJSDownloadValidation : NSObject
- (void)validate:(NSURL *)file completion:(void (^)(NSError *))completion;
- (void)cancel;
@end
@implementation FMJSDownloadValidation {
    NSLock *_lock;
    BOOL _cancelled;
    AVURLAsset *_asset;
    AVAssetReader *_reader;
}
- (instancetype)init { if((self=[super init]))_lock=[NSLock new];return self; }
- (BOOL)isCancelled { [_lock lock];BOOL value=_cancelled;[_lock unlock];return value; }
- (void)cancel {
    [_lock lock];_cancelled=YES;AVAssetReader *reader=_reader;AVURLAsset *asset=_asset;[_lock unlock];
    [asset cancelLoading];[reader cancelReading];
}
- (void)validate:(NSURL *)file completion:(void (^)(NSError *))completion {
    AVURLAsset *asset=[AVURLAsset URLAssetWithURL:file options:nil];
    [_lock lock];_asset=asset;BOOL cancelled=_cancelled;[_lock unlock];
    if(cancelled){completion(FMJDCancelled());return;}
    [asset loadValuesAsynchronouslyForKeys:@[@"tracks",@"duration",@"playable"] completionHandler:^{
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0), ^{
            @autoreleasepool {
                NSError *error=nil;
                if([self isCancelled]){completion(FMJDCancelled());return;}
                for(NSString *key in @[@"tracks",@"duration",@"playable"]){
                    if([asset statusOfValueForKey:key error:&error]!=AVKeyValueStatusLoaded){completion(FMJDValidationError(error,[@"asset_load_" stringByAppendingString:key]));return;}
                }
                NSArray<AVAssetTrack *> *tracks=[asset tracksWithMediaType:AVMediaTypeAudio];
                double duration=CMTimeGetSeconds(asset.duration);
                if(!asset.playable || !tracks.count || !isfinite(duration) || duration<=0){completion(FMJDValidationError(FMJDError(FMJSDownloadInvalidAudio,@"Downloaded file contains no playable finite audio"),!asset.playable?@"asset_not_playable":(!tracks.count?@"asset_no_audio_tracks":@"asset_invalid_duration")));return;}
                AVAssetReader *reader=[[AVAssetReader alloc] initWithAsset:asset error:&error];
                if(!reader){completion(FMJDValidationError(error,@"reader_create"));return;}
                NSDictionary *settings=@{AVFormatIDKey:@(kAudioFormatLinearPCM),AVLinearPCMBitDepthKey:@16,
                    AVLinearPCMIsFloatKey:@NO,AVLinearPCMIsBigEndianKey:@NO,AVLinearPCMIsNonInterleaved:@NO};
                AVAssetReaderTrackOutput *output=[[AVAssetReaderTrackOutput alloc] initWithTrack:tracks.firstObject outputSettings:settings];
                output.alwaysCopiesSampleData=NO;
                if(![reader canAddOutput:output]){completion(FMJDValidationError(nil,@"reader_add_output"));return;}
                [reader addOutput:output];
                [self->_lock lock];self->_reader=reader;BOOL stopped=self->_cancelled;[self->_lock unlock];
                if(stopped){completion(FMJDCancelled());return;}
                if(![reader startReading]){completion(FMJDValidationError(reader.error,@"reader_start"));return;}
                uint64_t samples=0;
                while(![self isCancelled]){
                    @autoreleasepool {
                        CMSampleBufferRef buffer=[output copyNextSampleBuffer];
                        if(!buffer)break;
                        samples+=(uint64_t)MAX(0,CMSampleBufferGetNumSamples(buffer));CFRelease(buffer);
                    }
                }
                if([self isCancelled]){[reader cancelReading];completion(FMJDCancelled());return;}
                if(reader.status!=AVAssetReaderStatusCompleted || !samples){completion(FMJDValidationError(reader.error,reader.status!=AVAssetReaderStatusCompleted?@"reader_incomplete":@"reader_no_samples"));return;}
                completion(nil);
            }
        });
    }];
}
@end

// A task owns this immutable destination/revision and its delegate-queue result.
// didFinish must adopt Foundation's temporary file before returning; only the
// subsequent didComplete callback may hand the transfer back to the main state.
static const void *FMJDTransferKey=&FMJDTransferKey;
@interface FMJSDownloadTransfer : NSObject
@property(nonatomic,strong) NSURL *target;
@property(nonatomic) NSUInteger revision;
@property(nonatomic) BOOL moved;
@property(nonatomic,strong) NSError *moveError;
@end
@implementation FMJSDownloadTransfer @end

@interface FMJSDownloadCoordinator ()
- (void)next;
- (void)removeCandidate;
- (void)transfer:(NSURL *)url quality:(NSString *)quality;
- (void)inspectFile:(NSURL *)file response:(NSHTTPURLResponse *)response revision:(NSUInteger)revision;
- (void)finishFile:(NSURL *)file response:(NSHTTPURLResponse *)response quality:(NSString *)quality error:(NSError *)error;
- (void)recordPhase:(NSString *)phase error:(NSError *)error response:(NSHTTPURLResponse *)response bytes:(uint64_t)bytes;
@end
@implementation FMJSDownloadCoordinator {
    FMQualityResolver *_resolver;
    NSURLSessionConfiguration *_configuration;
    NSURL *_parentDirectory,*_directory,*_candidateFile,*_pendingURL;
    NSHTTPURLResponse *_candidateResponse;
    NSString *_quality,*_pendingQuality;
    NSError *_pendingError,*_lastError;
    BOOL (^_isCurrent)(void);
    FMJSDownloadProgress _progress;
    FMJSDownloadCompletion _completion;
    NSURLSession *_session;
    NSURLSessionDownloadTask *_task;
    FMJSDownloadValidation *_validation;
    dispatch_source_t _timer;
    BOOL _started,_finished,_suspended,_resolving,_validated;
    NSUInteger _revision,_attempts,_transferFailures,_validationFailures,_successes,_completionCount;
    NSUInteger _progressCallbacks;
    NSMutableArray *_events;
    NSTimeInterval _remaining,_lastTick;
}
- (instancetype)initWithResolver:(FMQualityResolver *)resolver configuration:(NSURLSessionConfiguration *)configuration
              temporaryDirectory:(NSURL *)temporaryDirectory isCurrent:(BOOL (^)(void))isCurrent {
    if((self=[super init])){
        _resolver=resolver;_parentDirectory=temporaryDirectory;_isCurrent=[isCurrent copy];
        _configuration=configuration && !configuration.identifier.length ? [configuration copy] : [NSURLSessionConfiguration ephemeralSessionConfiguration];
        // Do not duplicate a host background-session identifier. This operation
        // is owned by the live manual-download task, not a persisted new service.
        if(configuration.identifier.length){
            _configuration.timeoutIntervalForRequest=configuration.timeoutIntervalForRequest;
            _configuration.timeoutIntervalForResource=configuration.timeoutIntervalForResource;
            _configuration.allowsCellularAccess=configuration.allowsCellularAccess;
        }
        if(!configuration){_configuration.timeoutIntervalForRequest=30;_configuration.timeoutIntervalForResource=300;}
        _configuration.URLCache=nil;_configuration.requestCachePolicy=NSURLRequestReloadIgnoringLocalCacheData;
        _configuration.HTTPShouldSetCookies=NO;_configuration.HTTPCookieStorage=nil;_configuration.URLCredentialStorage=nil;
        // LX musicUrl returns a bare URL. Never forward the original API session's
        // cookie/authentication or arbitrary default headers to a script URL.
        _configuration.HTTPAdditionalHeaders=nil;
        _remaining=900;_events=NSMutableArray.array;
    }return self;
}
- (BOOL)current {
    @try{return _isCurrent && _isCurrent();}@catch(__unused NSException *exception){return NO;}
}
- (void)recordPhase:(NSString *)phase error:(NSError *)error response:(NSHTTPURLResponse *)response bytes:(uint64_t)bytes {
    NSMutableDictionary *event=[@{@"phase":phase,@"quality":_quality ?: @"",@"http_status":@(response.statusCode),@"bytes":@(bytes)} mutableCopy];
    if(error){
        NSMutableArray *chain=NSMutableArray.array;
        for(NSError *item=error;item && chain.count<4;item=[item.userInfo[NSUnderlyingErrorKey] isKindOfClass:NSError.class]?item.userInfo[NSUnderlyingErrorKey]:nil)
            [chain addObject:@{@"domain":item.domain ?: @"",@"code":@(item.code)}];
        event[@"errors"]=chain;
        if([error.userInfo[@"FMJSValidationStage"] isKindOfClass:NSString.class])event[@"validation_stage"]=error.userInfo[@"FMJSValidationStage"];
    }
    [_events addObject:event];if(_events.count>32)[_events removeObjectAtIndex:0];
}
- (void)startWithProgress:(FMJSDownloadProgress)progress completion:(FMJSDownloadCompletion)completion {
    FMJDMain(^{
        if(self->_started){dispatch_async(dispatch_get_main_queue(),^{completion(nil,nil,nil,FMJDError(FMJSDownloadAlreadyStarted,@"Download has already started"));});return;}
        self->_started=YES;self->_progress=[progress copy];self->_completion=[completion copy];
        if(self->_finished || ![self current]){[self finishFile:nil response:nil quality:nil error:FMJDCancelled()];return;}
        if(!self->_parentDirectory.isFileURL){[self finishFile:nil response:nil quality:nil error:FMJDError(FMJSDownloadStorageFailure,@"A local temporary directory is required")];return;}
        self->_directory=[self->_parentDirectory URLByAppendingPathComponent:[@"FMJSDownload-" stringByAppendingString:NSUUID.UUID.UUIDString] isDirectory:YES];
        NSError *error=nil;
        if(![NSFileManager.defaultManager createDirectoryAtURL:self->_directory withIntermediateDirectories:YES attributes:nil error:&error]){
            [self finishFile:nil response:nil quality:nil error:error];return;
        }
        NSOperationQueue *queue=[NSOperationQueue new];queue.maxConcurrentOperationCount=1;queue.qualityOfService=NSQualityOfServiceUtility;
        self->_session=[NSURLSession sessionWithConfiguration:self->_configuration delegate:self delegateQueue:queue];
        self->_lastTick=NSProcessInfo.processInfo.systemUptime;
        self->_timer=dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,0,0,dispatch_get_main_queue());
        dispatch_source_set_timer(self->_timer,dispatch_time(DISPATCH_TIME_NOW,250*NSEC_PER_MSEC),250*NSEC_PER_MSEC,20*NSEC_PER_MSEC);
        __weak typeof(self) weakSelf=self;
        dispatch_source_set_event_handler(self->_timer,^{
            typeof(self) self=weakSelf;if(!self || self->_finished)return;
            NSTimeInterval now=NSProcessInfo.processInfo.systemUptime;
            if(!self->_suspended)self->_remaining-=MAX(0,now-self->_lastTick);self->_lastTick=now;
            if(![self current]){[self finishFile:nil response:nil quality:nil error:FMJDCancelled()];return;}
            if(self->_remaining<=0)[self finishFile:nil response:nil quality:nil error:[NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorTimedOut userInfo:nil]];
        });
        dispatch_resume(self->_timer);if(!self->_suspended)[self next];
    });
}
- (void)removeCandidate {
    [_validation cancel];_validation=nil;_validated=NO;
    if(_candidateFile)[NSFileManager.defaultManager removeItemAtURL:_candidateFile error:nil];
    _candidateFile=nil;_candidateResponse=nil;
}
- (void)next {
    if(_finished || _suspended || _resolving)return;
    if(![self current]){[self finishFile:nil response:nil quality:nil error:FMJDCancelled()];return;}
    [self removeCandidate];_resolving=YES;
    NSUInteger revision=++_revision;
    __weak typeof(self) weakSelf=self;
    [_resolver nextWithCompletion:^(NSURL *url,NSString *quality,NSError *error){
        typeof(self) self=weakSelf;if(!self || self->_finished || revision!=self->_revision)return;
        self->_resolving=NO;
        if(![self current]){[self finishFile:nil response:nil quality:nil error:FMJDCancelled()];return;}
        if(self->_suspended){self->_pendingURL=url;self->_pendingQuality=quality;self->_pendingError=error;return;}
        if(!url || error){[self recordPhase:@"resolution_end" error:error response:nil bytes:0];[self finishFile:nil response:nil quality:nil error:error ?: self->_lastError ?: FMJDError(FMJSDownloadInvalidResponse,@"No download candidate remains")];return;}
        [self transfer:url quality:quality];
    }];
}
- (void)transfer:(NSURL *)url quality:(NSString *)quality {
    if(_finished)return;
    _quality=[quality copy];++_attempts;NSUInteger revision=++_revision;
    NSMutableURLRequest *request=[NSMutableURLRequest requestWithURL:url cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:_configuration.timeoutIntervalForRequest];
    [request setValue:@"identity" forHTTPHeaderField:@"Accept-Encoding"];
    FMJSDownloadTransfer *transfer=FMJSDownloadTransfer.new;transfer.revision=revision;
    transfer.target=[_directory URLByAppendingPathComponent:[NSUUID.UUID.UUIDString stringByAppendingString:@".media"]];
    // Completion-handler tasks suppress download delegate progress on Foundation.
    // Delegate mode is required for real pause/cancel/progress behavior.
    NSURLSessionDownloadTask *task=[_session downloadTaskWithRequest:request];
    objc_setAssociatedObject(task,FMJDTransferKey,transfer,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    _task=task;
    if(_progress)_progress(0,NSURLSessionTransferSizeUnknown,_quality);
    if(!_suspended)[task resume];
}
- (void)inspectFile:(NSURL *)file response:(NSHTTPURLResponse *)response revision:(NSUInteger)revision {
    NSError *failure=nil;NSNumber *size=nil;
    [file getResourceValue:&size forKey:NSURLFileSizeKey error:&failure];
    uint64_t bytes=size.unsignedLongLongValue;
    if(!failure && (!response || response.statusCode<200 || response.statusCode>=300))failure=FMJDError(FMJSDownloadInvalidResponse,@"Download server returned an unsuccessful HTTP response");
    if(!failure && (bytes<16 || bytes>FMJSMaximumFileBytes))failure=FMJDError(bytes>FMJSMaximumFileBytes?FMJSDownloadSizeLimit:FMJSDownloadIncompleteFile,@"Downloaded file size is invalid");
    NSString *encoding=FMJDHeader(response,@"Content-Encoding");
    if(!failure && (!encoding.length || [encoding caseInsensitiveCompare:@"identity"]==NSOrderedSame) && response.expectedContentLength>=0 && (uint64_t)response.expectedContentLength!=bytes)
        failure=FMJDError(FMJSDownloadIncompleteFile,@"Downloaded bytes do not match Content-Length");
    if(!failure && response.statusCode==206){
        NSString *range=FMJDHeader(response,@"Content-Range");unsigned long long first=0,last=0,total=0;
        if(!range || sscanf(range.UTF8String,"bytes %llu-%llu/%llu",&first,&last,&total)!=3 || first!=0 || last+1!=total || total!=bytes)
            failure=FMJDError(FMJSDownloadIncompleteFile,@"Partial response is not a complete audio file");
    }
    NSString *mime=response.MIMEType.lowercaseString ?: @"";
    if(!failure && ([mime hasPrefix:@"text/"] || [mime containsString:@"json"] || [mime containsString:@"html"] || [mime containsString:@"xml"] || [mime containsString:@"mpegurl"]))
        failure=FMJDError(FMJSDownloadInvalidAudio,@"Server returned a document instead of audio");
    // WAV explicitly declares its container size. Reject a truncated file even
    // when a server incorrectly labels its shortened payload as a complete 200.
    if(!failure){
        NSFileHandle *handle=[NSFileHandle fileHandleForReadingFromURL:file error:&failure];
        NSData *prefix=[handle readDataUpToLength:512 error:&failure];[handle closeAndReturnError:nil];
        NSString *text=[[NSString alloc] initWithData:prefix encoding:NSUTF8StringEncoding];
        text=[[text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] lowercaseString];
        if([text hasPrefix:@"#extm3u"] || [text hasPrefix:@"[playlist]"] || [text hasPrefix:@"<?xml"] || [text hasPrefix:@"<mpd"])
            failure=FMJDError(FMJSDownloadInvalidAudio,@"A streaming manifest is not a downloaded audio file");
        if(prefix.length>=12 && !memcmp(prefix.bytes,"RIFF",4) && !memcmp((const uint8_t *)prefix.bytes+8,"WAVE",4)){
            const uint8_t *p=prefix.bytes;uint64_t declared=(uint64_t)p[4]|((uint64_t)p[5]<<8)|((uint64_t)p[6]<<16)|((uint64_t)p[7]<<24);
            if(declared+8>bytes)failure=FMJDError(FMJSDownloadIncompleteFile,@"WAV container is truncated");
        }
    }
    if(failure){[self recordPhase:@"file_validation" error:failure response:response bytes:bytes];_lastError=failure;++_validationFailures;[self removeCandidate];[self next];return;}
    _validation=[FMJSDownloadValidation new];
    __weak typeof(self) weakSelf=self;
    [_validation validate:file completion:^(NSError *error){
        dispatch_async(dispatch_get_main_queue(),^{
            typeof(self) self=weakSelf;if(!self || self->_finished || revision!=self->_revision)return;
            self->_validation=nil;
            if(![self current]){[self finishFile:nil response:nil quality:nil error:FMJDCancelled()];return;}
            if(error){[self recordPhase:@"audio_validation" error:error response:response bytes:bytes];self->_lastError=error;++self->_validationFailures;[self removeCandidate];[self next];return;}
            [self recordPhase:@"validated" error:nil response:response bytes:bytes];
            self->_validated=YES;if(!self->_suspended)[self finishFile:file response:response quality:self->_quality error:nil];
        });
    }];
}
- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)task didWriteData:(int64_t)bytesWritten totalBytesWritten:(int64_t)totalBytesWritten totalBytesExpectedToWrite:(int64_t)totalBytesExpectedToWrite {
    FMJDMain(^{
        if(self->_finished || task!=self->_task)return;
        ++self->_progressCallbacks;
        if(totalBytesWritten>(int64_t)FMJSMaximumFileBytes || totalBytesExpectedToWrite>(int64_t)FMJSMaximumFileBytes){
            [self->_task cancel];self->_task=nil;++self->_revision;self->_lastError=FMJDError(FMJSDownloadSizeLimit,@"Download exceeds the bounded file size");++self->_transferFailures;[self next];return;
        }
        if(![self current]){[self finishFile:nil response:nil quality:nil error:FMJDCancelled()];return;}
        if(!self->_suspended && self->_progress)self->_progress(totalBytesWritten,totalBytesExpectedToWrite,self->_quality);
    });
}
- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)task didFinishDownloadingToURL:(NSURL *)location {
    FMJSDownloadTransfer *transfer=objc_getAssociatedObject(task,FMJDTransferKey);if(!transfer)return;
    NSError *error=nil;
    transfer.moved=[NSFileManager.defaultManager moveItemAtURL:location toURL:transfer.target error:&error];
    transfer.moveError=error;
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    FMJSDownloadTransfer *transfer=objc_getAssociatedObject(task,FMJDTransferKey);if(!transfer)return;
    NSHTTPURLResponse *response=[task.response isKindOfClass:NSHTTPURLResponse.class]?(NSHTTPURLResponse *)task.response:nil;
    FMJDMain(^{
        NSURL *target=transfer.target;
        if(self->_finished || transfer.revision!=self->_revision || task!=self->_task){if(transfer.moved)[NSFileManager.defaultManager removeItemAtURL:target error:nil];return;}
        self->_task=nil;
        if(![self current]){if(transfer.moved)[NSFileManager.defaultManager removeItemAtURL:target error:nil];[self finishFile:nil response:nil quality:nil error:FMJDCancelled()];return;}
        if(error || !transfer.moved){
            if(transfer.moved)[NSFileManager.defaultManager removeItemAtURL:target error:nil];
            if(!error && transfer.moveError){[self recordPhase:@"storage" error:transfer.moveError response:response bytes:0];[self finishFile:nil response:nil quality:nil error:transfer.moveError];return;}
            self->_lastError=error ?: FMJDError(FMJSDownloadInvalidResponse,@"Download did not produce a file");++self->_transferFailures;
            [self recordPhase:@"transfer" error:self->_lastError response:response bytes:(uint64_t)MAX((int64_t)0,task.countOfBytesReceived)];
            if(error.code==NSURLErrorCancelled){[self finishFile:nil response:nil quality:nil error:error];return;}
            [self next];return;
        }
        self->_candidateFile=target;self->_candidateResponse=response;
        [self inspectFile:target response:response revision:transfer.revision];
    });
}
- (void)suspend { FMJDMain(^{if(self->_finished || self->_suspended)return;self->_suspended=YES;[self->_task suspend];}); }
- (void)resume {
    FMJDMain(^{
        if(self->_finished)return;self->_suspended=NO;self->_lastTick=NSProcessInfo.processInfo.systemUptime;
        if(!self->_started)return;
        if(![self current]){[self finishFile:nil response:nil quality:nil error:FMJDCancelled()];return;}
        if(self->_validated){[self finishFile:self->_candidateFile response:self->_candidateResponse quality:self->_quality error:nil];return;}
        if(self->_pendingError){NSError *error=self->_pendingError;self->_pendingError=nil;[self finishFile:nil response:nil quality:nil error:error];return;}
        if(self->_pendingURL){NSURL *url=self->_pendingURL;NSString *quality=self->_pendingQuality;self->_pendingURL=nil;self->_pendingQuality=nil;[self transfer:url quality:quality];return;}
        if(self->_task){[self->_task resume];return;}
        if(!self->_validation && !self->_resolving)[self next];
    });
}
- (void)cancel { FMJDMain(^{if(self->_finished)return;if(!self->_started){self->_finished=YES;[self->_resolver cancel];return;}[self finishFile:nil response:nil quality:nil error:FMJDCancelled()];}); }
- (void)finishFile:(NSURL *)file response:(NSHTTPURLResponse *)response quality:(NSString *)quality error:(NSError *)error {
    if(_finished && !_completion)return;
    _finished=YES;++_revision;[_task cancel];_task=nil;[_resolver cancel];[_validation cancel];_validation=nil;
    if(_timer){dispatch_source_cancel(_timer);_timer=nil;}
    [_session invalidateAndCancel];_session=nil;
    FMJSDownloadCompletion completion=_completion;_completion=nil;_progress=nil;
    if(file && !error)++_successes;
    if(completion){++_completionCount;completion(file,response,quality,error);}
    // This UUID directory was created exclusively by this operation.
    if(_directory)[NSFileManager.defaultManager removeItemAtURL:_directory error:nil];
    _candidateFile=nil;_candidateResponse=nil;_pendingURL=nil;_pendingQuality=nil;_pendingError=nil;
}
- (NSDictionary<NSString *,id> *)diagnostics {
    NSAssert(NSThread.isMainThread,@"Download diagnostics are main-thread confined");
    return @{@"attempts":@(_attempts),@"transfer_failures":@(_transferFailures),@"validation_failures":@(_validationFailures),
        @"successes":@(_successes),@"completions":@(_completionCount),@"finished":@(_finished),@"suspended":@(_suspended),
        @"progress_callbacks":@(_progressCallbacks),@"events":[_events copy]};
}
@end
