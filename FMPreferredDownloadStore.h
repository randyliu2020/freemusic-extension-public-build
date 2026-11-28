#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
/// Read-only access to completed, manually downloaded recordings.
@interface FMPreferredDownloadStore : NSObject
+ (instancetype)sharedStore;
- (instancetype)initWithApplicationSupport:(NSURL *)support documents:(NSURL *)documents caches:(NSURL *)caches;
- (nullable NSURL *)lookupTrack:(NSDictionary *)request;
- (nullable NSURL *)lookupServer:(NSString *)server trackID:(NSString *)trackID;
/// Begin one new user selection. Internal playback retries use the same selection.
- (NSUInteger)beginPlaybackSelection;
- (NSUInteger)playbackSelection;
/// Retire a failed file revision for this selection. Stale callbacks are ignored.
- (void)rejectURL:(NSURL *)URL forSelection:(NSUInteger)selection;
@end
NS_ASSUME_NONNULL_END
