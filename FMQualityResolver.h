#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>

NS_ASSUME_NONNULL_BEGIN
FOUNDATION_EXPORT NSString * const FMQualityResolverErrorDomain;
typedef NS_ENUM(NSInteger, FMQualityResolverErrorCode) {
    FMQualityResolverNoSupportedQuality = 1,
    FMQualityResolverExhausted = 2,
    FMQualityResolverSourceChanged = 3,
    FMQualityResolverBusy = 4,
};
typedef void (^FMQualityAttemptCompletion)(NSURL * _Nullable URL, NSError * _Nullable error);
/// Called on main. Return a cancellation block; completion may arrive on any queue.
/// timeout is this attempt's share of the remaining total active-resolution budget.
typedef dispatch_block_t _Nullable (^FMQualityAttemptResolver)(NSString *quality,
    NSTimeInterval timeout, FMQualityAttemptCompletion completion);
typedef void (^FMQualityResolutionCompletion)(NSURL * _Nullable URL,
    NSString * _Nullable requestedQuality, NSError * _Nullable error);

/// One song/source-generation session. All mutable state and callbacks are main-queue confined.
/// Each common quality is attempted once, highest first; kg is restricted to 128k.
/// A successful URL is an unverified candidate, not proof of its actual encoded quality.
@interface FMQualityResolver : NSObject
+ (NSArray<NSString *> *)orderedQualitiesForPlatform:(NSString *)platform
                                supportedQualities:(NSArray<NSString *> *)supportedQualities;
/// timeout is cumulative active resolution time (max 60 seconds), excluding time spent playing.
/// Each attempt gets at most 10 seconds and a fair share of the remaining budget.
/// isCurrent must check the source/generation and is always evaluated on main.
- (instancetype)initWithPlatform:(NSString *)platform
              supportedQualities:(NSArray<NSString *> *)supportedQualities
                         timeout:(NSTimeInterval)timeout
                       isCurrent:(BOOL (^)(void))isCurrent
                         resolve:(FMQualityAttemptResolver)resolve NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
/// Call initially, or again after the previous returned URL fails to play.
/// A duplicate URL is skipped; concurrent next calls fail with Busy without changing the active call.
- (void)nextWithCompletion:(FMQualityResolutionCompletion)completion;
/// Idempotent. Cancels the current attempt and permanently closes this session.
- (void)cancel;
@end
NS_ASSUME_NONNULL_END
