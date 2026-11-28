#import "FMReplayMedia.h"
#import "FMReplayCache.h"
#import "FMJSDownloadCoordinator.h"
#import <CommonCrypto/CommonDigest.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <objc/runtime.h>
#import <math.h>
#import <unistd.h>
#if __has_feature(ptrauth_calls)
#import <ptrauth.h>
#endif

typedef void (^FMReplayFileCompletion)(NSURL *, NSURLResponse *, NSError *);
static const int64_t FMReplayLimit = 128ll * 1024 * 1024;

@class FMReplayTransfer;
@interface FMReplayCandidate : NSObject
@property(nonatomic,copy) NSString *key;
@property(nonatomic,copy) NSURL *url;
@property(nonatomic) NSUInteger order, observation;
@property(nonatomic) BOOL ambiguous, nativePending, validating, supplementalStarted;
@property(nonatomic,strong) FMReplayTransfer *transfer;
@property(nonatomic,copy) dispatch_block_t cancelValidation;
@property(nonatomic,weak) AVPlayer *player;
@property(nonatomic,strong) id timeObserver;
@end
@implementation FMReplayCandidate
@end

@interface FMReplayTransfer : NSObject<NSURLSessionDownloadDelegate>
@property(nonatomic,weak) FMReplayCandidate *candidate;
@property(nonatomic,strong) NSURLSession *session;
@property(nonatomic,strong) NSURL *staging;
- (void)start;
- (void)cancel;
@end

static NSMutableDictionary<NSString *, FMReplayCandidate *> *byKey, *byURL;
static NSMutableIndexSet *retiredURLHashes;
static NSUInteger sequence;
static __weak FMReplayCandidate *playingCandidate;
#if defined(FMX_REPLAY_MEDIA_TESTING) && FMX_REPLAY_MEDIA_TESTING
static FMReplayCache *fixtureStore;
#endif
static FMReplayCache *FMStore(void) {
#if defined(FMX_REPLAY_MEDIA_TESTING) && FMX_REPLAY_MEDIA_TESTING
    if(fixtureStore)return fixtureStore;
#endif
    return [FMReplayCache sharedCache];
}
static Class FMLock(void) {return FMReplayMedia.class;}
static void FMState(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{byKey=[NSMutableDictionary new];byURL=[NSMutableDictionary new];retiredURLHashes=[NSMutableIndexSet indexSet];});
}
static BOOL FMCurrent(FMReplayCandidate *candidate) {
    return candidate && byKey[candidate.key]==candidate;
}
static BOOL FMRemote(NSURL *url) {
    NSString *scheme=url.scheme.lowercaseString;
    if(!([scheme isEqual:@"https"] || [scheme isEqual:@"http"]) || !url.host.length || url.user.length || url.password.length)return NO;
    return ![@[@"m3u8",@"m3u",@"mpd",@"ism",@"ismc",@"m4s"] containsObject:url.pathExtension.lowercaseString];
}
static NSString *FMHeader(NSHTTPURLResponse *response,NSString *name) {
    return [response valueForHTTPHeaderField:name].lowercaseString ?: @"";
}
static BOOL FMCanStoreResponse(NSURLResponse *value) {
    if(![value isKindOfClass:NSHTTPURLResponse.class])return NO;
    NSHTTPURLResponse *r=(id)value;
    if(!FMRemote(r.URL) || (r.statusCode!=200 && r.statusCode!=206) ||
       [FMHeader(r,@"Cache-Control") containsString:@"no-store"])return NO;
    int64_t count=r.expectedContentLength;
    if(count<16 || count>FMReplayLimit)return NO;
    NSString *encoding=FMHeader(r,@"Content-Encoding");
    if(encoding.length && ![encoding isEqual:@"identity"])return NO;
    if(r.statusCode==206){
        NSString *expected=[NSString stringWithFormat:@"bytes 0-%lld/%lld",(long long)count-1,(long long)count];
        if(![FMHeader(r,@"Content-Range") isEqual:expected])return NO;
    }else if(FMHeader(r,@"Content-Range").length)return NO;
    NSString *mime=r.MIMEType.lowercaseString ?: @"";
    return !([mime hasPrefix:@"text/"] || [mime containsString:@"mpegurl"] || [mime containsString:@"dash"] ||
             [mime containsString:@"html"] || [mime containsString:@"json"] || [mime containsString:@"xml"]);
}
static NSURL *FMStageURL(void) {
    static NSURL *folder;
    static dispatch_once_t once;
    dispatch_once(&once,^{
        NSURL *root=[NSFileManager.defaultManager.temporaryDirectory URLByAppendingPathComponent:@"FMReplayTransfer" isDirectory:YES];
        // Only our transient decoded/download candidates live here. The store owns published files.
        [NSFileManager.defaultManager removeItemAtURL:root error:nil];
        if([NSFileManager.defaultManager createDirectoryAtURL:root withIntermediateDirectories:YES attributes:nil error:nil])folder=root;
    });
    return [folder URLByAppendingPathComponent:NSUUID.UUID.UUIDString];
}
static NSURL *FMPin(NSURL *file, NSHTTPURLResponse *r) {
    if(!file.isFileURL || !FMCanStoreResponse(r))return nil;
    NSNumber *size=nil,*regular=nil;
    if(![file getResourceValue:&regular forKey:NSURLIsRegularFileKey error:nil] || !regular.boolValue ||
       ![file getResourceValue:&size forKey:NSURLFileSizeKey error:nil] || size.longLongValue!=r.expectedContentLength)return nil;
    NSURL *dest=FMStageURL();
    if(dest && link(file.fileSystemRepresentation,dest.fileSystemRepresentation)==0)return dest;
    return nil;
}
static void FMClearObserver(FMReplayCandidate *c) {
    NSCAssert(NSThread.isMainThread,@"Player observation belongs to the main queue");
    c.observation++;
    AVPlayer *player=c.player;
    if(c.timeObserver && player)[player removeTimeObserver:c.timeObserver];
    c.timeObserver=nil;c.player=nil;
}
static void FMRetire(FMReplayCandidate *c) {
    if(!c)return;
    [c.transfer cancel];c.transfer=nil;
    if(c.cancelValidation)c.cancelValidation();
    c.cancelValidation=nil;
    if(NSThread.isMainThread)FMClearObserver(c);
    else dispatch_async(dispatch_get_main_queue(), ^{FMClearObserver(c);});
}
static void FMForget(FMReplayCandidate *c) {
    if(byURL[c.url.absoluteString]==c)[byURL removeObjectForKey:c.url.absoluteString];
    [byKey removeObjectForKey:c.key];
    // A late native request using exactly the same URL cannot prove its old
    // provenance. Collisions here only turn off passive adoption, for this process.
    [retiredURLHashes addIndex:(c.url.absoluteString.hash & 0xffff)];
    FMRetire(c);
}
static void FMValidateCandidate(FMReplayCandidate *c,NSURL *staged,NSHTTPURLResponse *response,BOOL fromNativeTransfer) {
    @synchronized(FMLock()){
        if(!FMCurrent(c)||c.validating){[NSFileManager.defaultManager removeItemAtURL:staged error:nil];return;}
        c.validating=YES;
        c.cancelValidation=FMJSValidateReplayAudio(staged,response,^(NSURL *file,NSString *extension){
            BOOL current;
            @synchronized(FMLock()){current=FMCurrent(c) && (!fromNativeTransfer || !c.ambiguous);}
            if(current && file && extension){
                [FMStore() publishVerifiedAudio:file fileExtension:extension forKey:c.key expectedAddress:c.url];
            }
            [NSFileManager.defaultManager removeItemAtURL:staged error:nil];
            @synchronized(FMLock()){c.validating=NO;c.cancelValidation=nil;}
        });
    }
}
static FMReplayFileCompletion FMWrap(FMReplayCandidate *c,FMReplayFileCompletion original) {
    @synchronized(FMLock()){
        if(!FMCurrent(c) || c.ambiguous || c.nativePending || c.validating)return original;
        c.nativePending=YES;
        [c.transfer cancel];c.transfer=nil;
    }
    return ^(NSURL *file,NSURLResponse *response,NSError *error){
        __block NSURL *pinned=nil;
        @synchronized(FMLock()){
            if(FMCurrent(c) && !c.ambiguous && !error && FMCanStoreResponse(response))pinned=FMPin(file,(id)response);
            c.nativePending=NO;
            if([response isKindOfClass:NSHTTPURLResponse.class] && [FMHeader((id)response,@"Cache-Control") containsString:@"no-store"])c.supplementalStarted=YES;
            if(pinned)FMValidateCandidate(c,pinned,(id)response,YES);
        }
        original(file,response,error);
    };
}

// The native automatic-MP3 writer checks its exact destination before it
// creates the shared-session request, both synchronously on the same thread.
static NSString *const FMNativeDestinationSlot = @"FMReplay.automaticDestination";
static NSMutableDictionary<NSString *, NSNumber *> *nativeGenerations;
static IMP originalFileExists, originalDownload;
static uintptr_t nativeFileCheckReturn;
static NSURL *nativeMusicDirectory;

static BOOL FMObserveDestination(id receiver, SEL command, NSString *path) {
    BOOL exists = ((BOOL(*)(id,SEL,id))originalFileExists)(receiver,command,path);
    uintptr_t caller=(uintptr_t)__builtin_extract_return_addr(__builtin_return_address(0));
#if __has_feature(ptrauth_calls)
    caller=(uintptr_t)ptrauth_strip((void *)caller,ptrauth_key_return_address);
#endif
    if (caller != nativeFileCheckReturn) return exists;
    NSMutableDictionary *state = NSThread.currentThread.threadDictionary;
    [state removeObjectForKey:FMNativeDestinationSlot];
    if (exists || ![path.pathExtension isEqual:@"mp3"] ||
        ![path.stringByDeletingLastPathComponent isEqual:nativeMusicDirectory.path]) return exists;
    NSString *base = path.lastPathComponent.stringByDeletingPathExtension;
    if (base.length) @synchronized(FMLock()) {
        state[FMNativeDestinationSlot] = @[base, nativeGenerations[base] ?: @0];
    }
    return exists;
}

static FMReplayFileCompletion FMGuardNativeAuto(NSArray *ticket, FMReplayFileCompletion callback) {
    if (ticket.count != 2) return callback;
    return ^(NSURL *file, NSURLResponse *response, NSError *error) {
        // This callback belongs only to the native background MusicCache writer.
        // Hold the song-clear boundary through its synchronous file operation.
        @synchronized(FMLock()) {
            BOOL valid = [(nativeGenerations[ticket[0]] ?: @0) isEqual:ticket[1]];
            if (valid) callback(file,response,error);
            else callback(nil,response,[NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorCancelled userInfo:nil]);
        }
    };
}
static uintptr_t nativeReturn;
static NSURLSessionDownloadTask *FMObserveAutoDownload(NSURLSession *session,SEL selector,NSURLRequest *request,FMReplayFileCompletion completion) {
    uintptr_t caller=(uintptr_t)__builtin_extract_return_addr(__builtin_return_address(0));
#if __has_feature(ptrauth_calls)
    caller=(uintptr_t)ptrauth_strip((void *)caller,ptrauth_key_return_address);
#endif
    if(caller==nativeReturn && completion && session==NSURLSession.sharedSession && [request.HTTPMethod isEqual:@"GET"] && request.URL.absoluteString.length){
        NSMutableDictionary *state = NSThread.currentThread.threadDictionary;
        NSArray *ticket = state[FMNativeDestinationSlot];
        [state removeObjectForKey:FMNativeDestinationSlot];
        completion = FMGuardNativeAuto(ticket,completion);
        @synchronized(FMLock()){
            FMReplayCandidate *candidate=byURL[request.URL.absoluteString];
            if(candidate)completion=FMWrap(candidate,completion);
        }
    }
    return ((id(*)(id,SEL,id,FMReplayFileCompletion))originalDownload)(session,selector,request,completion);
}
static BOOL FMCheckNativeImage(void) {
    const struct mach_header_64 *h=(const void *)_dyld_get_image_header(0);
    if(!h || h->magic!=MH_MAGIC_64 || h->cputype!=CPU_TYPE_ARM64 || h->filetype!=MH_EXECUTE || h->ncmds>1024 || h->sizeofcmds>65536)return NO;
    const uint8_t uuid[]={0x21,0x2e,0x31,0x08,0x9a,0x0c,0x33,0x09,0xbe,0xdc,0x7e,0x99,0x6e,0x81,0x99,0xd1};
    const uint8_t *p=(const uint8_t *)(h+1),*end=p+h->sizeofcmds;BOOL identity=NO,range=NO;
    for(NSUInteger i=0;i<h->ncmds;i++){
        if(end-p<(ptrdiff_t)sizeof(struct load_command))return NO;
        const struct load_command *lc=(const void *)p;if(lc->cmdsize<sizeof(*lc)||lc->cmdsize>(NSUInteger)(end-p))return NO;
        if(lc->cmd==LC_UUID && lc->cmdsize==sizeof(struct uuid_command))identity=!memcmp(((const struct uuid_command *)lc)->uuid,uuid,16);
        if(lc->cmd==LC_SEGMENT_64 && lc->cmdsize>=sizeof(struct segment_command_64)){
            const struct segment_command_64 *s=(const void *)lc;
            if(!strncmp(s->segname,"__TEXT",16) && s->fileoff==0 && s->filesize>=0x73528 && (s->initprot&4))range=YES;
        }
        p+=lc->cmdsize;
    }
    if(!identity || !range)return NO;
    const unsigned char expected[]={0x36,0xe5,0x4e,0x4c,0xda,0xe2,0x8d,0xa8,0xb3,0x36,0xff,0xc4,0x92,0x2b,0xff,0xaf,0x01,0x41,0x17,0xf5,0x0c,0x61,0xf0,0xaf,0x24,0xf0,0x90,0x21,0xe4,0xd3,0x8c,0x81};
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];CC_SHA256((const uint8_t *)h+0x734d8,80,digest);
    if(memcmp(digest,expected,sizeof(expected)))return NO;
    uint32_t checkedCall;
    memcpy(&checkedCall, (const uint8_t *)h + 0x733a4, sizeof(checkedCall));
    if (checkedCall != (0x94000000u | ((0x40ae00u-0x733a4u)/4))) return NO;
    nativeFileCheckReturn=(uintptr_t)h+0x733a8;
    nativeReturn=(uintptr_t)h+0x734fc;
    return YES;
}
static void FMInstall(void) {
    static dispatch_once_t once;
    dispatch_once(&once,^{
        if(!FMCheckNativeImage())return;
        Class cls=object_getClass(NSURLSession.sharedSession);
        SEL sel=@selector(downloadTaskWithRequest:completionHandler:);
        Method m=class_getInstanceMethod(cls,sel);
        if(!m || method_getNumberOfArguments(m)!=4)return;
        Class files = object_getClass(NSFileManager.defaultManager);
        SEL probe = @selector(fileExistsAtPath:);
        Method check = class_getInstanceMethod(files,probe);
        if (!check || method_getNumberOfArguments(check)!=3) return;
        NSURL *caches = [NSFileManager.defaultManager URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask].firstObject;
        nativeMusicDirectory = [caches URLByAppendingPathComponent:@"MusicCache" isDirectory:YES];
        nativeGenerations = [NSMutableDictionary dictionary];
        originalFileExists = method_getImplementation(check);
        class_replaceMethod(files,probe,(IMP)FMObserveDestination,method_getTypeEncoding(check));
        originalDownload=method_getImplementation(m);
        class_replaceMethod(cls,sel,(IMP)FMObserveAutoDownload,method_getTypeEncoding(m));
    });
}

@implementation FMReplayTransfer
- (void)start {
    FMReplayCandidate *c=self.candidate;if(!c)return;
    NSURLSessionConfiguration *cfg=NSURLSessionConfiguration.ephemeralSessionConfiguration;
    cfg.URLCache=nil;cfg.HTTPCookieStorage=nil;cfg.URLCredentialStorage=nil;
    cfg.requestCachePolicy=NSURLRequestReloadIgnoringLocalCacheData;
    cfg.timeoutIntervalForRequest=15;cfg.timeoutIntervalForResource=180;
    if(@available(iOS 13.0,macOS 10.15,*))cfg.allowsConstrainedNetworkAccess=NO;
    NSMutableURLRequest *request=[NSMutableURLRequest requestWithURL:c.url];
    [request setValue:@"identity" forHTTPHeaderField:@"Accept-Encoding"];
    [request setValue:@"FreeMusicApp" forHTTPHeaderField:@"User-Agent"];
    self.session=[NSURLSession sessionWithConfiguration:cfg delegate:self delegateQueue:nil];
    [[self.session downloadTaskWithRequest:request] resume];
}
- (void)cancel { [self.session invalidateAndCancel]; }
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task willPerformHTTPRedirection:(NSHTTPURLResponse *)r newRequest:(NSURLRequest *)request completionHandler:(void (^)(NSURLRequest *))completion {
    completion(FMRemote(request.URL)?request:nil);
}
- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)task didWriteData:(int64_t)written totalBytesWritten:(int64_t)total totalBytesExpectedToWrite:(int64_t)expected {
    if(!FMCanStoreResponse(task.response) || total>FMReplayLimit || total>expected)[task cancel];
}
- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)task didFinishDownloadingToURL:(NSURL *)file {
    if(FMCanStoreResponse(task.response))self.staging=FMPin(file,(id)task.response);
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    NSURL *pinned=self.staging;self.staging=nil;
    @synchronized(FMLock()){
        FMReplayCandidate *c=self.candidate;
        if(c.transfer==self){
            c.transfer=nil;
            if(!error && pinned){FMValidateCandidate(c,pinned,(id)task.response,NO);pinned=nil;}
        }
    }
    if(pinned)[NSFileManager.defaultManager removeItemAtURL:pinned error:nil];
    [session finishTasksAndInvalidate];self.session=nil;
}
@end

// Return YES when watching this player can stop. Native downloads and decode
// validation may still fail, so leave the observer in place for those two states.
static BOOL FMStartIfNeeded(FMReplayCandidate *c) {
    @synchronized(FMLock()){
        if(!FMCurrent(c) || ![FMStore() isCurrentKey:c.key] || c.supplementalStarted)return YES;
        if(c.nativePending || c.validating)return NO;
        if([FMStore() audioForKey:c.key])return YES;
        c.supplementalStarted=YES;
        c.transfer=[FMReplayTransfer new];c.transfer.candidate=c;
        [c.transfer start];
        return YES;
    }
}
#if defined(FMX_REPLAY_MEDIA_TESTING) && FMX_REPLAY_MEDIA_TESTING
void FMReplayMediaTestStore(FMReplayCache *store) {
    fixtureStore=store;
    if (!nativeGenerations) nativeGenerations = [NSMutableDictionary dictionary];
}
FMReplayFileCompletion FMReplayMediaTestNativeWrite(NSString *basename, FMReplayFileCompletion original) {
    return FMGuardNativeAuto(@[basename, nativeGenerations[basename] ?: @0], original);
}
FMReplayFileCompletion FMReplayMediaTestAdopt(NSURL *url,FMReplayFileCompletion completion) {
    @synchronized(FMLock()){
        FMReplayCandidate *c=byURL[url.absoluteString];
        return c ? FMWrap(c,completion) : completion;
    }
}
BOOL FMReplayMediaTestStart(NSString *key) {
    return FMStartIfNeeded(byKey[key]);
}
BOOL FMReplayMediaTestIdle(NSString *key) {
    @synchronized(FMLock()){
        FMReplayCandidate *c=byKey[key];
        return !c.nativePending && !c.validating && !c.transfer;
    }
}
#endif

@implementation FMReplayMedia
+ (void)installAutomaticTransferTracking { FMState(); FMInstall(); }
+ (void)retireNativeAutomaticSong:(NSString *)basename {
    if (!basename.length) return;
    @synchronized(FMLock()) {
        nativeGenerations[basename] = @([nativeGenerations[basename] unsignedLongLongValue]+1);
    }
}
+ (void)registerRemoteURL:(NSURL *)url key:(NSString *)key {
    if(!key.length || !FMRemote(url) || ![FMStore() isCurrentKey:key])return;
    FMState();FMInstall();
    @synchronized(FMLock()){
        FMReplayCandidate *old=byKey[key];
        if([old.url isEqual:url])return;
        if(old)FMForget(old);
        FMReplayCandidate *c=[FMReplayCandidate new];c.key=key;c.url=url;c.order=++sequence;
        FMReplayCandidate *other=byURL[url.absoluteString];
        if(other || [retiredURLHashes containsIndex:(url.absoluteString.hash & 0xffff)]){
            other.ambiguous=YES;c.ambiguous=YES;
        }
        byKey[key]=c;byURL[url.absoluteString]=c;
        if(byKey.count>64){
            FMReplayCandidate *oldest=nil;
            for(FMReplayCandidate *item in byKey.allValues)if(!oldest || item.order<oldest.order)oldest=item;
            FMForget(oldest);
        }
    }
}
+ (void)observePlayer:(AVPlayer *)player remoteURL:(NSURL *)url key:(NSString *)key isCurrent:(BOOL (^)(void))isCurrent {
    if(!NSThread.isMainThread || !player || !isCurrent || !key.length || !FMRemote(url))return;
    FMState();
    FMReplayCandidate *c;@synchronized(FMLock()){c=byKey[key];}
    if(![c.url isEqual:url])return;
    @synchronized(FMLock()){
        FMReplayCandidate *previous=playingCandidate;
        if(previous && previous!=c){
            [previous.transfer cancel];previous.transfer=nil;
            previous.supplementalStarted=NO;
            FMClearObserver(previous);
        }
        playingCandidate=c;
    }
    FMClearObserver(c);
    if([FMStore() audioForKey:key])return;
    __weak AVPlayer *weakPlayer=player;__weak AVPlayerItem *weakItem=player.currentItem;
    __weak FMReplayCandidate *weakCandidate=c;
    NSUInteger observation=c.observation;
    c.player=player;
    c.timeObserver=[player addPeriodicTimeObserverForInterval:CMTimeMake(2,1) queue:dispatch_get_main_queue() usingBlock:^(CMTime time){
        FMReplayCandidate *current=weakCandidate;AVPlayer *p=weakPlayer;AVPlayerItem *item=weakItem;
        if(!current || current.observation!=observation)return;
        if(!isCurrent() || !p || !item || p.currentItem!=item){FMClearObserver(current);return;}
        double position=CMTimeGetSeconds(time),duration=CMTimeGetSeconds(item.duration);
        if(item.status!=AVPlayerItemStatusReadyToPlay || p.timeControlStatus!=AVPlayerTimeControlStatusPlaying ||
           !isfinite(position) || position<2 || !isfinite(duration) || duration<=0 || item.asset.hasProtectedContent)return;
        if(FMStartIfNeeded(current))FMClearObserver(current);
    }];
}
+ (void)playbackSelectionWillChange {
    if(!NSThread.isMainThread)return;
    @synchronized(FMLock()){
        FMReplayCandidate *previous=playingCandidate;
        if(!previous)return;
        FMClearObserver(previous);
        if(previous.transfer){
            [previous.transfer cancel];
            previous.transfer=nil;
            previous.supplementalStarted=NO;
        }
        playingCandidate=nil;
    }
}
+ (void)retireClearedTracks {
    FMState();
    @synchronized(FMLock()) {
        for (FMReplayCandidate *candidate in byKey.allValues) {
            if (![FMStore() isCurrentKey:candidate.key]) FMForget(candidate);
        }
    }
}
+ (void)sourceDidChange {
    FMState();@synchronized(FMLock()){
        for(FMReplayCandidate *c in byKey.allValues)FMForget(c);
    }
}
@end
