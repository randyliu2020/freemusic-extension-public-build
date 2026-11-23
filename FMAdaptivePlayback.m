#import "FMAdaptivePlayback.h"
#import "FMQualityResolver.h"
#import "FMPlaybackQualityDisplay.h"
#import "FMPlaybackSequence.h"
#import <CommonCrypto/CommonDigest.h>
#import <math.h>
#import <string.h>
#import <stdio.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>

typedef void (*FMNativeSetup)(const void *, void *, void * __attribute__((swift_context))) __attribute__((swiftcall));
typedef void (*FMNativeFailure)(uintptr_t, void *, uint32_t, void * __attribute__((swift_context))) __attribute__((swiftcall));
extern bool FMAdaptiveBridgeSetupURL(void *owner, void *urlObject);

@interface FMAdaptiveBinding : NSObject
@property(nonatomic,weak) id owner;
@property(nonatomic,weak) AVPlayer *player;
@property(nonatomic,strong) AVPlayerItem *item;
@property(nonatomic,strong) FMQualityResolver *session;
@property(nonatomic,copy) NSString *quality, *trackKey;
@property(nonatomic) NSUInteger revision;
@property(nonatomic) BOOL retired, recovering, waitingRestore, observing;
@property(nonatomic) float intentRate;
@property(nonatomic) double lastTime, resumeTime;
@property(nonatomic,strong) id timer;
- (void)detach;
- (void)watchReady;
@end

@interface FMAdaptiveRegistration : NSObject
@property(nonatomic,strong) FMQualityResolver *session;
@property(nonatomic,copy) NSString *quality, *trackKey;
@property(nonatomic,weak) FMAdaptiveBinding *continuation;
@property(nonatomic) NSTimeInterval created;
@property(nonatomic) BOOL ambiguous;
@end
@implementation FMAdaptiveRegistration @end

static NSMapTable *FMBindings;
static NSMutableDictionary<NSString *,FMAdaptiveRegistration *> *FMURLs;
static void (^FMPlayerObserver)(id,AVPlayer *,NSString *);
static FMNativeSetup FMSetup;
static FMNativeFailure FMFailure;
static BOOL FMImageAllowed, FMHooksInstalled;
static NSUInteger FMBoundCount, FMRetryCount, FMRecoveredCount, FMExhaustedCount, FMCanceledCount, FMAmbiguousCount;
static _Thread_local NSUInteger FMRebuildDepth, FMNativeFailureDepth, FMIntentSuppression;
static const void *FMBindingKey=&FMBindingKey;
static const void *FMReadyContext=&FMReadyContext;
static void (*FMOriginalPlay)(AVPlayer *,SEL);
static void (*FMOriginalPause)(AVPlayer *,SEL);
static void (*FMOriginalRate)(AVPlayer *,SEL,float);
static void FMRestore(FMAdaptiveBinding *binding);
static BOOL FMStillCurrent(FMAdaptiveBinding *binding) {
    return NSThread.isMainThread && !binding.retired && binding.owner &&
        [FMBindings objectForKey:binding.owner]==binding &&
        binding.player && binding.player.currentItem==binding.item;
}
static void FMMain(dispatch_block_t block) {
    if (NSThread.isMainThread) block(); else dispatch_async(dispatch_get_main_queue(),block);
}
static void FMState(void) {
    static dispatch_once_t once;
    dispatch_once(&once,^{ FMBindings=[NSMapTable weakToStrongObjectsMapTable]; FMURLs=NSMutableDictionary.dictionary; });
}
@implementation FMAdaptiveBinding
- (void)detach {
    if (self.observing) {
        [self.item removeObserver:self forKeyPath:@"status" context:(void *)FMReadyContext];
        self.observing=NO;
    }
    AVPlayer *player=self.player;
    if (self.timer && player) [player removeTimeObserver:self.timer];
    self.timer=nil;
    if (player && objc_getAssociatedObject(player,FMBindingKey)==self)
        objc_setAssociatedObject(player,FMBindingKey,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
- (void)watchReady {
    self.observing=YES;
    [self.item addObserver:self forKeyPath:@"status" options:NSKeyValueObservingOptionInitial|NSKeyValueObservingOptionNew context:(void *)FMReadyContext];
}
- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    if (context!=(void *)FMReadyContext) { [super observeValueForKeyPath:keyPath ofObject:object change:change context:context]; return; }
    __weak typeof(self) weak=self;
    FMMain(^{ typeof(self) strong=weak; if(strong && object==strong.item && strong.waitingRestore && FMStillCurrent(strong) && strong.item.status==AVPlayerItemStatusReadyToPlay) FMRestore(strong); });
}
- (void)dealloc { [self detach]; }
@end

static void FMSetIntent(AVPlayer *player,float rate) {
    if (FMRebuildDepth || FMIntentSuppression) return;
    FMAdaptiveBinding *binding=objc_getAssociatedObject(player,FMBindingKey);
    if (!binding) return;
    FMMain(^{ if(FMStillCurrent(binding)) binding.intentRate=isfinite(rate)&&rate>0 ? rate : 0; });
}
static void FMPlay(AVPlayer *player,SEL selector) {
    if(FMRebuildDepth) return; // Rebuild is synchronous; start only after its seek completes.
    FMSetIntent(player,1);
    FMOriginalPlay(player,selector);
}
static void FMPause(AVPlayer *player,SEL selector) {
    FMSetIntent(player,0);
    FMOriginalPause(player,selector);
}
static void FMRate(AVPlayer *player,SEL selector,float rate) {
    if(FMRebuildDepth && rate>0) return;
    FMSetIntent(player,rate);
    FMOriginalRate(player,selector,rate);
}
static BOOL FMDigest(const uint8_t *bytes,size_t size,const char *expected) {
    unsigned char digest[32]; char hex[65];
    CC_SHA256(bytes,(CC_LONG)size,digest);
    for(NSUInteger i=0;i<32;i++)snprintf(hex+i*2,3,"%02x",digest[i]);
    return !strcmp(hex,expected);
}
static BOOL FMVerifyHost(void) {
    const struct mach_header_64 *header=(const struct mach_header_64 *)_dyld_get_image_header(0);
    if(!header || header->magic!=MH_MAGIC_64 || header->cputype!=CPU_TYPE_ARM64 ||
       header->filetype!=MH_EXECUTE || header->ncmds>1024 || header->sizeofcmds>65536)return NO;
    const uint8_t expectedUUID[]={0x21,0x2e,0x31,0x08,0x9a,0x0c,0x33,0x09,0xbe,0xdc,0x7e,0x99,0x6e,0x81,0x99,0xd1};
    BOOL uuid=NO,range=NO;
    const uint8_t *cursor=(const uint8_t *)(header+1),*end=cursor+header->sizeofcmds;
    for(uint32_t i=0;i<header->ncmds;i++){
        if((size_t)(end-cursor)<sizeof(struct load_command))return NO;
        const struct load_command *command=(const struct load_command *)cursor;
        if(command->cmdsize<sizeof(*command)||command->cmdsize>(size_t)(end-cursor))return NO;
        if(command->cmd==LC_UUID&&command->cmdsize==sizeof(struct uuid_command))
            uuid=!memcmp(((const struct uuid_command *)command)->uuid,expectedUUID,16);
        if(command->cmd==LC_SEGMENT_64&&command->cmdsize>=sizeof(struct segment_command_64)){
            const struct segment_command_64 *segment=(const struct segment_command_64 *)command;
            if(!strncmp(segment->segname,"__TEXT",16)&&segment->fileoff==0&&segment->vmaddr==0x100000000ull&&
               segment->filesize>=0x509d40&&segment->vmsize>=0x509d40&&(segment->initprot&5)==5)range=YES;
        }
        cursor+=command->cmdsize;
    }
    if(!uuid||!range)return NO;
    const uint8_t *base=(const uint8_t *)header;
    if(!FMDigest(base+0x581f8,0x928,"f18af736fca1e2c5d742bd4a3e6a4ad4a58fe2f6d4b010b114fae992e4de7f01")||
       !FMDigest(base+0x5aa9c,0x28,"36f8fd0f2f5c16d8851a328afd48364ea03a30dbccd5ad99bdc17872ce90f32f")||
       !FMDigest(base+0x509b40,0x200,"0af3ef088561c992df64de91fcce007305ef8fe76fdd5a54061652825953d9ea"))return NO;
    const uint32_t sites[]={0x58b20,0x5aa98},targets[]={0x509b40,0x509bc0};
    for(NSUInteger i=0;i<2;i++){
        uint32_t value;memcpy(&value,base+sites[i],4);
        if(value!=(0x14000000u|(((targets[i]-sites[i])/4)&0x03ffffffu)))return NO;
    }
    FMSetup=(FMNativeSetup)(base+0x581f8); FMFailure=(FMNativeFailure)(base+0x5aa98);
    return YES;
}
static void FMInstallHooks(void) {
    if(FMHooksInstalled)return;
    Method play=class_getInstanceMethod(AVPlayer.class,@selector(play));
    Method pause=class_getInstanceMethod(AVPlayer.class,@selector(pause));
    Method rate=class_getInstanceMethod(AVPlayer.class,@selector(setRate:));
    if(!play||!pause||!rate)return;
    FMOriginalPlay=(void *)method_getImplementation(play);
    FMOriginalPause=(void *)method_getImplementation(pause);
    FMOriginalRate=(void *)method_getImplementation(rate);
    method_setImplementation(play,(IMP)FMPlay);
    method_setImplementation(pause,(IMP)FMPause);
    method_setImplementation(rate,(IMP)FMRate);
    FMHooksInstalled=YES;
}
void FMAdaptivePlaybackInstall(void) {
    FMState();
    static dispatch_once_t once;
    dispatch_once(&once,^{FMImageAllowed=FMVerifyHost();if(FMImageAllowed)FMInstallHooks();});
}
void FMAdaptivePlaybackSetPlayerObserver(void (^observer)(id,AVPlayer *,NSString *)) {
    FMMain(^{FMPlayerObserver=[observer copy];});
}
static void FMRegister(NSURL *URL,FMQualityResolver *session,NSString *quality,FMAdaptiveBinding *continuation,NSString *trackKey) {
    NSString *key=URL.absoluteString;
    if(!key.length||!session||!quality.length||!trackKey.length)return;
    NSTimeInterval now=NSProcessInfo.processInfo.systemUptime;
    for(NSString *oldKey in FMURLs.allKeys){
        FMAdaptiveRegistration *old=FMURLs[oldKey];
        if(now-old.created>600)[FMURLs removeObjectForKey:oldKey];
    }
    if(FMURLs.count>=64 && !FMURLs[key]){
        NSString *oldest=[FMURLs keysSortedByValueUsingComparator:^NSComparisonResult(FMAdaptiveRegistration *a,FMAdaptiveRegistration *b){return a.created<b.created?NSOrderedAscending:NSOrderedDescending;}].firstObject;
        if(oldest)[FMURLs removeObjectForKey:oldest];
    }
    FMAdaptiveRegistration *existing=FMURLs[key];
    BOOL conflict=existing && (existing.ambiguous || ![existing.trackKey isEqual:trackKey]);
    for(FMAdaptiveBinding *active in FMBindings.objectEnumerator.allObjects) {
        NSURL *activeURL=[active.item.asset isKindOfClass:AVURLAsset.class]?((AVURLAsset *)active.item.asset).URL:nil;
        if(!active.retired && [activeURL.absoluteString isEqual:key] && ![active.trackKey isEqual:trackKey])conflict=YES;
    }
    if(existing && existing.session!=session && !conflict)[existing.session cancel];
    FMAdaptiveRegistration *entry=[FMAdaptiveRegistration new];
    entry.session=session;entry.quality=quality;entry.trackKey=trackKey;entry.continuation=continuation;entry.created=now;entry.ambiguous=conflict;
    if(conflict)FMAmbiguousCount++;
    FMURLs[key]=entry;
}
void FMAdaptivePlaybackRegisterURL(NSURL *URL,FMQualityResolver *session,NSString *requestedQuality,NSString *trackKey) {
    FMState(); NSCAssert(NSThread.isMainThread,@"Adaptive registration must be on main");
    if(!NSThread.isMainThread||!FMImageAllowed)return;
    FMRegister(URL,session,requestedQuality,nil,trackKey);
}
static void FMRetire(FMAdaptiveBinding *binding,BOOL cancel) {
    if(!binding||binding.retired)return;
    binding.retired=YES;binding.revision++;binding.recovering=NO;binding.waitingRestore=NO;
    [binding detach];
    if(cancel)[binding.session cancel];
}
void FMAdaptivePlaybackSelectionWillChange(id manager) {
    FMState();if(!NSThread.isMainThread||!manager)return;
    FMAdaptiveBinding *binding=[FMBindings objectForKey:manager];
    if(binding){FMRetire(binding,YES);[FMBindings removeObjectForKey:manager];FMCanceledCount++;}
}
void FMAdaptivePlaybackSourceTransition(void) {
    FMState();NSCAssert(NSThread.isMainThread,@"Source transition must be on main");
    if(!NSThread.isMainThread)return;
    for(FMAdaptiveRegistration *entry in FMURLs.allValues)[entry.session cancel];
    [FMURLs removeAllObjects];
    for(FMAdaptiveBinding *binding in FMBindings.objectEnumerator.allObjects){FMRetire(binding,YES);FMCanceledCount++;}
    [FMBindings removeAllObjects];
}
void FMAdaptiveNativeDidSetup(id manager,AVPlayer *player) {
    FMState();
    if(!FMImageAllowed||!NSThread.isMainThread||!manager||!player)return;
    AVPlayerItem *item=player.currentItem;
    NSURL *URL=[item.asset isKindOfClass:AVURLAsset.class]?((AVURLAsset *)item.asset).URL:nil;
    FMAdaptiveRegistration *entry=URL ? FMURLs[URL.absoluteString] : nil;
    if(entry && (entry.ambiguous || NSProcessInfo.processInfo.systemUptime-entry.created>600))entry=nil;
    FMAdaptiveBinding *old=[FMBindings objectForKey:manager];
    if(entry.continuation && entry.continuation!=old)entry=nil;
    FMAdaptiveBinding *binding=entry.continuation;
    if(old && old!=binding){FMRetire(old,old.session!=entry.session);[FMBindings removeObjectForKey:manager];}
    FMPlaybackQualityDisplayObserve(manager,player,entry.quality);
    FMPlaybackSequenceDidSetup(manager,player);
    if(FMPlayerObserver)FMPlayerObserver(manager,player,entry.quality);
    if(!entry||!item)return;
    [FMURLs removeObjectForKey:URL.absoluteString];
    if(!binding){binding=[FMAdaptiveBinding new];binding.intentRate=player.rate>0?player.rate:0;binding.lastTime=0;}
    else [binding detach];
    binding.owner=manager;binding.player=player;binding.item=item;binding.session=entry.session;
    binding.quality=entry.quality;binding.trackKey=entry.trackKey;binding.retired=NO;binding.recovering=NO;binding.revision++;
    [FMBindings setObject:binding forKey:manager];
    objc_setAssociatedObject(player,FMBindingKey,binding,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    __weak FMAdaptiveBinding *weak=binding;
    binding.timer=[player addPeriodicTimeObserverForInterval:CMTimeMakeWithSeconds(0.5,600) queue:dispatch_get_main_queue() usingBlock:^(CMTime time){
        FMAdaptiveBinding *current=weak;if(!current||!FMStillCurrent(current))return;
        double seconds=CMTimeGetSeconds(time);if(isfinite(seconds)&&seconds>=0)current.lastTime=seconds;
    }];
    FMBoundCount++;
    if(binding.waitingRestore)[binding watchReady];
}
static void FMRestore(FMAdaptiveBinding *binding) {
    if(!FMStillCurrent(binding)||!binding.waitingRestore)return;
    binding.waitingRestore=NO;
    if(binding.observing){[binding.item removeObserver:binding forKeyPath:@"status" context:(void *)FMReadyContext];binding.observing=NO;}
    AVPlayer *player=binding.player;
    NSUInteger revision=binding.revision;
    double seconds=binding.resumeTime,duration=CMTimeGetSeconds(binding.item.duration);
    if(!isfinite(seconds)||seconds<0)seconds=0;
    if(isfinite(duration)&&duration>0)seconds=MIN(seconds,MAX(0,duration-0.25));
    // Seeking zero also gives an explicit ordering point before user intent resumes.
    [player seekToTime:CMTimeMakeWithSeconds(seconds,600) toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero completionHandler:^(BOOL finished){
        FMMain(^{
            if(!FMStillCurrent(binding)||binding.revision!=revision)return;
            binding.recovering=NO;
            FMIntentSuppression++;
            if(binding.intentRate>0)[player setRate:binding.intentRate];else[player pause];
            FMIntentSuppression--;
            FMRecoveredCount++;
        });
    }];
}
static void FMResumeNativeFailure(FMAdaptiveBinding *binding) {
    if(!FMStillCurrent(binding)||!FMFailure)return;
    id owner=binding.owner;
    FMRetire(binding,NO);
    [FMBindings removeObjectForKey:owner];
    FMExhaustedCount++;
    // Exact original status/failedToEnd call shape: optional value 1/0, reason 4.
    FMNativeFailureDepth++;
    FMFailure(1,NULL,4,(__bridge void *)owner);
    FMNativeFailureDepth--;
}
BOOL FMAdaptiveNativeHandleFailure(id manager,AVPlayer *currentNativePlayer) {
    FMState();
    if(!FMImageAllowed||!NSThread.isMainThread||FMNativeFailureDepth)return NO;
    if(FMPlaybackSequenceSuppressOldFailure(manager,currentNativePlayer))return YES;
    FMAdaptiveBinding *binding=[FMBindings objectForKey:manager];
    if(!binding||binding.player!=currentNativePlayer||!FMStillCurrent(binding))return NO;
    if(binding.recovering)return YES; // duplicate native notifications for this same item
    binding.recovering=YES;binding.revision++;
    double seconds=CMTimeGetSeconds(binding.player.currentTime);
    binding.resumeTime=isfinite(seconds)&&seconds>=0?seconds:binding.lastTime;
    NSUInteger revision=binding.revision;
    FMRetryCount++;
    [binding.session nextWithCompletion:^(NSURL *URL,NSString *quality,NSError *error){
        if(!FMStillCurrent(binding)||binding.revision!=revision)return;
        if(error && ([error.domain isEqual:FMQualityResolverErrorDomain] &&
            (error.code==NSURLErrorCancelled || error.code==NSUserCancelledError || error.code==FMQualityResolverSourceChanged))) {
            id owner=binding.owner;FMRetire(binding,NO);[FMBindings removeObjectForKey:owner];FMCanceledCount++;return;
        }
        if(!URL||error){FMResumeNativeFailure(binding);return;}
        FMRegister(URL,binding.session,quality,binding,binding.trackKey);
        binding.waitingRestore=YES;
        FMRebuildDepth++;
        bool rebuilt=FMAdaptiveBridgeSetupURL((__bridge void *)binding.owner,(__bridge void *)URL);
        FMRebuildDepth--;
        if(!rebuilt || !FMStillCurrent(binding)){if(FMStillCurrent(binding))FMResumeNativeFailure(binding);return;}
        // The native setup trampoline attached the new player and its real host observers.
        if(binding.waitingRestore&&binding.item.status==AVPlayerItemStatusReadyToPlay)FMRestore(binding);
    }];
    return YES;
}
bool FMAdaptiveNativeSetupValue(const void *urlValue,void *owner) {
    if(!FMImageAllowed||!FMSetup||!urlValue||!owner||!NSThread.isMainThread||!FMRebuildDepth)return false;
    FMSetup(urlValue,NULL,owner);
    return true;
}
NSDictionary *FMAdaptivePlaybackDiagnostics(void) {
    if(!NSThread.isMainThread)return @{};
    FMState();
    return @{@"installed":@(FMImageAllowed&&FMHooksInstalled),@"bound":@(FMBoundCount),
        @"retry":@(FMRetryCount),@"recovered":@(FMRecoveredCount),@"exhausted":@(FMExhaustedCount),
        @"cancelled":@(FMCanceledCount),@"ambiguousURLs":@(FMAmbiguousCount),
        @"pending":@(FMURLs.count),@"owners":@(FMBindings.count)};
}
#if defined(FMX_ADAPTIVE_PLAYBACK_TESTING) && FMX_ADAPTIVE_PLAYBACK_TESTING && TARGET_OS_SIMULATOR
void FMAdaptivePlaybackTestConfigureNative(void *setup,void *failure) {
    NSCAssert(NSThread.isMainThread,@"Fixture setup must be on main");
    FMState();FMAdaptivePlaybackSourceTransition();
    FMSetup=(FMNativeSetup)setup;FMFailure=(FMNativeFailure)failure;
    FMImageAllowed=setup&&failure;
    if(FMImageAllowed)FMInstallHooks();
}
#endif

