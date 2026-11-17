#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <TargetConditionals.h>
#import <stdbool.h>
@class FMQualityResolver;
NS_ASSUME_NONNULL_BEGIN
FOUNDATION_EXPORT void FMAdaptivePlaybackInstall(void);
/// Call on main, before giving this URL to the original host.
FOUNDATION_EXPORT void FMAdaptivePlaybackRegisterURL(NSURL *URL, FMQualityResolver *session, NSString *requestedQuality, NSString *trackKey);
/// Cancels retry ownership; never stops or replaces a healthy current player.
FOUNDATION_EXPORT void FMAdaptivePlaybackSourceTransition(void);
FOUNDATION_EXPORT NSDictionary *FMAdaptivePlaybackDiagnostics(void);
/// Reports a real host setup, including native/non-JS items. Quality is requested, not measured.
FOUNDATION_EXPORT void FMAdaptivePlaybackSetPlayerObserver(void (^ _Nullable observer)(id manager, AVPlayer *player, NSString * _Nullable requestedQuality));
/// Called only by exact, locally verified original-host trampolines.
FOUNDATION_EXPORT void FMAdaptiveNativeDidSetup(id manager, AVPlayer * _Nullable player);
FOUNDATION_EXPORT BOOL FMAdaptiveNativeHandleFailure(id manager, AVPlayer * _Nullable currentNativePlayer);
/// Swift shim owns the real Foundation.URL value for this synchronous call.
FOUNDATION_EXPORT bool FMAdaptiveNativeSetupValue(const void *urlValue, void *owner);
#if defined(FMX_ADAPTIVE_PLAYBACK_TESTING) && FMX_ADAPTIVE_PLAYBACK_TESTING && TARGET_OS_SIMULATOR
FOUNDATION_EXPORT void FMAdaptivePlaybackTestConfigureNative(void * _Nullable setup, void * _Nullable failure);
#endif
NS_ASSUME_NONNULL_END

