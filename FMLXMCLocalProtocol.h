#import <Foundation/Foundation.h>
/// Precedes FMExtensionProtocol in session configurations. Only the exact native
/// endpoint is inspected; unrelated platform imports continue down the old path.
@interface FMLXMCLocalProtocol : NSURLProtocol
/// Reads the selected existing cloud playlist using the native list request's
/// current account context. The supplied completion always runs on main.
+ (nullable NSURLSessionDataTask *)loadEditorTracksForKey:(NSString *)key
                      completion:(void (^)(NSError * _Nullable error))completion;
@end
