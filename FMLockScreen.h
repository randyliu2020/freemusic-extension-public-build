#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Adds generated artwork through the existing public MediaPlayer API.
/// Does not alter playback commands, signing identity or app-launch routing.
FOUNDATION_EXPORT void FMLockScreenInstall(void);
FOUNDATION_EXPORT void FMLockScreenRefresh(void);
FOUNDATION_EXPORT NSDictionary<NSString *, id> *FMLockScreenStatus(void);

#if defined(FMX_LOCKSCREEN_TESTING)
FOUNDATION_EXPORT UIImage * _Nullable FMLockScreenTestPreview(UIImage *image, BOOL portrait);
/// Test-only policy override (nil restores actual power/accessibility state).
FOUNDATION_EXPORT void FMLockScreenTestSetSystemAllowed(NSNumber * _Nullable allowed);
FOUNDATION_EXPORT void FMLockScreenTestWriteMovie(
    UIImage *image, BOOL portrait, NSURL *outputURL,
    BOOL (^shouldContinue)(void),
    void (^completion)(NSURL * _Nullable, NSError * _Nullable));
#endif

NS_ASSUME_NONNULL_END
