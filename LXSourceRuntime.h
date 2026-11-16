#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString * const LXSourceRuntimeErrorDomain;
typedef void (^LXSourceLoadCompletion)(NSDictionary * _Nullable manifest, NSError * _Nullable error);
typedef void (^LXSourceURLCompletion)(NSURL * _Nullable URL, NSError * _Nullable error);

/// One imported source per instance. All JS runs on a dedicated serial queue;
/// all public completions, including updateAlertHandler, run on the main queue.
/// No file APIs, application cookies, credentials or account data are exposed.
/// IMPORTANT: This is API isolation, NOT a resource/security sandbox. Public
/// JavaScriptCore APIs cannot interrupt an infinite loop or cap its heap. Only
/// import trusted scripts. Timeouts finish native requests independently, but
/// cannot stop executing JS; discard timed-out instances, never reuse them.
@interface LXSourceRuntime : NSObject

/// Read LXBootstrap.js from the containing app's resources and pass its contents.
- (instancetype)initWithBootstrapScript:(NSString *)bootstrap NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

/// Updated after successful load. Snapshot safe to read from any thread.
@property (atomic, copy, readonly, nullable) NSDictionary *manifest;
@property (atomic, copy, nullable) void (^updateAlertHandler)(NSDictionary *alert);

/// UTF-8 script <= 2 MiB, timeout clamped to 1...30 seconds. name is a fallback
/// for currentScriptInfo; leading @name/@description/etc. are also parsed.
- (void)loadSource:(NSString *)script
              name:(NSString *)name
           timeout:(NSTimeInterval)timeout
        completion:(LXSourceLoadCompletion)completion;

/// musicInfo must be JSON-compatible metadata without cookies or credentials.
/// Its platform-specific IDs must already match LX's source contract.
/// quality must be listed in the imported source's qualitys (nil for local).
/// Returns a cancellation identifier immediately. Timeout: 1...60 seconds.
- (NSString *)resolveMusicURLForSource:(NSString *)source
                            musicInfo:(NSDictionary *)musicInfo
                              quality:(nullable NSString *)quality
                              timeout:(NSTimeInterval)timeout
                           completion:(LXSourceURLCompletion)completion;
- (void)cancelRequestWithIdentifier:(NSString *)identifier;

/// Idempotent; cancels network requests and timers, fails pending completions.
/// JS references are released on the JS queue when that queue can make progress.
- (void)invalidate;
@end

NS_ASSUME_NONNULL_END
