// Include inside Host's natural test run. Helper media/server/Swift methods live
// in AdaptivePlaybackFixture.swift. All media is authored and loopback-only.
{
[self test:@"v6_actual_media_failure_retries_quality_and_preserves_user_intent" body:^NSDictionary *{
    void *(*create)(void)=dlsym(self.swiftUIFixtureHandle,"FMAdaptiveFixtureCreate");
    void *(*copyState)(void *)=dlsym(self.swiftUIFixtureHandle,"FMAdaptiveFixtureCopyState");
    void *(*copyPlayer)(void *)=dlsym(self.swiftUIFixtureHandle,"FMAdaptiveFixtureCopyPlayer");
    void (*start)(void *,void *)=dlsym(self.swiftUIFixtureHandle,"FMAdaptiveFixtureStart");
    void (*startPaused)(void *,void *)=dlsym(self.swiftUIFixtureHandle,"FMAdaptiveFixtureStartPaused");
    void (*stop)(void *)=dlsym(self.swiftUIFixtureHandle,"FMAdaptiveFixtureStop");
    void *setup=dlsym(self.swiftUIFixtureHandle,"FMAdaptiveFixtureSetupNative");
    void *failure=dlsym(self.swiftUIFixtureHandle,"FMAdaptiveFixtureFailureNative");
    void (*configure)(void *,void *)=dlsym(self.extensionHandle,"FMAdaptivePlaybackTestConfigureNative");
    void (*registerURL)(NSURL *,id,NSString *,NSString *)=dlsym(self.extensionHandle,"FMAdaptivePlaybackRegisterURL");
    void (*transition)(void)=dlsym(self.extensionHandle,"FMAdaptivePlaybackSourceTransition");
    NSDictionary *(*diagnostics)(void)=dlsym(self.extensionHandle,"FMAdaptivePlaybackDiagnostics");
    Class resolverClass=NSClassFromString(@"FMQualityResolver");
    Check(create&&copyState&&copyPlayer&&start&&startPaused&&stop&&setup&&failure&&configure&&registerURL&&transition&&diagnostics&&resolverClass,
          @"Adaptive exports, genuine Swift method entries and production resolver are loaded");
    __block NSUInteger realFailures=0,successes=0,cancelChecks=0,pausedChecks=0;
    __block NSString *oldCategory,*oldMode;
    __block AVAudioSessionCategoryOptions oldOptions;
    Main(^{
        AVAudioSession *audio=AVAudioSession.sharedInstance;oldCategory=audio.category;oldMode=audio.mode;oldOptions=audio.categoryOptions;
        NSError *error=nil;Check([audio setCategory:AVAudioSessionCategoryPlayback error:&error],error.localizedDescription);
        Check([audio setActive:YES error:&error],error.localizedDescription);configure(setup,failure);
    });
    @try {
        // Normal retry, initially paused failure, and user pause while the lower
        // URL is still resolving each use a fresh genuine corrupt media load.
        for(NSUInteger mode=0;mode<3;mode++){
            __block id fixture=nil;
            __block FMQualityResolver *session=nil;
            __block FMQualityAttemptCompletion lower=nil;
            __block NSURL *bad=nil,*good=nil;
            __block AVPlayer *player=nil;
            __block NSMutableArray *attempts=NSMutableArray.array;
            __block BOOL current=YES;
            @try {
                Main(^{
                    fixture=CFBridgingRelease(create());NSDictionary *state=CFBridgingRelease(copyState((__bridge void *)fixture));
                    bad=[NSURL URLWithString:state[@"bad"]];good=[NSURL URLWithString:state[@"good"]];
                    session=[[resolverClass alloc] initWithPlatform:@"wy" supportedQualities:@[@"128k",@"flac"] timeout:20 isCurrent:^BOOL{return current;} resolve:^dispatch_block_t(NSString *quality,NSTimeInterval budget,FMQualityAttemptCompletion completion){
                        [attempts addObject:quality];
                        if([quality isEqual:@"flac"])completion(bad,nil);else lower=[completion copy];
                        return ^{};
                    }];
                    [session nextWithCompletion:^(NSURL *url,NSString *quality,NSError *error){
                        Check(url&&!error,@"Initial high-quality candidate resolves");
                        registerURL(url,session,quality,@"wy:authored-adaptive");
                        if(mode==1)startPaused((__bridge void *)fixture,(__bridge void *)url);
                        else start((__bridge void *)fixture,(__bridge void *)url);
                    }];
                });
                Check(Until(^BOOL{return lower!=nil;},12),@"Real AVPlayerItem failure invokes the next quality, without a synthetic notification");
                Main(^{
                    NSDictionary *state=CFBridgingRelease(copyState((__bridge void *)fixture));
                    Check([state[@"actual_failures"] unsignedIntegerValue]>0 && [state[@"native_failures"] unsignedIntegerValue]==0,
                          @"Owned corrupt media reaches host failure callback before native skip");
                    Check([attempts isEqual:@[@"flac",@"128k"]],@"One highest attempt followed by one lower attempt");
                    player=CFBridgingRelease(copyPlayer((__bridge void *)fixture));
                    if(mode==2)[player pause];
                    FMQualityAttemptCompletion callback=lower;lower=nil;callback(good,nil);
                });
                Check(Until(^BOOL{
                    NSDictionary *state=CFBridgingRelease(copyState((__bridge void *)fixture));
                    return [state[@"setups"] integerValue]==2 && [state[@"status"] integerValue]==AVPlayerItemStatusReadyToPlay;
                },12),@"Returned lower URL is really decoded by a newly rebound host player");
                Main(^{
                    NSDictionary *state=CFBridgingRelease(copyState((__bridge void *)fixture));
                    Check([state[@"url"] isEqual:good.absoluteString],@"Swift URL bridge preserves exact escaped URL and genuine receiver");
                    Check([state[@"native_failures"] integerValue]==0,@"Native failure/skip is suppressed only while recovery succeeds");
                    player=CFBridgingRelease(copyPlayer((__bridge void *)fixture));
                    if(mode>0){Check(player.rate==0,@"Initial pause and pause during resolution survive replacement");pausedChecks++;[player play];}
                    realFailures+=[state[@"actual_failures"] unsignedIntegerValue];
                });
                Check(Until(^BOOL{return player.currentItem.status==AVPlayerItemStatusReadyToPlay && player.rate>0 && CMTimeGetSeconds(player.currentTime)>0.25;},6),
                      @"Actual lower-quality media time advances");
                Main(^{
                    AVPlayerItem *same=player.currentItem;transition();
                    Check(player.currentItem==same && player.rate>0,@"Source transition cancels retry ownership without stopping healthy media");
                    current=NO;successes++;
                });
            } @finally {Main(^{current=NO;[session cancel];transition();if(fixture)stop((__bridge void *)fixture);fixture=nil;});}
        }
        // Let real bad media fail, hold its lower resolution, then change source
        // or select a different native item before the held URL completes.
        for(NSUInteger mode=0;mode<2;mode++){
            __block id fixture=nil;__block FMQualityResolver *session=nil;__block FMQualityAttemptCompletion lower=nil;
            __block NSURL *bad,*good;__block BOOL current=YES;__block AVPlayerItem *selectedItem=nil;__block NSUInteger setupsBefore=0;
            @try {
                Main(^{
                    fixture=CFBridgingRelease(create());NSDictionary *state=CFBridgingRelease(copyState((__bridge void *)fixture));
                    bad=[NSURL URLWithString:state[@"bad"]];good=[NSURL URLWithString:state[@"good"]];
                    session=[[resolverClass alloc] initWithPlatform:@"wy" supportedQualities:@[@"flac",@"128k"] timeout:20 isCurrent:^BOOL{return current;} resolve:^dispatch_block_t(NSString *quality,NSTimeInterval budget,FMQualityAttemptCompletion completion){
                        if([quality isEqual:@"flac"])completion(bad,nil);else lower=[completion copy];return ^{};
                    }];
                    [session nextWithCompletion:^(NSURL *url,NSString *quality,NSError *error){registerURL(url,session,quality,@"wy:cancel-fixture");start((__bridge void *)fixture,(__bridge void *)url);}];
                });
                Check(Until(^BOOL{return lower!=nil;},12),@"Actual bad-media failure occurs before cancellation race");
                Main(^{
                    if(mode==0){current=NO;transition();}
                    else start((__bridge void *)fixture,(__bridge void *)good);
                    AVPlayer *player=CFBridgingRelease(copyPlayer((__bridge void *)fixture));selectedItem=player.currentItem;
                    NSDictionary *state=CFBridgingRelease(copyState((__bridge void *)fixture));setupsBefore=[state[@"setups"] unsignedIntegerValue];
                    FMQualityAttemptCompletion callback=lower;lower=nil;callback(good,nil);
                });
                __block NSUInteger stable=0;
                Check(Until(^BOOL{
                    NSDictionary *state=CFBridgingRelease(copyState((__bridge void *)fixture));
                    AVPlayer *player=CFBridgingRelease(copyPlayer((__bridge void *)fixture));
                    Check(player.currentItem==selectedItem && [state[@"setups"] unsignedIntegerValue]==setupsBefore,
                          @"Late lower-quality URL cannot replace a changed source/track");
                    return ++stable>=8;
                },3),@"Cancellation remains stable after queued completion");
                cancelChecks++;
            } @finally {Main(^{current=NO;[session cancel];transition();if(fixture)stop((__bridge void *)fixture);fixture=nil;});}
        }
        // A duplicate URL cannot loop. Exhaustion resumes the original native
        // failure method; an unrelated native item is never intercepted.
        for(NSUInteger mode=0;mode<2;mode++){
            __block id fixture=nil;__block FMQualityResolver *session=nil;__block NSUInteger attempts=0;
            @try {
                Main(^{
                    fixture=CFBridgingRelease(create());NSDictionary *state=CFBridgingRelease(copyState((__bridge void *)fixture));NSURL *bad=[NSURL URLWithString:state[@"bad"]];
                    if(mode==1){start((__bridge void *)fixture,(__bridge void *)bad);return;}
                    session=[[resolverClass alloc] initWithPlatform:@"wy" supportedQualities:@[@"flac",@"128k"] timeout:20 isCurrent:^BOOL{return YES;} resolve:^dispatch_block_t(NSString *quality,NSTimeInterval budget,FMQualityAttemptCompletion completion){attempts++;completion(bad,nil);return ^{};}];
                    [session nextWithCompletion:^(NSURL *url,NSString *quality,NSError *error){registerURL(url,session,quality,@"wy:duplicate");start((__bridge void *)fixture,(__bridge void *)url);}];
                });
                Check(Until(^BOOL{NSDictionary *s=CFBridgingRelease(copyState((__bridge void *)fixture));return [s[@"native_failures"] integerValue]>0;},12),
                      @"Exhausted or unrelated media retains native failure handling");
                Main(^{NSDictionary *s=CFBridgingRelease(copyState((__bridge void *)fixture));
                    Check([s[@"setups"] integerValue]==1,@"No repeated identical URL or unrelated-media replacement");
                    if(mode==0)Check(attempts==2,@"Each supported quality consumed once; duplicate URL never replayed");
                });
            } @finally {Main(^{[session cancel];transition();if(fixture)stop((__bridge void *)fixture);fixture=nil;});}
        }
        __block NSDictionary *numbers;
        Main(^{numbers=diagnostics();});
        return @{@"actual_corrupt_media_failures":@(realFailures),@"real_lower_media_playback_successes":@(successes),
            @"paused_state_cases":@(pausedChecks),@"source_or_track_cancellation_cases":@(cancelChecks),
            @"production":numbers ?: @{},@"synthetic_failure_notifications":@NO,@"external_network_used":@NO,
            @"swift_url_and_self_abi_verified":@YES,@"original_app_runtime_verified":@NO,
            @"midstream_seek_recovery_tested":@NO};
    } @finally {Main(^{
        transition();configure(NULL,NULL);
        AVAudioSession *audio=AVAudioSession.sharedInstance;
        [audio setActive:NO error:nil];
        if(oldCategory)[audio setCategory:oldCategory mode:oldMode ?: AVAudioSessionModeDefault options:oldOptions error:nil];
    });}
}];
}

