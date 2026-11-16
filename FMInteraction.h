#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN
/// Enables UIKit's drag-to-dismiss behavior only for visible result lists whose
/// owning navigation item has a UISearchController with its search field editing.
FOUNDATION_EXPORT void FMInteractionInstall(void);
FOUNDATION_EXPORT void FMInteractionRefresh(void);
/// Counts only; does not expose search terms or view contents.
FOUNDATION_EXPORT NSDictionary<NSString *, NSNumber *> *FMInteractionDiagnostics(void);
NS_ASSUME_NONNULL_END
