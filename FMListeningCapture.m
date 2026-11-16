#import "FMListeningCapture.h"
#import <AVFoundation/AVFoundation.h>
#import <MediaPlayer/MediaPlayer.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <math.h>
#if __has_feature(ptrauth_calls)
#import <ptrauth.h>
#endif

static id (*FMPreviousAddObserver)(id, SEL, CMTime, dispatch_queue_t, void (^)(CMTime));
static void (*FMPreviousBecomeCurrent)(id, SEL);
static NSObject *FMCaptureLock;
static FMListeningSampleHandler FMSampleHandler;
static BOOL FMMainMatched, FMInstalled;
static uintptr_t FMMainAddress;
static __weak AVPlayer *FMActivePlayer;
static NSUInteger FMObserverGeneration, FMMatchedObservers, FMActivityUpdates, FMSamples, FMMissingMetadata;
static NSDictionary *FMCurrentActivity;
static NSMutableDictionary<NSString *, NSString *> *FMKnownArtists;
#if defined(FMX_LISTENING_CAPTURE_TESTING) && FMX_LISTENING_CAPTURE_TESTING
static __weak AVPlayer *FMTestPlayer;
static BOOL FMTestActivityAllowed, FMTestForced;
static FMListeningSampleHandler FMTestSampleObserver;
#endif

@interface FMListeningObserverState : NSObject
@property(nonatomic) NSUInteger generation;
@property(nonatomic, weak) AVPlayerItem *item;
@property(nonatomic, copy) NSString *trackID;
@property(nonatomic) double lastUptime;
@property(nonatomic) double lastRate;
@end
@implementation FMListeningObserverState
@end

static NSString *FMValidString(id value, NSUInteger limit) {
    return [value isKindOfClass:NSString.class] && [value length] && [value length] <= limit ? value : nil;
}
static BOOL FMVerifyMainImage(void) {
    const struct mach_header_64 *header = (const struct mach_header_64 *)_dyld_get_image_header(0);
    if (!header || header->magic != MH_MAGIC_64 || header->cputype != CPU_TYPE_ARM64 || header->sizeofcmds > 65536 || header->ncmds > 1024) return NO;
    const unsigned char expected[16] = {0x48,0xc7,0x7a,0x33,0x63,0xbc,0x3e,0x8f,0x8f,0xc7,0x5e,0xd6,0x13,0x29,0x24,0xc4};
    const uint8_t *cursor = (const uint8_t *)(header + 1), *end = cursor + header->sizeofcmds;
    BOOL uuid = NO;
    for (uint32_t index = 0; index < header->ncmds; index++) {
        if ((size_t)(end - cursor) < sizeof(struct load_command)) return NO;
        const struct load_command *command = (const struct load_command *)cursor;
        if (command->cmdsize < sizeof(*command) || command->cmdsize > (size_t)(end - cursor)) return NO;
        if (command->cmd == LC_UUID && command->cmdsize == sizeof(struct uuid_command)) uuid = !memcmp(((const struct uuid_command *)command)->uuid, expected, 16);
        cursor += command->cmdsize;
    }
    if (!uuid) return NO;
    // UUID plus the exact inspected public-selector call instructions. The parent
    // packager separately verifies the original binary hash before patching.
    const uint8_t *base = (const uint8_t *)header;
    const uint8_t addCall[4] = {0xa2,0x9f,0x0e,0x94};
    const uint8_t activityOne[4] = {0x5a,0x97,0x0e,0x94};
    const uint8_t activityTwo[4] = {0xf4,0x96,0x0e,0x94};
    if (memcmp(base + 0x618d8, addCall, 4) || memcmp(base + 0x64018, activityOne, 4) || memcmp(base + 0x641b0, activityTwo, 4)) return NO;
    FMMainAddress = (uintptr_t)header; return YES;
}
static uintptr_t FMReturnAddress(void *address) {
#if __has_feature(ptrauth_calls)
    address = ptrauth_strip(address, ptrauth_key_return_address);
#endif
    return (uintptr_t)__builtin_extract_return_addr(address);
}
static BOOL FMMatchesObserver(AVPlayer *player, void *caller) {
    if (FMMainMatched && FMReturnAddress(caller) == FMMainAddress + 0x618dc) return YES;
#if defined(FMX_LISTENING_CAPTURE_TESTING) && FMX_LISTENING_CAPTURE_TESTING
    @synchronized(FMCaptureLock) { return player && player == FMTestPlayer; }
#else
    return NO;
#endif
}
static BOOL FMMatchesActivity(void *caller) {
    uintptr_t address = FMReturnAddress(caller);
    if (FMMainMatched && (address == FMMainAddress + 0x6401c || address == FMMainAddress + 0x641b4)) return YES;
#if defined(FMX_LISTENING_CAPTURE_TESTING) && FMX_LISTENING_CAPTURE_TESTING
    @synchronized(FMCaptureLock) { return FMTestActivityAllowed; }
#else
    return NO;
#endif
}
static NSDictionary *FMNormalize(NSDictionary *info, NSDictionary *activity) {
    NSString *identifier = FMValidString(info[MPNowPlayingInfoPropertyExternalContentIdentifier], 1024);
    NSString *title = FMValidString(activity[@"title"], 1024);
    if (!identifier || !title || ![identifier isEqual:activity[@"trackID"]]) return nil;
    NSString *artist = FMValidString(info[MPMediaItemPropertyArtist], 2048) ?: @"";
    NSString *displayedTitle = FMValidString(info[MPMediaItemPropertyTitle], 2048);
    if (![displayedTitle isEqual:title]) {
        // Only remove a proven, complete song-title prefix. Never split on generic
        // hyphens; both song and performer names can themselves contain them.
        NSString *prefix = [title stringByAppendingString:@" - "];
        artist = [artist hasPrefix:prefix] ? [artist substringFromIndex:prefix.length] : @"";
    }
    if (artist.length) {
        if (FMKnownArtists.count >= 128 && !FMKnownArtists[identifier]) [FMKnownArtists removeAllObjects];
        FMKnownArtists[identifier] = artist;
    } else artist = FMKnownArtists[identifier] ?: @"";
    NSMutableDictionary *track = [@{@"id":identifier, @"title":title, @"artist":artist} mutableCopy];
    NSString *album = FMValidString(info[MPMediaItemPropertyAlbumTitle], 1024);
    NSString *genre = FMValidString(info[MPMediaItemPropertyGenre], 256);
    if (album) track[@"album"] = album;
    if (genre) track[@"genre"] = genre;
    return [track copy];
}
static void FMSample(AVPlayer *player, FMListeningObserverState *state) {
    NSDate *date = NSDate.date; double uptime = NSProcessInfo.processInfo.systemUptime;
    CMTime time = player.currentTime;
    double elapsed = CMTIME_IS_NUMERIC(time) ? CMTimeGetSeconds(time) : NAN;
    double rate = player.timeControlStatus == AVPlayerTimeControlStatusPlaying ? player.rate : 0;
    AVPlayerItem *item = player.currentItem;
    NSDictionary *info = MPNowPlayingInfoCenter.defaultCenter.nowPlayingInfo;
    FMListeningSampleHandler handler = nil; NSDictionary *track = nil; BOOL reset = NO;
#if defined(FMX_LISTENING_CAPTURE_TESTING) && FMX_LISTENING_CAPTURE_TESTING
    FMListeningSampleHandler testObserver = nil;
#endif
    @synchronized(FMCaptureLock) {
        if (player != FMActivePlayer || state.generation != FMObserverGeneration) return;
        track = FMNormalize(info, FMCurrentActivity);
        NSString *identifier = track[@"id"];
        BOOL changed = state.item != item || ![state.trackID isEqual:identifier];
        if (!changed && state.lastRate == rate && uptime - state.lastUptime < 0.5) return;
        reset = state.item && state.item != item;
        state.item = item; state.trackID = identifier; state.lastRate = rate; state.lastUptime = uptime;
        if (!track) FMMissingMetadata++;
        handler = FMSampleHandler; FMSamples++;
#if defined(FMX_LISTENING_CAPTURE_TESTING) && FMX_LISTENING_CAPTURE_TESTING
        testObserver = FMTestSampleObserver;
#endif
    }
    // No synthetic progress. A buffer stall is rate 0 even when intended rate is
    // nonzero; the engine also requires observed currentTime advancement.
    if (handler) {
        if (reset) handler(nil, NAN, 0, date, uptime);
        handler(track, elapsed, rate, date, uptime);
    }
#if defined(FMX_LISTENING_CAPTURE_TESTING) && FMX_LISTENING_CAPTURE_TESTING
    if (testObserver) {
        if (reset) testObserver(nil, NAN, 0, date, uptime);
        testObserver(track, elapsed, rate, date, uptime);
    }
#endif
}
__attribute__((noinline)) static id FMAddObserver(AVPlayer *player, SEL selector, CMTime interval, dispatch_queue_t queue, void (^originalBlock)(CMTime)) {
    void *caller = __builtin_return_address(0);
    if (!originalBlock || !FMMatchesObserver(player, caller)) return FMPreviousAddObserver(player, selector, interval, queue, originalBlock);
    FMListeningObserverState *state = [FMListeningObserverState new];
    @synchronized(FMCaptureLock) {
        state.generation = ++FMObserverGeneration; FMActivePlayer = player; FMMatchedObservers++;
    }
    __weak AVPlayer *weakPlayer = player;
    void (^hostBlock)(CMTime) = [originalBlock copy];
    // Preserve the host queue, requested interval, original block ordering and
    // original opaque return token. No extra timer or player observer is created.
    return FMPreviousAddObserver(player, selector, interval, queue, ^(CMTime time) {
        hostBlock(time);
        AVPlayer *strongPlayer = weakPlayer;
        if (strongPlayer) FMSample(strongPlayer, state);
    });
}
__attribute__((noinline)) static void FMBecomeCurrent(NSUserActivity *activity, SEL selector) {
    void *caller = __builtin_return_address(0);
    FMPreviousBecomeCurrent(activity, selector);
    if (!FMMatchesActivity(caller) || ![activity.activityType isEqualToString:@"com.freemusic.playback"]) return;
    NSString *title = FMValidString(activity.title, 1024);
    NSString *identifier = FMValidString(activity.userInfo[@"trackID"], 1024);
    if (!title || !identifier) return;
    @synchronized(FMCaptureLock) { FMCurrentActivity = @{@"title":title, @"trackID":identifier}; FMActivityUpdates++; }
}
void FMListeningCaptureInstall(FMListeningSampleHandler handler) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        FMCaptureLock = [NSObject new]; FMKnownArtists = [NSMutableDictionary dictionary];
        FMMainMatched = FMVerifyMainImage();
#if !defined(FMX_LISTENING_CAPTURE_TESTING) || !FMX_LISTENING_CAPTURE_TESTING
        if (!FMMainMatched) return;
#endif
        Method observe = class_getInstanceMethod(AVPlayer.class, @selector(addPeriodicTimeObserverForInterval:queue:usingBlock:));
        Method activity = class_getInstanceMethod(NSUserActivity.class, @selector(becomeCurrent));
        if (!observe || !activity) return;
        FMPreviousAddObserver = (void *)method_getImplementation(observe);
        FMPreviousBecomeCurrent = (void *)method_getImplementation(activity);
        method_setImplementation(activity, (IMP)FMBecomeCurrent);
        method_setImplementation(observe, (IMP)FMAddObserver);
        FMInstalled = YES;
    });
    @synchronized(FMCaptureLock) { FMSampleHandler = [handler copy]; }
}
NSDictionary *FMListeningCaptureDiagnostics(void) {
    @synchronized(FMCaptureLock) {
        BOOL forced = NO;
#if defined(FMX_LISTENING_CAPTURE_TESTING) && FMX_LISTENING_CAPTURE_TESTING
        forced = FMTestForced;
#endif
        return @{@"installed":@(FMInstalled), @"mainImageMatched":@(FMMainMatched), @"observerRegistrations":@(FMMatchedObservers), @"activityUpdates":@(FMActivityUpdates), @"samples":@(FMSamples), @"missingMetadataSamples":@(FMMissingMetadata), @"fixtureCapabilityForced":@(forced)};
    }
}
#if defined(FMX_LISTENING_CAPTURE_TESTING) && FMX_LISTENING_CAPTURE_TESTING
void FMListeningCaptureTestAllowPlayer(AVPlayer *player) {
    @synchronized(FMCaptureLock) { FMTestPlayer = player; FMTestForced = YES; }
}
void FMListeningCaptureTestAllowActivity(BOOL allow) {
    @synchronized(FMCaptureLock) { FMTestActivityAllowed = allow; FMTestForced = YES; }
}
void FMListeningCaptureTestSetSampleObserver(FMListeningSampleHandler observer) {
    @synchronized(FMCaptureLock) { FMTestSampleObserver = [observer copy]; }
}
#endif
