#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
@interface FMDownloadArtwork : NSObject
+ (instancetype)sharedStore;
+ (BOOL)isUsableJPEGAtURL:(NSURL *)file;
+ (BOOL)isUsableImageAtURL:(NSURL *)file;
// Only a regular file in the app's download directory is eligible. Completion
// runs on the main queue with a validated, persistent, local JPEG if available.
- (void)resolvePlatform:(NSString *)platform trackID:(NSString *)trackID
              audioFile:(NSURL *)audio coverURL:(nullable NSURL *)coverURL
             completion:(void (^)(NSURL * _Nullable jpeg))completion;
// Separate roots and transport allow offline tests with real files.
- (instancetype)initWithDirectory:(NSURL *)directory downloads:(NSURL *)downloads
                    configuration:(NSURLSessionConfiguration *)configuration;
@end
NS_ASSUME_NONNULL_END
