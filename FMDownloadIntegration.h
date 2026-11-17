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

#if defined(FMX_DOWNLOAD_INTEGRATION_TESTING)
/// Available only in a simulator/macOS test build. Production rejects unknown binaries.
FOUNDATION_EXPORT BOOL FMDownloadIntegrationInstallForTesting(Class delegateClass);
#endif
NS_ASSUME_NONNULL_END
