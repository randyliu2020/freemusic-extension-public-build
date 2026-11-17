#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <TargetConditionals.h>
NS_ASSUME_NONNULL_BEGIN
FOUNDATION_EXPORT void FMPlaybackSequenceInstall(void);
/// Exact host bridge: its original selection UUID has already been committed.
FOUNDATION_EXPORT void FMPlaybackSequenceNativeSelection(id manager);
FOUNDATION_EXPORT void FMPlaybackSequenceDidSetup(id manager, AVPlayer *player);
FOUNDATION_EXPORT BOOL FMPlaybackSequenceSuppressOldFailure(id manager, AVPlayer * _Nullable player);
FOUNDATION_EXPORT void FMPlaybackSequenceSourceTransition(void);
FOUNDATION_EXPORT NSDictionary *FMPlaybackSequenceDiagnostics(void);
#if defined(FMX_ADAPTIVE_PLAYBACK_TESTING) && FMX_ADAPTIVE_PLAYBACK_TESTING && TARGET_OS_SIMULATOR
FOUNDATION_EXPORT void FMPlaybackSequenceTestConfigure(void * _Nullable reconcile);
FOUNDATION_EXPORT void FMPlaybackSequenceTestTick(id manager, AVPlayer *player, double elapsed, double duration);
#endif
NS_ASSUME_NONNULL_END
