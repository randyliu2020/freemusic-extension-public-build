#import "FMSongCacheAction.h"
#import "FMDownloadFiles.h"
#import "FMPlaybackCache.h"
#import "FMReplayCache.h"
#import "FMReplayMedia.h"
#import <UIKit/UIKit.h>

static void FMShowSongCacheResult(NSString *message) {
    static __weak UIView *previous;
    [previous removeFromSuperview];
    UIWindow *window = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (scene.activationState == UISceneActivationStateForegroundActive && [scene isKindOfClass:UIWindowScene.class]) {
            window = ((UIWindowScene *)scene).keyWindow;
            if (window) break;
        }
    }
    if (!window) return;
    UIVisualEffectView *banner = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThickMaterial]];
    banner.userInteractionEnabled = NO;
    banner.clipsToBounds = YES;
    banner.layer.cornerRadius = 14;
    UILabel *label = [UILabel new];
    label.text = message;
    label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    label.adjustsFontForContentSizeCategory = YES;
    label.numberOfLines = 0;
    label.textAlignment = NSTextAlignmentCenter;
    label.accessibilityIdentifier = @"FMX.songCache.result";
    [banner.contentView addSubview:label];
    [window addSubview:banner];
    banner.translatesAutoresizingMaskIntoConstraints = NO;
    label.translatesAutoresizingMaskIntoConstraints = NO;
    UILayoutGuide *safe = window.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [label.topAnchor constraintEqualToAnchor:banner.contentView.topAnchor constant:10],
        [label.bottomAnchor constraintEqualToAnchor:banner.contentView.bottomAnchor constant:-10],
        [label.leadingAnchor constraintEqualToAnchor:banner.contentView.leadingAnchor constant:16],
        [label.trailingAnchor constraintEqualToAnchor:banner.contentView.trailingAnchor constant:-16],
        [banner.topAnchor constraintEqualToAnchor:safe.topAnchor constant:12],
        [banner.centerXAnchor constraintEqualToAnchor:safe.centerXAnchor],
        [banner.widthAnchor constraintLessThanOrEqualToAnchor:safe.widthAnchor constant:-32]
    ]];
    previous = banner;
    UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification, message);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [banner removeFromSuperview];
    });
}

void FMXClearSongCache(NSString *nativeServer, NSString *trackID) {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ FMXClearSongCache(nativeServer, trackID); });
        return;
    }
    NSString *platform = FMDASource(nativeServer);
    NSString *identifier = FMDAIdentifier(trackID);
    if (!platform || !identifier) {
        FMShowSongCacheResult(@"无法识别这首歌，缓存已保留");
        return;
    }
    NSUInteger entries = 0, files = 0;
    BOOL replayOK = [FMReplayCache.sharedCache clearPlatform:platform trackID:identifier removedEntries:&entries];
    BOOL nativeOK = FMPlaybackCacheClearTrack(nativeServer, identifier, &files);
    [FMReplayMedia retireClearedTracks];
    NSString *result;
    if (!replayOK || !nativeOK) result = @"缓存未完全清除，请重试";
    else if (entries || files) result = @"已清除这首歌的播放缓存";
    else result = @"这首歌的播放缓存已重置";
    FMShowSongCacheResult(result);
#if defined(FMX_PLAYBACK_CACHE_TESTING) && FMX_PLAYBACK_CACHE_TESTING && TARGET_OS_SIMULATOR
    [NSNotificationCenter.defaultCenter postNotificationName:@"FMX.songCache.testCompleted" object:nil
        userInfo:@{@"server":nativeServer, @"id":identifier}];
#endif
}
