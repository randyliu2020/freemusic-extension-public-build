#import <UIKit/UIKit.h>

/// Called from the recognized native Library surface. This only adds the
/// management action; it never selects a tab or a playlist.
FOUNDATION_EXPORT void FMPlaylistEditorAttach(UIViewController *libraryRoot);
