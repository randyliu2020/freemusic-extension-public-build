#import "FMLXMC.h"
#import <zlib.h>
#import <CoreFoundation/CoreFoundation.h>
#import <fcntl.h>
#import <sys/stat.h>
#import <unistd.h>
#import <math.h>

NSString * const FMLXMCErrorDomain = @"FMX.LXMC";
const NSUInteger FMLXMCMaximumFileBytes = 8 * 1024 * 1024;
const NSUInteger FMLXMCMaximumExpandedBytes = 16 * 1024 * 1024;
static const NSUInteger FMMaximumLists = 100;
static const NSUInteger FMMaximumTracks = 20000;
static const NSUInteger FMMaximumPending = 16;
static NSString * const FMBridgePrefix = @"https://fmx-lxmc.invalid/import/";

@interface FMLXMCPlaylist ()
@property(nonatomic, copy, readwrite) NSString *title;
@property(nonatomic, copy, readwrite) NSArray<NSDictionary *> *tracks;
@property(nonatomic, readwrite) NSUInteger inputCount;
@property(nonatomic, readwrite) NSUInteger duplicateCount;
@property(nonatomic, readwrite) NSUInteger invalidCount;
@property(nonatomic, copy, readwrite) NSDictionary<NSString *, NSNumber *> *unsupportedSources;
@end
@implementation FMLXMCPlaylist
@end
@interface FMLXMCImportDocument ()
@property(nonatomic, copy, readwrite) NSString *format;
@property(nonatomic, copy, readwrite) NSArray<FMLXMCPlaylist *> *playlists;
@property(nonatomic, readwrite) NSUInteger inputCount;
@property(nonatomic, readwrite) NSUInteger importedTrackCount;
@property(nonatomic, readwrite) NSUInteger skippedCount;
@end
@implementation FMLXMCImportDocument
@end

static NSError *FMError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:FMLXMCErrorDomain code:code userInfo:@{NSLocalizedDescriptionKey:message}];
}
static id FMFail(NSError **error, NSInteger code, NSString *message) {
    if (error) *error = FMError(code, message);
    return nil;
}
static NSString *FMString(id value, NSUInteger limit) {
    if (![value isKindOfClass:NSString.class] || [value length] > limit) return nil;
    if ([value rangeOfString:@"\0"].location != NSNotFound) return nil;
    return value;
}
static BOOL FMMatches(NSString *string, NSString *pattern) {
    return string && [string rangeOfString:pattern options:NSRegularExpressionSearch].location != NSNotFound;
}
static NSString *FMNumericID(id value) {
    NSString *result = nil;
    if ([value isKindOfClass:NSString.class]) result = FMString(value, 20);
    else if ([value isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)value) != CFBooleanGetTypeID()) {
        // Decimal/string conversion avoids losing IDs above JavaScript's 2^53.
        result = [value stringValue];
    }
    if (!FMMatches(result, @"^[0-9]{1,19}$")) return nil;
    NSDecimalNumber *number = [NSDecimalNumber decimalNumberWithString:result];
    if ([number compare:NSDecimalNumber.zero] != NSOrderedDescending ||
        [number compare:[NSDecimalNumber decimalNumberWithString:@"9223372036854775807"]] == NSOrderedDescending) return nil;
    return number.stringValue;
}
static NSNumber *FMDuration(id interval) {
    NSString *text = FMString(interval, 16);
    if (!FMMatches(text, @"^(?:[0-9]{1,3}:)?[0-9]{1,3}:[0-5][0-9]$")) return nil;
    NSArray *parts = [text componentsSeparatedByString:@":"];
    NSUInteger seconds = 0;
    for (NSString *part in parts) seconds = seconds * 60 + part.integerValue;
    return seconds <= 604800 ? @(seconds) : nil;
}
static NSString *FMCover(id value) {
    NSString *text = FMString(value, 4096);
    if (!text.length) return @"";
    NSURLComponents *url = [NSURLComponents componentsWithString:text];
    if (!url.host.length || url.user || url.password || ![@[@"http", @"https"] containsObject:url.scheme.lowercaseString]) return @"";
    return url.URL ? text : @"";
}
static NSDictionary *FMTrack(id raw, BOOL modern, NSString **unsupported) {
    if (![raw isKindOfClass:NSDictionary.class]) return nil;
    NSDictionary *track = raw;
    NSString *source = FMString(track[@"source"], 16);
    if (![@[@"wy", @"tx", @"kg"] containsObject:source ?: @""]) {
        if (unsupported && source.length) *unsupported = source;
        return nil;
    }
    NSDictionary *meta = modern && [track[@"meta"] isKindOfClass:NSDictionary.class] ? track[@"meta"] : nil;
    if (modern && !meta) return nil;
    NSString *identifier = nil;
    if ([source isEqualToString:@"wy"]) identifier = FMNumericID(modern ? meta[@"songId"] : track[@"songmid"]);
    else if ([source isEqualToString:@"tx"]) {
        identifier = FMString(modern ? meta[@"songId"] : track[@"songmid"], 32);
        // LX meta.id is QQ's numeric song ID; strMediaMid is a different ID.
        // Neither is a substitute for the native player's songmid.
        if (!FMMatches(identifier, @"^[A-Za-z0-9]{14}$")) identifier = nil;
    } else {
        identifier = FMString(modern ? meta[@"hash"] : track[@"hash"], 32);
        if (!FMMatches(identifier, @"^[A-Fa-f0-9]{32}$")) identifier = nil;
        identifier = identifier.uppercaseString;
    }
    NSString *title = FMString(track[@"name"], 1024);
    if (!identifier.length || ![title stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].length) return nil;
    NSString *singer = FMString(track[@"singer"], 2048) ?: @"";
    NSString *album = FMString(modern ? meta[@"albumName"] : track[@"albumName"], 2048) ?: @"";
    NSString *server = [source isEqualToString:@"tx"] ? @"qq" : source;
    NSMutableDictionary *result = [@{@"id":identifier, @"title":title, @"server":server,
        @"singer":singer, @"album":album, @"cover":FMCover(modern ? meta[@"picUrl"] : track[@"img"])} mutableCopy];
    NSNumber *duration = FMDuration(track[@"interval"]);
    if (duration) result[@"duration"] = duration;
    return [result copy];
}
static NSData *FMExpand(NSData *data, NSError **error) {
    if (!data.length || data.length > FMLXMCMaximumFileBytes) return FMFail(error, 1, @"歌单文件为空或超过 8 MB。");
    const unsigned char *bytes = data.bytes;
    if (data.length < 2 || bytes[0] != 0x1f || bytes[1] != 0x8b) return data;
    z_stream stream = {0};
    if (inflateInit2(&stream, 16 + MAX_WBITS) != Z_OK) return FMFail(error, 2, @"无法初始化歌单解压。");
    stream.next_in = (Bytef *)data.bytes;
    stream.avail_in = (uInt)data.length;
    NSMutableData *output = [NSMutableData data];
    unsigned char chunk[32768];
    int status = Z_OK;
    do {
        stream.next_out = chunk; stream.avail_out = sizeof(chunk);
        status = inflate(&stream, Z_NO_FLUSH);
        NSUInteger count = sizeof(chunk) - stream.avail_out;
        if (output.length + count > FMLXMCMaximumExpandedBytes) { inflateEnd(&stream); return FMFail(error, 3, @"歌单展开后超过 16 MB。"); }
        if (count) [output appendBytes:chunk length:count];
        if (status != Z_OK && status != Z_STREAM_END) break;
        if (!count && !stream.avail_in && status != Z_STREAM_END) { status = Z_DATA_ERROR; break; }
    } while (status != Z_STREAM_END);
    BOOL complete = status == Z_STREAM_END && stream.avail_in == 0;
    inflateEnd(&stream);
    // Require one complete member. Reject truncation, corrupt CRC and appended data.
    if (!complete) return FMFail(error, 4, @"LX 歌单压缩数据损坏或含额外数据。");
    return output;
}

FMLXMCImportDocument *FMLXMCParseData(NSData *data, NSError **error) {
    if (error) *error = nil;
    if (![data isKindOfClass:NSData.class]) return FMFail(error, 1, @"歌单文件无效。");
    NSData *expanded = FMExpand(data, error);
    if (!expanded) return nil;
    // NSJSONSerialization accepts UTF-16 too; LX config is explicitly UTF-8.
    if (![[NSString alloc] initWithData:expanded encoding:NSUTF8StringEncoding]) return FMFail(error, 5, @"歌单不是有效 UTF-8 JSON。");
    id parsed = [NSJSONSerialization JSONObjectWithData:expanded options:0 error:nil];
    if (![parsed isKindOfClass:NSDictionary.class]) return FMFail(error, 5, @"歌单 JSON 格式无效。");
    NSString *format = parsed[@"type"];
    if (![@[@"playListPart_v2", @"playList_v2", @"playListPart", @"playList"] containsObject:format ?: @""]) return FMFail(error, 6, @"仅支持 LX 单歌单或完整歌单备份，不导入设置、账号或其他数据。");
    BOOL modern = [format hasSuffix:@"_v2"];
    BOOL single = [format hasPrefix:@"playListPart"];
    id payload = parsed[@"data"];
    if ((single && ![payload isKindOfClass:NSDictionary.class]) || (!single && ![payload isKindOfClass:NSArray.class])) return FMFail(error, 7, @"歌单列表结构无效。");
    NSArray *lists = single ? @[payload] : payload;
    if (!lists.count || lists.count > FMMaximumLists) return FMFail(error, 8, @"歌单数量必须在 1 到 100 之间。");
    NSMutableArray *normalized = [NSMutableArray array];
    NSUInteger inputCount = 0, trackCount = 0;
    for (id item in lists) {
        if (![item isKindOfClass:NSDictionary.class] || ![item[@"list"] isKindOfClass:NSArray.class]) return FMFail(error, 7, @"歌单列表结构无效。");
        NSString *name = FMString(item[@"name"], 256);
        if (![name stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].length) return FMFail(error, 9, @"歌单名称为空或过长。");
        NSArray *songs = item[@"list"];
        if (songs.count > FMMaximumTracks || inputCount + songs.count > FMMaximumTracks) return FMFail(error, 10, @"单次文件最多支持 20,000 首歌曲。");
        inputCount += songs.count;
        NSMutableArray *tracks = [NSMutableArray array];
        NSMutableSet *seen = [NSMutableSet set];
        NSMutableDictionary *unsupported = [NSMutableDictionary dictionary];
        NSUInteger duplicate = 0, invalid = 0;
        for (id song in songs) {
            NSString *unsupportedSource = nil;
            NSDictionary *track = FMTrack(song, modern, &unsupportedSource);
            if (!track) {
                if (unsupportedSource) unsupported[unsupportedSource] = @([unsupported[unsupportedSource] unsignedIntegerValue] + 1);
                else invalid++;
                continue;
            }
            NSString *key = [NSString stringWithFormat:@"%@:%@", track[@"server"], track[@"id"]];
            if ([seen containsObject:key]) { duplicate++; continue; }
            [seen addObject:key]; [tracks addObject:track];
        }
        FMLXMCPlaylist *list = [FMLXMCPlaylist new];
        list.title = name; list.tracks = tracks; list.inputCount = songs.count;
        list.duplicateCount = duplicate; list.invalidCount = invalid; list.unsupportedSources = unsupported;
        [normalized addObject:list]; trackCount += tracks.count;
    }
    FMLXMCImportDocument *document = [FMLXMCImportDocument new];
    document.format = format; document.playlists = normalized; document.inputCount = inputCount;
    document.importedTrackCount = trackCount; document.skippedCount = inputCount - trackCount;
    return document;
}

FMLXMCImportDocument *FMLXMCReadFile(NSURL *url, NSError **error) {
    if (error) *error = nil;
    if (!url.isFileURL || !url.fileSystemRepresentation) return FMFail(error, 11, @"请选择本地 LX 歌单文件。");
    int fd = open(url.fileSystemRepresentation, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    if (fd < 0) return FMFail(error, 12, @"无法读取所选歌单文件。");
    struct stat st = {0};
    if (fstat(fd, &st) || !S_ISREG(st.st_mode) || st.st_size <= 0 || st.st_size > FMLXMCMaximumFileBytes) {
        close(fd); return FMFail(error, 1, @"歌单必须是非空普通文件，且不超过 8 MB。");
    }
    NSMutableData *data = [NSMutableData dataWithCapacity:(NSUInteger)st.st_size];
    char chunk[32768]; ssize_t count;
    while ((count = read(fd, chunk, sizeof(chunk))) > 0) {
        if (data.length + (NSUInteger)count > FMLXMCMaximumFileBytes) { close(fd); return FMFail(error, 1, @"歌单文件超过 8 MB。"); }
        [data appendBytes:chunk length:(NSUInteger)count];
    }
    close(fd);
    if (count < 0) return FMFail(error, 12, @"歌单文件读取失败。");
    return FMLXMCParseData(data, error);
}

static NSMutableDictionary<NSString *, NSDictionary *> *FMPending(void) {
    static NSMutableDictionary *pending; static dispatch_once_t once;
    dispatch_once(&once, ^{ pending = [NSMutableDictionary dictionary]; }); return pending;
}
static NSUInteger FMRegistered = 0, FMConsumed = 0, FMRejected = 0;
static void FMPrune(NSMutableDictionary *pending) {
    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    for (NSString *key in pending.allKeys) if ([pending[key][@"expires"] doubleValue] <= now) [pending removeObjectForKey:key];
}
NSString *FMLXMCRegisterPlaylist(FMLXMCPlaylist *playlist, NSError **error) {
    if (error) *error = nil;
    if (![playlist isKindOfClass:FMLXMCPlaylist.class] || !playlist.tracks.count) return FMFail(error, 13, @"这个歌单没有可导入的网易云、QQ 或酷狗歌曲。");
    NSDictionary *response = @{@"code":@200, @"data":@{@"title":playlist.title, @"tracks":playlist.tracks}};
    NSData *data = [NSJSONSerialization dataWithJSONObject:response options:0 error:nil];
    if (!data || data.length > FMLXMCMaximumExpandedBytes) return FMFail(error, 14, @"歌单内容无法转换。");
    NSMutableDictionary *pending = FMPending();
    @synchronized(pending) {
        FMPrune(pending);
        if (pending.count >= FMMaximumPending) return FMFail(error, 15, @"待导入歌单过多，请先完成或取消之前的导入。");
        NSString *url = [FMBridgePrefix stringByAppendingString:NSUUID.UUID.UUIDString.lowercaseString];
        pending[url] = @{@"data":data, @"expires":@(NSProcessInfo.processInfo.systemUptime + 1800)};
        FMRegistered++; return url;
    }
}
void FMLXMCRevokeURL(NSString *url) { NSMutableDictionary *pending = FMPending(); @synchronized(pending) { [pending removeObjectForKey:url ?: @""]; } }

static NSDictionary *FMForm(NSString *text) {
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    for (NSString *pair in [text componentsSeparatedByString:@"&"]) {
        NSRange split = [pair rangeOfString:@"="];
        if (split.location == NSNotFound) continue;
        NSString *key = [[[pair substringToIndex:split.location] stringByReplacingOccurrencesOfString:@"+" withString:@" "] stringByRemovingPercentEncoding];
        NSString *value = [[[pair substringFromIndex:split.location + 1] stringByReplacingOccurrencesOfString:@"+" withString:@" "] stringByRemovingPercentEncoding];
        if (!key || !value || result[key]) return nil;
        result[key] = value;
    }
    return result;
}
static NSString *FMRequestToken(NSURLRequest *request) {
    NSURLComponents *url = [NSURLComponents componentsWithURL:request.URL resolvingAgainstBaseURL:NO];
    if (![url.scheme.lowercaseString isEqualToString:@"https"] || ![url.host.lowercaseString isEqualToString:@"aacert.com"] ||
        (url.port && url.port.integerValue != 443) || url.user || url.password || ![url.path isEqualToString:@"/ms/api.php"] ||
        ![request.HTTPMethod.uppercaseString isEqualToString:@"POST"]) return nil;
    NSDictionary *query = FMForm(url.percentEncodedQuery ?: @"");
    if (![query[@"action"] isEqualToString:@"import_playlist"]) return nil;
    NSData *body = request.HTTPBody;
    if (!body.length || body.length > 65536) return nil;
    NSDictionary *form = FMForm([[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding] ?: @"");
    NSString *token = form[@"url"];
    // Claim all synthetic-host values, including expired/invalid ones, locally.
    NSURLComponents *bridge = [NSURLComponents componentsWithString:token ?: @""];
    return [bridge.host.lowercaseString isEqualToString:@"fmx-lxmc.invalid"] ? token : nil;
}
BOOL FMLXMCRequestMatches(NSURLRequest *request) { return FMRequestToken(request) != nil; }
NSData *FMLXMCResponseForRequest(NSURLRequest *request, NSError **error) {
    if (error) *error = nil;
    NSString *token = FMRequestToken(request);
    if (!token) return FMFail(error, 16, @"请求不是本机 LX 歌单导入。");
    NSMutableDictionary *pending = FMPending();
    @synchronized(pending) {
        FMPrune(pending);
        NSDictionary *record = pending[token];
        if (!record) { FMRejected++; return FMFail(error, 17, @"这次歌单选择已失效或已经提交，请重新选择文件。"); }
        NSData *data = record[@"data"];
        [pending removeObjectForKey:token]; FMConsumed++; return data;
    }
}
NSDictionary *FMLXMCDiagnostics(void) {
    NSMutableDictionary *pending = FMPending();
    @synchronized(pending) { FMPrune(pending); return @{@"pending":@(pending.count), @"registered":@(FMRegistered), @"consumed":@(FMConsumed), @"rejected":@(FMRejected)}; }
}
