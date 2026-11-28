#import "FMReplayCache.h"

static NSUInteger checks;
static void Check(BOOL ok, NSString *name) {
    if (!ok) {
        fprintf(stderr, "FAILED: %s\n", name.UTF8String);
        exit(1);
    }
    checks++;
}

static FMReplayCache *Store(NSURL *root, NSUInteger limit, NSUInteger entries) {
    return [[FMReplayCache alloc] initWithDirectory:root audioByteLimit:limit entryLimit:entries];
}
static NSString *Key(FMReplayCache *store, NSString *epoch, NSString *track) {
    return [store keyForNamespace:epoch platform:@"tx" trackID:track quality:@"320k"];
}
static NSURL *Sample(NSURL *root, NSString *name, NSString *contents) {
    NSURL *url = [root URLByAppendingPathComponent:name];
    BOOL ok = [contents writeToURL:url atomically:YES encoding:NSUTF8StringEncoding error:nil];
    Check(ok, @"create test bytes");
    return url;
}

// The old on-disk format was an index keyed by a length-prefixed SHA-256 of
// (platform, native ID, quality); rows contained no reversible song metadata.
static void TestSongClear(NSURL *base, NSURL *sample, NSURL *one, NSURL *two) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSURL *root = [base URLByAppendingPathComponent:@"song-clear"];
    FMReplayCache *store = Store(root, 4096, 64);
    NSString *epoch = [store selectSourceFile:@"source.js" script:@"fixture"];
    NSString *song = @"CaseMID";
    NSArray *qualities = @[@"128k", @"320k", @"flac", @"flac24bit", @"future-format"];
    NSMutableArray *keys = [NSMutableArray array], *files = [NSMutableArray array];
    for (NSString *quality in qualities) {
        NSString *key = [store keyForNamespace:epoch platform:@"tx" trackID:song quality:quality];
        [store saveAddress:one forKey:key];
        Check([store publishVerifiedAudio:sample fileExtension:@"wav" forKey:key], @"prepare one cached quality");
        [keys addObject:key]; [files addObject:[store audioForKey:key]];
    }
    NSString *pending = [store keyForNamespace:epoch platform:@"tx" trackID:song quality:@"pending-only"];
    NSString *otherPlatform = [store keyForNamespace:epoch platform:@"wy" trackID:song quality:@"320k"];
    NSString *otherQQ = Key(store,epoch,@"casemid");
    [store saveAddress:two forKey:otherPlatform];
    Check([store publishVerifiedAudio:sample fileExtension:@"mp3" forKey:otherQQ], @"other QQ song shares audio contents");
    NSURL *otherAudio = [store audioForKey:otherQQ];
    NSUInteger removed = NSNotFound;
    Check([store clearPlatform:@"qq" trackID:song removedEntries:&removed] && removed == qualities.count,
          @"all qualities, including future formats, are removed by the native platform alias");
    for (NSUInteger index=0; index<keys.count; index++)
        Check(![store isCurrentKey:keys[index]] && ![store addressForKey:keys[index]] &&
              ![fm fileExistsAtPath:[files[index] path]], @"original URL, complete audio and old token discarded");
    Check([store isCurrentKey:otherPlatform] && [[store addressForKey:otherPlatform] isEqual:two] &&
          [[store audioForKey:otherQQ] isEqual:otherAudio] && [fm fileExistsAtPath:sample.path],
          @"other platforms, case-sensitive QQ identities and the original download survive");
    Check(![store isCurrentKey:pending], @"unwritten in-flight request is retired");
    dispatch_apply(8, dispatch_get_global_queue(QOS_CLASS_UTILITY,0), ^(size_t i){
        NSString *old = i % 2 ? pending : keys[0];
        [store saveAddress:two forKey:old];
        [store publishVerifiedAudio:sample fileExtension:@"mp3" forKey:old];
    });
    NSString *fresh = [store keyForNamespace:epoch platform:@"tx" trackID:song quality:@"128k"];
    Check([store isCurrentKey:fresh] && ![store audioForKey:fresh] && ![store addressForKey:fresh],
          @"delayed resolver and transfer publications cannot repopulate a cleared song");
    [store saveAddress:two forKey:fresh];
    [store discardAddress:two forKey:keys[0]];
    Check([[store addressForKey:fresh] isEqual:two], @"fresh playback can recache after clearing");
    Check([store clearPlatform:@"tx" trackID:song removedEntries:&removed] && removed == 1 &&
          [store clearPlatform:@"tx" trackID:song removedEntries:&removed] && removed == 0, @"repeat clear is idempotent");
    NSString *coldArchiveKey = [store keyForNamespace:epoch platform:@"tx" trackID:song quality:@"new-after-restart"];
    [store saveAddress:one forKey:coldArchiveKey];
    FMReplayCache *cold = Store(root,4096,64);
    Check([cold clearPlatform:@"qq" trackID:song removedEntries:&removed] && removed == 1,
          @"persisted song digest permits clearing a new quality before selecting JS");
    [cold selectSourceFile:@"source.js" script:@"fixture"];
    Check(![cold addressForKey:[cold keyForNamespace:epoch platform:@"tx" trackID:song quality:@"new-after-restart"]] &&
          [[cold audioForKey:Key(cold,epoch,@"casemid")] isEqual:otherAudio], @"cold clear is durable and targeted");
    Check(![cold clearPlatform:@"qq" trackID:@"../Downloads/x" removedEntries:nil], @"malformed track never clears data");
    NSURL *folder = [root URLByAppendingPathComponent:epoch];
    Check([fm removeItemAtURL:folder error:nil], @"simulate an iOS disk cache purge");
    Check([cold clearPlatform:@"qq" trackID:song removedEntries:&removed] && !removed &&
          [[cold addressForKey:[cold keyForNamespace:epoch platform:@"wy" trackID:song quality:@"320k"]] isEqual:two],
          @"clearing one song after an OS disk purge preserves unrelated live addresses");
}

static void TestPlayingFile(NSURL *base, NSURL *sample) {
    FMReplayCache *store = Store([base URLByAppendingPathComponent:@"player-pins"],4096,64);
    NSString *epoch = [store selectSourceFile:@"fixture.js" script:@"fixture"];
    NSString *key = Key(store,epoch,@"playing");
    Check([store publishVerifiedAudio:sample fileExtension:@"mp3" forKey:key], @"prepare current playback file");
    NSURL *url = [store audioForKey:key];
    @autoreleasepool {
        __attribute__((objc_precise_lifetime)) NSObject *firstItem = [NSObject new];
        [store protectAudio:url forPlaybackItem:firstItem];
        [store protectAudio:url forPlaybackItem:firstItem];
        @autoreleasepool {
            __attribute__((objc_precise_lifetime)) NSObject *secondItem = [NSObject new];
            [store protectAudio:url forPlaybackItem:secondItem];
            NSUInteger removed = NSNotFound;
            Check([store clearPlatform:@"qq" trackID:@"playing" removedEntries:&removed] && removed == 1 &&
                  ![store audioForKey:Key(store,epoch,@"playing")] && ![store isCurrentKey:key],
                  @"playing file is immediately undiscoverable for a later playback");
            Check([[NSData dataWithContentsOfURL:url] isEqual:[NSData dataWithContentsOfURL:sample]],
                  @"bound player items can reopen and seek the retired bytes");
        }
        Check([NSFileManager.defaultManager fileExistsAtPath:url.path], @"a second reader finishing does not interrupt the first");
    }
    Check(![NSFileManager.defaultManager fileExistsAtPath:url.path] && [NSFileManager.defaultManager fileExistsAtPath:sample.path],
          @"last reader reclaims only the retired cache copy");
}

static void TestV11Clear(NSURL *base, BOOL beforeActivation, NSURL *sample, NSURL *address) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSURL *root = [base URLByAppendingPathComponent:beforeActivation ? @"v11-cold" : @"v11-open"];
    FMReplayCache *seed = Store(root,4096,64);
    NSString *epoch = [seed selectSourceFile:@"legacy.js" script:@"legacy source"];
    NSURL *directory = [root URLByAppendingPathComponent:epoch isDirectory:YES];
    NSURL *index = [directory URLByAppendingPathComponent:@"entries.plist"];
    NSString *name = [NSUUID.UUID.UUIDString stringByAppendingPathExtension:@"wav"];
    NSURL *audio = [directory URLByAppendingPathComponent:name];
    Check([fm copyItemAtURL:sample toURL:audio error:nil], @"prepare previous-release audio");
    NSString *target = @"a8afff1cd6e909debf6eb79b4f395783a91872de1ba0449eb9e28a9fb0a3bbe4", *second = @"5fad33831f0ac2e62f2e3b75433aaf420c5ab589fd4429ed269d375d0e5de6d4", *other = @"d1d4270046ee7a28ec1bfe66779d15a9385b136cf236b884c1e9b23389abbb28";
    NSDictionary *legacy = @{target:@{@"url":address.absoluteString, @"file":name, @"bytes":@8, @"t":@1},
                             second:@{@"url":address.absoluteString, @"t":@2},
                             other:@{@"url":address.absoluteString, @"t":@3}};
    Check([legacy writeToURL:index atomically:YES], @"write genuine v11 index shape");
    FMReplayCache *store = Store(root,4096,64);
    if (!beforeActivation) {
        Check([[store selectSourceFile:@"legacy.js" script:@"legacy source"] isEqual:epoch], @"previous release epoch restored");
        Check([[store audioForKey:Key(store,epoch,@"CaseMID")] isEqual:audio], @"v11 complete audio can be replayed before clearing");
    }
    NSUInteger removed = NSNotFound;
    Check([store clearPlatform:@"qq" trackID:@"CaseMID" removedEntries:&removed] && removed == 2,
          @"remove both previous-release qualities by their exact v11 digests");
    Check(![fm fileExistsAtPath:audio.path] && [fm fileExistsAtPath:sample.path], @"only the old replay copy is unlinked");
    NSDictionary *after = [NSDictionary dictionaryWithContentsOfURL:index];
    Check(after.count == 1 && [after[other] isEqual:legacy[other]], @"other platform's original on-disk row survives unchanged");
    [store selectSourceFile:@"legacy.js" script:@"legacy source"];
    NSString *wy = [store keyForNamespace:epoch platform:@"wy" trackID:@"CaseMID" quality:@"320k"];
    Check(![store addressForKey:Key(store,epoch,@"CaseMID")] && [[store addressForKey:wy] isEqual:address],
          @"subsequent activation can see only the unrelated cache");
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSFileManager *fm = NSFileManager.defaultManager;
        NSURL *tmp = [NSURL fileURLWithPath:NSTemporaryDirectory() isDirectory:YES];
        NSURL *base = [tmp URLByAppendingPathComponent:NSUUID.UUID.UUIDString isDirectory:YES];
        Check([fm createDirectoryAtURL:base withIntermediateDirectories:YES attributes:nil error:nil], @"make test directory");
        NSURL *root = [base URLByAppendingPathComponent:@"cache" isDirectory:YES];
        NSURL *sample = Sample(base, @"original", @"12345678");
        NSURL *other = Sample(base, @"other", @"87654321");
        NSURL *one = [NSURL URLWithString:@"https://cache.invalid/audio?token=f1"];
        NSURL *two = [NSURL URLWithString:@"https://cache.invalid/audio?token=f2"];
        NSString *file = @"private-fixture-file-name.js", *script = @"private-test-script";
        FMReplayCache *store = Store(root, 16, 4);
        NSString *epoch = [store selectSourceFile:file script:script];
        NSString *key = Key(store, epoch, @"private-fixture-song");
        Check(epoch.length == 36 && [store isCurrentKey:key], @"issue namespace-scoped key");
        Check(![key containsString:@"private-fixture-song"], @"track identifiers are hashed");
        Check([Key(store, epoch, @"private-fixture-song") isEqual:key], @"same song source and quality use same key");
        Check(![Key(store, epoch, @"other-id") isEqual:key], @"another native id misses");
        Check(![[store keyForNamespace:epoch platform:@"wy" trackID:@"private-fixture-song" quality:@"320k"] isEqual:key], @"platform isolation");
        Check(![[store keyForNamespace:epoch platform:@"tx" trackID:@"private-fixture-song" quality:@"flac"] isEqual:key], @"quality isolation");
        Check(!Key(store, @"fake-epoch", @"id") && !Key(store, epoch, @""), @"invalid key components");
        Check(![store audioForKey:key] && ![store addressForKey:key], @"empty cache");
        [store saveAddress:[NSURL URLWithString:@"file:///tmp/test"] forKey:key];
        [store saveAddress:[NSURL URLWithString:@"https://u:pw@cache.invalid/a"] forKey:key];
        Check(![store addressForKey:key], @"only HTTP(S) without URL user info");
        [store saveAddress:one forKey:key];
        Check([[store addressForKey:key] isEqual:one] && ![store audioForKey:key], @"address alone enables a hit");
        [store saveAddress:two forKey:key];
        [store discardAddress:one forKey:key];
        Check([[store addressForKey:key] isEqual:two], @"late failed URL does not evict its replacement");
        Check(![store publishVerifiedAudio:sample fileExtension:@"flac" forKey:key expectedAddress:one], @"obsolete address completion rejected");
        Check(![store publishVerifiedAudio:sample fileExtension:@"../other" forKey:key], @"reject unsafe container");
        Check([store publishVerifiedAudio:sample fileExtension:@"FLAC" forKey:key expectedAddress:two], @"copy validated audio from current address");
        NSURL *first = [store audioForKey:key];
        Check(first.isFileURL && [first.pathExtension isEqual:@"flac"] &&
              [[NSData dataWithContentsOfURL:first] isEqual:[NSData dataWithContentsOfURL:sample]], @"stored bytes and real container preserved");
        Check([fm fileExistsAtPath:sample.path], @"caller retains original");
        Check([store publishVerifiedAudio:other fileExtension:@"m4a" forKey:key], @"atomic audio replacement");
        NSURL *second = [store audioForKey:key];
        Check(![first isEqual:second] && ![fm fileExistsAtPath:first.path], @"file versions are unique and retired");
        [store discardAudio:first forKey:key];
        Check([[store audioForKey:key] isEqual:second], @"late decoder error cannot evict replacement");
        [store discardAddress:two forKey:key];
        Check(![store addressForKey:key] && [[store audioForKey:key] isEqual:second], @"URL expiry preserves verified audio");
        [store saveAddress:one forKey:key];
        NSString *oldKey = key;
        store = Store(root, 16, 4);
        NSString *reopened = [store selectSourceFile:file script:script];
        Check([reopened isEqual:epoch], @"same imported source survives restart");
        key = Key(store, reopened, @"private-fixture-song");
        Check([key isEqual:oldKey] && [[store audioForKey:key] isEqual:second] && [[store addressForKey:key] isEqual:one],
              @"reopen persisted address and complete audio");
        [@"x" writeToURL:second atomically:YES encoding:NSUTF8StringEncoding error:nil];
        Check(![store audioForKey:key] && [[store addressForKey:key] isEqual:one], @"truncated disk entry safely falls back to address");
        Check([store publishVerifiedAudio:sample fileExtension:@"mp3" forKey:key], @"publish old-source file again");
        NSString *b = [store selectSourceFile:@"b.js" script:script];
        Check(![b isEqual:epoch] && ![store addressForKey:key] && ![store audioForKey:key], @"distinct imports revoke old keys even for identical script text");
        [store saveAddress:two forKey:key];
        Check(![store publishVerifiedAudio:other fileExtension:@"mp3" forKey:key], @"old callback cannot publish after switch");
        NSString *a2 = [store selectSourceFile:file script:script];
        NSString *current = Key(store, a2, @"private-fixture-song");
        Check(![a2 isEqual:epoch] && ![store addressForKey:current] && ![store audioForKey:current], @"A to B to A never restores prior A bytes");
        Check(!Key(store, epoch, @"private-fixture-song") && ![store addressForKey:key], @"revoked generation never revives");
        [store saveAddress:one forKey:current];
        NSString *edited = [store selectSourceFile:file script:@"edited"];
        Check(![a2 isEqual:edited] && ![store addressForKey:current], @"in-place script edit revokes cache");
        NSString *beforeDisable = Key(store, edited, @"id");
        [store saveAddress:one forKey:beforeDisable];
        Check(![store selectSourceFile:nil script:nil] && ![store addressForKey:beforeDisable], @"disable revokes");
        store = Store(root, 16, 4);
        NSString *afterDisable = [store selectSourceFile:file script:@"edited"];
        Check(![afterDisable isEqual:edited], @"disable persists across restart");
        NSString *k1 = Key(store, afterDisable, @"1"), *k2 = Key(store, afterDisable, @"2"), *k3 = Key(store, afterDisable, @"3");
        [store saveAddress:one forKey:k1];
        [store saveAddress:two forKey:k2];
        [store publishVerifiedAudio:sample fileExtension:@"mp3" forKey:k1];
        [store publishVerifiedAudio:sample fileExtension:@"mp3" forKey:k2];
        [store audioForKey:k1];
        [store publishVerifiedAudio:sample fileExtension:@"mp3" forKey:k3];
        Check([store audioForKey:k1] && ![store audioForKey:k2] && [store audioForKey:k3], @"byte limit evicts least recently used audio");
        Check([[store addressForKey:k2] isEqual:two], @"audio LRU preserves independent address");
        NSURL *tooLarge = Sample(base, @"big", @"1234567890123456789");
        Check(![store publishVerifiedAudio:tooLarge fileExtension:@"mp3" forKey:k1] && [store audioForKey:k1],
              @"oversized replacement keeps good bytes");
        NSURL *bad = [base URLByAppendingPathComponent:@"missing.mp3"];
        Check(![store publishVerifiedAudio:bad fileExtension:@"mp3" forKey:k1] && [store audioForKey:k1], @"failed copy leaves prior file");
        NSURL *link = [base URLByAppendingPathComponent:@"link.mp3"];
        Check([fm createSymbolicLinkAtURL:link withDestinationURL:sample error:nil] &&
              ![store publishVerifiedAudio:link fileExtension:@"mp3" forKey:k1], @"reject external symlink inputs");
        NSURL *secondRoot = [base URLByAppendingPathComponent:@"bounded"];
        FMReplayCache *bounded = Store(secondRoot, 256, 2);
        NSString *e = [bounded selectSourceFile:@"test.js" script:@"return"];
        NSString *x = Key(bounded, e, @"x"), *y = Key(bounded, e, @"y"), *z = Key(bounded, e, @"z");
        [bounded saveAddress:one forKey:x]; [bounded saveAddress:one forKey:y]; [bounded addressForKey:x];
        [bounded saveAddress:two forKey:z];
        Check([bounded addressForKey:x] && ![bounded addressForKey:y] && [[bounded addressForKey:z] isEqual:two], @"bounded address index LRU");
        // Match callback races from several concurrent requests. Whichever write
        // wins must name one whole copy, never a mixture or an obsolete epoch.
        dispatch_apply(8, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^(size_t n) {
            [bounded publishVerifiedAudio:n % 2 ? other : sample fileExtension:@"m4a" forKey:x];
        });
        NSURL *winner = [bounded audioForKey:x];
        NSData *bytes = [NSData dataWithContentsOfURL:winner];
        Check([bytes isEqual:[NSData dataWithContentsOfURL:sample]] || [bytes isEqual:[NSData dataWithContentsOfURL:other]],
              @"concurrent publishers return complete media");
        NSURL *folder = [secondRoot URLByAppendingPathComponent:e];
        NSArray *names = [fm contentsOfDirectoryAtPath:folder.path error:nil];
        Check(names.count == 2 && [names containsObject:@"entries.plist"], @"no extra files after concurrent replacement");
        [fm removeItemAtURL:winner error:nil];
        Check(![bounded audioForKey:x] && [bounded addressForKey:x], @"iOS cache purge leaves usable address");
        // Simulate an interrupted write: it has a UUID filename but no committed entry.
        NSURL *orphan = [folder URLByAppendingPathComponent:[NSUUID.UUID.UUIDString stringByAppendingPathExtension:@"mp3"]];
        [@"orphan" writeToURL:orphan atomically:YES encoding:NSUTF8StringEncoding error:nil];
        bounded = Store(secondRoot, 256, 2);
        [bounded selectSourceFile:@"test.js" script:@"return"];
        Check(![fm fileExistsAtPath:orphan.path] && [bounded addressForKey:x], @"orphan recovery preserves committed data");
        TestSongClear(base,sample,one,two);
        TestPlayingFile(base,sample);
        TestV11Clear(base,YES,sample,one);
        TestV11Clear(base,NO,sample,one);
        [fm removeItemAtURL:base error:nil];
        if (argc > 1) {
            NSDictionary *report = @{@"passed":@YES, @"assertion_count":@(checks), @"original_app_used":@NO};
            NSData *json = [NSJSONSerialization dataWithJSONObject:report options:0 error:nil];
            Check([json writeToFile:@(argv[1]) atomically:YES], @"write report");
        }
        printf("PASS playback cache store (%lu checks)\n", (unsigned long)checks);
    }
    return 0;
}
