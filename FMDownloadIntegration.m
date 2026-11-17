#import "FMDownloadIntegration.h"
#import "FMJSDownloadCoordinator.h"
#import <CommonCrypto/CommonDigest.h>
#import <TargetConditionals.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <objc/runtime.h>
#import <string.h>
#import <float.h>
#import <stdio.h>
#import <stdlib.h>
#import <sys/stat.h>
#import <errno.h>
#if __has_feature(ptrauth_calls)
#import <ptrauth.h>
#endif

typedef void (*FMDownloadProgressIMP)(id,SEL,NSURLSession *,NSURLSessionDownloadTask *,int64_t,int64_t,int64_t);
typedef void (*FMDownloadFinishIMP)(id,SEL,NSURLSession *,NSURLSessionDownloadTask *,NSURL *);
typedef void (*FMDownloadCompleteIMP)(id,SEL,NSURLSession *,NSURLSessionTask *,NSError *);
static SEL FMProgressSEL(void) { return @selector(URLSession:downloadTask:didWriteData:totalBytesWritten:totalBytesExpectedToWrite:); }
static SEL FMFinishSEL(void) { return @selector(URLSession:downloadTask:didFinishDownloadingToURL:); }
static SEL FMCompleteSEL(void) { return @selector(URLSession:task:didCompleteWithError:); }
static const void *FMBindingKey=&FMBindingKey;
static NSRecursiveLock *FMLock;
static NSMutableDictionary *FMRegistrations,*FMHookedMethods,*FMCounters;
static NSMutableSet *FMActiveBindings;
static NSMutableDictionary *FMFileTickets;
static Class FMNativeDelegateClass;
static FMDownloadProgressIMP FMOriginalProgress;
static FMDownloadFinishIMP FMOriginalFinish;
static FMDownloadCompleteIMP FMOriginalComplete;
static BOOL FMInstalled,FMHostAllowed;
static NSUInteger FMGeneration;
static _Thread_local uintptr_t FMCarrierCleanupTask;

@interface FMDownloadRegistration : NSObject
@property(nonatomic,copy) NSString *trackKey;
@property(nonatomic,copy) FMDownloadResolverFactory factory;
@property(nonatomic,copy) BOOL (^isCurrent)(void);
@property(nonatomic) NSTimeInterval created;
@property(nonatomic) NSUInteger generation;
@property(nonatomic) BOOL ambiguous;
@end
@implementation FMDownloadRegistration @end

@interface FMDownloadFileTicket : NSObject
@property(nonatomic,copy) NSString *basename,*extension;
@property(nonatomic) NSUInteger generation;
@property(nonatomic) NSTimeInterval created;
@end
@implementation FMDownloadFileTicket @end
static NSError *FMFormatError(NSInteger code,NSString *message) {
    return [NSError errorWithDomain:@"FMDownloadNativeFormat" code:code userInfo:@{NSLocalizedDescriptionKey:message}];
}
static NSArray *FMNativeAudioExtensions(void) {
    // Exact original MusicFileStorage lookup/delete list, verified at 0x554c58.
    return @[@"mp3",@"flac",@"m4a",@"wav",@"ogg",@"opus",@"aac",@"aif",@"aiff",@"aifc",@"caf",@"mp4",@"ape",@"wv",@"mpc",@"tta",@"spx",@"dsf",@"dff"];
}
static NSString *FMFileIdentity(NSURL *URL) {
    if(!URL.isFileURL)return nil;struct stat attributes;
    if(lstat(URL.fileSystemRepresentation,&attributes)!=0 || !S_ISREG(attributes.st_mode) || attributes.st_size<=0)return nil;
    // Rename keeps inode/birth time/length; a new file reusing an inode does not
    // inherit the ticket. Do not key ownership by an arbitrary URL or extension.
    return [NSString stringWithFormat:@"%llu:%llu:%lld:%lld:%ld",(unsigned long long)attributes.st_dev,
        (unsigned long long)attributes.st_ino,(long long)attributes.st_size,
        (long long)attributes.st_birthtimespec.tv_sec,attributes.st_birthtimespec.tv_nsec];
}
static NSString *FMNativeBasename(NSString *trackKey) {
    NSRange separator=[trackKey rangeOfString:@":"];
    if(separator.location==NSNotFound || !separator.location)return nil;
    NSString *source=[trackKey substringToIndex:separator.location],*identifier=[trackKey substringFromIndex:separator.location+1];
    NSString *native=@{@"tx":@"qq",@"wy":@"wy",@"kg":@"kg"}[source];
    if(!native || !identifier.length || identifier.length>256 || [identifier containsString:@"/"] || [identifier containsString:@"\\"] || [identifier containsString:@"\0"])return nil;
    return [NSString stringWithFormat:@"%@_%@",native,identifier];
}
static BOOL FMRegisterFile(NSURL *file,NSString *trackKey,NSString *extension,NSUInteger generation,NSError **error) {
    NSString *identity=FMFileIdentity(file),*basename=FMNativeBasename(trackKey);
    if(!identity || !basename || ![@[@"mp3",@"flac",@"m4a",@"wav",@"aac",@"aiff",@"caf"] containsObject:extension]){
        if(error)*error=FMFormatError(1,@"Validated download identity or container format is missing");return NO;
    }
    [FMLock lock];NSTimeInterval now=NSDate.timeIntervalSinceReferenceDate;
    for(NSString *key in FMFileTickets.allKeys)if(now-[FMFileTickets[key] created]>3600)[FMFileTickets removeObjectForKey:key];
    if(FMFileTickets.count>=256 || FMFileTickets[identity]){[FMLock unlock];if(error)*error=FMFormatError(2,@"Too many pending native saves or duplicate file identity");return NO;}
    FMDownloadFileTicket *ticket=FMDownloadFileTicket.new;ticket.basename=basename;ticket.extension=extension;ticket.generation=generation;ticket.created=now;
    FMFileTickets[identity]=ticket;[FMLock unlock];return YES;
}
static void FMForgetFile(NSURL *file) {NSString *identity=FMFileIdentity(file);if(identity){[FMLock lock];[FMFileTickets removeObjectForKey:identity];[FMLock unlock];}}

@interface FMDownloadBinding : NSObject
@property(nonatomic,strong) NSURLSessionDownloadTask *task;
@property(nonatomic,strong) NSURLSession *session;
@property(nonatomic,strong) FMDownloadRegistration *registration;
@property(nonatomic,strong) FMJSDownloadCoordinator *coordinator;
@property(nonatomic,strong) NSOperation *lastOperation;
@property(nonatomic) void (*cancelCarrier)(id,SEL);
@property(atomic,strong) NSHTTPURLResponse *response;
@property(atomic,strong) NSError *error;
@property(atomic,strong) NSURLRequest *currentRequest;
@property(atomic) NSURLSessionTaskState state;
@property(atomic) int64_t received,expected;
@property(nonatomic) int64_t lastDeliveredBytes;
@property(nonatomic) BOOL started,terminal;
- (void)resume;
- (void)suspend;
- (void)cancel;
- (void)finishFile:(NSURL *)file response:(NSHTTPURLResponse *)response error:(NSError *)error;
@end

static void FMState(void) {
    static dispatch_once_t once;
    dispatch_once(&once,^{FMLock=NSRecursiveLock.new;FMRegistrations=NSMutableDictionary.new;
        FMHookedMethods=NSMutableDictionary.new;FMActiveBindings=NSMutableSet.new;FMCounters=NSMutableDictionary.new;FMFileTickets=NSMutableDictionary.new;});
}
static void FMCount(NSString *key) { [FMLock lock];FMCounters[key]=@([FMCounters[key] unsignedIntegerValue]+1);[FMLock unlock]; }
static void FMMain(dispatch_block_t block) { if(NSThread.isMainThread)block();else dispatch_async(dispatch_get_main_queue(),block); }
static NSError *FMCanceled(void) { return [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorCancelled userInfo:nil]; }
static BOOL FMRegistrationCurrent(FMDownloadRegistration *registration) {
    NSCAssert(NSThread.isMainThread,@"Resolver ownership must be checked on main");
    [FMLock lock];BOOL same=registration.generation==FMGeneration;[FMLock unlock];
    return same && registration.isCurrent && registration.isCurrent();
}
static void FMEnqueue(FMDownloadBinding *binding,dispatch_block_t block) {
    NSBlockOperation *operation=[NSBlockOperation blockOperationWithBlock:block];
    if(binding.lastOperation)[operation addDependency:binding.lastOperation];
    binding.lastOperation=operation;
    [binding.session.delegateQueue addOperation:operation];
}

@implementation FMDownloadBinding
- (void)resume {
    FMMain(^{
        if(self.terminal)return;
        self.state=NSURLSessionTaskStateRunning;
        if(self.started){[self.coordinator resume];return;}
        self.started=YES;
        if(!FMRegistrationCurrent(self.registration)){[self finishFile:nil response:nil error:FMCanceled()];return;}
        FMQualityResolver *resolver=self.registration.factory();
        if(!resolver){[self finishFile:nil response:nil error:FMCanceled()];return;}
        NSURL *directory=[NSFileManager.defaultManager.temporaryDirectory URLByAppendingPathComponent:@"FMJSManualDownloads" isDirectory:YES];
        __weak typeof(self) weak=self;
        self.coordinator=[[FMJSDownloadCoordinator alloc] initWithResolver:resolver configuration:self.session.configuration
            temporaryDirectory:directory isCurrent:^BOOL{typeof(self) strong=weak;return strong && !strong.terminal && FMRegistrationCurrent(strong.registration);}];
        [self.coordinator startWithProgress:^(int64_t written,int64_t expected,NSString *quality){
            typeof(self) strong=weak;if(!strong || strong.terminal)return;
            // A lower-quality retry restarts its byte count. Preserve the host's per-attempt progress.
            int64_t delta=MAX((int64_t)0,written-strong.lastDeliveredBytes);strong.lastDeliveredBytes=written;
            strong.received=written;strong.expected=expected;
            NSURLSession *session=strong.session;NSURLSessionDownloadTask *task=strong.task;
            NSUInteger generation=strong.registration.generation;
            FMEnqueue(strong,^{[FMLock lock];BOOL current=generation==FMGeneration;[FMLock unlock];
                if(current)FMOriginalProgress(session.delegate,FMProgressSEL(),session,task,delta,written,expected);});
        } completion:^(NSURL *file,NSHTTPURLResponse *response,NSString *quality,NSError *error){
            typeof(self) strong=weak;if(!strong)return;
            if(!FMRegistrationCurrent(strong.registration)){file=nil;error=FMCanceled();}
            [strong finishFile:file response:response error:error];
        }];
    });
}
- (void)suspend { FMMain(^{if(!self.terminal){self.state=NSURLSessionTaskStateSuspended;[self.coordinator suspend];}}); }
- (void)cancel { FMMain(^{if(self.terminal)return;self.state=NSURLSessionTaskStateCanceling;
    [self.coordinator cancel];if(!self.terminal)[self finishFile:nil response:nil error:FMCanceled()];}); }
- (void)finishFile:(NSURL *)file response:(NSHTTPURLResponse *)response error:(NSError *)error {
    NSCAssert(NSThread.isMainThread,@"Download completion must be serialized on main");
    if(self.terminal)return;self.terminal=YES;
    NSURL *handoff=nil;
    if(file && !error){
        NSNumber *fileSize=nil;[file getResourceValue:&fileSize forKey:NSURLFileSizeKey error:nil];
        if(fileSize)self.received=fileSize.longLongValue;
        if(response.expectedContentLength>0)self.expected=response.expectedContentLength;
        NSURL *directory=[NSFileManager.defaultManager.temporaryDirectory URLByAppendingPathComponent:@"FMJSNativeHandoff" isDirectory:YES];
        if([NSFileManager.defaultManager createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:&error]){
            handoff=[directory URLByAppendingPathComponent:[NSUUID.UUID.UUIDString stringByAppendingPathExtension:file.pathExtension]];
            if(![NSFileManager.defaultManager moveItemAtURL:file toURL:handoff error:&error])handoff=nil;
            else if(!FMRegisterFile(handoff,self.registration.trackKey,file.pathExtension,self.registration.generation,&error)){
                [NSFileManager.defaultManager removeItemAtURL:handoff error:nil];handoff=nil;
            }
        }
    }
    if(!handoff && !error)error=[NSError errorWithDomain:FMJSDownloadErrorDomain code:FMJSDownloadInvalidAudio userInfo:nil];
    self.response=response;self.error=error;self.currentRequest=response.URL ? [NSURLRequest requestWithURL:response.URL] : self.currentRequest;
    self.state=NSURLSessionTaskStateCompleted;
    NSURLSession *session=self.session;NSURLSessionDownloadTask *task=self.task;
    NSUInteger generation=self.registration.generation;NSError *terminalError=error;
    void (*cancelCarrier)(id,SEL)=self.cancelCarrier;
    FMEnqueue(self,^{
        [FMLock lock];BOOL stillSame=generation==FMGeneration;[FMLock unlock];
        NSError *deliveredError=stillSame ? terminalError : FMCanceled();
        self.error=deliveredError;
        // The original delegate adopts the file synchronously before scheduling its library update.
        // Its identity, taskIdentifier, response, session and delegate queue are all preserved.
        if(handoff && !deliveredError){FMOriginalFinish(session.delegate,FMFinishSEL(),session,task,handoff);FMCount(@"filesDelivered");}
        FMOriginalComplete(session.delegate,FMCompleteSEL(),session,task,deliveredError);
        FMCount(deliveredError ? @"failed" : @"completed");
        if(handoff){FMForgetFile(handoff);[NSFileManager.defaultManager removeItemAtURL:handoff error:nil];}
        // Release Foundation's suspended carrier. Its automatic cancellation callback is suppressed.
        uintptr_t previousCleanup=FMCarrierCleanupTask;FMCarrierCleanupTask=(uintptr_t)(__bridge void *)task;
        cancelCarrier(task,@selector(cancel));FMCarrierCleanupTask=previousCleanup;
        FMMain(^{[FMLock lock];[FMActiveBindings removeObject:self];[FMLock unlock];
            self.coordinator=nil;self.session=nil;self.task=nil;self.lastOperation=nil;});
    });
}
@end

static BOOL FMDescends(Class cls,Class base) { for(Class value=cls;value;value=class_getSuperclass(value))if(value==base)return YES;return NO; }
static Method FMOwnMethod(Class cls,SEL selector) {
    unsigned count=0;Method result=NULL;Method *methods=class_copyMethodList(cls,&count);
    for(unsigned i=0;i<count;i++)if(method_getName(methods[i])==selector){result=methods[i];break;}
    free(methods);return result;
}
static NSString *FMMethodKey(Class cls,SEL selector) { return [NSString stringWithFormat:@"%p/%@",cls,NSStringFromSelector(selector)]; }
static IMP FMOriginalForObject(id object,SEL selector) {
    [FMLock lock];IMP result=NULL;
    for(Class cls=object_getClass(object);cls;cls=class_getSuperclass(cls)){
        NSValue *value=FMHookedMethods[FMMethodKey(cls,selector)];if(value){result=value.pointerValue;break;}
    }
    [FMLock unlock];return result;
}
static void FMReplace(Class cls,SEL selector,id (^makeBlock)(IMP)) {
    Method method=FMOwnMethod(cls,selector);if(!method)return;
    NSString *key=FMMethodKey(cls,selector);if(FMHookedMethods[key])return;
    IMP original=method_getImplementation(method);id block=makeBlock(original);
    FMHookedMethods[key]=[NSValue valueWithPointer:original];method_setImplementation(method,imp_implementationWithBlock(block));
}
static FMDownloadBinding *FMTaskBinding(NSURLSessionTask *task) {
    if(FMCarrierCleanupTask==(uintptr_t)(__bridge void *)task)return nil;
    return objc_getAssociatedObject(task,FMBindingKey);
}
static void FMHookTaskClass(Class cls) {
    for(Class current=cls;current && FMDescends(current,NSURLSessionTask.class);current=class_getSuperclass(current)){
        FMReplace(current,@selector(resume),^id(IMP imp){return ^(NSURLSessionTask *task){FMDownloadBinding *binding=FMTaskBinding(task);if(binding)[binding resume];else ((void(*)(id,SEL))imp)(task,@selector(resume));};});
        FMReplace(current,@selector(suspend),^id(IMP imp){return ^(NSURLSessionTask *task){FMDownloadBinding *binding=FMTaskBinding(task);if(binding)[binding suspend];else ((void(*)(id,SEL))imp)(task,@selector(suspend));};});
        FMReplace(current,@selector(cancel),^id(IMP imp){return ^(NSURLSessionTask *task){FMDownloadBinding *binding=FMTaskBinding(task);if(binding)[binding cancel];else ((void(*)(id,SEL))imp)(task,@selector(cancel));};});
        FMReplace(current,@selector(cancelByProducingResumeData:),^id(IMP imp){return ^(NSURLSessionDownloadTask *task,void(^completion)(NSData *)){FMDownloadBinding *binding=FMTaskBinding(task);if(binding){[binding cancel];if(completion)completion(nil);}else ((void(*)(id,SEL,id))imp)(task,@selector(cancelByProducingResumeData:),completion);};});
        FMReplace(current,@selector(state),^id(IMP imp){return ^NSURLSessionTaskState(NSURLSessionTask *task){FMDownloadBinding *binding=FMTaskBinding(task);return binding ? binding.state : ((NSURLSessionTaskState(*)(id,SEL))imp)(task,@selector(state));};});
        FMReplace(current,@selector(response),^id(IMP imp){return ^NSURLResponse *(NSURLSessionTask *task){FMDownloadBinding *binding=FMTaskBinding(task);return binding ? binding.response : ((id(*)(id,SEL))imp)(task,@selector(response));};});
        FMReplace(current,@selector(error),^id(IMP imp){return ^NSError *(NSURLSessionTask *task){FMDownloadBinding *binding=FMTaskBinding(task);return binding ? binding.error : ((id(*)(id,SEL))imp)(task,@selector(error));};});
        FMReplace(current,@selector(currentRequest),^id(IMP imp){return ^NSURLRequest *(NSURLSessionTask *task){FMDownloadBinding *binding=FMTaskBinding(task);return binding ? binding.currentRequest : ((id(*)(id,SEL))imp)(task,@selector(currentRequest));};});
        FMReplace(current,@selector(countOfBytesReceived),^id(IMP imp){return ^int64_t(NSURLSessionTask *task){FMDownloadBinding *binding=FMTaskBinding(task);return binding ? binding.received : ((int64_t(*)(id,SEL))imp)(task,@selector(countOfBytesReceived));};});
        FMReplace(current,@selector(countOfBytesExpectedToReceive),^id(IMP imp){return ^int64_t(NSURLSessionTask *task){FMDownloadBinding *binding=FMTaskBinding(task);return binding ? binding.expected : ((int64_t(*)(id,SEL))imp)(task,@selector(countOfBytesExpectedToReceive));};});
    }
}
static void FMPrune(void) {
    NSTimeInterval now=NSDate.timeIntervalSinceReferenceDate;
    for(NSString *key in FMRegistrations.allKeys)if(now-[FMRegistrations[key] created]>600)[FMRegistrations removeObjectForKey:key];
    while(FMRegistrations.count>64){NSString *oldest=nil;NSTimeInterval value=DBL_MAX;
        for(NSString *key in FMRegistrations){NSTimeInterval created=[FMRegistrations[key] created];if(created<value){value=created;oldest=key;}}
        if(oldest)[FMRegistrations removeObjectForKey:oldest];else break;
    }
}
static NSURLSessionDownloadTask *FMCreate(NSURLSession *session,NSURL *URL,IMP original) {
    NSURLSessionDownloadTask *task=((id(*)(id,SEL,id))original)(session,@selector(downloadTaskWithURL:),URL);
    if(!task || object_getClass(session.delegate)!=FMNativeDelegateClass || objc_getAssociatedObject(task,FMBindingKey))return task;
    [FMLock lock];FMPrune();FMDownloadRegistration *registration=FMRegistrations[URL.absoluteString];
    if(!registration || registration.ambiguous){[FMLock unlock];return task;}
    FMHookTaskClass(object_getClass(task));
    FMDownloadBinding *binding=FMDownloadBinding.new;binding.task=task;binding.session=session;binding.registration=registration;
    binding.currentRequest=[NSURLRequest requestWithURL:URL];binding.state=NSURLSessionTaskStateSuspended;binding.expected=NSURLSessionTransferSizeUnknown;
    binding.cancelCarrier=(void(*)(id,SEL))FMOriginalForObject(task,@selector(cancel));
    if(!binding.cancelCarrier){[FMLock unlock];return task;}
    objc_setAssociatedObject(task,FMBindingKey,binding,OBJC_ASSOCIATION_RETAIN_NONATOMIC);[FMActiveBindings addObject:binding];FMCount(@"claimed");
    [FMLock unlock];return task;
}
static void FMHookSessionClass(Class cls) {
    for(Class current=cls;current && FMDescends(current,NSURLSession.class);current=class_getSuperclass(current))
        FMReplace(current,@selector(downloadTaskWithURL:),^id(IMP imp){return ^NSURLSessionDownloadTask *(NSURLSession *session,NSURL *URL){return FMCreate(session,URL,imp);};});
}
static BOOL FMDigest(const uint8_t *bytes,size_t length,const char *expected) {
    unsigned char hash[32];char hex[65];CC_SHA256(bytes,(CC_LONG)length,hash);
    for(NSUInteger i=0;i<32;i++)snprintf(hex+i*2,3,"%02x",hash[i]);return strcmp(hex,expected)==0;
}
static uintptr_t FMImpAddress(IMP implementation) {
#if __has_feature(ptrauth_calls)
    return (uintptr_t)ptrauth_strip(implementation,ptrauth_key_function_pointer);
#else
    return (uintptr_t)implementation;
#endif
}
static BOOL FMVerify(void) {
    const struct mach_header_64 *header=(void *)_dyld_get_image_header(0);
    if(!header || header->magic!=MH_MAGIC_64 || header->filetype!=MH_EXECUTE || header->cputype!=CPU_TYPE_ARM64 || header->sizeofcmds>65536 || header->ncmds>1024)return NO;
    const uint8_t expected[]={0x48,0xc7,0x7a,0x33,0x63,0xbc,0x3e,0x8f,0x8f,0xc7,0x5e,0xd6,0x13,0x29,0x24,0xc4};
    BOOL uuid=NO,range=NO;const uint8_t *cursor=(const void *)(header+1),*end=cursor+header->sizeofcmds;
    for(uint32_t i=0;i<header->ncmds;i++){
        if(end-cursor<(ptrdiff_t)sizeof(struct load_command))return NO;const struct load_command *command=(const void *)cursor;
        if(command->cmdsize<sizeof(*command) || command->cmdsize>(size_t)(end-cursor))return NO;
        if(command->cmd==LC_UUID && command->cmdsize==sizeof(struct uuid_command))uuid=!memcmp(((const struct uuid_command *)command)->uuid,expected,16);
        if(command->cmd==LC_SEGMENT_64 && command->cmdsize>=sizeof(struct segment_command_64)){
            const struct segment_command_64 *segment=(const void *)command;
            if(!strncmp(segment->segname,"__TEXT",16) && segment->fileoff==0 && segment->vmaddr==0x100000000ull && segment->filesize>=0x509e40 && segment->vmsize>=0x509e40 && (segment->initprot&5)==5)range=YES;
        }cursor+=command->cmdsize;
    }
    if(!uuid || !range)return NO;
    const uintptr_t offsets[]={0x7a910,0x7af24,0x7b1bc};SEL selectors[]={FMProgressSEL(),FMFinishSEL(),FMCompleteSEL()};
    const char *hashes[]={"f6f34513fef64004f8be0bf3f92ba307b128bac6b91c7c9f8306146e325901ed","e6ba6ca73b96f76b48e696558ca082ea3732b3f9d7147d3f01c99903bb560995","b0b576691558ef0d14e593af6ea6575d2aff464eebf39d03833d29edb71f82ed"};
    Class cls=NSClassFromString(@"_TtC9FreeMusic12CacheManager");if(!cls)return NO;
    for(NSUInteger i=0;i<3;i++){Method method=FMOwnMethod(cls,selectors[i]);const uint8_t *code=(const uint8_t *)header+offsets[i];
        if(!method || FMImpAddress(method_getImplementation(method))!=(uintptr_t)code || !FMDigest(code,64,hashes[i]))return NO;}
    const uint8_t formatBranch[]={0x19,0x3c,0x12,0x14};
    return FMDigest((const uint8_t *)header+0x780e4,64,"35efab6f7fbf04e02029fe13a93bb92f2b28f04a0be6496738cf5b3829089b53") &&
        !memcmp((const uint8_t *)header+0x7acdc,formatBranch,sizeof(formatBranch)) &&
        FMDigest((const uint8_t *)header+0x509d40,0x100,"8a301f4c5b6667c0e5fd3e6d00771a86c57da5cf3c72eaeae795205072b730b5");
}
static BOOL FMInstallClass(Class cls) {
    FMState();[FMLock lock];
    if(FMInstalled){BOOL same=FMNativeDelegateClass==cls;[FMLock unlock];return same;}
    Method progress=FMOwnMethod(cls,FMProgressSEL()),finish=FMOwnMethod(cls,FMFinishSEL()),complete=FMOwnMethod(cls,FMCompleteSEL());
    if(!progress || !finish || !complete){[FMLock unlock];return NO;}
    FMNativeDelegateClass=cls;FMOriginalProgress=(FMDownloadProgressIMP)method_getImplementation(progress);
    FMOriginalFinish=(FMDownloadFinishIMP)method_getImplementation(finish);FMOriginalComplete=(FMDownloadCompleteIMP)method_getImplementation(complete);
    method_setImplementation(progress,imp_implementationWithBlock(^(id delegate,NSURLSession *session,NSURLSessionDownloadTask *task,int64_t bytes,int64_t total,int64_t expected){
        if(!objc_getAssociatedObject(task,FMBindingKey))FMOriginalProgress(delegate,FMProgressSEL(),session,task,bytes,total,expected);
    }));
    method_setImplementation(finish,imp_implementationWithBlock(^(id delegate,NSURLSession *session,NSURLSessionDownloadTask *task,NSURL *file){
        if(!objc_getAssociatedObject(task,FMBindingKey))FMOriginalFinish(delegate,FMFinishSEL(),session,task,file);
    }));
    method_setImplementation(complete,imp_implementationWithBlock(^(id delegate,NSURLSession *session,NSURLSessionTask *task,NSError *error){
        if(!objc_getAssociatedObject(task,FMBindingKey))FMOriginalComplete(delegate,FMCompleteSEL(),session,task,error);
    }));
    unsigned count=0;Class *classes=objc_copyClassList(&count);
    for(unsigned i=0;i<count;i++)if(FMDescends(classes[i],NSURLSession.class))FMHookSessionClass(classes[i]);free(classes);
    // Also catch lazily realized concrete session classes created after installation.
    Class meta=object_getClass(NSURLSession.class);
    FMReplace(meta,@selector(sessionWithConfiguration:delegate:delegateQueue:),^id(IMP imp){return ^NSURLSession *(id cls,NSURLSessionConfiguration *config,id delegate,NSOperationQueue *queue){
        NSURLSession *session=((id(*)(id,SEL,id,id,id))imp)(cls,@selector(sessionWithConfiguration:delegate:delegateQueue:),config,delegate,queue);
        [FMLock lock];FMHookSessionClass(object_getClass(session));[FMLock unlock];return session;
    };});
    FMInstalled=YES;[FMLock unlock];return YES;
}
void FMDownloadIntegrationInstall(void) { FMState();FMHostAllowed=FMVerify();if(FMHostAllowed)FMInstallClass(NSClassFromString(@"_TtC9FreeMusic12CacheManager")); }
void FMDownloadIntegrationRegisterURL(NSURL *URL,NSString *trackKey,FMDownloadResolverFactory factory,BOOL(^isCurrent)(void)) {
    if(!URL.absoluteString.length || !trackKey.length || !factory || !isCurrent)return;FMState();
    FMDownloadRegistration *registration=FMDownloadRegistration.new;registration.trackKey=trackKey;registration.factory=factory;registration.isCurrent=isCurrent;
    registration.created=NSDate.timeIntervalSinceReferenceDate;
    [FMLock lock];FMPrune();registration.generation=FMGeneration;
    FMDownloadRegistration *old=FMRegistrations[URL.absoluteString];
    registration.ambiguous=old && (old.ambiguous || ![old.trackKey isEqualToString:trackKey]);
    if(registration.ambiguous)FMCount(@"ambiguous");FMRegistrations[URL.absoluteString]=registration;FMPrune();[FMLock unlock];
}
void FMDownloadIntegrationSourceTransition(void) { FMState();[FMLock lock];FMGeneration++;[FMRegistrations removeAllObjects];NSArray *bindings=FMActiveBindings.allObjects;[FMLock unlock];
    for(FMDownloadBinding *binding in bindings)[binding cancel];
}
NSDictionary *FMDownloadIntegrationDiagnostics(void) { FMState();[FMLock lock];NSMutableDictionary *result=[FMCounters mutableCopy];
    result[@"installed"]=@(FMInstalled);result[@"hostVerified"]=@(FMHostAllowed);result[@"active"]=@(FMActiveBindings.count);result[@"registrations"]=@(FMRegistrations.count);result[@"pendingFormatSaves"]=@(FMFileTickets.count);[FMLock unlock];return result;
}

static BOOL FMMoveManagedNativeFile(NSFileManager *manager,NSURL *source,NSURL *destination,NSError **error) {
    FMState();NSString *identity=FMFileIdentity(source);[FMLock lock];FMDownloadFileTicket *ticket=identity?FMFileTickets[identity]:nil;
    if(!ticket){[FMLock unlock];return [manager moveItemAtURL:source toURL:destination error:error];}
    // Keep source transitions and same-key replacement serialized. Only bounded
    // local filesystem work occurs here; no decoder/network request holds this lock.
    @try {
    NSError *failure=nil;BOOL success=NO;NSMutableArray<NSURL *> *backedUp=NSMutableArray.array;NSURL *backup=nil;
    NSURL *parent=destination.URLByDeletingLastPathComponent;
    struct stat parentStat;
    if(ticket.generation!=FMGeneration)failure=FMCanceled();
    else if(!destination.isFileURL || ![destination.pathExtension isEqual:@"mp3"] ||
            ![destination.lastPathComponent.stringByDeletingPathExtension isEqual:ticket.basename] ||
            lstat(parent.fileSystemRepresentation,&parentStat)!=0 || !S_ISDIR(parentStat.st_mode))
        failure=FMFormatError(3,@"Native save destination does not match this verified track");
    NSURL *target=[parent URLByAppendingPathComponent:[ticket.basename stringByAppendingPathExtension:ticket.extension]];
    NSMutableArray<NSURL *> *siblings=NSMutableArray.array;
    @try {
    if(!failure){
        NSMutableArray<NSURL *> *candidates=NSMutableArray.array;
        for(NSString *extension in FMNativeAudioExtensions())
            [candidates addObject:[parent URLByAppendingPathComponent:[ticket.basename stringByAppendingPathExtension:extension]]];
        // Original MusicFileStorage initializes downloads under Documents/Downloads
        // (0x72bcc), but its higher-priority decoded CAF is under Application
        // Support/DownloadAssets (0x72bf4, read at 0x173128). These are different
        // directories. Resolve the exact original root, never scan arbitrary paths.
        NSURL *support=[[manager URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask] firstObject];
        NSURL *assets=[support URLByAppendingPathComponent:@"DownloadAssets" isDirectory:YES];
        struct stat assetsStat;
        if(!assets.isFileURL)failure=FMFormatError(3,@"Native download assets directory is unavailable");
        else if(lstat(assets.fileSystemRepresentation,&assetsStat)==0){
            if(!S_ISDIR(assetsStat.st_mode))failure=FMFormatError(4,@"Native download assets path is not a directory");
            else [candidates addObject:[assets URLByAppendingPathComponent:[ticket.basename stringByAppendingString:@"_playback.caf"]]];
        }else if(errno!=ENOENT)failure=[NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil];
        for(NSURL *candidate in candidates){
            if(failure)break;struct stat item;
            if(lstat(candidate.fileSystemRepresentation,&item)==0){
                if(!S_ISREG(item.st_mode)){failure=FMFormatError(4,@"An existing track path is not a regular file");break;}
                [siblings addObject:candidate];
            }else if(errno!=ENOENT){failure=[NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil];break;}
        }
    }
    if(!failure){
        backup=[parent URLByAppendingPathComponent:[@".FMJSReplacement-" stringByAppendingString:NSUUID.UUID.UUIDString] isDirectory:YES];
        if(![manager createDirectoryAtURL:backup withIntermediateDirectories:NO attributes:nil error:&failure])backup=nil;
    }
    if(!failure)for(NSURL *existing in siblings){
        if(![manager moveItemAtURL:existing toURL:[backup URLByAppendingPathComponent:existing.lastPathComponent] error:&failure])break;
        [backedUp addObject:existing];
    }
    if(!failure)success=[manager moveItemAtURL:source toURL:target error:&failure];
    } @catch(__unused NSException *exception) {failure=FMFormatError(6,@"Native file operation raised an exception");success=NO;}
    if(success){
        [FMFileTickets removeObjectForKey:identity];FMCount(@"nativeFormatSaves");
        @try {if(![manager removeItemAtURL:backup error:nil])FMCount(@"nativeFormatBackupCleanupFailures");}
        @catch(__unused NSException *exception){FMCount(@"nativeFormatBackupCleanupFailures");}
    }else{
        BOOL restored=YES;
        for(NSURL *existing in backedUp.reverseObjectEnumerator){
            NSError *restoreError=nil;
            @try {if(![manager moveItemAtURL:[backup URLByAppendingPathComponent:existing.lastPathComponent] toURL:existing error:&restoreError])restored=NO;}
            @catch(__unused NSException *exception){restored=NO;}
        }
        // If restoration fails, leave the exact bounded backup intact for recovery.
        @try {if(backup && restored)[manager removeItemAtURL:backup error:nil];}
        @catch(__unused NSException *exception){FMCount(@"nativeFormatBackupCleanupFailures");}
        FMCount(restored?@"nativeFormatRejectedOrRolledBack":@"nativeFormatRollbackFailures");
        if(!failure)failure=FMFormatError(5,@"Native media replacement failed");
    }
    if(!success && error)*error=failure;return success;
    } @finally {[FMLock unlock];}
}
BOOL FMDownloadNativeMove(NSFileManager *manager,NSURL *source,NSURL *destination,NSError **error) {
    @try {return FMMoveManagedNativeFile(manager,source,destination,error);}
    @catch(__unused NSException *exception){
        // The authored ARM64 call-site bridge deliberately has no Objective-C
        // exception unwind information. Never unwind through it into Swift.
        if(error)*error=FMFormatError(6,@"Native file operation raised an exception");return NO;
    }
}
#if defined(FMX_DOWNLOAD_INTEGRATION_TESTING)
BOOL FMDownloadIntegrationInstallForTesting(Class cls) {
#if TARGET_OS_SIMULATOR || TARGET_OS_OSX
    return cls && FMInstallClass(cls);
#else
    return NO;
#endif
}
BOOL FMDownloadIntegrationRegisterFileForTesting(NSURL *file,NSString *trackKey,NSString *extension,NSError **error) {
#if TARGET_OS_SIMULATOR || TARGET_OS_OSX
    FMState();return FMRegisterFile(file,trackKey,extension,FMGeneration,error);
#else
    return NO;
#endif
}
#endif
