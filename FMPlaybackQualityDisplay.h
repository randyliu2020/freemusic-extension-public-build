#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <TargetConditionals.h>

NS_ASSUME_NONNULL_BEGIN
/// Call after the verified native setup has installed the current JS item.
/// All lifecycle and display writes are serialized on the main thread.
/// A nil/empty requestedQuality retires the previous JS probe without changing
/// the original display for a native-only item. The value is never evidence.
FOUNDATION_EXPORT void FMPlaybackQualityDisplayObserve(id manager, AVPlayer *player,
                                                       NSString * _Nullable requestedQuality);
FOUNDATION_EXPORT NSDictionary *FMPlaybackQualityDisplayDiagnostics(void);

/// Evidence contains only decoded AVAsset format descriptions, never URL suffixes
/// or resolver/requested-quality claims. estimatedBitsPerSecond is an estimate.
FOUNDATION_EXPORT NSDictionary *FMPlaybackQualityDescribeFormats(NSArray<NSDictionary *> *formats);

#if defined(FMX_PLAYBACK_QUALITY_TESTING) && FMX_PLAYBACK_QUALITY_TESTING && TARGET_OS_SIMULATOR
FOUNDATION_EXPORT void FMPlaybackQualityTestConfigureReceiver(id _Nullable receiver,
                                                             void * _Nullable setter, BOOL allowed);
/// Delay genuine completed AVAsset probes to exercise item-switch races.
FOUNDATION_EXPORT void FMPlaybackQualityTestHoldCompletedProbes(BOOL hold);
FOUNDATION_EXPORT NSUInteger FMPlaybackQualityTestPendingProbes(void);
FOUNDATION_EXPORT void FMPlaybackQualityTestReleaseOldestProbe(void);
#endif
NS_ASSUME_NONNULL_END
