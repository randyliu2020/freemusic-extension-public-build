#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
/// Read-only access to completed, manually downloaded recordings.
@interface FMPreferredDownloadStore : NSObject
+ (instancetype)sharedStore;
- (instancetype)initWithApplicationSupport:(NSURL *)support documents:(NSURL *)documents caches:(NSURL *)caches;
- (nullable NSURL *)lookupTrack:(NSDictionary *)request;
- (nullable NSURL *)lookupServer:(NSString *)server trackID:(NSString *)trackID;
/// Suppress a failed version until a new file replaces it. Never removes a user's download.
- (void)rejectURL:(NSURL *)URL;
@end
NS_ASSUME_NONNULL_END
