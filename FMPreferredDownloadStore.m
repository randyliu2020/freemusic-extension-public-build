#import "FMPreferredDownloadStore.h"
#import "FMDownloadFiles.h"
#import "FMRecordingMatch.h"
#import <AVFoundation/AVFoundation.h>
#import <errno.h>
#import <math.h>

static NSArray *FMFileStamp(struct stat value) {
    return @[@(value.st_dev), @(value.st_ino), @(value.st_size), @(value.st_mtimespec.tv_sec), @(value.st_mtimespec.tv_nsec)];
}

static BOOL FMAudioDurationFits(double seconds, id declaration) {
    if (!isfinite(seconds) || seconds <= 0) return NO;
    double expected = [declaration isKindOfClass:NSNumber.class] ? [declaration doubleValue] : 0;
    return !(isfinite(expected) && expected > 0 && seconds + MAX(2, MIN(5, expected * 0.015)) < expected);
}

// A compressed stream may not yield a full PCM read starting exactly 128
// frames before its estimated end. Ask the player's own media framework for
// decoded samples near both ends before excluding this registered file.
static BOOL FMAssetSample(AVAsset *asset, AVAssetTrack *track, double start, double length) {
    AVAssetReader *reader = [[AVAssetReader alloc] initWithAsset:asset error:nil];
    if (!reader) return NO;
    NSDictionary *pcm = @{AVFormatIDKey:@(kAudioFormatLinearPCM), AVLinearPCMBitDepthKey:@16,
                           AVLinearPCMIsFloatKey:@NO, AVLinearPCMIsNonInterleaved:@NO};
    AVAssetReaderTrackOutput *output = [[AVAssetReaderTrackOutput alloc] initWithTrack:track outputSettings:pcm];
    if (![reader canAddOutput:output]) return NO;
    [reader addOutput:output];
    reader.timeRange = CMTimeRangeMake(CMTimeMakeWithSeconds(start, 60000), CMTimeMakeWithSeconds(length, 60000));
    if (![reader startReading]) return NO;
    CMSampleBufferRef buffer = [output copyNextSampleBuffer];
    BOOL decoded = buffer && CMSampleBufferGetNumSamples(buffer) > 0;
    if (buffer) CFRelease(buffer);
    [reader cancelReading];
    return decoded;
}

static BOOL FMReadPlayerAsset(NSURL *URL, id declaredSeconds) {
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:URL options:@{AVURLAssetReferenceRestrictionsKey:@(AVAssetReferenceRestrictionForbidAll)}];
    AVAssetTrack *track = [asset tracksWithMediaType:AVMediaTypeAudio].firstObject;
    if (!track || !asset.playable || asset.hasProtectedContent) return NO;
    double start = CMTimeGetSeconds(track.timeRange.start);
    double length = CMTimeGetSeconds(track.timeRange.duration);
    if (!isfinite(start) || start < 0 || !FMAudioDurationFits(length,declaredSeconds)) return NO;
    double window = MIN(0.35,length);
    return FMAssetSample(asset,track,start,window) &&
           (length <= window || FMAssetSample(asset,track,start + length - window,window));
}

// Require readable audio at both ends. A completed registry entry is necessary;
// when the original duration is known, reject substantially truncated audio.
static BOOL FMReadAudioEnds(NSURL *URL, id declaredSeconds) {
    AVAudioFile *file = [[AVAudioFile alloc] initForReading:URL error:nil];
    if (!file || file.length <= 0 || !isfinite(file.processingFormat.sampleRate) || file.processingFormat.sampleRate <= 0) return NO;
    double seconds = (double)file.length / file.processingFormat.sampleRate;
    if (!FMAudioDurationFits(seconds,declaredSeconds)) return NO;
    AVAudioFrameCount frames = (AVAudioFrameCount)MIN((AVAudioFramePosition)128, file.length);
    AVAudioPCMBuffer *buffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:file.processingFormat frameCapacity:frames];
    if (!buffer || ![file readIntoBuffer:buffer frameCount:frames error:nil] || buffer.frameLength != frames) return NO;
    file.framePosition = file.length - frames;
    return [file readIntoBuffer:buffer frameCount:frames error:nil] && buffer.frameLength == frames;
}

@implementation FMPreferredDownloadStore {
    NSURL *_index, *_legacy, *_downloads, *_assets, *_legacyAudio;
    NSURL *_lastIndex;
    NSArray *_indexStamp, *_registeredRows;
    NSDictionary *_byID, *_byAlias;
    NSCache *_matches, *_audioChecks;
    NSMutableDictionary<NSURL *,NSArray *> *_rejected;
    NSUInteger _playbackSelection;
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
        _legacyAudio = [caches URLByAppendingPathComponent:@"MusicCache" isDirectory:YES];
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
    _lastIndex = index; _indexStamp = nil; _registeredRows = @[]; _byID = @{}; _byAlias = @{};
    [_matches removeAllObjects];
    NSArray *records = version.count ? FMDAReadIndex(index) : nil;
    // A protected or temporarily unreadable index must be tried again even
    // when the underlying inode and modification time have not changed.
    if (version.count && (!records || !FMDARegular(index, &stamp) || ![version isEqual:FMFileStamp(stamp)])) return;
    _indexStamp = version;
    NSMutableDictionary *rows = [NSMutableDictionary dictionary];
    NSMutableDictionary *aliases = [NSMutableDictionary dictionary];
    NSMutableArray *allRows = [NSMutableArray array];
    for (id row in records) {
        if (![row isKindOfClass:NSDictionary.class]) continue;
        NSString *server = FMDASource(row[@"server"]), *identifier = FMDownloadLookupID(server, row[@"id"]);
        if (!server || !identifier) continue;
        NSArray *key = @[server, identifier];
        NSMutableArray *group = rows[key];
        if (!group) rows[key] = group = [NSMutableArray array];
        [group addObject:row]; [allRows addObject:row];
        NSString *alias = FMDownloadLookupID(server,FMDownloadRowAlias(row,server));
        if (alias && ![alias isEqual:identifier]) {
            NSArray *aliasKey = @[server,alias];
            NSMutableArray *groupForAlias = aliases[aliasKey];
            if (!groupForAlias) aliases[aliasKey] = groupForAlias = [NSMutableArray array];
            [groupForAlias addObject:row];
        }
    }
    _registeredRows = allRows.copy;
    _byID = rows.copy;
    _byAlias = aliases.copy;
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
        if (!playable) {
            @try { playable = FMReadPlayerAsset(file, duration); }
            @catch (__unused NSException *exception) { playable = NO; }
        }
        if (!FMDARegular(file, &stamp) || ![version isEqual:FMFileStamp(stamp)]) return NO;
        // iOS can make a registered file temporarily unreadable without
        // changing its stamp. A failed probe must not poison later selections.
        verified = @(playable);
        if (playable) [_audioChecks setObject:verified forKey:key];
    }
    return verified.boolValue;
}

- (NSURL *)fileForRow:(NSDictionary *)row request:(NSDictionary *)request {
    NSString *server = row[@"server"], *identifier = FMDAIdentifier(row[@"id"]);
    NSString *platform = FMDASource(server);
    if (!platform || !identifier) return nil;
    id duration = row[@"duration"];
    if (![duration isKindOfClass:NSNumber.class] && [platform isEqual:FMDASource(request[@"server"])])
        duration = request[@"duration"];
    // New native downloads use qq_<MID> for the LX tx provider. Registered
    // imports and older versions can spell the provider differently.
    NSString *native = [platform isEqual:@"tx"] ? @"qq" : ([platform isEqual:@"qishui"] ? @"qs" : platform);
    NSMutableOrderedSet *servers = [NSMutableOrderedSet orderedSetWithArray:@[server,native,platform]];
    NSMutableOrderedSet *ids = [NSMutableOrderedSet orderedSetWithObject:identifier];
    NSString *alias = FMDownloadRowAlias(row,platform);
    if (alias) {
        NSArray *aliasKey = @[platform,FMDownloadLookupID(platform,alias)];
        if (!_byID[aliasKey] && [_byAlias[aliasKey] count] == 1) [ids addObject:alias];
    }
    for (NSString *value in ids.array.copy) if (FMDownloadHash(platform,value)) {
        [ids addObject:value.uppercaseString]; [ids addObject:value.lowercaseString];
    }
    NSMutableArray *bases = [NSMutableArray array];
    for (NSString *source in servers) for (NSString *trackID in ids)
        [bases addObject:[NSString stringWithFormat:@"%@_%@",source,trackID]];
    // The original player first tries the ready-to-play sidecar under
    // Application Support. A replacement native download retires its old CAF.
    if (FMDADirectory(_assets)) for (NSString *base in bases) {
        NSURL *decoded = [_assets URLByAppendingPathComponent:[base stringByAppendingString:@"_playback.caf"]];
        if ([self validate:decoded duration:duration]) return decoded;
    }
    // Old manually registered media can still be in Library/Caches/MusicCache.
    // Reach it only from a matching downloaded_tracks.json record.
    for (NSURL *root in @[_downloads, _assets, _legacyAudio]) {
        if (!FMDADirectory(root)) continue;
        for (NSString *base in bases) for (NSString *ext in FMDAExtensions()) {
            NSURL *file = [root URLByAppendingPathComponent:[base stringByAppendingPathExtension:ext]];
            if ([self validate:file duration:duration]) return file;
        }
    }
    return nil;
}

- (NSURL *)lookupTrack:(NSDictionary *)request {
    NSString *server = FMDASource(request[@"server"]), *identifier = FMDownloadLookupID(server, request[@"id"]);
    if (!server || !identifier) return nil;
    @synchronized (self) {
        [self refreshIndex];
        NSArray *lookup = @[server,identifier];
        NSArray *directRows = _byID[lookup];
        if (!directRows.count && [_byAlias[lookup] count] == 1) directRows = _byAlias[lookup];
        for (NSDictionary *direct in directRows) {
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

- (NSUInteger)beginPlaybackSelection {
    @synchronized (self) {
        [_rejected removeAllObjects];
        return ++_playbackSelection;
    }
}

- (NSUInteger)playbackSelection {
    @synchronized (self) { return _playbackSelection; }
}

- (void)rejectURL:(NSURL *)URL forSelection:(NSUInteger)selection {
    if (!URL.isFileURL) return;
    @synchronized (self) {
        if (selection != _playbackSelection) return;
        struct stat stamp;
        if (FMDARegular(URL, &stamp)) _rejected[URL] = FMFileStamp(stamp);
    }
}
@end
