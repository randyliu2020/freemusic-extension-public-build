#import <Foundation/Foundation.h>
#import <TargetConditionals.h>

NS_ASSUME_NONNULL_BEGIN
typedef void (^FMListeningSampleHandler)(NSDictionary * _Nullable track, double elapsed,
                                         double rate, NSDate *date, double uptime);
/// Install synchronously from the early extension constructor, BEFORE the host
/// registers its player time observer. The handler is called on the original
/// observer queue (the inspected app uses main); dispatch persistence yourself.
/// Samples actual AVPlayer time; does not infer progress from wall time or rate.
FOUNDATION_EXPORT void FMListeningCaptureInstall(FMListeningSampleHandler handler);
/// Numeric diagnostics only, no tracks, IDs, paths, or account data.
FOUNDATION_EXPORT NSDictionary<NSString *, NSNumber *> *FMListeningCaptureDiagnostics(void);

#if defined(FMX_LISTENING_CAPTURE_TESTING) && FMX_LISTENING_CAPTURE_TESTING
#if !TARGET_OS_SIMULATOR
#error FMX_LISTENING_CAPTURE_TESTING must never be enabled in a device build
#endif
@class AVPlayer;
/// Authored simulator fixture only. Allows registration by exactly this player
/// instead of the version-locked main executable callsite. Reset with nil.
FOUNDATION_EXPORT void FMListeningCaptureTestAllowPlayer(AVPlayer * _Nullable player);
/// Allows authored com.freemusic.playback becomeCurrent calls in simulator only.
FOUNDATION_EXPORT void FMListeningCaptureTestAllowActivity(BOOL allow);
/// Receives the same measured samples in addition to the production handler.
/// Does not manufacture samples or bypass player/timeControlStatus checks.
FOUNDATION_EXPORT void FMListeningCaptureTestSetSampleObserver(FMListeningSampleHandler _Nullable observer);
#endif
NS_ASSUME_NONNULL_END
