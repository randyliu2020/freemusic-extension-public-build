#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
/// Migrate only extension-owned settings. Unrelated app/account keys are untouched.
/// A durable journal precedes writes; an interrupted upgrade is restored first.
FOUNDATION_EXPORT BOOL FMSettingsMigrate(NSUserDefaults *defaults, NSString *domain, NSError * _Nullable * _Nullable error);
FOUNDATION_EXPORT BOOL FMSettingsPrepareStandard(NSError * _Nullable * _Nullable error);
FOUNDATION_EXPORT NSInteger FMSettingsCurrentSchema(void);
/// Persist a successfully initialized source before clearing its interruption marker.
FOUNDATION_EXPORT BOOL FMSettingsCommitSourceSelection(NSUserDefaults *defaults, NSString *filename, NSError * _Nullable * _Nullable error);
NS_ASSUME_NONNULL_END
