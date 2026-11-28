#pragma once
#import <Foundation/Foundation.h>

/// Invoked by a track menu with that row's original platform and song identifier.
FOUNDATION_EXPORT void FMXClearSongCache(NSString *nativeServer, NSString *trackID);
