#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Adds a navigation-bar entry only to the visible, positively identified host Settings page.
/// The callback receives that page; the caller owns presenting/pushing its existing panel.
FOUNDATION_EXPORT void FMSettingsEntryInstall(void (^openPanel)(UIViewController *settingsController));
/// Coalesces a visibility check on the main queue; never creates an overlay or a new window.
FOUNDATION_EXPORT void FMSettingsEntryRefresh(void);
/// Read-only counters for diagnosing entry recognition; never returns screen images or recognized text.
FOUNDATION_EXPORT NSDictionary<NSString *, id> *FMSettingsEntryDiagnostics(void);

NS_ASSUME_NONNULL_END
