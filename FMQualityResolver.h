#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>

NS_ASSUME_NONNULL_BEGIN
@class AVPlayer;
typedef NS_ENUM(NSUInteger, FMQualityCandidateOrigin) {
    FMQualityCandidateFromJS,
    FMQualityCandidateFromAddressCache,
    FMQualityCandidateFromAudioCache,
};
typedef NSURL * _Nullable (^FMQualityCacheLookup)(NSString *quality, FMQualityCandidateOrigin origin);
typedef void (^FMQualityCacheMutation)(NSString *quality, NSURL *URL);
typedef void (^FMQualityPlayerBinding)(AVPlayer *player, NSURL *URL, NSString *quality);
FOUNDATION_EXPORT NSString * const FMQualityResolverErrorDomain;
typedef NS_ENUM(NSInteger, FMQualityResolverErrorCode) {
    FMQualityResolverNoSupportedQuality = 1,
    FMQualityResolverExhausted = 2,
    FMQualityResolverSourceChanged = 3,
    FMQualityResolverBusy = 4,
};
typedef void (^FMQualityAttemptCompletion)(NSURL * _Nullable URL, NSError * _Nullable error);
/// Called on main. Return a cancellation block; completion may arrive on any queue.
/// timeout is at most 20 seconds, bounded by this next call's remaining budget.
typedef dispatch_block_t _Nullable (^FMQualityAttemptResolver)(NSString *quality,
    NSTimeInterval timeout, FMQualityAttemptCompletion completion);
typedef void (^FMQualityResolutionCompletion)(NSURL * _Nullable URL,
    NSString * _Nullable requestedQuality, NSError * _Nullable error);

/// One song/source-generation session. All mutable state and callbacks are main-queue confined.
/// Common qualities are tried highest first; kg is restricted to 128k. Replay-enabled
/// sessions can refresh a remotely delivered candidate once after a media failure.
/// A successful URL is an unverified candidate, not proof of its actual encoded quality.
@interface FMQualityResolver : NSObject
+ (NSArray<NSString *> *)orderedQualitiesForPlatform:(NSString *)platform
                                supportedQualities:(NSArray<NSString *> *)supportedQualities;
/// timeout bounds one candidate-resolution call (max 60 seconds). Explicit
/// failures immediately advance; each attempt gets up to 20 seconds of the
/// remaining budget so a source can perform its own ordered fallback first.
/// A returned candidate's later media failure permits a new next call with the
/// same budget. Metadata-only failures stay within that call's original deadline.
/// isCurrent must check the source/generation and is always evaluated on main.
- (instancetype)initWithPlatform:(NSString *)platform
              supportedQualities:(NSArray<NSString *> *)supportedQualities
                         timeout:(NSTimeInterval)timeout
                       isCurrent:(BOOL (^)(void))isCurrent
                         resolve:(FMQualityAttemptResolver)resolve NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
/// Configure a playback session on main before its first next call. Download
/// sessions without these callbacks keep their independent JS quality ladder.
- (void)setReplayLookup:(FMQualityCacheLookup)lookup
            saveAddress:(FMQualityCacheMutation)saveAddress
          discardFailed:(FMQualityCacheMutation)discardFailed;
@property(nonatomic,readonly) FMQualityCandidateOrigin lastCandidateOrigin;
/// Invoked on main before handing a current remote playback candidate to the host.
@property(nonatomic,copy,nullable) FMQualityCacheMutation willUseRemoteURL;
/// Called by the verified playback binding, also on recovery to a later URL.
@property(nonatomic,copy,nullable) FMQualityPlayerBinding didBindPlayer;
/// Call initially, or again after the previous returned URL fails to play/download.
/// Only successful candidate delivery renews the budget for a later next call;
/// metadata failures and duplicate URLs within one call share its original limit.
/// A duplicate URL is skipped except for the single same-quality JS refresh,
/// where the server may recover at an unchanged URL. Concurrent calls report Busy.
- (void)nextWithCompletion:(FMQualityResolutionCompletion)completion;
/// Idempotent. Cancels the current attempt and permanently closes this session.
- (void)cancel;
@end
NS_ASSUME_NONNULL_END
