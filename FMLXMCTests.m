// Self-authored fixtures only. No user files, credentials, or network requests.
// xcrun clang -fobjc-arc -fblocks -framework Foundation -lz FMLXMC.m FMLXMCTests.m -o lxmc-tests && ./lxmc-tests
#import "FMLXMC.h"
#import <zlib.h>
#import <unistd.h>

static NSUInteger failures, checks;
static void Check(BOOL pass, NSString *name) {
    checks++; if (!pass) failures++;
    printf("%s %s\n", pass ? "PASS" : "FAIL", name.UTF8String);
}
static NSData *JSON(id value) { return [NSJSONSerialization dataWithJSONObject:value options:0 error:nil]; }
static NSDictionary *Song(NSString *source, id identifier) {
    NSMutableDictionary *meta = [@{@"songId":identifier ?: @"", @"albumName":@"Fixture Album", @"picUrl":@"https://example.invalid/cover.jpg"} mutableCopy];
    if ([source isEqualToString:@"tx"]) { meta[@"id"] = @2345; meta[@"strMediaMid"] = @"ZZZZZZZZZZZZZZ"; }
    if ([source isEqualToString:@"kg"]) meta[@"hash"] = identifier ?: @"";
    return @{@"id":@"NOT_NATIVE_ID", @"name":@"Fixture Song", @"source":source, @"singer":@"Fixture Artist", @"interval":@"03:07", @"meta":meta};
}
static NSDictionary *List(NSString *name, NSArray *songs) { return @{@"id":@"love", @"name":name, @"list":songs}; }
static NSData *Part(NSArray *songs) { return JSON(@{@"type":@"playListPart_v2", @"data":List(@"Fixture Favorites", songs)}); }
static NSData *Gzip(NSData *source) {
    z_stream stream = {0};
    if (deflateInit2(&stream, Z_BEST_SPEED, Z_DEFLATED, 16 + MAX_WBITS, 8, Z_DEFAULT_STRATEGY) != Z_OK) abort();
    stream.next_in = (Bytef *)source.bytes; stream.avail_in = (uInt)source.length;
    NSMutableData *out = [NSMutableData data]; int status;
    do {
        unsigned char chunk[32768]; stream.next_out = chunk; stream.avail_out = sizeof(chunk);
        status = deflate(&stream, Z_FINISH); [out appendBytes:chunk length:sizeof(chunk) - stream.avail_out];
    } while (status == Z_OK);
    deflateEnd(&stream); if (status != Z_STREAM_END) abort(); return out;
}
static NSMutableURLRequest *Request(NSString *token) {
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"https://aacert.com/ms/api.php?action=import_playlist&_t=123"]];
    request.HTTPMethod = @"POST";
    [request setValue:@"application/x-www-form-urlencoded" forHTTPHeaderField:@"Content-Type"];
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~"];
    request.HTTPBody = [[@"url=" stringByAppendingString:[token stringByAddingPercentEncodingWithAllowedCharacters:allowed]] dataUsingEncoding:NSUTF8StringEncoding];
    return request;
}
static BOOL Invalid(NSData *data, NSInteger code) {
    NSError *error = nil; id result = FMLXMCParseData(data, &error);
    return !result && [error.domain isEqualToString:FMLXMCErrorDomain] && error.code == code;
}
int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSArray *songs = @[Song(@"wy", @9223372036854775806LL), Song(@"tx", @"Ab0123456789Cd"), Song(@"kg", @"0123456789abcdef0123456789abcdef")];
        NSError *error = nil;
        FMLXMCImportDocument *plain = FMLXMCParseData(Part(songs), &error);
        FMLXMCImportDocument *packed = FMLXMCParseData(Gzip(Part(songs)), &error);
        Check(plain && packed && plain.importedTrackCount == 3 && packed.importedTrackCount == 3 && !error, @"gzip_and_plain_v2_three_native_platforms");
        NSArray *tracks = packed.playlists.firstObject.tracks;
        Check([tracks[0][@"id"] isEqual:@"9223372036854775806"] && [tracks[0][@"server"] isEqual:@"wy"], @"wy_large_integer_id_is_exact");
        Check([tracks[1][@"id"] isEqual:@"Ab0123456789Cd"] && [tracks[1][@"server"] isEqual:@"qq"], @"qq_uses_songmid_not_numeric_id_or_media_mid");
        Check([tracks[2][@"id"] isEqual:@"0123456789ABCDEF0123456789ABCDEF"] && [tracks[2][@"server"] isEqual:@"kg"], @"kg_uses_actual_normalized_hash");
        Check([tracks[0][@"duration"] isEqual:@187] && !tracks[0][@"record_id"] && !tracks[0][@"platform"], @"native_payload_preserves_duration_without_fabricated_database_identity");
        NSMutableDictionary *badQQ = [Song(@"tx", @"12345") mutableCopy];
        NSMutableDictionary *badKG = [Song(@"kg", @"12345") mutableCopy];
        FMLXMCImportDocument *invalids = FMLXMCParseData(Part(@[badQQ, badKG, Song(@"wy", @YES), Song(@"wy", @-2), Song(@"wy", @1.5), Song(@"wy", @"9223372036854775808")]), &error);
        Check(invalids && invalids.importedTrackCount == 0 && invalids.playlists.firstObject.invalidCount == 6, @"invalid_ids_and_booleans_are_not_remapped");
        FMLXMCImportDocument *mixed = FMLXMCParseData(Part(@[songs[0], songs[0], Song(@"kw", @"8"), Song(@"mg", @"9"), Song(@"local", @"/private/fixture.mp3"), @42]), &error);
        FMLXMCPlaylist *mp = mixed.playlists.firstObject;
        Check(mp.tracks.count == 1 && mp.duplicateCount == 1 && mp.invalidCount == 1 && mp.unsupportedSources.count == 3 && mixed.skippedCount == 5, @"dedupe_first_wins_and_explicit_unsupported_counts");
        NSArray *lists = @[List(@"Same name", @[songs[0]]), List(@"Same name", @[songs[1]]), List(@"Empty", @[])];
        FMLXMCImportDocument *multi = FMLXMCParseData(JSON(@{@"type":@"playList_v2", @"data":lists}), &error);
        Check(multi.playlists.count == 3 && multi.importedTrackCount == 2 && [multi.playlists[1].tracks.firstObject[@"server"] isEqual:@"qq"], @"multiple_lists_and_same_lx_ids_are_kept_separate");
        Check(!FMLXMCRegisterPlaylist(multi.playlists[2], &error) && error.code == 13, @"empty_or_unmappable_playlist_cannot_create_native_empty_list");
        NSDictionary *oldSong = @{@"songmid":@"Ab0123456789Cd", @"songId":@7, @"source":@"tx", @"name":@"Legacy Fixture", @"singer":@"Artist", @"interval":@"1:03:02", @"albumName":@"Album", @"img":@"https://example.invalid/a.jpg"};
        FMLXMCImportDocument *legacy = FMLXMCParseData(JSON(@{@"type":@"playListPart", @"data":List(@"Legacy", @[oldSong])}), &error);
        Check(legacy.importedTrackCount == 1 && [legacy.playlists.firstObject.tracks.firstObject[@"duration"] isEqual:@3782], @"documented_legacy_single_list_mapping");
        Check(FMLXMCParseData(JSON(@{@"type":@"playList", @"data":@[List(@"Legacy", @[oldSong])]}), &error).playlists.count == 1, @"documented_legacy_multiple_lists");
        NSMutableDictionary *unsafeCover = [Song(@"wy", @12) mutableCopy];
        NSMutableDictionary *unsafeMeta = [unsafeCover[@"meta"] mutableCopy]; unsafeMeta[@"picUrl"] = @"file:///private/fixture.jpg"; unsafeCover[@"meta"] = unsafeMeta;
        FMLXMCPlaylist *safe = FMLXMCParseData(Part(@[unsafeCover]), &error).playlists.firstObject;
        Check([safe.tracks.firstObject[@"cover"] isEqual:@""], @"cover_local_path_is_not_exposed");
        Check(Invalid([NSData data], 1) && Invalid([@"garbage" dataUsingEncoding:NSUTF8StringEncoding], 5), @"empty_and_invalid_json_are_errors");
        Check(Invalid(JSON(@{@"type":@"allData_v2", @"playList":lists, @"settings":@{}}), 6), @"account_and_settings_backup_is_not_imported");
        Check(Invalid(JSON(@{@"type":@"playList_v2", @"data":@{}}), 7) && Invalid(JSON(@{@"type":@"playListPart_v2", @"data":List(@"", @[])}), 9), @"bad_structure_and_name_are_errors");
        NSMutableData *truncated = [Gzip(Part(songs)) mutableCopy]; [truncated setLength:truncated.length - 3];
        NSMutableData *extra = [Gzip(Part(songs)) mutableCopy]; [extra appendData:[@"x" dataUsingEncoding:NSUTF8StringEncoding]];
        NSMutableData *corrupt = [Gzip(Part(songs)) mutableCopy]; ((unsigned char *)corrupt.mutableBytes)[corrupt.length - 5] ^= 1;
        Check(Invalid(truncated, 4) && Invalid(extra, 4) && Invalid(corrupt, 4), @"gzip_truncation_crc_and_trailing_bytes_rejected");
        Check(Invalid([NSMutableData dataWithLength:FMLXMCMaximumFileBytes + 1], 1), @"compressed_or_plain_file_size_limit");
        Check(Invalid(Gzip([NSMutableData dataWithLength:FMLXMCMaximumExpandedBytes + 1]), 3), @"gzip_expansion_limit");
        NSMutableArray *tooManyLists = [NSMutableArray array]; for (int i = 0; i < 101; i++) [tooManyLists addObject:List(@"Empty", @[])];
        Check(Invalid(JSON(@{@"type":@"playList_v2", @"data":tooManyLists}), 8), @"playlist_count_limit");
        NSMutableArray *tooManyTracks = [NSMutableArray array]; for (int i = 0; i < 20001; i++) [tooManyTracks addObject:songs[0]];
        Check(Invalid(Gzip(Part(tooManyTracks)), 10), @"total_song_count_limit");

        NSString *token = FMLXMCRegisterPlaylist(packed.playlists.firstObject, &error);
        NSMutableURLRequest *request = Request(token);
        Check(token.length && FMLXMCRequestMatches(request), @"exact_native_import_bridge_request_matches");
        NSData *responseData = FMLXMCResponseForRequest(request, &error);
        NSDictionary *response = responseData ? [NSJSONSerialization JSONObjectWithData:responseData options:0 error:nil] : nil;
        Check([response[@"code"] isEqual:@200] && [response[@"data"][@"tracks"] count] == 3 && [response[@"data"][@"title"] isEqual:@"Fixture Favorites"], @"bridge_returns_native_import_playlist_response");
        Check(FMLXMCRequestMatches(request) && !FMLXMCResponseForRequest(request, &error) && error.code == 17, @"same_token_second_submission_is_local_error");
        NSMutableURLRequest *normal = Request(@"https://music.163.com/playlist?id=123");
        Check(!FMLXMCRequestMatches(normal), @"ordinary_native_link_import_passes_through");
        NSMutableURLRequest *badToken = Request(@"https://fmx-lxmc.invalid/import/not-a-token");
        Check(FMLXMCRequestMatches(badToken) && !FMLXMCResponseForRequest(badToken, &error) && error.code == 17, @"invalid_synthetic_token_never_leaves_process");
        NSString *revoked = FMLXMCRegisterPlaylist(plain.playlists.firstObject, &error); FMLXMCRevokeURL(revoked);
        Check(FMLXMCRequestMatches(Request(revoked)) && !FMLXMCResponseForRequest(Request(revoked), &error), @"revoked_selection_is_local_error");
        NSMutableURLRequest *wrongRoute = [request mutableCopy]; wrongRoute.URL = [NSURL URLWithString:@"https://aacert.com/ms/api.php?action=playlist_create"];
        NSMutableURLRequest *wrongHost = [request mutableCopy]; wrongHost.URL = [NSURL URLWithString:@"https://example.invalid/ms/api.php?action=import_playlist"];
        Check(!FMLXMCRequestMatches(wrongRoute) && !FMLXMCRequestMatches(wrongHost), @"create_bulk_and_non_native_hosts_are_untouched");
        NSMutableURLRequest *stream = [request mutableCopy]; stream.HTTPBody = nil; stream.HTTPBodyStream = [NSInputStream inputStreamWithData:request.HTTPBody];
        Check(!FMLXMCRequestMatches(stream) && stream.HTTPBodyStream.streamStatus == NSStreamStatusNotOpen, @"protocol_must_materialize_stream_without_parser_consuming_it");
        NSMutableURLRequest *huge = [request mutableCopy]; huge.HTTPBody = [NSMutableData dataWithLength:65537];
        Check(!FMLXMCRequestMatches(huge), @"protocol_body_limit_is_bounded");
        NSDictionary *diagnostics = FMLXMCDiagnostics(); BOOL numeric = YES;
        for (id value in diagnostics.allValues) numeric &= [value isKindOfClass:NSNumber.class];
        Check(numeric && [diagnostics[@"pending"] unsignedIntegerValue] == 0, @"diagnostics_contain_no_titles_ids_paths_or_tokens");
        NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSUUID.UUID.UUIDString stringByAppendingString:@".lxmc"]];
        [Gzip(Part(songs)) writeToFile:path atomically:YES];
        Check(FMLXMCReadFile([NSURL fileURLWithPath:path], &error).importedTrackCount == 3, @"bounded_regular_file_reader");
        NSString *link = [path stringByAppendingString:@".symlink"];
        symlink(path.fileSystemRepresentation, link.fileSystemRepresentation);
        Check(!FMLXMCReadFile([NSURL fileURLWithPath:link], &error), @"file_reader_refuses_symlink");
        unlink(link.fileSystemRepresentation); unlink(path.fileSystemRepresentation);
        printf("%s LXMC %lu checks, %lu failures\n", failures ? "FAILED" : "DONE", (unsigned long)checks, (unsigned long)failures);
        return failures ? 1 : 0;
    }
}
