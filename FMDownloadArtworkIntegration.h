#import <Foundation/Foundation.h>
@class FMDownloadArtwork;

NS_ASSUME_NONNULL_BEGIN
FOUNDATION_EXPORT void FMDownloadArtworkInstall(void);
// Main queue. userInfo contains server, id, trackKey strings, expectedCover
// (the index's original string or NSNull) and coverURL (the local native URL).
FOUNDATION_EXPORT NSNotificationName const FMDownloadArtworkDidRecoverNotification;
FOUNDATION_EXPORT NSNotificationName const FMDownloadArtworkStatusDidChangeNotification;
FOUNDATION_EXPORT NSDictionary *FMDownloadArtworkStatus(void);

// Native 4.2.9 DownloadAssets sidecars are shared by the download list and player.
@interface FMDownloadArtworkIntegration : NSObject
- (instancetype)initWithSupport:(NSURL *)support documents:(NSURL *)documents store:(FMDownloadArtwork *)store;
- (void)start;
- (void)refresh;
- (NSDictionary *)status;
@end
NS_ASSUME_NONNULL_END
