#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>
@class FMQishuiSearchClient;

NS_ASSUME_NONNULL_BEGIN

typedef void (^FMXProtocolCompletion)(NSDictionary * _Nullable payload, NSError * _Nullable error);
typedef BOOL (^FMXParsePredicate)(NSURLRequest *request, NSDictionary<NSString *, NSString *> *parameters);
/// Cleanup reason: nil on success, NSURLErrorCancelled on client cancellation,
/// NSURLErrorTimedOut on the protocol deadline, or the failure that ended handling.
typedef void (^FMXParseCancellation)(NSError * _Nullable reason);
/// Return a cleanup/cancellation block. Complete at most once with a JSON dictionary.
/// aacert parse uses APIResponse; the exact m.kugou.com native route uses top-level url/bitRate.
/// Kugou parameters are synthesized as {server:kg,id:uppercase hash,level:standard}; no native quality is available.
/// The predicate must accept kg only when the active script explicitly supports kg musicUrl at 128k.
/// Playback handling is capped at 45 seconds and still honors any shorter native
/// request deadline. Search/import keep their 20-second cap. Client cancellation is immediate.
typedef FMXParseCancellation _Nullable (^FMXParseHandler)(NSURLRequest *request,
                                                     NSDictionary<NSString *, NSString *> *parameters,
                                                     FMXProtocolCompletion completion);

/// Narrow extension point for FreeMusic 4.2.7 search and parse requests.
@interface FMExtensionProtocol : NSURLProtocol
+ (void)install;
+ (void)setParseHandler:(nullable FMXParseHandler)handler canHandle:(nullable FMXParsePredicate)predicate;
/// Injectable catalogue collaborator; nil restores the verified same-App native configuration loader.
+ (void)setQishuiSearchClient:(nullable FMQishuiSearchClient *)client;
@end

/// Local status only; contains no credentials, request headers, or client configuration values.
FOUNDATION_EXPORT NSDictionary<NSString *, NSString *> *FMXQishuiSearchStatus(void);

/// Strict form/query decoding for a retained body. Duplicate keys or unbuffered streams return nil.
FOUNDATION_EXPORT NSDictionary<NSString *, NSString *> * _Nullable FMXRequestParameters(NSURLRequest *request);
/// Successful responses in platform order (0, 2, 3, qs), with NSNull for failed sources.
/// Merges in stable round-robin order and de-duplicates exact (server,id) pairs.
FOUNDATION_EXPORT NSDictionary *FMXMergeSearchResponses(NSArray *responses, NSInteger page);

NS_ASSUME_NONNULL_END
