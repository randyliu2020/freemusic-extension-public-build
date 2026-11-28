#pragma once
#import <Foundation/Foundation.h>

/// Unique, cross-catalogue match among completed download records.
/// Callers try the exact platform/identifier first.
FOUNDATION_EXPORT NSDictionary * _Nullable FMConfirmedLocalRecording(NSDictionary *request, NSArray<NSDictionary *> *registeredRows);
