// Production sequence/adaptive code, genuine Swift self ABI and real AVPlayer.
// The queue/cache fixture models the inspected host contract; it is not the IPA.
{
NSDictionary *(^beginSequenceAudio)(void)=^NSDictionary *{
    AVAudioSession *audio=AVAudioSession.sharedInstance;
    NSDictionary *saved=@{@"category":audio.category,@"mode":audio.mode,@"options":@(audio.categoryOptions)};
    NSError *error=nil;Check([audio setCategory:AVAudioSessionCategoryPlayback error:&error],error.localizedDescription);
    Check([audio setActive:YES error:&error],error.localizedDescription);return saved;
};
void (^endSequenceAudio)(NSDictionary *)=^(NSDictionary *saved){
    AVAudioSession *audio=AVAudioSession.sharedInstance;[audio setActive:NO error:nil];
    if(saved)[audio setCategory:saved[@"category"] mode:saved[@"mode"] options:[saved[@"options"] unsignedIntegerValue] error:nil];
};
[self test:@"v8_latest_selection_retires_old_audio_before_new_setup" body:^NSDictionary *{
    void *(*create)(void)=dlsym(self.swiftUIFixtureHandle,"FMAdaptiveFixtureCreate");
    void *(*state)(void *)=dlsym(self.swiftUIFixtureHandle,"FMAdaptiveFixtureCopyState");
    void *(*copyPlayer)(void *)=dlsym(self.swiftUIFixtureHandle,"FMAdaptiveFixtureCopyPlayer");
    void (*start)(void *,void *)=dlsym(self.swiftUIFixtureHandle,"FMAdaptiveFixtureStart");
    void (*stop)(void *)=dlsym(self.swiftUIFixtureHandle,"FMAdaptiveFixtureStop");
    void (*configure)(void *,void *)=dlsym(self.extensionHandle,"FMAdaptivePlaybackTestConfigureNative");
    void (*configureSequence)(void *)=dlsym(self.extensionHandle,"FMPlaybackSequenceTestConfigure");
    void (*select)(id)=dlsym(self.extensionHandle,"FMPlaybackSequenceNativeSelection");
    void (*tick)(id,AVPlayer *,double,double)=dlsym(self.extensionHandle,"FMPlaybackSequenceTestTick");
    BOOL (*failure)(id,AVPlayer *)=dlsym(self.extensionHandle,"FMAdaptiveNativeHandleFailure");
    void (*registerURL)(NSURL *,id,NSString *,NSString *)=dlsym(self.extensionHandle,"FMAdaptivePlaybackRegisterURL");
    void (*transition)(void)=dlsym(self.extensionHandle,"FMAdaptivePlaybackSourceTransition");
    void *setup=dlsym(self.swiftUIFixtureHandle,"FMAdaptiveFixtureSetupNative");
    void *nativeFailure=dlsym(self.swiftUIFixtureHandle,"FMAdaptiveFixtureFailureNative");
    void *reconcile=dlsym(self.swiftUIFixtureHandle,"FMPlaybackSequenceFixtureReconcileNative");
    Class resolverClass=NSClassFromString(@"FMQualityResolver");
    Check(create&&state&&copyPlayer&&start&&stop&&configure&&configureSequence&&select&&tick&&failure&&registerURL&&transition&&setup&&nativeFailure&&reconcile&&resolverClass,@"Sequence and genuine native fixture exports loaded");
    __block id fixture=nil;__block FMQualityResolver *resolver=nil;__block FMQualityAttemptCompletion delayed=nil;
    __block NSURL *good=nil;__block AVPlayer *oldPlayer=nil;__block NSUInteger resolverCancels=0;
    __block NSDictionary *oldAudio=nil;
    @try {
        Main(^{
            oldAudio=beginSequenceAudio();
            configure(setup,nativeFailure);configureSequence(reconcile);fixture=CFBridgingRelease(create());
            NSDictionary *initial=CFBridgingRelease(state((__bridge void *)fixture));
            NSURL *bad=[NSURL URLWithString:initial[@"bad"]];good=[NSURL URLWithString:initial[@"good"]];select(fixture);
            resolver=[[resolverClass alloc] initWithPlatform:@"wy" supportedQualities:@[@"flac",@"128k"] timeout:20 isCurrent:^BOOL{return YES;} resolve:^dispatch_block_t(NSString *quality,NSTimeInterval budget,FMQualityAttemptCompletion complete){
                if([quality isEqual:@"flac"])complete(bad,nil);else delayed=[complete copy];
                return ^{resolverCancels++;};
            }];
            [resolver nextWithCompletion:^(NSURL *url,NSString *quality,NSError *error){
                Check(url&&!error,@"A initial JS candidate returns");registerURL(url,resolver,quality,@"wy:A");start((__bridge void *)fixture,(__bridge void *)url);
            }];
        });
        Check(Until(^BOOL{return delayed!=nil;},12),@"Actual A media failure starts a held lower-quality request");
        Main(^{
            oldPlayer=CFBridgingRelease(copyPlayer((__bridge void *)fixture));
            select(fixture);select(fixture); // B then C commit; neither URL has installed a player yet.
            Check(failure(fixture,oldPlayer),@"Pending newest selection suppresses an old player's late failure/skip");
            tick(fixture,oldPlayer,100,105);
            FMQualityAttemptCompletion late=delayed;delayed=nil;late(good,nil);
        });
        __block NSUInteger stable=0;
        Check(Until(^BOOL{
            NSDictionary *current=CFBridgingRelease(state((__bridge void *)fixture));
            Check([current[@"setups"] integerValue]==1,@"A delayed retry cannot rebuild audio while C is still resolving");
            Check([current[@"sequence_reconciliations"] integerValue]==0,@"A's stale time event cannot preload for pending C");
            Check([current[@"native_failures"] integerValue]==0,@"Old media failure cannot skip pending newest selection");return ++stable>=5;
        },3),@"Queued old completion remains rejected");
        Main(^{Check(resolverCancels>0,@"Old isolated resolver cancellation invoked immediately at selection intent");start((__bridge void *)fixture,(__bridge void *)good);});
        Check(Until(^BOOL{
            NSDictionary *current=CFBridgingRelease(state((__bridge void *)fixture));
            return [current[@"setups"] integerValue]==2&&[current[@"status"] integerValue]==AVPlayerItemStatusReadyToPlay&&[current[@"time"] doubleValue]>0.1;
        },12),@"Newest real media loads and advances after pending selection");
        return @{@"consecutive_pending_selections":@2,@"held_real_failure_rejected":@YES,@"latest_actual_media_plays":@YES,
            @"scope":@"production extension and actual AVPlayer; authored native host",@"original_app_runtime_verified":@NO};
    } @finally {Main(^{[resolver cancel];transition();configureSequence(NULL);configure(NULL,NULL);if(fixture)stop((__bridge void *)fixture);endSequenceAudio(oldAudio);});}
}];

[self test:@"v8_near_end_retries_failed_preload_and_preserves_shuffle_candidate" body:^NSDictionary *{
    void *(*create)(void)=dlsym(self.swiftUIFixtureHandle,"FMAdaptiveFixtureCreate");
    void *(*state)(void *)=dlsym(self.swiftUIFixtureHandle,"FMAdaptiveFixtureCopyState");
    void *(*copyPlayer)(void *)=dlsym(self.swiftUIFixtureHandle,"FMAdaptiveFixtureCopyPlayer");
    void (*startPaused)(void *,void *)=dlsym(self.swiftUIFixtureHandle,"FMAdaptiveFixtureStartPaused");
    void (*stop)(void *)=dlsym(self.swiftUIFixtureHandle,"FMAdaptiveFixtureStop");
    void (*configure)(void *,void *)=dlsym(self.extensionHandle,"FMAdaptivePlaybackTestConfigureNative");
    void (*configureSequence)(void *)=dlsym(self.extensionHandle,"FMPlaybackSequenceTestConfigure");
    void (*select)(id)=dlsym(self.extensionHandle,"FMPlaybackSequenceNativeSelection");
    void (*tick)(id,AVPlayer *,double,double)=dlsym(self.extensionHandle,"FMPlaybackSequenceTestTick");
    void (*sourceChanged)(void)=dlsym(self.extensionHandle,"FMPlaybackSequenceSourceTransition");
    void (*fixtureConfigure)(void *,BOOL,BOOL)=dlsym(self.swiftUIFixtureHandle,"FMPlaybackSequenceFixtureConfigure");
    void (*prime)(void *)=dlsym(self.swiftUIFixtureHandle,"FMPlaybackSequenceFixturePrime");
    void (*next)(void *)=dlsym(self.swiftUIFixtureHandle,"FMPlaybackSequenceFixtureNext");
    void *setup=dlsym(self.swiftUIFixtureHandle,"FMAdaptiveFixtureSetupNative");
    void *nativeFailure=dlsym(self.swiftUIFixtureHandle,"FMAdaptiveFixtureFailureNative");
    void *reconcile=dlsym(self.swiftUIFixtureHandle,"FMPlaybackSequenceFixtureReconcileNative");
    Check(create&&state&&copyPlayer&&startPaused&&stop&&configure&&configureSequence&&select&&tick&&sourceChanged&&fixtureConfigure&&prime&&next&&setup&&nativeFailure&&reconcile,@"Near-end production exports and genuine Swift method loaded");
    NSMutableArray *modes=NSMutableArray.array;
    for(NSUInteger mode=0;mode<2;mode++) {
        __block id fixture=nil;__block AVPlayer *player=nil;
        __block NSDictionary *oldAudio=nil;
        NSString *candidate=mode==0?@"B":@"C";
        @try {
            Main(^{
                oldAudio=beginSequenceAudio();
                configure(setup,nativeFailure);configureSequence(reconcile);fixture=CFBridgingRelease(create());
                fixtureConfigure((__bridge void *)fixture,mode==1,YES);select(fixture);
                NSDictionary *initial=CFBridgingRelease(state((__bridge void *)fixture));NSURL *good=[NSURL URLWithString:initial[@"good"]];
                startPaused((__bridge void *)fixture,(__bridge void *)good);player=CFBridgingRelease(copyPlayer((__bridge void *)fixture));
                prime((__bridge void *)fixture);
            });
            Check(Until(^BOOL{
                NSDictionary *current=CFBridgingRelease(state((__bridge void *)fixture));
                return [current[@"sequence_media_failures"] integerValue]==1&&player.currentItem.status==AVPlayerItemStatusReadyToPlay;
            },12),@"Early preload really fails and removes its cache entry while current media remains usable");
            Main(^{
                tick(fixture,player,90,100); // Paused, must not consume the compensation.
                NSDictionary *paused=CFBridgingRelease(state((__bridge void *)fixture));
                Check([paused[@"sequence_requests"] count]==1,@"Paused playback does not request another preload");
                [player play];tick(fixture,player,80,100);
                NSDictionary *early=CFBridgingRelease(state((__bridge void *)fixture));
                Check([early[@"sequence_requests"] count]==1,@"Outside ten-second window no extra request is made");
                tick(fixture,player,90,100);tick(fixture,player,91,100);tick(fixture,player,92,100);
                NSDictionary *retry=CFBridgingRelease(state((__bridge void *)fixture));
                Check([retry[@"sequence_requests"] isEqual:@[candidate,candidate]],@"One missing-entry retry uses the same ordered/shuffled queue candidate");
                [player pause];
            });
            Check(Until(^BOOL{NSDictionary *current=CFBridgingRelease(state((__bridge void *)fixture));return [current[@"sequence_ready"] containsObject:candidate];},12),@"Retry actually creates and decodes a real playable next AVPlayer");
            Main(^{
                sourceChanged();[player play];tick(fixture,player,94,100);[player pause];
                NSDictionary *cached=CFBridgingRelease(state((__bridge void *)fixture));
                Check([cached[@"sequence_requests"] count]==2,@"Reconciliation preserves a successful matching cache entry without a new request");
                next((__bridge void *)fixture);
            });
            Check(Until(^BOOL{
                NSDictionary *current=CFBridgingRelease(state((__bridge void *)fixture));
                return [current[@"sequence_actual"] isEqual:candidate]&&[current[@"sequence_adoptions"] integerValue]==1&&
                    [current[@"status"] integerValue]==AVPlayerItemStatusReadyToPlay&&[current[@"time"] doubleValue]>0.1;
            },8),@"Actual next adopts the exact preloaded media, including the stable shuffle permutation");
            Main(^{tick(fixture,player,99,100);NSDictionary *done=CFBridgingRelease(state((__bridge void *)fixture));
                Check([done[@"sequence_requests"] count]==2,@"Old player time after next cannot request a different song");
                [modes addObject:@{@"mode":mode==0?@"ordered":@"shuffle",@"attempts":done[@"sequence_requests"],@"actual":done[@"sequence_actual"],@"adopted":done[@"sequence_adoptions"]}];
            });
        } @finally {Main(^{configureSequence(NULL);configure(NULL,NULL);if(fixture)stop((__bridge void *)fixture);endSequenceAudio(oldAudio);});}
    }
    return @{@"modes":modes,@"thresholdSeconds":@10,@"real_media_failure_and_ready":@YES,
        @"native_contract":@"inspected original queue/cache; authored host fixture",@"original_app_runtime_verified":@NO};
}];

[self test:@"v8_selection_commit_rejects_old_quality_probe_before_item_replacement" body:^NSDictionary *{
    void (*observe)(id,AVPlayer *,NSString *)=dlsym(self.extensionHandle,"FMPlaybackQualityDisplayObserve");
    void (*qualityConfigure)(id,void *,BOOL)=dlsym(self.extensionHandle,"FMPlaybackQualityTestConfigureReceiver");
    void (*hold)(BOOL)=dlsym(self.extensionHandle,"FMPlaybackQualityTestHoldCompletedProbes");
    NSUInteger (*pending)(void)=dlsym(self.extensionHandle,"FMPlaybackQualityTestPendingProbes");
    void (*releaseOldest)(void)=dlsym(self.extensionHandle,"FMPlaybackQualityTestReleaseOldestProbe");
    void *(*createManager)(void)=dlsym(self.swiftUIFixtureHandle,"FMPlaybackQualityFixtureCreate");
    void *(*copyQuality)(const void *)=dlsym(self.swiftUIFixtureHandle,"FMPlaybackQualityFixtureCopyState");
    void *setter=dlsym(self.swiftUIFixtureHandle,"FMPlaybackQualityFixtureSetIndirect");
    void *reconcile=dlsym(self.swiftUIFixtureHandle,"FMPlaybackQualityFixtureReconcileNative");
    void *(*createAudio)(void)=dlsym(self.swiftUIFixtureHandle,"FMAdaptiveFixtureCreate");
    void *(*audioState)(void *)=dlsym(self.swiftUIFixtureHandle,"FMAdaptiveFixtureCopyState");
    void (*stopAudio)(void *)=dlsym(self.swiftUIFixtureHandle,"FMAdaptiveFixtureStop");
    void (*sequenceConfigure)(void *)=dlsym(self.extensionHandle,"FMPlaybackSequenceTestConfigure");
    void (*sequenceSetup)(id,AVPlayer *)=dlsym(self.extensionHandle,"FMPlaybackSequenceDidSetup");
    void (*select)(id)=dlsym(self.extensionHandle,"FMPlaybackSequenceNativeSelection");
    Check(observe&&qualityConfigure&&hold&&pending&&releaseOldest&&createManager&&copyQuality&&setter&&reconcile&&createAudio&&audioState&&stopAudio&&sequenceConfigure&&sequenceSetup&&select,@"Pending-selection quality fixture exports loaded");
    __block id manager=nil,audio=nil;__block AVPlayer *player=nil;__block AVPlayerItem *oldItem=nil;__block NSUInteger writes=0;
    @try {
        Main(^{
            sequenceConfigure(reconcile);manager=CFBridgingRelease(createManager());audio=CFBridgingRelease(createAudio());
            NSDictionary *media=CFBridgingRelease(audioState((__bridge void *)audio));
            player=[AVPlayer playerWithURL:[NSURL URLWithString:media[@"good"]]];oldItem=player.currentItem;
            qualityConfigure(manager,setter,YES);hold(YES);observe(manager,player,@"flac");sequenceSetup(manager,player);
        });
        Check(Until(^BOOL{return pending()>0;},12),@"Actual decoded asset probe is held before applying its display result");
        Main(^{
            NSDictionary *before=CFBridgingRelease(copyQuality((__bridge void *)manager));writes=[before[@"changes"] unsignedIntegerValue];
            select(manager);
            Check(player.currentItem==oldItem,@"Selection committed while old player/item still exists");
            while(pending())releaseOldest();
            NSDictionary *after=CFBridgingRelease(copyQuality((__bridge void *)manager));
            Check([after[@"changes"] unsignedIntegerValue]==writes,@"Old actual-media probe cannot update newest selection's badge before new setup");
        });
        return @{@"delayed_real_AVAsset_probe":@YES,@"new_item_not_yet_installed":@YES,@"old_result_discarded":@YES,@"original_app_runtime_verified":@NO};
    } @finally {Main(^{hold(NO);while(pending())releaseOldest();qualityConfigure(nil,NULL,NO);sequenceConfigure(NULL);[player pause];[player replaceCurrentItemWithPlayerItem:nil];if(audio)stopAudio((__bridge void *)audio);});}
}];
}
