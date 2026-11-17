#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString * const FMLXMCErrorDomain;
FOUNDATION_EXPORT const NSUInteger FMLXMCMaximumFileBytes;
FOUNDATION_EXPORT const NSUInteger FMLXMCMaximumExpandedBytes;

/// Immutable, normalized input for FreeMusic 4.2.7's existing ImportPlaylistResponse.
/// Neither the LX list ID nor a record_id is copied into the native database.
@interface FMLXMCPlaylist : NSObject
@property(nonatomic, copy, readonly) NSString *title;
@property(nonatomic, copy, readonly) NSArray<NSDictionary *> *tracks;
@property(nonatomic, readonly) NSUInteger inputCount;
@property(nonatomic, readonly) NSUInteger duplicateCount;
@property(nonatomic, readonly) NSUInteger invalidCount;
@property(nonatomic, copy, readonly) NSDictionary<NSString *, NSNumber *> *unsupportedSources;
@end

@interface FMLXMCImportDocument : NSObject
@property(nonatomic, copy, readonly) NSString *format;
@property(nonatomic, copy, readonly) NSArray<FMLXMCPlaylist *> *playlists;
@property(nonatomic, readonly) NSUInteger inputCount;
@property(nonatomic, readonly) NSUInteger importedTrackCount;
@property(nonatomic, readonly) NSUInteger skippedCount;
@end

/// Optional internal observer of accepted, deduplicated LX track dictionaries.
/// Invoked on the parsing thread only after the whole document validates; never
/// changes the native import response. Receivers must allowlist fields they keep.
typedef void (^FMLXMCTrackObserver)(NSDictionary *track);
FOUNDATION_EXPORT void FMLXMCSetTrackObserver(FMLXMCTrackObserver _Nullable observer);

/// Synchronous parser: call away from the main thread. Supports gzip and plain
/// UTF-8 JSON, playListPart[_v2] and playList[_v2]. No network or file access;
/// native output excludes account fields, even when an internal observer is set.
FOUNDATION_EXPORT FMLXMCImportDocument * _Nullable FMLXMCParseData(NSData *data, NSError **error);

/// Reads a local, regular file through a bounded descriptor (no network or symlink
/// following). The caller owns the security-scoped URL lifetime.
FOUNDATION_EXPORT FMLXMCImportDocument * _Nullable FMLXMCReadFile(NSURL *url, NSError **error);

/// Creates a process-local, random, single-use bridge URL, valid for 30 minutes.
/// The URL must go into the ORIGINAL external-playlist alert's existing TextField.
/// The UI hides its implementation value behind the selected playlist's title.
FOUNDATION_EXPORT NSString * _Nullable FMLXMCRegisterPlaylist(FMLXMCPlaylist *playlist, NSError **error);
FOUNDATION_EXPORT void FMLXMCRevokeURL(NSString *url);

/// Integrate BEFORE other parse/search protocol guards. Match only the original
/// HTTPS aacert /ms/api.php import_playlist POST and our synthetic URL. Claims even
/// expired or malformed module URLs to ensure they never reach the remote service.
FOUNDATION_EXPORT BOOL FMLXMCRequestMatches(NSURLRequest *request);
FOUNDATION_EXPORT NSData * _Nullable FMLXMCResponseForRequest(NSURLRequest *request, NSError **error);

/// Only count/format/size information. Never returns titles, IDs, token URLs, paths,
/// credentials, or request bodies. Useful in authored-fixture smoke tests.
FOUNDATION_EXPORT NSDictionary<NSString *, NSNumber *> *FMLXMCDiagnostics(void);

NS_ASSUME_NONNULL_END
