#import <Foundation/Foundation.h>
#import "FMQualityResolver.h"

NS_ASSUME_NONNULL_BEGIN
FOUNDATION_EXPORT NSString * const FMJSDownloadErrorDomain;
typedef NS_ENUM(NSInteger, FMJSDownloadErrorCode) {
    FMJSDownloadInvalidResponse = 1,
    FMJSDownloadInvalidAudio = 2,
    FMJSDownloadIncompleteFile = 3,
    FMJSDownloadStorageFailure = 4,
    FMJSDownloadSizeLimit = 5,
    FMJSDownloadAlreadyStarted = 6,
};
typedef void (^FMJSDownloadProgress)(int64_t written, int64_t expected, NSString *requestedQuality);
/// Called on main, exactly once. The successful file is temporary: synchronously
/// move/copy it into the host's existing store before returning, like NSURLSession.
/// requestedQuality is the requested candidate, not measured/proven audio quality.
typedef void (^FMJSDownloadCompletion)(NSURL * _Nullable fileURL,
    NSHTTPURLResponse * _Nullable response, NSString * _Nullable requestedQuality,
    NSError * _Nullable error);

/// Decode a completed replay transfer through EOF. Called on a utility queue.
/// The verified file is available only during the synchronous completion block.
FOUNDATION_EXPORT dispatch_block_t FMJSValidateReplayAudio(NSURL *file, NSHTTPURLResponse *response,
    void (^completion)(NSURL * _Nullable verifiedFile, NSString * _Nullable fileExtension));

/// One explicit manual-download operation. Never intercepts unrelated NSURLSession
/// tasks. The resolver must be NEW and exclusively owned by this download; do not
/// reuse a playback resolver or an unrelated download's state based on URL equality.
/// Public methods are thread safe; all user callbacks are delivered on main.
@interface FMJSDownloadCoordinator : NSObject <NSURLSessionDownloadDelegate>
- (instancetype)initWithResolver:(FMQualityResolver *)resolver
                   configuration:(nullable NSURLSessionConfiguration *)configuration
              temporaryDirectory:(NSURL *)temporaryDirectory
                       isCurrent:(BOOL (^)(void))isCurrent NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
- (void)startWithProgress:(nullable FMJSDownloadProgress)progress completion:(FMJSDownloadCompletion)completion;
- (void)suspend;
- (void)resume;
- (void)cancel;
/// Main-thread snapshot; contains counters only, never song IDs, URLs or paths.
- (NSDictionary<NSString *, id> *)diagnostics;
@end
NS_ASSUME_NONNULL_END
