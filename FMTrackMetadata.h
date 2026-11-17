#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
/// Remember only allowlisted song fields from responses already received by the app.
/// Never fetches another service, saves credentials, or invents available qualities.
FOUNDATION_EXPORT void FMTrackMetadataObserveResponse(id response);
FOUNDATION_EXPORT NSDictionary *FMTrackMetadataForParameters(NSDictionary *parameters, NSString *source);
FOUNDATION_EXPORT void FMTrackMetadataReset(void);
NS_ASSUME_NONNULL_END
