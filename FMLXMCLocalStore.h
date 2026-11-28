#import <Foundation/Foundation.h>
#import "FMLXMC.h"
NS_ASSUME_NONNULL_BEGIN
FOUNDATION_EXPORT NSNotificationName const FMLXMCLocalImportDidFinish;
/// Device-only playlists. No login token, account identifier or original file is
/// persisted. A successful import is one atomic replacement of the complete store.
@interface FMLXMCLocalStore : NSObject
+ (instancetype)sharedStore;
- (instancetype)initWithDirectory:(NSURL *)directory;
/// Each result is an immutable native playlist summary plus revision/matchKind.
/// Identity is only a suggestion; overwriting always needs explicit UI selection.
- (NSArray<NSDictionary *> *)matchesForPlaylist:(FMLXMCPlaylist *)playlist;
- (NSArray<NSDictionary *> *)nativePlaylists;
- (nullable NSString *)preparePlaylist:(FMLXMCPlaylist *)playlist replacing:(nullable NSNumber *)identifier error:(NSError **)error;
- (void)revokeImportURL:(NSString *)url;
/// Returns nil only for an unrelated request. All owned failures remain local.
- (nullable NSDictionary *)responseForAction:(NSString *)action parameters:(NSDictionary<NSString *,NSString *> *)parameters importRequest:(nullable NSURLRequest *)request;
- (NSDictionary *)mergePlaylistList:(nullable NSDictionary *)response;
/// Library editor works on ordinary native responses. A cloud override is
/// applied only to its original account/list identity on this device.
- (NSArray<NSDictionary *> *)editorPlaylists;
- (nullable NSArray<NSDictionary *> *)editorTracks:(NSString *)playlistKey;
- (BOOL)renameEditorPlaylist:(NSString *)key title:(NSString *)title error:(NSError **)error;
- (BOOL)saveEditorListOrder:(NSArray<NSString *> *)keys error:(NSError **)error;
- (BOOL)saveEditorTracks:(NSArray<NSString *> *)desired replacing:(NSArray<NSString *> *)observed
                 playlist:(NSString *)key error:(NSError **)error;
- (NSDictionary *)mergeTracks:(NSDictionary *)response playlistID:(NSString *)identifier;
- (BOOL)ownsPlaylistID:(nullable NSString *)identifier;
- (BOOL)ownsRecordID:(nullable NSString *)identifier;
- (NSDictionary *)diagnostics;
@end
NS_ASSUME_NONNULL_END
