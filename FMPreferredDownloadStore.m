#import "FMPreferredDownloadStore.h"
#import "FMDownloadFiles.h"
#import "FMRecordingMatch.h"
#import <AVFoundation/AVFoundation.h>
#import <errno.h>
#import <math.h>

static NSArray *FMFileStamp(struct stat value) {
    return @[@(value.st_dev), @(value.st_ino), @(value.st_size), @(value.st_mtimespec.tv_sec), @(value.st_mtimespec.tv_nsec)];
}

static NSString *FMDownloadLookupID(NSString *server, id value) {
    NSString *identifier = FMDAIdentifier(value);
    if ([server isEqual:@"kg"] && identifier.length == 32) {
        NSCharacterSet *invalid = [[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdefABCDEF"] invertedSet];
        if ([identifier rangeOfCharacterFromSet:invalid].location == NSNotFound) return identifier.uppercaseString;
    }
    return identifier;
}

// Require readable audio at both ends. A completed registry entry is necessary;
// when the original duration is known, reject substantially truncated audio.
static BOOL FMReadAudioEnds(NSURL *URL, id declaredSeconds) {
    AVAudioFile *file = [[AVAudioFile alloc] initForReading:URL error:nil];
    if (!file || file.length <= 0 || !isfinite(file.processingFormat.sampleRate) || file.processingFormat.sampleRate <= 0) return NO;
    double seconds = (double)file.length / file.processingFormat.sampleRate;
    double expected = [declaredSeconds isKindOfClass:NSNumber.class] ? [declaredSeconds doubleValue] : 0;
    if (isfinite(expected) && expected > 0 && seconds + MAX(2, MIN(5, expected * 0.015)) < expected) return NO;
    AVAudioFrameCount frames = (AVAudioFrameCount)MIN((AVAudioFramePosition)128, file.length);
    AVAudioPCMBuffer *buffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:file.processingFormat frameCapacity:frames];
    if (!buffer || ![file readIntoBuffer:buffer frameCount:frames error:nil] || buffer.frameLength != frames) return NO;
    file.framePosition = file.length - frames;
    return [file readIntoBuffer:buffer frameCount:frames error:nil] && buffer.frameLength == frames;
}

@implementation FMPreferredDownloadStore {
    NSURL *_index, *_legacy, *_downloads, *_assets;
    NSURL *_lastIndex;
    NSArray *_indexStamp, *_registeredRows;
    NSDictionary *_byID;
    NSCache *_matches, *_audioChecks;
    NSMutableDictionary<NSURL *,NSArray *> *_rejected;
}

+ (instancetype)sharedStore {
    static FMPreferredDownloadStore *store;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSFileManager *files = NSFileManager.defaultManager;
        store = [[self alloc] initWithApplicationSupport:[files URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject
                                                documents:[files URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject
                                                   caches:[files URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask].firstObject];
    });
    return store;
}

- (instancetype)initWithApplicationSupport:(NSURL *)support documents:(NSURL *)documents caches:(NSURL *)caches {
    if ((self = [super init])) {
        _index = [support URLByAppendingPathComponent:@"downloaded_tracks.json"];
        _legacy = [caches URLByAppendingPathComponent:@"downloaded_tracks.json"];
        _downloads = [documents URLByAppendingPathComponent:@"Downloads" isDirectory:YES];
        _assets = [support URLByAppendingPathComponent:@"DownloadAssets" isDirectory:YES];
        _matches = [NSCache new]; _matches.countLimit = 512;
        _audioChecks = [NSCache new]; _audioChecks.countLimit = 512;
        _rejected = [NSMutableDictionary dictionary];
    }
    return self;
}

- (void)refreshIndex {
    struct stat stamp;
    NSURL *index = _index;
    if (lstat(index.fileSystemRepresentation, &stamp) && errno == ENOENT) index = _legacy;
    NSArray *version = FMDARegular(index, &stamp) ? FMFileStamp(stamp) : @[];
    if ([_lastIndex isEqual:index] && [_indexStamp isEqual:version]) return;
    _lastIndex = index; _indexStamp = nil; _registeredRows = @[]; _byID = @{};
    [_matches removeAllObjects];
    NSArray *records = version.count ? FMDAReadIndex(index) : nil;
    if (records && (!FMDARegular(index, &stamp) || ![version isEqual:FMFileStamp(stamp)])) return;
    _indexStamp = version;
    NSMutableDictionary *rows = [NSMutableDictionary dictionary];
    NSMutableArray *allRows = [NSMutableArray array];
    for (id row in records) {
        if (![row isKindOfClass:NSDictionary.class]) continue;
        NSString *server = FMDASource(row[@"server"]), *identifier = FMDownloadLookupID(server, row[@"id"]);
        if (!server || !identifier) continue;
        NSArray *key = @[server, identifier];
        NSMutableArray *group = rows[key];
        if (!group) rows[key] = group = [NSMutableArray array];
        [group addObject:row]; [allRows addObject:row];
    }
    _registeredRows = allRows.copy;
    _byID = rows.copy;
}

- (BOOL)validate:(NSURL *)file duration:(id)duration {
    struct stat stamp;
    if (!FMDARegular(file, &stamp)) return NO;
    NSArray *version = FMFileStamp(stamp);
    if ([_rejected[file] isEqual:version]) return NO;
    [_rejected removeObjectForKey:file];
    NSArray *key = @[file, version, duration ?: NSNull.null];
    NSNumber *verified = [_audioChecks objectForKey:key];
    if (!verified) {
        BOOL playable = NO;
        @try { playable = FMReadAudioEnds(file, duration); }
        @catch (__unused NSException *exception) { playable = NO; }
        if (!FMDARegular(file, &stamp) || ![version isEqual:FMFileStamp(stamp)]) return NO;
        verified = @(playable);
        [_audioChecks setObject:verified forKey:key];
    }
    return verified.boolValue;
}

- (NSURL *)fileForRow:(NSDictionary *)row request:(NSDictionary *)request {
    id duration = row[@"duration"] ?: request[@"duration"];
    NSString *server = row[@"server"], *identifier = FMDAIdentifier(row[@"id"]);
    if (!FMDASource(server) || !identifier) return nil;
    NSString *base = [NSString stringWithFormat:@"%@_%@", server, identifier];
    for (NSURL *root in @[_downloads, _assets]) {
        if (!FMDADirectory(root)) continue;
        for (NSString *ext in FMDAExtensions()) {
            NSURL *file = [root URLByAppendingPathComponent:[base stringByAppendingPathExtension:ext]];
            if ([self validate:file duration:duration]) return file;
        }
        if ([root isEqual:_assets]) {
            NSURL *decoded = [root URLByAppendingPathComponent:[base stringByAppendingString:@"_playback.caf"]];
            if ([self validate:decoded duration:duration]) return decoded;
        }
    }
    return nil;
}

- (NSURL *)lookupTrack:(NSDictionary *)request {
    NSString *server = FMDASource(request[@"server"]), *identifier = FMDownloadLookupID(server, request[@"id"]);
    if (!server || !identifier) return nil;
    @synchronized (self) {
        [self refreshIndex];
        for (NSDictionary *direct in _byID[@[server,identifier]]) {
            NSURL *file = [self fileForRow:direct request:request];
            if (file) return file;
        }
        if (!_registeredRows.count) return nil;
        NSMutableDictionary *key = [NSMutableDictionary dictionaryWithObjectsAndKeys:server, @"server", identifier, @"id", nil];
        for (NSString *field in @[@"title", @"singer", @"album", @"duration", @"isrc"]) {
            id value = request[field];
            if ([value isKindOfClass:NSString.class] || [value isKindOfClass:NSNumber.class]) key[field] = value;
        }
        if (!key[@"title"] && !key[@"isrc"]) return nil;
        id cross = [_matches objectForKey:key];
        if (!cross) {
            cross = FMConfirmedLocalRecording(request, _registeredRows) ?: NSNull.null;
            [_matches setObject:cross forKey:key.copy];
        }
        return [cross isKindOfClass:NSDictionary.class] ? [self fileForRow:cross request:request] : nil;
    }
}

- (NSURL *)lookupServer:(NSString *)server trackID:(NSString *)trackID {
    return [self lookupTrack:@{@"server":server ?: @"", @"id":trackID ?: @""}];
}

- (void)rejectURL:(NSURL *)URL {
    if (!URL.isFileURL) return;
    @synchronized (self) {
        struct stat stamp;
        if (FMDARegular(URL, &stamp)) _rejected[URL] = FMFileStamp(stamp);
    }
}
@end
