#import "FMReplayCache.h"
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

@implementation FMReplayCache {
    NSURL *_root;
    NSURL *_directory;
    NSString *_identity;
    NSString *_epoch;
    BOOL _initialized;
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
    if (!platform.length || !trackID.length || !quality.length) return nil;
    @synchronized(self) {
        if (!_epoch || ![_epoch isEqualToString:namespaceID]) return nil;
        NSString *digest = FMReplayDigest(@[platform, trackID, quality]);
        return digest ? [NSString stringWithFormat:@"%@/%@", _epoch, digest] : nil;
    }
}

- (NSString *)digestForActiveKey:(NSString *)key {
    if (!_epoch || key.length != 101 || ![key hasPrefix:_epoch] || [key characterAtIndex:36] != '/') return nil;
    NSString *digest = [key substringFromIndex:37];
    return FMReplayHex(digest) ? digest : nil;
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
            [NSFileManager.defaultManager removeItemAtURL:[self->_directory URLByAppendingPathComponent:oldName] error:nil];
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
