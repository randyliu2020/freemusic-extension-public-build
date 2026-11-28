#import "FMReplayCache.h"
#import "FMDownloadFiles.h"
#import <errno.h>
#import <objc/runtime.h>
#import <CommonCrypto/CommonDigest.h>
#import <TargetConditionals.h>
#import <sys/stat.h>

static NSString *FMReplayDigest(NSArray<NSString *> *parts) {
    NSMutableData *input = [NSMutableData data];
    for (NSString *part in parts) {
        NSData *data = [part dataUsingEncoding:NSUTF8StringEncoding];
        if (!data.length || data.length > UINT32_MAX) return nil;
        uint32_t size = CFSwapInt32HostToBig((uint32_t)data.length);
        [input appendBytes:&size length:sizeof(size)];
        [input appendData:data];
    }
    if (input.length > UINT32_MAX) return nil;
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(input.bytes, (CC_LONG)input.length, digest);
    char hex[CC_SHA256_DIGEST_LENGTH * 2 + 1];
    for (NSUInteger i = 0; i < sizeof(digest); i++) snprintf(hex + 2*i, 3, "%02x", digest[i]);
    return [NSString stringWithUTF8String:hex];
}

static BOOL FMReplayUUID(id value) {
    return [value isKindOfClass:NSString.class] && [value length] == 36 &&
        [[NSUUID alloc] initWithUUIDString:value] != nil;
}

static BOOL FMReplayHex(id value) {
    if (![value isKindOfClass:NSString.class] || [value length] != 64) return NO;
    static NSCharacterSet *nonHex;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ nonHex = [NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"].invertedSet; });
    return [value rangeOfCharacterFromSet:nonHex].location == NSNotFound;
}

static BOOL FMReplayRemote(NSURL *url) {
    if (![url isKindOfClass:NSURL.class] || !url.host.length || url.user || url.password ||
        url.absoluteString.length > 8192) return NO;
    return [@[@"http", @"https"] containsObject:url.scheme.lowercaseString];
}

static NSDictionary *FMReplayAttributes(void) {
#if TARGET_OS_IOS
    return @{ NSFileProtectionKey: NSFileProtectionCompleteUntilFirstUserAuthentication };
#else
    return @{};
#endif
}

static BOOL FMReplayMakeDirectory(NSURL *url) {
    NSFileManager *fm = NSFileManager.defaultManager;
    if (![fm createDirectoryAtURL:url withIntermediateDirectories:YES attributes:FMReplayAttributes() error:nil]) return NO;
    [url setResourceValue:@YES forKey:NSURLIsExcludedFromBackupKey error:nil];
    return YES;
}

static BOOL FMReplayWrite(NSDictionary *data, NSURL *url) {
    NSData *encoded = [NSPropertyListSerialization dataWithPropertyList:data format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
    NSDataWritingOptions options = NSDataWritingAtomic;
#if TARGET_OS_IOS
    options |= NSDataWritingFileProtectionCompleteUntilFirstUserAuthentication;
#endif
    return encoded && [encoded writeToURL:url options:options error:nil];
}

static NSDictionary *FMReplayRead(NSURL *url) {
    struct stat st;
    if (lstat(url.fileSystemRepresentation, &st) != 0 || !S_ISREG(st.st_mode) || st.st_size <= 0 ||
        st.st_size > 16*1024*1024) return nil;
    NSData *data = [NSData dataWithContentsOfURL:url];
    if (!data) return nil;
    id value = [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable format:nil error:nil];
    return [value isKindOfClass:NSDictionary.class] ? value : nil;
}

static unsigned long long FMReplayRegularFileSize(NSURL *url) {
    struct stat st;
    if (!url.isFileURL || lstat(url.fileSystemRepresentation, &st) != 0 || !S_ISREG(st.st_mode) || st.st_size <= 0) return 0;
    return (unsigned long long)st.st_size;
}

static BOOL FMReplayExtension(NSString *extension) {
    static NSSet *allowed;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ allowed = [NSSet setWithArray:@[@"mp3", @"flac", @"m4a", @"mp4", @"aac", @"alac", @"wav",
        @"wave", @"aif", @"aiff", @"aifc", @"caf", @"ogg", @"oga", @"opus", @"ac3", @"m4b", @"webm"]]; });
    return extension && [allowed containsObject:extension];
}

static BOOL FMReplayMediaName(id name) {
    return [name isKindOfClass:NSString.class] && FMReplayUUID([name stringByDeletingPathExtension]) &&
        FMReplayExtension([name pathExtension]);
}

static BOOL FMReplayKugouHash(NSString *source, NSString *identifier) {
    if (![source isEqual:@"kg"] || identifier.length != 32) return NO;
    NSCharacterSet *invalid = [NSCharacterSet characterSetWithCharactersInString:@"abcdefABCDEF0123456789"].invertedSet;
    return [identifier rangeOfCharacterFromSet:invalid].location == NSNotFound;
}

static NSString *FMReplayIdentity(NSString *platform, NSString *trackID) {
    NSString *source = FMDASource(platform);
    NSString *identifier = FMDAIdentifier(trackID);
    if (!source || !identifier) return nil;
    if (FMReplayKugouHash(source,identifier)) identifier = identifier.uppercaseString;
    return FMReplayDigest(@[source, identifier]);
}

// The v11 index stored only a digest of these three raw values. These are
// every quality the v11 resolver could emit, including disabled qualities.
static NSSet *FMReplayLegacyDigests(NSString *platform, NSString *trackID) {
    NSString *source = FMDASource(platform);
    NSMutableSet *ids = [NSMutableSet setWithObject:trackID];
    if (FMReplayKugouHash(source,trackID)) {
        [ids addObject:trackID.lowercaseString];
        [ids addObject:trackID.uppercaseString];
    }
    NSMutableSet *digests = [NSMutableSet set];
    for (NSString *identifier in ids)
        for (NSString *quality in @[@"128k", @"320k", @"flac", @"flac24bit"])
            [digests addObject:FMReplayDigest(@[source, identifier, quality])];
    return digests;
}

// AVPlayerItem can reopen its URL during a seek. Its associated pin owns no
// player references and releases the final retired file when the item dies.
@interface FMReplayFilePin : NSObject
@property(nonatomic, strong) NSURL *url;
@property(nonatomic, copy) dispatch_block_t releaseFile;
@end

@implementation FMReplayFilePin
- (void)dealloc { if (_releaseFile) _releaseFile(); }
@end

static char FMReplayFilePinAssociation;

@implementation FMReplayCache {
    NSURL *_root;
    NSURL *_directory;
    NSString *_identity;
    NSString *_epoch;
    BOOL _initialized;
    NSMutableDictionary<NSString *,NSString *> *_clearedSongs;
    NSMutableDictionary<NSURL *,NSNumber *> *_playingFiles;
    NSMutableSet<NSURL *> *_retiredFiles;
    NSDictionary<NSString *, NSDictionary *> *_entries;
    unsigned long long _byteLimit;
    unsigned long long _copyingBytes;
    NSUInteger _entryLimit;
    long long _lastTick;
    dispatch_queue_t _cleanup;
}

+ (instancetype)sharedCache {
    static FMReplayCache *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSURL *base = [NSFileManager.defaultManager URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask].firstObject;
        cache = [[self alloc] initWithDirectory:[base URLByAppendingPathComponent:@"FMExtensionReplay-v1" isDirectory:YES]
                                  audioByteLimit:256ULL * 1024 * 1024 entryLimit:512];
    });
    return cache;
}

- (instancetype)initWithDirectory:(NSURL *)directory audioByteLimit:(unsigned long long)byteLimit entryLimit:(NSUInteger)entryLimit {
    if ((self = [super init])) {
        _root = [directory copy];
        _byteLimit = byteLimit;
        _entryLimit = entryLimit;
        _clearedSongs = [NSMutableDictionary dictionary];
        _playingFiles = [NSMutableDictionary dictionary];
        _retiredFiles = [NSMutableSet set];
        _entries = @{};
        _cleanup = dispatch_queue_create("fmextension.replay.cleanup", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (long long)nextTick {
    _lastTick = MAX(_lastTick + 1, (long long)(NSDate.date.timeIntervalSince1970 * 1000));
    return _lastTick;
}

- (void)openDirectory:(NSURL *)directory {
    _directory = directory;
    NSDictionary *disk = FMReplayRead([directory URLByAppendingPathComponent:@"entries.plist"]);
    NSMutableDictionary *entries = [NSMutableDictionary dictionary];
    NSMutableSet *retainedFiles = [NSMutableSet set];
    for (NSString *key in disk) {
        NSDictionary *entry = disk[key];
        if (!FMReplayHex(key) || ![entry isKindOfClass:NSDictionary.class]) continue;
        NSMutableDictionary *clean = [NSMutableDictionary dictionary];
        NSString *address = entry[@"url"];
        if ([address isKindOfClass:NSString.class] && FMReplayRemote([NSURL URLWithString:address])) clean[@"url"] = address;
        NSString *name = entry[@"file"];
        if (FMReplayMediaName(name) && [entry[@"bytes"] isKindOfClass:NSNumber.class]) {
            NSURL *local = [directory URLByAppendingPathComponent:name];
            unsigned long long size = FMReplayRegularFileSize(local);
            if (size && size <= _byteLimit && size == [entry[@"bytes"] unsignedLongLongValue]) {
                clean[@"file"] = name;
                clean[@"bytes"] = @(size);
                [retainedFiles addObject:name];
            }
        }
        if (!clean.count) continue;
        if (FMReplayHex(entry[@"song"])) clean[@"song"] = entry[@"song"];
        long long tick = [entry[@"t"] isKindOfClass:NSNumber.class] ? [entry[@"t"] longLongValue] : 0;
        if (tick < 0 || tick > LLONG_MAX / 2) tick = 0;
        _lastTick = MAX(_lastTick, tick);
        clean[@"t"] = @(tick);
        entries[key] = clean;
    }
    _entries = entries;
    // Files from an interrupted copy or replacement were never published.
    for (NSURL *child in [NSFileManager.defaultManager contentsOfDirectoryAtURL:directory includingPropertiesForKeys:nil options:0 error:nil]) {
        if (FMReplayMediaName(child.lastPathComponent) && ![retainedFiles containsObject:child.lastPathComponent]) {
            [NSFileManager.defaultManager removeItemAtURL:child error:nil];
        }
    }
}

- (nullable NSString *)selectSourceFile:(NSString *)file script:(NSString *)script {
    NSString *identity = file.length && script.length ? FMReplayDigest(@[file, script]) : nil;
    @synchronized(self) {
        if (_initialized && [_identity isEqualToString:identity] && _epoch) return _epoch;
        NSURL *stateURL = [_root URLByAppendingPathComponent:@"selection.plist"];
        NSDictionary *saved = _initialized ? nil : FMReplayRead(stateURL);
        NSString *epoch = identity ? NSUUID.UUID.UUIDString : nil;
        if (identity && [saved[@"identity"] isEqual:identity] && FMReplayUUID(saved[@"epoch"])) epoch = saved[@"epoch"];
        _identity = nil;
        _epoch = nil;
        _directory = nil;
        _entries = @{};
        _initialized = YES;
        [_clearedSongs removeAllObjects];
        if (!FMReplayMakeDirectory(_root)) return nil;
        NSURL *directory = epoch ? [_root URLByAppendingPathComponent:epoch isDirectory:YES] : nil;
        NSDictionary *state = epoch ? @{@"identity":identity, @"epoch":epoch} : @{};
        if ((directory && !FMReplayMakeDirectory(directory)) || !FMReplayWrite(state, stateURL)) {
            [NSFileManager.defaultManager removeItemAtURL:stateURL error:nil];
            return nil;
        }
        if (epoch) {
            [self openDirectory:directory];
            _identity = identity;
            _epoch = [epoch copy];
        }
        for (NSURL *child in [NSFileManager.defaultManager contentsOfDirectoryAtURL:_root includingPropertiesForKeys:nil options:0 error:nil]) {
            if (FMReplayUUID(child.lastPathComponent) && ![child.lastPathComponent isEqualToString:epoch]) {
                dispatch_async(_cleanup, ^{ [NSFileManager.defaultManager removeItemAtURL:child error:nil]; });
            }
        }
        return _epoch;
    }
}

- (NSString *)keyForNamespace:(NSString *)namespaceID platform:(NSString *)platform trackID:(NSString *)trackID quality:(NSString *)quality {
    trackID = FMDAIdentifier(trackID);
    NSString *song = FMReplayIdentity(platform, trackID);
    if (!song || ![quality isKindOfClass:NSString.class] || !quality.length) return nil;
    @synchronized(self) {
        if (!_epoch || ![_epoch isEqualToString:namespaceID]) return nil;
        NSString *digest = FMReplayDigest(@[platform, trackID, quality]);
        if (!digest) return nil;
        NSString *base = [NSString stringWithFormat:@"%@/%@/%@", _epoch, digest, song];
        NSString *revision = _clearedSongs[song];
        return revision ? [NSString stringWithFormat:@"%@/%@", base, revision] : base;
    }
}

- (NSString *)digestForActiveKey:(NSString *)key {
    if (!_epoch || (key.length != 166 && key.length != 203)) return nil;
    NSArray *parts = [key componentsSeparatedByString:@"/"];
    if ((parts.count != 3 && parts.count != 4) || ![parts[0] isEqual:_epoch] ||
        !FMReplayHex(parts[1]) || !FMReplayHex(parts[2])) return nil;
    NSString *revision = _clearedSongs[parts[2]];
    if (parts.count == 4) {
        if (![revision isEqual:parts[3]]) return nil;
    } else if (revision) return nil;
    NSString *storedOwner = _entries[parts[1]][@"song"];
    if (storedOwner && ![storedOwner isEqual:parts[2]]) return nil;
    return parts[1];
}

- (BOOL)isCurrentKey:(NSString *)key {
    @synchronized(self) { return [self digestForActiveKey:key] != nil; }
}

- (void)protectAudio:(NSURL *)file forPlaybackItem:(id)item {
    if (!item || !file.isFileURL || !FMReplayMediaName(file.lastPathComponent)) return;
    @synchronized(self) {
        if (!_directory || ![file.URLByDeletingLastPathComponent.path isEqual:_directory.path]) return;
        NSString *name = file.lastPathComponent;
        BOOL indexed = NO;
        for (NSDictionary *row in _entries.allValues) {
            if ([row[@"file"] isEqual:name]) { indexed = YES; break; }
        }
        if (!indexed) return;
        NSURL *owned = [_directory URLByAppendingPathComponent:name];
        FMReplayFilePin *old = objc_getAssociatedObject(item,&FMReplayFilePinAssociation);
        if ([old.url isEqual:owned]) return;
        _playingFiles[owned] = @([_playingFiles[owned] unsignedIntegerValue]+1);
        FMReplayFilePin *pin = [FMReplayFilePin new];
        pin.url = owned;
        pin.releaseFile = ^{
            @synchronized(self) {
                NSUInteger count = [self->_playingFiles[owned] unsignedIntegerValue];
                if (count > 1) {
                    self->_playingFiles[owned] = @(count-1);
                    return;
                }
                [self->_playingFiles removeObjectForKey:owned];
                if ([self->_retiredFiles containsObject:owned]) {
                    unlink(owned.fileSystemRepresentation);
                    [self->_retiredFiles removeObject:owned];
                }
            }
        };
        objc_setAssociatedObject(item,&FMReplayFilePinAssociation,pin,OBJC_ASSOCIATION_RETAIN);
    }
}

- (BOOL)clearPlatform:(NSString *)platform trackID:(NSString *)trackID removedEntries:(NSUInteger *)removed {
    if (removed) *removed = 0;
    NSString *song = FMReplayIdentity(platform, trackID);
    if (!song) return NO;

    @synchronized(self) {
        NSURL *directory = _directory;
        NSDictionary *entries = _entries;
        // A song action can arrive before JS initialization. Read only the
        // selected epoch; no source activation or whole-directory cleanup.
        if (!_initialized) {
            NSURL *selection = [_root URLByAppendingPathComponent:@"selection.plist"];
            struct stat st;
            if (lstat(selection.fileSystemRepresentation, &st)) return errno == ENOENT;
            NSDictionary *saved = FMReplayRead(selection);
            if (!saved) return NO;
            if (!saved.count) return YES;
            if (!FMReplayHex(saved[@"identity"]) || !FMReplayUUID(saved[@"epoch"])) return NO;
            directory = [_root URLByAppendingPathComponent:saved[@"epoch"] isDirectory:YES];
        }
        if (!directory) return YES;
        NSURL *index = [directory URLByAppendingPathComponent:@"entries.plist"];
        struct stat dirStat;
        // iOS may purge an entire cache directory. Existing in-memory keys
        // still need to be invalidated in that case.
        BOOL directoryExists = lstat(directory.fileSystemRepresentation, &dirStat) == 0;
        if (directoryExists) {
            if (!S_ISDIR(dirStat.st_mode) || !FMDADirectory(_root)) return NO;
            if (!_initialized) {
                struct stat st;
                if (lstat(index.fileSystemRepresentation, &st)) {
                    if (errno != ENOENT) return NO;
                    entries = @{};
                } else if (!(entries = FMReplayRead(index))) return NO;
            }
        } else if (errno != ENOENT) return NO;
        else if (!_initialized) return YES;

        NSSet *legacy = FMReplayLegacyDigests(platform, FMDAIdentifier(trackID));
        NSMutableDictionary *next = entries.mutableCopy;
        NSMutableSet *discard = [NSMutableSet set], *keep = [NSMutableSet set];
        for (id digest in entries) {
            id row = entries[digest];
            if (![row isKindOfClass:NSDictionary.class]) continue;
            BOOL matches = FMReplayHex(row[@"song"]) ? [row[@"song"] isEqual:song] : [legacy containsObject:digest];
            if (matches) [next removeObjectForKey:digest];
            if (FMReplayMediaName(row[@"file"])) [(matches ? discard : keep) addObject:row[@"file"]];
        }
        NSUInteger count = entries.count - next.count;
        if (count) {
            [discard minusSet:keep];
            NSMutableArray *playing = [NSMutableArray array];
            for (NSString *name in discard) {
                // unlink only an indexed UUID filename underneath this replay
                // directory; never follow links, recurse, or touch manual files.
                NSURL *file = [directory URLByAppendingPathComponent:name];
                if (_playingFiles[file]) [playing addObject:file];
                else if (unlink(file.fileSystemRepresentation) && errno != ENOENT) return NO;
            }
            if (directoryExists && !FMReplayWrite(next,index)) return NO;
            [_retiredFiles addObjectsFromArray:playing];
            if (_initialized) _entries = next.copy;
        }
        if (_initialized) _clearedSongs[song] = NSUUID.UUID.UUIDString;
        if (removed) *removed = count;
        return YES;
    }
}

- (BOOL)commit:(NSMutableDictionary<NSString *, NSDictionary *> *)next {
    if (!_directory) return NO;
    if (![NSFileManager.defaultManager fileExistsAtPath:_directory.path]) {
        if (!FMReplayMakeDirectory(_directory) ||
            !FMReplayWrite(@{@"identity":_identity,@"epoch":_epoch},[_root URLByAppendingPathComponent:@"selection.plist"])) return NO;
    }
    NSArray *oldest = [next keysSortedByValueUsingComparator:^NSComparisonResult(NSDictionary *left, NSDictionary *right) {
        return [left[@"t"] compare:right[@"t"]];
    }];
    NSUInteger i = 0;
    while (next.count > _entryLimit) [next removeObjectForKey:oldest[i++]];
    unsigned long long total = 0;
    for (NSDictionary *entry in next.allValues) total += [entry[@"bytes"] unsignedLongLongValue];
    for (NSString *key in oldest) {
        if (total <= _byteLimit) break;
        NSMutableDictionary *entry = [next[key] mutableCopy];
        if (!entry[@"file"]) continue;
        total -= [entry[@"bytes"] unsignedLongLongValue];
        [entry removeObjectsForKeys:@[@"file", @"bytes"]];
        if (entry[@"url"]) next[key] = entry;
        else [next removeObjectForKey:key];
    }
    if (!FMReplayWrite(next, [_directory URLByAppendingPathComponent:@"entries.plist"])) return NO;
    NSDictionary *old = _entries;
    _entries = next;
    [old enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSDictionary *entry, BOOL *stop) {
        NSString *oldName = entry[@"file"];
        if (oldName && ![next[key][@"file"] isEqual:oldName]) {
            NSURL *file = [self->_directory URLByAppendingPathComponent:oldName];
            if (self->_playingFiles[file]) [self->_retiredFiles addObject:file];
            else [NSFileManager.defaultManager removeItemAtURL:file error:nil];
        }
    }];
    return YES;
}

- (void)touch:(NSString *)digest {
    // LRU changes are folded into the next metadata write. A forced termination
    // can lose recent access timestamps, but cannot expose an uncommitted file.
    NSMutableDictionary *entry = [_entries[digest] mutableCopy];
    entry[@"t"] = @([self nextTick]);
    NSMutableDictionary *next = [_entries mutableCopy];
    next[digest] = entry;
    _entries = next;
}

- (NSURL *)addressForKey:(NSString *)key {
    @synchronized(self) {
        NSString *digest = [self digestForActiveKey:key];
        if (!digest) return nil;
        NSString *value = _entries[digest][@"url"];
        NSURL *url = value ? [NSURL URLWithString:value] : nil;
        if (url) [self touch:digest];
        return url;
    }
}

- (void)saveAddress:(NSURL *)address forKey:(NSString *)key {
    if (!FMReplayRemote(address)) return;
    @synchronized(self) {
        NSString *digest = [self digestForActiveKey:key];
        if (!digest) return;
        NSMutableDictionary *entry = [_entries[digest] mutableCopy] ?: [NSMutableDictionary dictionary];
        entry[@"song"] = [key componentsSeparatedByString:@"/"][2];
        entry[@"url"] = address.absoluteString;
        entry[@"t"] = @([self nextTick]);
        NSMutableDictionary *next = [_entries mutableCopy];
        next[digest] = entry;
        [self commit:next];
    }
}

- (NSURL *)audioForKey:(NSString *)key {
    @synchronized(self) {
        NSString *digest = [self digestForActiveKey:key];
        if (!digest) return nil;
        NSDictionary *entry = _entries[digest];
        NSString *name = entry[@"file"];
        if (!name) return nil;
        NSURL *url = [_directory URLByAppendingPathComponent:name];
        unsigned long long bytes = FMReplayRegularFileSize(url);
        if (!bytes || bytes != [entry[@"bytes"] unsignedLongLongValue]) {
            [self discardAudio:url forKey:key];
            return nil;
        }
        [self touch:digest];
        return url;
    }
}

- (void)removeFields:(NSArray<NSString *> *)fields digest:(NSString *)digest {
    NSMutableDictionary *entry = [_entries[digest] mutableCopy];
    [entry removeObjectsForKeys:fields];
    NSMutableDictionary *next = [_entries mutableCopy];
    if (entry[@"url"] || entry[@"file"]) next[digest] = entry;
    else [next removeObjectForKey:digest];
    [self commit:next];
}

- (void)discardAddress:(NSURL *)address forKey:(NSString *)key {
    @synchronized(self) {
        NSString *digest = [self digestForActiveKey:key];
        if (digest && [_entries[digest][@"url"] isEqual:address.absoluteString]) [self removeFields:@[@"url"] digest:digest];
    }
}

- (void)discardAudio:(NSURL *)file forKey:(NSString *)key {
    @synchronized(self) {
        NSString *digest = [self digestForActiveKey:key];
        NSString *name = digest ? _entries[digest][@"file"] : nil;
        if (name && [[_directory URLByAppendingPathComponent:name].path isEqual:file.path])
            [self removeFields:@[@"file", @"bytes"] digest:digest];
    }
}

- (BOOL)publishVerifiedAudio:(NSURL *)file fileExtension:(NSString *)extension forKey:(NSString *)key {
    return [self publishVerifiedAudio:file fileExtension:extension forKey:key expectedAddress:nil];
}

- (BOOL)publishVerifiedAudio:(NSURL *)file fileExtension:(NSString *)extension forKey:(NSString *)key expectedAddress:(NSURL *)expectedAddress {
    extension = extension.lowercaseString;
    if (!FMReplayExtension(extension)) return NO;
    unsigned long long size = FMReplayRegularFileSize(file);
    if (!size || size > _byteLimit) return NO;
    NSURL *destination;
    NSString *name = [NSUUID.UUID.UUIDString stringByAppendingPathExtension:extension];
    @synchronized(self) {
        NSString *digest = [self digestForActiveKey:key];
        if (!digest || (expectedAddress && ![_entries[digest][@"url"] isEqual:expectedAddress.absoluteString])) return NO;
        if (_copyingBytes > _byteLimit-size) return NO;
        _copyingBytes+=size;
        destination = [_directory URLByAppendingPathComponent:name];
    }
    // Copy without holding up another playback lookup or a source switch.
    NSFileManager *fm = NSFileManager.defaultManager;
    if (![fm copyItemAtURL:file toURL:destination error:nil]) {
        [fm removeItemAtURL:destination error:nil];
        @synchronized(self) { _copyingBytes-=size; }
        return NO;
    }
    BOOL published = NO;
    NSDictionary *protection = FMReplayAttributes();
    if (FMReplayRegularFileSize(destination) == size &&
        (!protection.count || [fm setAttributes:protection ofItemAtPath:destination.path error:nil])) {
        @synchronized(self) {
            NSString *digest = [self digestForActiveKey:key];
            if (digest && (!expectedAddress || [_entries[digest][@"url"] isEqual:expectedAddress.absoluteString])) {
                NSMutableDictionary *entry = [_entries[digest] mutableCopy] ?: [NSMutableDictionary dictionary];
                entry[@"song"] = [key componentsSeparatedByString:@"/"][2];
                entry[@"file"] = name;
                entry[@"bytes"] = @(size);
                entry[@"t"] = @([self nextTick]);
                NSMutableDictionary *next = [_entries mutableCopy];
                next[digest] = entry;
                published = [self commit:next] && [_entries[digest][@"file"] isEqual:name];
            }
        }
    }
    if (!published) [fm removeItemAtURL:destination error:nil];
    @synchronized(self) { _copyingBytes-=size; }
    return published;
}
@end
