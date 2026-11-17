#import <Foundation/Foundation.h>
#import "FMQualityResolver.h"

NS_ASSUME_NONNULL_BEGIN
/// Each invocation creates a NEW resolver, exclusively owned by one manual download.
/// Invoked on main; never return a resolver already used for playback.
typedef FMQualityResolver * _Nullable (^FMDownloadResolverFactory)(void);
FOUNDATION_EXPORT void FMDownloadIntegrationInstall(void);
FOUNDATION_EXPORT void FMDownloadIntegrationRegisterURL(NSURL *URL, NSString *trackKey,
    FMDownloadResolverFactory factory, BOOL (^isCurrent)(void));
FOUNDATION_EXPORT void FMDownloadIntegrationSourceTransition(void);
/// Counters only: does not expose track identifiers, URLs, script contents or cookies.
FOUNDATION_EXPORT NSDictionary<NSString *,id> *FMDownloadIntegrationDiagnostics(void);
/// Called only by the exact-version native manual-download final-save bridge.
/// Unregistered files retain the original move behavior. Registered, validated
/// files keep their real container extension and the host's directory/basename.
FOUNDATION_EXPORT BOOL FMDownloadNativeMove(NSFileManager *manager, NSURL *source,
    NSURL *destination, NSError * _Nullable * _Nullable error);

#if defined(FMX_DOWNLOAD_INTEGRATION_TESTING)
/// Available only in a simulator/macOS test build. Production rejects unknown binaries.
FOUNDATION_EXPORT BOOL FMDownloadIntegrationInstallForTesting(Class delegateClass);
FOUNDATION_EXPORT BOOL FMDownloadIntegrationRegisterFileForTesting(NSURL *file,
    NSString *trackKey, NSString *extension, NSError * _Nullable * _Nullable error);
#endif
NS_ASSUME_NONNULL_END
