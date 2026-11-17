#import <Foundation/Foundation.h>
/// Precedes FMExtensionProtocol in session configurations. Only the exact native
/// endpoint is inspected; unrelated platform imports continue down the old path.
@interface FMLXMCLocalProtocol : NSURLProtocol
@end
