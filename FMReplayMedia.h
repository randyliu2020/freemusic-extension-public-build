#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface FMReplayMedia : NSObject
/// Called before a JS playback result is returned to the native host.
+ (void)registerRemoteURL:(NSURL *)url key:(NSString *)key;
/// Called only for a real native player binding, on the main thread.
+ (void)observePlayer:(AVPlayer *)player remoteURL:(NSURL *)url key:(NSString *)key isCurrent:(BOOL (^)(void))isCurrent;
+ (void)playbackSelectionWillChange;
+ (void)sourceDidChange;
@end

NS_ASSUME_NONNULL_END
