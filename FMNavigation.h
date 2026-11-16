#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN
/// Host-only installation. Keeps the native five-tab model and identifiers intact.
FOUNDATION_EXPORT void FMNavigationInstall(void);
FOUNDATION_EXPORT void FMNavigationRefresh(void);
/// Optional profile navigation action, appended without replacing the host's existing settings item.
FOUNDATION_EXPORT void FMNavigationSetProfileAction(void (^ _Nullable action)(UIViewController *profileController));
/// Ordinary controller integration seam. Returns NO unless the complete native tab set is recognized.
FOUNDATION_EXPORT BOOL FMNavigationConfigureTabController(UITabBarController *controller);
/// Read-only state; never includes account data or screen text.
FOUNDATION_EXPORT NSDictionary<NSString *, id> *FMNavigationDiagnostics(void);
NS_ASSUME_NONNULL_END
