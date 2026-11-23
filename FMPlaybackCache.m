#import "FMPlaybackCache.h"
#import <CommonCrypto/CommonDigest.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#if __has_feature(ptrauth_calls)
#import <ptrauth.h>
#endif

// No raw writes into Swift objects, no KVC, and no synthetic player events.
// The exact original quality-picker invalidator accepts only Swift self (x20).
typedef void (*FMCacheNativeInvalidator)(
    void * __attribute__((swift_context))) __attribute__((swiftcall));
typedef id (*FMCacheInitIMP)(id __attribute__((ns_consumed)), SEL)
    __attribute__((ns_returns_retained));

static NSObject *FMCacheLock;
static NSHashTable *FMCacheReceivers;
static NSSet<NSString *> *FMCacheTaintedServers;
static NSString *FMCacheProcessID, *FMCacheSuffix;
static NSUInteger FMCacheGeneration, FMCacheInvalidations, FMCacheRejectedThreadCalls;
static BOOL FMCacheImageMatched, FMCacheInstalled;
static uintptr_t FMCacheMainBase;
static FMCacheNativeInvalidator FMCacheInvalidate;
static FMCacheInitIMP FMCachePreviousInit;
static NSString *const FMCacheTaintKey = @"FMX.playbackCache.taintedServers";
#if defined(FMX_PLAYBACK_CACHE_TESTING) && FMX_PLAYBACK_CACHE_TESTING && TARGET_OS_SIMULATOR
static BOOL FMCacheFixtureConfigured, FMCacheFixtureAllowed;
static FMCacheNativeInvalidator FMCacheFixtureInvalidator;
static __weak id FMCacheFixtureReceiver;
#endif

static BOOL FMCacheEnabledLocked(void) {
#if defined(FMX_PLAYBACK_CACHE_TESTING) && FMX_PLAYBACK_CACHE_TESTING && TARGET_OS_SIMULATOR
    if (FMCacheFixtureConfigured) return FMCacheFixtureAllowed;
#endif
    return FMCacheImageMatched && FMCacheInstalled;
}
static NSSet<NSString *> *FMCacheSanitizeServers(id value) {
    NSMutableSet *result = [NSMutableSet set];
    if (![value isKindOfClass:NSArray.class] && ![value isKindOfClass:NSSet.class]) return result;
    for (id item in value) {
        if ([item isKindOfClass:NSString.class] &&
            ([@"wy" isEqual:item] || [@"qq" isEqual:item] || [@"kg" isEqual:item])) [result addObject:item];
    }
    return [result copy];
}
static void FMCachePrepareState(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        FMCacheLock = [NSObject new];
        FMCacheReceivers = NSHashTable.weakObjectsHashTable;
        FMCacheTaintedServers = FMCacheSanitizeServers([NSUserDefaults.standardUserDefaults objectForKey:FMCacheTaintKey]);
        FMCacheProcessID = NSUUID.UUID.UUIDString;
        FMCacheSuffix = [NSString stringWithFormat:@"|FMX:%@:0", FMCacheProcessID];
    });
}
static BOOL FMCacheDigest(const uint8_t *bytes, size_t length, const char *expected) {
    if (!bytes || length > UINT32_MAX || strlen(expected) != 64) return NO;
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(bytes, (CC_LONG)length, digest);
    char hex[65];
    for (NSUInteger i=0;i<32;i++) snprintf(hex+i*2,3,"%02x",digest[i]);
    return !strcmp(hex,expected);
}
static uintptr_t FMCacheIMPAddress(IMP imp) {
#if __has_feature(ptrauth_calls)
    return (uintptr_t)ptrauth_strip((void *)imp,ptrauth_key_function_pointer);
#else
    return (uintptr_t)imp;
#endif
}
static BOOL FMCacheVerifyImage(void) {
    const struct mach_header_64 *header=(const struct mach_header_64 *)_dyld_get_image_header(0);
    if (!header || header->magic!=MH_MAGIC_64 || header->cputype!=CPU_TYPE_ARM64 ||
        header->filetype!=MH_EXECUTE || header->ncmds>1024 || header->sizeofcmds>65536) return NO;
    const uint8_t uuid[16]={0x21,0x2e,0x31,0x08,0x9a,0x0c,0x33,0x09,0xbe,0xdc,0x7e,0x99,0x6e,0x81,0x99,0xd1};
    const uint8_t *cursor=(const uint8_t *)(header+1),*end=cursor+header->sizeofcmds;
    BOOL matchingUUID=NO, executableRange=NO;
    for (uint32_t i=0;i<header->ncmds;i++) {
        if ((size_t)(end-cursor)<sizeof(struct load_command)) return NO;
        const struct load_command *command=(const struct load_command *)cursor;
        if (command->cmdsize<sizeof(*command) || command->cmdsize>(size_t)(end-cursor)) return NO;
        if (command->cmd==LC_UUID && command->cmdsize==sizeof(struct uuid_command))
            matchingUUID=!memcmp(((const struct uuid_command *)command)->uuid,uuid,16);
        if (command->cmd==LC_SEGMENT_64 && command->cmdsize>=sizeof(struct segment_command_64)) {
            const struct segment_command_64 *segment=(const struct segment_command_64 *)command;
            if (!strncmp(segment->segname,"__TEXT",16) && segment->fileoff==0 &&
                segment->vmaddr==0x100000000ull && segment->filesize>=0x509b40 &&
                segment->vmsize>=0x509b40 && (segment->initprot&5)==5) executableRange=YES;
        }
        cursor+=command->cmdsize;
    }
    if (!matchingUUID || !executableRange) return NO;
    const uint8_t *base=(const uint8_t *)header;
    // Digests, not original app bytecode. Require our complete authored payload,
    // five entry branches, and the untouched init / native invalidator routines.
    if (!FMCacheDigest(base+0x43bc4,0x134,"c712ed770d616dbcfd59e2392bcca2d184e3890edc6145cf09f3234fb26f4202") ||
        !FMCacheDigest(base+0x4a378,0x15c,"180561c7f6cd8cbdde5080d3598d52113a1d705340cf9b9baa4260be3aa360e0") ||
        !FMCacheDigest(base+0x509780,0x3c0,"2e7b3bd62a17e25e4e64113b2e907decaee412cadb143a3fab5cf608facafa4c")) return NO;
    const uint32_t sites[]={0x4b040,0x4de24,0x57130,0x731a0,0x4b320};
    const uint32_t targets[]={0x509780,0x5097a0,0x5097c0,0x5098c0,0x509940};
    for (NSUInteger i=0;i<5;i++) {
        uint32_t word; memcpy(&word,base+sites[i],4);
        uint32_t expected=0x14000000u|(((targets[i]-sites[i])/4)&0x03ffffffu);
        if (word!=expected) return NO;
    }
    FMCacheMainBase=(uintptr_t)header;
    return YES;
}

static id FMCacheInit(id receiver __attribute__((ns_consumed)), SEL selector)
    __attribute__((ns_returns_retained));
static id FMCacheInit(id receiver __attribute__((ns_consumed)), SEL selector) {
    id result=FMCachePreviousInit(receiver,selector);
    if (result) @synchronized(FMCacheLock) { [FMCacheReceivers addObject:result]; }
    return result;
}
void FMPlaybackCacheInstall(void) {
    FMCachePrepareState();
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        if (!FMCacheVerifyImage()) return;
        Class nativeClass=NSClassFromString(@"_TtC9FreeMusic18AudioPlayerManager");
        Method method=nativeClass ? class_getInstanceMethod(nativeClass,sel_registerName("init")) : NULL;
        if (!method || method_getNumberOfArguments(method)!=2 ||
            FMCacheIMPAddress(method_getImplementation(method))!=FMCacheMainBase+0x43bc4) return;
        FMCachePreviousInit=(FMCacheInitIMP)method_getImplementation(method);
        FMCacheInvalidate=(FMCacheNativeInvalidator)(FMCacheMainBase+0x4a378);
        @synchronized(FMCacheLock) { FMCacheImageMatched=YES; FMCacheInstalled=YES; }
        method_setImplementation(method,(IMP)FMCacheInit);
    });
}

void FMPlaybackCacheSourceTransition(NSSet<NSString *> *affectedServers) {
    FMCachePrepareState();
    // Caller serializes runtime activation and source changes with the original
    // UI/Swift dictionaries. Never synchronously hop while holding another lock.
    if (!NSThread.isMainThread) {
        @synchronized(FMCacheLock) { FMCacheRejectedThreadCalls++; }
        return;
    }
    NSArray *receivers; FMCacheNativeInvalidator invalidate;
    @synchronized(FMCacheLock) {
        if (!FMCacheEnabledLocked()) return;
        FMCacheGeneration++;
        FMCacheSuffix=[NSString stringWithFormat:@"|FMX:%@:%lu",FMCacheProcessID,(unsigned long)FMCacheGeneration];
        NSMutableSet *tainted=[FMCacheTaintedServers mutableCopy];
        [tainted unionSet:FMCacheSanitizeServers(affectedServers)];
        FMCacheTaintedServers=[tainted copy];
        [NSUserDefaults.standardUserDefaults setObject:[FMCacheTaintedServers.allObjects sortedArrayUsingSelector:@selector(compare:)] forKey:FMCacheTaintKey];
        receivers=FMCacheReceivers.allObjects; invalidate=FMCacheInvalidate;
#if defined(FMX_PLAYBACK_CACHE_TESTING) && FMX_PLAYBACK_CACHE_TESTING && TARGET_OS_SIMULATOR
        if (FMCacheFixtureConfigured) {
            id receiver=FMCacheFixtureReceiver;
            receivers=receiver ? @[receiver] : @[]; invalidate=FMCacheFixtureInvalidator;
        }
#endif
    }
    // Advance namespace BEFORE clearing. Already-completed/queued old callbacks
    // may repopulate old keys; three original key builders cannot select them.
    for (id receiver in receivers) {
        if (!invalidate) continue;
        invalidate((__bridge void *)receiver);
        @synchronized(FMCacheLock) { FMCacheInvalidations++; }
    }
}

NSString *FMPlaybackCacheCopySuffix(void) {
    FMCachePrepareState();
    @synchronized(FMCacheLock) { return FMCacheEnabledLocked() ? [FMCacheSuffix copy] : nil; }
}
BOOL FMPlaybackCacheShouldBypassAutomaticCache(NSString *server) {
    FMCachePrepareState();
    if (![server isKindOfClass:NSString.class]) return NO;
    @synchronized(FMCacheLock) { return FMCacheEnabledLocked() && [FMCacheTaintedServers containsObject:server]; }
}
BOOL FMPlaybackCacheShouldBypassURL(NSURL *candidate, NSURL *nativeCacheDirectory) {
    if (![candidate isKindOfClass:NSURL.class] || ![nativeCacheDirectory isKindOfClass:NSURL.class] ||
        !candidate.isFileURL || !nativeCacheDirectory.isFileURL) return NO;
    NSString *path=candidate.path.stringByStandardizingPath;
    NSString *directory=nativeCacheDirectory.path.stringByStandardizingPath;
    if (!path.length || !directory.length || [directory isEqual:@"/"]) return NO;
    NSString *prefix=[directory hasSuffix:@"/"] ? directory : [directory stringByAppendingString:@"/"];
    if (![path hasPrefix:prefix]) return NO;
    NSString *filename=candidate.lastPathComponent;
    NSRange separator=[filename rangeOfString:@"_"];
    if (separator.location==NSNotFound || separator.location==0) return NO;
    return FMPlaybackCacheShouldBypassAutomaticCache([filename substringToIndex:separator.location]);
}
NSDictionary *FMPlaybackCacheDiagnostics(void) {
    FMCachePrepareState();
    @synchronized(FMCacheLock) {
        return @{@"installed":@(FMCacheInstalled),@"imageMatched":@(FMCacheImageMatched),
                 @"generation":@(FMCacheGeneration),@"invalidations":@(FMCacheInvalidations),
                 @"capturedManagers":@(FMCacheReceivers.allObjects.count),
                 @"enabled":@(FMCacheEnabledLocked()),@"rejectedThreadCalls":@(FMCacheRejectedThreadCalls),
                 @"persistentBypassServers":[FMCacheTaintedServers.allObjects sortedArrayUsingSelector:@selector(compare:)]};
    }
}
NSArray *FMPlaybackCacheNativeManagers(void) {
    FMCachePrepareState();
    if (!NSThread.isMainThread) return @[];
    @synchronized(FMCacheLock) {
        // Test-only receiver injection must never make a non-native object
        // available to production ABI consumers.
        if (!FMCacheImageMatched || !FMCacheInstalled) return @[];
        return [FMCacheReceivers.allObjects copy];
    }
}
#if defined(FMX_PLAYBACK_CACHE_TESTING) && FMX_PLAYBACK_CACHE_TESTING && TARGET_OS_SIMULATOR
void FMPlaybackCacheTestConfigureReceiver(id receiver, void *swiftMethod, BOOL imageAllowed) {
    FMCachePrepareState();
    NSCAssert(NSThread.isMainThread,@"Fixture transitions must be on the UI thread");
    @synchronized(FMCacheLock) {
        FMCacheFixtureConfigured=YES;
        FMCacheFixtureAllowed=imageAllowed && receiver && swiftMethod;
        FMCacheFixtureReceiver=receiver;
        FMCacheFixtureInvalidator=(FMCacheNativeInvalidator)swiftMethod;
    }
}
#endif
