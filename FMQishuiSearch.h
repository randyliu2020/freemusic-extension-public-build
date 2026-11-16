#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>

NS_ASSUME_NONNULL_BEGIN
FOUNDATION_EXPORT NSArray<NSString *> *FMXQishuiConfigurationKeys(void);
/// Only FreeMusic 4.2.7's verified Mach-O UUID and public client configuration layout are accepted.
/// Returned values must never be logged or persisted by the extension.
FOUNDATION_EXPORT NSDictionary * _Nullable FMXQishuiConfigurationFromExecutable(NSData *data);
/// Maps the documented-by-native-code tracks group to FreeMusic tracks. No playback URL is synthesized.
FOUNDATION_EXPORT NSDictionary * _Nullable FMXQishuiDecodeSearch(NSDictionary *response, NSError **error);
FOUNDATION_EXPORT NSString * const FMXQishuiSearchStatusDidChangeNotification;
typedef void (^FMXQishuiCompletion)(NSDictionary * _Nullable response, NSError * _Nullable error);
typedef void (^FMXQishuiCancellation)(NSError * _Nullable reason);

@interface FMQishuiSearchClient : NSObject
/// Ordinary dependency injection: configuration = {query:{whitelisted string fields},trigger_type:string}.
/// Uses only the two fixed native catalogue endpoints. Configuration cannot change destinations.
- (instancetype)initWithConfiguration:(nullable NSDictionary *)configuration deviceID:(NSString *)deviceID;
- (instancetype)initWithConfiguration:(nullable NSDictionary *)configuration deviceID:(NSString *)deviceID sessionConfiguration:(NSURLSessionConfiguration *)sessionConfiguration;
+ (instancetype)nativeClient;
/// Zero-based native page; cursor continuity is maintained in memory, never guessed from page number.
- (FMXQishuiCancellation)search:(NSString *)keyword page:(NSInteger)page timeout:(NSTimeInterval)timeout completion:(FMXQishuiCompletion)completion;
- (NSDictionary<NSString *, NSString *> *)status;
@end
NS_ASSUME_NONNULL_END
