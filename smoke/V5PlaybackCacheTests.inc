// Included after the existing manager source tests. This uses real manager
// activation, a real Swift instance method and local AVPlayer decoding. The
// cache model deliberately allows old completions to write captured old keys.
{
[self test:@"v5_source_switch_cache_epochs_and_native_swift_self" body:^NSDictionary *{
    void *(*createFixture)(const char *, const char *) = (void *(*)(const char *, const char *))dlsym(self.swiftUIFixtureHandle, "FMCacheFixtureCreate");
    void (*seedFixture)(void *, const char *) = (void (*)(void *, const char *))dlsym(self.swiftUIFixtureHandle, "FMCacheFixtureSeed");
    void (*completeOld)(void *) = (void (*)(void *))dlsym(self.swiftUIFixtureHandle, "FMCacheFixtureCompleteOldResults");
    int32_t (*keyHit)(void *, const char *) = (int32_t (*)(void *, const char *))dlsym(self.swiftUIFixtureHandle, "FMCacheFixtureKeyHit");
    void *(*copyState)(void *) = (void *(*)(void *))dlsym(self.swiftUIFixtureHandle, "FMCacheFixtureCopyState");
    void *(*copyPlayer)(void *) = (void *(*)(void *))dlsym(self.swiftUIFixtureHandle, "FMCacheFixtureCopyPlayer");
    void *nativeMethod = dlsym(self.swiftUIFixtureHandle, "FMCacheFixtureInvalidateNative");
    void (*configure)(id, void *, BOOL) = (void (*)(id, void *, BOOL))dlsym(self.extensionHandle, "FMPlaybackCacheTestConfigureReceiver");
    // CopySuffix follows +1 Cocoa ownership. Use its raw pointer ABI here so
    // CFBridgingRelease consumes exactly the documented retained reference.
    void *(*copySuffix)(void) = (void *(*)(void))dlsym(self.extensionHandle, "FMPlaybackCacheCopySuffix");
    BOOL (*bypassAutomatic)(NSString *) = (BOOL (*)(NSString *))dlsym(self.extensionHandle, "FMPlaybackCacheShouldBypassAutomaticCache");
    BOOL (*bypassURL)(NSURL *, NSURL *) = (BOOL (*)(NSURL *, NSURL *))dlsym(self.extensionHandle, "FMPlaybackCacheShouldBypassURL");
    NSDictionary *(*diagnostics)(void) = (NSDictionary *(*)(void))dlsym(self.extensionHandle, "FMPlaybackCacheDiagnostics");
    Check(createFixture && seedFixture && completeOld && keyHit && copyState && copyPlayer && nativeMethod && configure && copySuffix && bypassAutomatic && bypassURL && diagnostics,
          @"Native cache bridge and authored Swift self fixture exports are present");

    NSURL *temporary = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:[@"FMX-cache-epoch-" stringByAppendingString:NSUUID.UUID.UUIDString]] isDirectory:YES];
    NSError *fileError = nil;
    Check([NSFileManager.defaultManager createDirectoryAtURL:temporary withIntermediateDirectories:YES attributes:nil error:&fileError], fileError.localizedDescription);
    NSURL *audioURL = [temporary URLByAppendingPathComponent:@"authored-tone.wav"];
    NSURL *automaticDirectory = [temporary URLByAppendingPathComponent:@"AudioCache" isDirectory:YES];
    NSURL *downloadDirectory = [temporary URLByAppendingPathComponent:@"Downloads" isDirectory:YES];
    NSURL *siblingDirectory = [temporary URLByAppendingPathComponent:@"AudioCache2" isDirectory:YES];
    for(NSURL *directory in @[automaticDirectory,downloadDirectory,siblingDirectory])
        Check([NSFileManager.defaultManager createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:&fileError], fileError.localizedDescription);
    NSURL *downloadURL = [downloadDirectory URLByAppendingPathComponent:@"qq_fixture.flac"];
    NSURL *automaticURL = [automaticDirectory URLByAppendingPathComponent:@"qq_fixture.mp3"];
    NSURL *siblingURL = [siblingDirectory URLByAppendingPathComponent:@"qq_fixture.mp3"];
    NSData *manualBytes = [@"Self-authored manual download sentinel; never remove this file" dataUsingEncoding:NSUTF8StringEncoding];
    NSData *automaticBytes = [@"Self-authored automatic cache sentinel" dataUsingEncoding:NSUTF8StringEncoding];
    Check([manualBytes writeToURL:downloadURL atomically:YES] && [automaticBytes writeToURL:automaticURL atomically:YES] && [manualBytes writeToURL:siblingURL atomically:YES], @"Write separate manual, automatic and sibling-directory cache sentinels");
    const uint32_t sampleRate = 22050, sampleCount = 60 * sampleRate, audioBytes = sampleCount * 2;
    NSMutableData *wave = NSMutableData.data;
    void (^u16)(uint16_t) = ^(uint16_t value) { uint8_t bytes[2] = {(uint8_t)value, (uint8_t)(value >> 8)}; [wave appendBytes:bytes length:2]; };
    void (^u32)(uint32_t) = ^(uint32_t value) { uint8_t bytes[4] = {(uint8_t)value, (uint8_t)(value >> 8), (uint8_t)(value >> 16), (uint8_t)(value >> 24)}; [wave appendBytes:bytes length:4]; };
    [wave appendBytes:"RIFF" length:4]; u32(36 + audioBytes); [wave appendBytes:"WAVEfmt " length:8];
    u32(16); u16(1); u16(1); u32(sampleRate); u32(sampleRate * 2); u16(2); u16(16);
    [wave appendBytes:"data" length:4]; u32(audioBytes);
    for (uint32_t index = 0; index < sampleCount; index++) u16((uint16_t)(int16_t)(500.0 * sin(2.0 * M_PI * 220.0 * index / sampleRate)));
    Check([wave writeToURL:audioURL atomically:YES], @"Write authored playable local media");

    __block FMXManager *manager = nil;
    __block id fixture = nil;
    __block AVPlayer *player = nil;
    __block NSURL *sourceDirectory = nil;
    __block NSString *oldCategory = nil, *oldMode = nil;
    __block AVAudioSessionCategoryOptions oldOptions = 0;
    __block NSError *audioError = nil;
    __block double lastTime = 0;
    __block NSDictionary *lastState = nil;
    __block NSUInteger audioContinuityChecks = 0;
    __block BOOL previousWyBypass = NO, previousKgBypass = NO;
    NSURLSession *pendingSession = nil;
    NSArray<NSString *> *fixtureFiles = @[@"CacheEpochA.js", @"CacheEpochB.js", @"CacheEpochFail.js"];
    NSString *(^currentKey)(void) = ^NSString *{
        NSString *suffix = CFBridgingRelease(copySuffix());
        Check(suffix.length > 0, @"Matched receiver exposes the production cache generation suffix");
        return [@"qq_authored-track|standard" stringByAppendingString:suffix];
    };
    void (^checkAudio)(void) = ^{
        lastState = CFBridgingRelease(copyState((__bridge void *)fixture));
        double now = CMTimeGetSeconds(player.currentTime);
        Check([lastState[@"current_item_preserved"] boolValue] && [lastState[@"current_adopted_from_preloads"] boolValue] && [lastState[@"adopted_wrapper_still_valid"] boolValue] && player.currentItem.status == AVPlayerItemStatusReadyToPlay,
              @"Source transition preserves the exact active AVPlayerItem adopted out of pending preloads");
        Check(isfinite(now) && now + 0.10 >= lastTime && player.rate > 0,
              @"Source transition neither rewinds nor pauses the current local AVPlayer");
        lastTime = now; audioContinuityChecks++;
        Check([[NSData dataWithContentsOfURL:downloadURL] isEqual:manualBytes], @"Manual download bytes remain unchanged");
        Check([[NSData dataWithContentsOfURL:automaticURL] isEqual:automaticBytes], @"Automatic cache policy does not delete existing media");
        Check([[NSData dataWithContentsOfURL:siblingURL] isEqual:manualBytes], @"Similarly prefixed sibling-directory bytes remain unchanged");
    };
    @try {
        Main(^{
            manager = [(id)NSClassFromString(@"FMXManager") shared]; sourceDirectory = manager.directory;
            AVAudioSession *session = AVAudioSession.sharedInstance;
            oldCategory = session.category; oldMode = session.mode; oldOptions = session.categoryOptions;
            if (![session setCategory:AVAudioSessionCategoryPlayback mode:AVAudioSessionModeDefault options:0 error:&audioError]) return;
            if (![session setActive:YES error:&audioError]) return;
            fixture = CFBridgingRelease(createFixture(audioURL.fileSystemRepresentation, downloadURL.fileSystemRepresentation));
            player = CFBridgingRelease(copyPlayer((__bridge void *)fixture));
            configure(fixture, nativeMethod, YES);
            previousWyBypass = bypassAutomatic(@"wy"); previousKgBypass = bypassAutomatic(@"kg");
        });
        Check(!audioError && fixture && player, audioError.localizedDescription ?: @"Create a real Swift receiver and player");
        Check(Until(^BOOL{return player.currentItem.status == AVPlayerItemStatusReadyToPlay;},8), @"Fixture AVPlayer decodes local media");
        Main(^{ [player play]; });
        Check(Until(^BOOL{return player.rate > 0 && CMTimeGetSeconds(player.currentTime) > 0.25;},8), @"Fixture playback clock advances before cache transitions");
        Main(^{checkAudio();});

        NSString *(^sourceScript)(NSString *) = ^NSString *(NSString *label) {
            return [NSString stringWithFormat:@"lx.on('request',({info})=>{if(info.musicInfo.songmid==='cache-pending'){setTimeout(()=>{},60000);return new Promise(r=>setTimeout(()=>r('https://fixture.invalid/late-old-source'),1200));}return Promise.resolve('https://fixture.invalid/%@/'+info.musicInfo.songmid)});setTimeout(()=>lx.send('inited',{sources:{tx:{type:'music',actions:['musicUrl'],qualitys:['128k']}}}),200);",label];
        };
        NSArray<NSString *> *scripts = @[sourceScript(@"cache-a"), sourceScript(@"cache-b"), @"lx.on('request',()=>Promise.resolve('https://fixture.invalid/unused'));setTimeout(()=>lx.send('inited',{sources:{kw:{type:'music',actions:['musicUrl'],qualitys:['128k']}}}),200);"];
        for(NSUInteger index=0;index<fixtureFiles.count;index++)
            Check([scripts[index] writeToURL:[sourceDirectory URLByAppendingPathComponent:fixtureFiles[index]] atomically:YES encoding:NSUTF8StringEncoding error:&fileError], fileError.localizedDescription);

        __block NSString *initializingKey = nil, *activeAKey = nil, *activeBKey = nil;
        __block NSUInteger invalidationsBefore = 0;
        Main(^{
            invalidationsBefore = [((NSDictionary *)CFBridgingRelease(copyState((__bridge void *)fixture)))[@"invalidations"] unsignedIntegerValue];
            [manager activate:@{@"file":fixtureFiles[0], @"name":@"Authored cache A"}];
            initializingKey = currentKey();
            // Exercise the exact single-song policy with a real Swift receiver and
            // actual temporary files in the simulator's original cache directory.
            NSString *nativeServer=@"wy", *song=[NSString stringWithFormat:@"fixture-%@", NSUUID.UUID.UUIDString];
            NSString *base=[NSString stringWithFormat:@"%@_%@",nativeServer,song];
            NSURL *caches=[NSFileManager.defaultManager URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask].firstObject;
            NSURL *nativeFolder=[caches URLByAppendingPathComponent:@"MusicCache" isDirectory:YES];
            Check([NSFileManager.defaultManager createDirectoryAtURL:nativeFolder withIntermediateDirectories:YES attributes:nil error:nil],@"Prepare native automatic cache for a single song");
            NSURL *target=[nativeFolder URLByAppendingPathComponent:[base stringByAppendingPathExtension:@"mp3"]];
            NSURL *foreign=[nativeFolder URLByAppendingPathComponent:[base stringByAppendingString:@"other.mp3"]];
            NSURL *cover=[nativeFolder URLByAppendingPathComponent:[base stringByAppendingString:@"_cover.jpg"]];
            NSString *targetKey=[base stringByAppendingString:@"|320k"], *otherKey=[base stringByAppendingString:@"other|320k"];
            void *(*suffixFor)(NSString *) = (void *)dlsym(self.extensionHandle,"FMPlaybackCacheCopySuffixForString");
            BOOL (*clearTrack)(NSString *,NSString *,NSUInteger *) = (void *)dlsym(self.extensionHandle,"FMPlaybackCacheClearTrack");
            Check(suffixFor && clearTrack,@"Exact native clear API and per-track key bridge loaded");
            NSString *(^suffix)(NSString *)=^NSString *(NSString *name) { return CFBridgingRelease(suffixFor(name)); };
            NSString *prior=suffix(targetKey), *unrelated=suffix(otherKey);
            for (NSURL *file in @[target,foreign,cover]) Check([automaticBytes writeToURL:file atomically:YES],@"Write simulator-owned cache fixtures");
            NSUInteger removed=0;
            Check(clearTrack(nativeServer,song,&removed) && removed==1 && ![NSFileManager.defaultManager fileExistsAtPath:target.path],
                  @"The target native MusicCache MP3 is removed");
            Check(![suffix(targetKey) isEqual:prior] && [suffix(otherKey) isEqual:unrelated] &&
                  [suffix([base stringByAppendingString:@"|128k"]) isEqual:suffix(targetKey)],
                  @"All qualities of one native address/preload key change; another song keeps its exact generation");
            Check(clearTrack(nativeServer,song,&removed) && removed==0 && [NSData dataWithContentsOfURL:foreign] && [NSData dataWithContentsOfURL:cover],
                  @"Repeated clear ignores similar song IDs and preserves artwork");
            // Earlier downloads may be filed under a native song_id even though
            // the primary id in downloaded_tracks.json is the row identifier.
            NSFileManager *files = NSFileManager.defaultManager;
            NSURL *support = [files URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
            NSURL *registry = [support URLByAppendingPathComponent:@"downloaded_tracks.json"];
            BOOL hadRegistry = [files fileExistsAtPath:registry.path];
            NSData *original = hadRegistry ? [NSData dataWithContentsOfURL:registry] : nil;
            NSArray *existingRows = original ? [NSJSONSerialization JSONObjectWithData:original options:0 error:nil] : @[];
            Check((!hadRegistry || original) && [existingRows isKindOfClass:NSArray.class], @"Preserve the simulator download registry");
            Check([files createDirectoryAtURL:support withIntermediateDirectories:YES attributes:nil error:nil], @"Prepare the simulator registry");
            NSMutableDictionary *row = [@{@"server":@"netease", @"id":NSUUID.UUID.UUIDString, @"song_id":song, @"platform":@0} mutableCopy];
            void (^writeRow)(void) = ^{
                NSData *data = [NSJSONSerialization dataWithJSONObject:[existingRows arrayByAddingObject:row] options:0 error:nil];
                Check([data writeToURL:registry atomically:YES], @"Install an authored row with a separate song identity");
            };
            @try {
                writeRow();
                Check([[@"registered" dataUsingEncoding:NSUTF8StringEncoding] writeToURL:target atomically:YES],
                      @"File the historical manual download under its verified song_id");
                Check(clearTrack(nativeServer,song,&removed) && !removed && [files fileExistsAtPath:target.path],
                      @"A platform-confirmed registered song_id protects a manual file under the alias");
                row[@"platform"] = @3;
                writeRow();
                Check(clearTrack(nativeServer,song,&removed) && removed==1 && ![files fileExistsAtPath:target.path],
                      @"A conflicting registration platform does not claim unrelated automatic media");
            } @finally {
                if (hadRegistry) [original writeToURL:registry atomically:YES];
                else [files removeItemAtURL:registry error:nil];
                [files removeItemAtURL:target error:nil];
            }
            void (*deferRetry)(NSString *,NSString *) = dlsym(self.extensionHandle,"FMPlaybackCacheDeferDownloadRetry");
            void (*beginRetry)(void) = dlsym(self.extensionHandle,"FMPlaybackCacheBeginSelection");
            Check(deferRetry && beginRetry, @"Scoped native manual retry is available");
            NSString *beforeRetry = suffix(targetKey);
            deferRetry(nativeServer,song);
            NSString *afterFailure = suffix(targetKey);
            deferRetry(nativeServer,song);
            Check(![beforeRetry isEqual:afterFailure] && [afterFailure isEqual:suffix(targetKey)] && [unrelated isEqual:suffix(otherKey)],
                  @"A failed manual file retires its old native URL only once during that play");
            beginRetry();
            Check(![afterFailure isEqual:suffix(targetKey)] && [unrelated isEqual:suffix(otherKey)],
                  @"A new selection rechecks this song's downloaded file ahead of its previous online fallback");
            [NSFileManager.defaultManager removeItemAtURL:foreign error:nil];
            [NSFileManager.defaultManager removeItemAtURL:cover error:nil];
            seedFixture((__bridge void *)fixture, initializingKey.UTF8String);
            Check(keyHit((__bridge void *)fixture, initializingKey.UTF8String)==3, @"Native caches can refill during asynchronous JS initialization");
        });
        Check(Until(^BOOL{return manager.runtime.manifest && [manager.selectedFile isEqual:fixtureFiles[0]] && [manager.status containsString:@"已启用"];},5), @"Real manager activates source A");
        Main(^{
            activeAKey = currentKey(); lastState = CFBridgingRelease(copyState((__bridge void *)fixture));
            Check([lastState[@"invalidations"] unsignedIntegerValue]>=invalidationsBefore+2 && [lastState[@"prefetched_count"] integerValue]==0 && [lastState[@"preloads_count"] integerValue]==0 && ![lastState[@"prefetched_token_present"] boolValue] && ![lastState[@"preloaded_token_present"] boolValue],
                  @"Old source retirement and new usable source boundary both invalidate native caches");
            Check(![activeAKey isEqual:initializingKey], @"Successful initialization establishes a fresh cache epoch");
            completeOld((__bridge void *)fixture);
            Check(keyHit((__bridge void *)fixture, initializingKey.UTF8String)==3 && keyHit((__bridge void *)fixture, activeAKey.UTF8String)==0,
                  @"Late old completion really repopulates both old caches but the new epoch cannot adopt either");
            Check(bypassAutomatic(@"qq") && bypassAutomatic(@"wy")==previousWyBypass && bypassAutomatic(@"kg")==previousKgBypass && !bypassAutomatic(@"qs"),
                  @"Automatic disk-cache bypass is limited to affected routed platforms");
            Check(bypassURL(automaticURL,automaticDirectory) && !bypassURL(downloadURL,automaticDirectory) && !bypassURL(siblingURL,automaticDirectory),
                  @"Native-directory policy rejects affected automatic media but preserves manual downloads and sibling prefixes");
            // Model the original format-candidate ordering using the real
            // production policy: old cache.mp3 must not hide download.flac.
            NSURL *selectedCandidate=nil;
            for(NSURL *candidate in @[automaticURL,downloadURL])
                if([NSFileManager.defaultManager fileExistsAtPath:candidate.path] && !bypassURL(candidate,automaticDirectory)) {selectedCandidate=candidate;break;}
            Check([selectedCandidate isEqual:downloadURL], @"Rejected automatic mp3 continues to the manual flac candidate instead of hiding it");
            checkAudio();
        });

        // Start an actual pending request through the production interceptor.
        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"https://aacert.com/ms/api.php?action=parse&_t=cache-switch"] cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:8];
        request.HTTPMethod=@"POST"; [request setValue:@"application/x-www-form-urlencoded" forHTTPHeaderField:@"Content-Type"];
        request.HTTPBody=[@"server=qq&id=cache-pending&level=standard&title=Authored&singer=Fixture" dataUsingEncoding:NSUTF8StringEncoding];
        NSURLSessionConfiguration *configuration=NSURLSessionConfiguration.ephemeralSessionConfiguration;
        configuration.protocolClasses=@[SmokeDenyNetwork.class]; configuration.timeoutIntervalForResource=10;
        pendingSession=[NSURLSession sessionWithConfiguration:configuration];
        dispatch_semaphore_t pendingDone=dispatch_semaphore_create(0);
        __block NSData *pendingData=nil; __block NSError *pendingError=nil; __block NSUInteger pendingCallbacks=0;
        [[pendingSession dataTaskWithRequest:request completionHandler:^(NSData *data,NSURLResponse *response,NSError *error){pendingData=data;pendingError=error;pendingCallbacks++;dispatch_semaphore_signal(pendingDone);}] resume];
        __block LXSourceRuntime *runtimeA=nil,*oldWorker=nil;
        __block NSDictionary *oldWorkerBefore=nil,*oldWorkerAfter=nil;
        Check(Until(^BOOL{
            for(LXSourceRuntime *worker in SmokeIsolatedWorkers(manager.runtime)){
                NSDictionary *resources=SmokeRuntimeResources(worker);
                // Only the real pending branch creates both a dedicated long
                // marker timer and the original 1200ms delayed result. The lone
                // initialization timer cannot satisfy this observation.
                if([resources[@"pending"] unsignedIntegerValue]==1 && [resources[@"timers"] unsignedIntegerValue]==2 && ![resources[@"invalidated"] boolValue]){
                    oldWorker=worker;oldWorkerBefore=resources;return YES;
                }
            }
            return NO;
        },3), @"Old source Promise is in flight before switching");
        Main(^{
            runtimeA=manager.runtime;
            Check([SmokeIsolatedWorkers(runtimeA) containsObject:oldWorker],@"Observed delayed Promise belongs to source A's isolated worker");
            [manager activate:@{@"file":fixtureFiles[1], @"name":@"Authored cache B"}];
            seedFixture((__bridge void *)fixture, activeAKey.UTF8String);
        });
        Check(Until(^BOOL{return manager.runtime.manifest && manager.runtime!=runtimeA && [manager.selectedFile isEqual:fixtureFiles[1]] && [manager.status containsString:@"已启用"];},5), @"Real manager switches from A to B");
        Check(dispatch_semaphore_wait(pendingDone,dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC))==0, @"Retired source's pending request completes promptly");
        NSDictionary *pendingJSON=pendingData ? [NSJSONSerialization JSONObjectWithData:pendingData options:0 error:nil] : nil;
        Check(pendingCallbacks==1 && (pendingError || [pendingJSON[@"code"] integerValue]==502) && !pendingJSON[@"data"][@"url"], @"Retired JS runtime cannot publish a successful old playback URL");
        Check(Until(^BOOL{
            oldWorkerAfter=SmokeRuntimeResources(oldWorker);
            return [oldWorkerAfter[@"invalidated"] boolValue] && [oldWorkerAfter[@"timers"] unsignedIntegerValue]==0
                && [oldWorkerAfter[@"http"] unsignedIntegerValue]==0 && [oldWorkerAfter[@"pending"] unsignedIntegerValue]==0
                && [SmokeRuntimeResources(runtimeA)[@"workers"] unsignedIntegerValue]==0;
        },3),@"Source switching drains the old delayed worker and its timers, HTTP tasks and pending callbacks");
        Main(^{
            activeBKey=currentKey();
            Check(![activeBKey isEqual:activeAKey] && !runtimeA.manifest, @"B has a new epoch and A runtime is invalidated");
            completeOld((__bridge void *)fixture);
            Check(keyHit((__bridge void *)fixture,activeAKey.UTF8String)==3 && keyHit((__bridge void *)fixture,activeBKey.UTF8String)==0, @"Old A late cache writes cannot be retrieved through B's key");
            Check(manager.playbackStatus==nil && manager.playbackRequest==nil, @"Old completion cannot overwrite new source playback diagnostics");
            checkAudio();
        });

        __block NSString *failedInitializingKey=nil;
        Main(^{
            [manager activate:@{@"file":fixtureFiles[2], @"name":@"Authored unsupported source"}];
            failedInitializingKey=currentKey(); seedFixture((__bridge void *)fixture,failedInitializingKey.UTF8String);
        });
        Check(Until(^BOOL{return manager.runtime==nil && manager.selectedFile==nil && [manager.status containsString:@"没有本版可用平台"];},5), @"Failed source activation returns to the disabled route");
        Main(^{
            NSString *failedKey=currentKey();
            lastState=CFBridgingRelease(copyState((__bridge void *)fixture));
            Check(![failedKey isEqual:failedInitializingKey] && [lastState[@"prefetched_count"] integerValue]==0 && [lastState[@"preloads_count"] integerValue]==0,
                  @"Failed initialization invalidates results accumulated during its pending interval");
            completeOld((__bridge void *)fixture);
            Check(keyHit((__bridge void *)fixture,failedInitializingKey.UTF8String)==3 && keyHit((__bridge void *)fixture,failedKey.UTF8String)==0, @"Failed activation also isolates late captured keys");
            Check(bypassAutomatic(@"qq"), @"Affected automatic cache remains bypassed after disabling JS");
            seedFixture((__bridge void *)fixture,failedKey.UTF8String);
            [manager disable];
            Check(![currentKey() isEqual:failedKey], @"Explicit disable advances the playback cache namespace");
            lastState=CFBridgingRelease(copyState((__bridge void *)fixture));
            Check([lastState[@"prefetched_count"] integerValue]==0 && [lastState[@"preloads_count"] integerValue]==0 && [lastState[@"retired_preloads_clean"] boolValue] && [lastState[@"invalidations_on_main"] boolValue],
                  @"Swift self bridge clears pending preload players and always executes on main");
            checkAudio();
        });

        // The same production guard must fail closed for an unmatched image.
        Main(^{
            seedFixture((__bridge void *)fixture,"guarded-native-key");
            NSUInteger before=[((NSDictionary *)CFBridgingRelease(copyState((__bridge void *)fixture)))[@"invalidations"] unsignedIntegerValue];
            configure(fixture,nativeMethod,NO);
            [manager disable];
            NSString *suffix=CFBridgingRelease(copySuffix());
            lastState=CFBridgingRelease(copyState((__bridge void *)fixture));
            Check(suffix==nil && !bypassAutomatic(@"qq") && !bypassURL(automaticURL,automaticDirectory) && [lastState[@"invalidations"] unsignedIntegerValue]==before && keyHit((__bridge void *)fixture,"guarded-native-key")==3,
                  @"Unmatched version/image neither calls the Swift entry point nor changes native cache selection");
            checkAudio();
        });
        // Let the old JS timer's nominal deadline pass, then check there is no
        // duplicate native completion (the retired runtime cancelled its timer).
        [NSThread sleepForTimeInterval:1.3];
        Check(pendingCallbacks==1, @"Retired delayed Promise never delivers a second native completion");
        Check([SmokeRuntimeResources(oldWorker)[@"timers"] unsignedIntegerValue]==0 && [SmokeRuntimeResources(oldWorker)[@"pending"] unsignedIntegerValue]==0,@"Old worker remains drained after its original delayed callback deadline");
        Main(^{checkAudio();});
        return @{@"source_transitions":@[@"activate",@"switch",@"failed_activate",@"disable"],
                 @"real_swift_instance_abi":@YES,@"late_old_cache_writes_exercised":@YES,@"new_epoch_rejects_old_keys":@YES,
                 @"real_avplayer_continuity_checks":@(audioContinuityChecks),@"manual_download_bytes_unchanged":@YES,@"automatic_cache_not_deleted":@YES,
                 @"current_player_adopted_out_of_pending_preloads":@YES,
                 @"automatic_mp3_does_not_mask_manual_flac_model":@YES,@"sibling_directory_prefix_preserved":@YES,
                 @"wrong_image_guard_preserves_native_state":@YES,@"retired_request_callback_count":@(pendingCallbacks),
                 @"old_worker_resources_before":oldWorkerBefore,@"old_worker_resources_after":oldWorkerAfter,@"production_update_alert_forwarding_added":@NO,
                 @"external_network_used":@NO,@"original_native_method_executed":@NO};
    } @finally {
        [pendingSession invalidateAndCancel];
        Main(^{
            configure(nil,NULL,NO); [manager disable]; [player pause]; player=nil; fixture=nil;
            if(oldCategory)[AVAudioSession.sharedInstance setCategory:oldCategory mode:oldMode options:oldOptions error:nil];
        });
        for(NSString *filename in fixtureFiles)if(sourceDirectory)[NSFileManager.defaultManager removeItemAtURL:[sourceDirectory URLByAppendingPathComponent:filename] error:nil];
        [NSFileManager.defaultManager removeItemAtURL:temporary error:nil];
    }
}];
}
