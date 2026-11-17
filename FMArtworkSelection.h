#import <Foundation/Foundation.h>
#include <stdbool.h>

NS_ASSUME_NONNULL_BEGIN
/// Narrow bridge used only by the fingerprinted native missing-cover branch.
/// Slots are the verified Optional<String> URL and retained artwork storage.
/// The native branch runs on the main actor; neither slot escapes this call.
FOUNDATION_EXPORT __attribute__((visibility("default"), used)) bool FMXAC(void * _Nullable urlStorage, void * _Nullable artworkStorage);
NS_ASSUME_NONNULL_END
