#import <Foundation/Foundation.h>
#import <TargetConditionals.h>

NS_ASSUME_NONNULL_BEGIN
FOUNDATION_EXPORT void FMPlaybackCacheInstall(void);
/// Main-thread transition boundary: native -> initializing -> usable/failed, or
/// usable -> disabled. Servers use original identifiers wy/qq/kg, not LX tx.
/// The set records affected disk namespaces; an empty set still advances RAM.
FOUNDATION_EXPORT void FMPlaybackCacheSourceTransition(NSSet<NSString *> *affectedServers);
FOUNDATION_EXPORT NSDictionary *FMPlaybackCacheDiagnostics(void);
/// Read-only, main-thread snapshot of live receivers captured from the verified
/// native manager initializer. Empty on an unrecognized image or other thread.
FOUNDATION_EXPORT NSArray *FMPlaybackCacheNativeManagers(void);

/// Called by verified main-image trampolines. +1 NSString ownership is explicit;
/// caller bridges to native Swift String, appends, and balances both references.
FOUNDATION_EXPORT NSString * _Nullable FMPlaybackCacheCopySuffix(void) NS_RETURNS_RETAINED;
FOUNDATION_EXPORT BOOL FMPlaybackCacheShouldBypassAutomaticCache(NSString *server);
FOUNDATION_EXPORT BOOL FMPlaybackCacheShouldBypassURL(NSURL *candidate, NSURL *nativeCacheDirectory);

#if defined(FMX_PLAYBACK_CACHE_TESTING) && FMX_PLAYBACK_CACHE_TESTING && TARGET_OS_SIMULATOR
/// Authored fixture uses a genuine Swift instance-method entry, not a C thunk.
FOUNDATION_EXPORT void FMPlaybackCacheTestConfigureReceiver(id _Nullable receiver,
                                                           void * _Nullable swiftMethod,
                                                           BOOL imageAllowed);
#endif
NS_ASSUME_NONNULL_END
