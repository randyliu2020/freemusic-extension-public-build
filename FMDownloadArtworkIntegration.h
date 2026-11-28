#import <Foundation/Foundation.h>
@class FMDownloadArtwork;

NS_ASSUME_NONNULL_BEGIN
FOUNDATION_EXPORT void FMDownloadArtworkInstall(void);

// Native 4.2.9 DownloadAssets sidecars are shared by the download list and player.
@interface FMDownloadArtworkIntegration : NSObject
- (instancetype)initWithSupport:(NSURL *)support documents:(NSURL *)documents store:(FMDownloadArtwork *)store;
- (void)start;
- (void)refresh;
@end
NS_ASSUME_NONNULL_END
