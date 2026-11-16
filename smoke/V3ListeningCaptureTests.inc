// Include inside SmokeRunner's natural run branch, after dlopen(extension).
// Host.m imports FMListeningHistory.h. The extension, not Host, is built with
// FMX_LISTENING_CAPTURE_TESTING=1 (which production forbids on device targets).
// No manufactured elapsed/rate values are passed to either history engine.
{
[self test:@"v3_real_avplayer_capture_progress_pause_seek_and_activity_metadata" body:^NSDictionary *{
    typedef void (^CaptureSample)(NSDictionary *, double, double, NSDate *, double);
    void (*allowPlayer)(AVPlayer *) = (void (*)(AVPlayer *))dlsym(self.extensionHandle, "FMListeningCaptureTestAllowPlayer");
    void (*allowActivity)(BOOL) = (void (*)(BOOL))dlsym(self.extensionHandle, "FMListeningCaptureTestAllowActivity");
    void (*setSampleObserver)(CaptureSample) = (void (*)(CaptureSample))dlsym(self.extensionHandle, "FMListeningCaptureTestSetSampleObserver");
    NSDictionary *(*diagnostics)(void) = (NSDictionary *(*)(void))dlsym(self.extensionHandle, "FMListeningCaptureDiagnostics");
    Check(allowPlayer && allowActivity && setSampleObserver && diagnostics,
          @"Actual AVPlayer capture test exports are present; no replacement production handler");
    Check([diagnostics()[@"installed"] boolValue], @"Capture installs before fixture player registration");

    NSURL *temporary = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:[@"FMX-listening-" stringByAppendingString:NSUUID.UUID.UUIDString]] isDirectory:YES];
    NSError *fileError = nil;
    Check([NSFileManager.defaultManager createDirectoryAtURL:temporary withIntermediateDirectories:YES attributes:nil error:&fileError], fileError.localizedDescription ?: @"Create isolated media fixture directory");
    NSURL *audioURL = [temporary URLByAppendingPathComponent:@"authored-tone.wav"];
    // 24 seconds of authored mono, 16-bit PCM. Muting AVPlayer avoids audible
    // test sound while its real decoder, clock and periodic callbacks still run.
    const uint32_t sampleRate = 22050, sampleCount = 24 * sampleRate, audioBytes = sampleCount * 2;
    NSMutableData *wave = [NSMutableData data];
    void (^u16)(uint16_t) = ^(uint16_t value) { uint8_t bytes[2] = {(uint8_t)value, (uint8_t)(value >> 8)}; [wave appendBytes:bytes length:2]; };
    void (^u32)(uint32_t) = ^(uint32_t value) { uint8_t bytes[4] = {(uint8_t)value, (uint8_t)(value >> 8), (uint8_t)(value >> 16), (uint8_t)(value >> 24)}; [wave appendBytes:bytes length:4]; };
    [wave appendBytes:"RIFF" length:4]; u32(36 + audioBytes); [wave appendBytes:"WAVEfmt " length:8];
    u32(16); u16(1); u16(1); u32(sampleRate); u32(sampleRate * 2); u16(2); u16(16);
    [wave appendBytes:"data" length:4]; u32(audioBytes);
    for (uint32_t index = 0; index < sampleCount; index++) u16((uint16_t)(int16_t)(900.0 * sin(2.0 * M_PI * 440.0 * index / sampleRate)));
    Check([wave writeToURL:audioURL options:NSDataWritingAtomic error:&fileError], fileError.localizedDescription ?: @"Write playable local PCM fixture");

    __block AVPlayer *player = nil;
    __block id timeObserver = nil;
    __block NSUserActivity *activity = nil;
    __block FMListeningHistory *history = nil;
    __block NSDictionary *oldInfo = nil;
    __block id oldLyricsSetting = nil;
    __block NSString *oldCategory = nil, *oldMode = nil;
    __block AVAudioSessionCategoryOptions oldOptions = 0;
    __block NSError *audioError = nil;
    __block NSMutableArray<NSDictionary *> *samples = NSMutableArray.array;
    __block NSUInteger originalCalls = 0, previousOriginalCalls = 0;
    __block BOOL originalRunsFirst = YES, samplesMatchPlayer = YES;
    __block double normalSeconds = 0, pausedSeconds = 0, seekSeconds = 0, finalSeconds = 0;
    __block double pauseStart = 0, pauseEnd = 0, resumedElapsed = 0;
    __block NSUInteger beforeLyrics = 0, beforeNoLyrics = 0, beforeWrongID = 0;
    __block NSUInteger sampleCountAfterRemoval = 0;
    __block NSDictionary *captureReport = nil;
    NSString *trackID = @"wy_smoke_capture_track";
    NSString *realTitle = @"Fixture - Song", *realArtist = @"Artist - Name";
    NSString *artistWithoutLyrics = @"Fixture - Song - Ensemble";
    @try {
        Main(^{
            oldInfo = MPNowPlayingInfoCenter.defaultCenter.nowPlayingInfo;
            oldLyricsSetting = [NSUserDefaults.standardUserDefaults objectForKey:@"show_lyrics_in_now_playing"];
            AVAudioSession *session = AVAudioSession.sharedInstance;
            oldCategory = session.category; oldMode = session.mode; oldOptions = session.categoryOptions;
            if (![session setCategory:AVAudioSessionCategoryPlayback mode:AVAudioSessionModeDefault options:0 error:&audioError]) return;
            if (![session setActive:YES error:&audioError]) return;
            history = [[NSClassFromString(@"FMListeningHistory") alloc] initWithURL:[temporary URLByAppendingPathComponent:@"measured-history.json"] calendar:NSCalendar.currentCalendar];
            player = [AVPlayer playerWithURL:audioURL]; player.muted = YES;
            allowPlayer(player); allowActivity(YES);
            activity = [[NSUserActivity alloc] initWithActivityType:@"com.freemusic.playback"];
            activity.title = realTitle; activity.userInfo = @{@"trackID":trackID};
            activity.eligibleForHandoff = NO; activity.eligibleForSearch = NO; activity.eligibleForPublicIndexing = NO;
            [activity becomeCurrent];
            MPNowPlayingInfoCenter.defaultCenter.nowPlayingInfo = @{MPNowPlayingInfoPropertyExternalContentIdentifier:trackID,
                MPMediaItemPropertyTitle:realTitle, MPMediaItemPropertyArtist:realArtist, MPMediaItemPropertyAlbumTitle:@"Authored local audio"};
            setSampleObserver(^(NSDictionary *track, double elapsed, double rate, NSDate *date, double uptime) {
                // This observes the same immutable sample after the installed
                // production handler; it never replaces or calls that handler.
                originalRunsFirst &= originalCalls > previousOriginalCalls; previousOriginalCalls = originalCalls;
                double actualElapsed = CMTimeGetSeconds(player.currentTime);
                double actualRate = player.timeControlStatus == AVPlayerTimeControlStatusPlaying ? player.rate : 0;
                samplesMatchPlayer &= isfinite(elapsed) && isfinite(actualElapsed) && fabs(actualElapsed - elapsed) < 0.12 && fabs(actualRate - rate) < 0.001;
                samplesMatchPlayer &= fabs(NSProcessInfo.processInfo.systemUptime - uptime) < 0.2 && fabs(date.timeIntervalSinceNow) < 0.2;
                [samples addObject:@{@"track":track ?: NSNull.null, @"elapsed":isfinite(elapsed) ? @(elapsed) : NSNull.null,
                    @"rate":@(rate), @"uptime":@(uptime), @"original_callback_count":@(originalCalls)}];
                [history observeTrack:track elapsed:elapsed rate:rate date:date uptime:uptime];
            });
            timeObserver = [player addPeriodicTimeObserverForInterval:CMTimeMake(1, 10) queue:dispatch_get_main_queue() usingBlock:^(CMTime measuredTime) {
                (void)measuredTime; originalCalls++;
            }];
            [player play];
        });
        Check(!audioError && player && history && timeObserver, audioError.localizedDescription ?: @"Real AVPlayer and observer initialized");
        Check(Until(^BOOL{
            normalSeconds = [[history summaryForDate:NSDate.date yearly:NO][@"seconds"] doubleValue];
            return player.status == AVPlayerStatusReadyToPlay && CMTimeGetSeconds(player.currentTime) >= 1.8 && normalSeconds >= 1.0 && samples.count >= 3;
        }, 12), @"Periodic progress produces listening seconds with just one initial metadata publication (including a song without lyrics)");

        Main(^{ [player pause]; pauseStart = CMTimeGetSeconds(player.currentTime); });
        [NSThread sleepForTimeInterval:1.0];
        Main(^{ pauseEnd = CMTimeGetSeconds(player.currentTime); pausedSeconds = [[history summaryForDate:NSDate.date yearly:NO][@"seconds"] doubleValue]; });
        Check(fabs(pauseEnd - pauseStart) < 0.12 && pausedSeconds - normalSeconds < 0.65,
              @"Pausing stops the real media clock and does not add the paused wall-clock second");

        __block BOOL seekFinished = NO, seekSucceeded = NO;
        Main(^{ [player seekToTime:CMTimeMakeWithSeconds(12, 600) toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero completionHandler:^(BOOL finished) {
            Main(^{ seekFinished = YES; seekSucceeded = finished; });
        }]; });
        Check(Until(^BOOL{return seekFinished;}, 5) && seekSucceeded, @"Real paused AVPlayer seek completes");
        Main(^{ seekSeconds = [[history summaryForDate:NSDate.date yearly:NO][@"seconds"] doubleValue]; [player play]; });
        Check(Until(^BOOL{
            resumedElapsed = CMTimeGetSeconds(player.currentTime);
            finalSeconds = [[history summaryForDate:NSDate.date yearly:NO][@"seconds"] doubleValue];
            return resumedElapsed >= 13.8 && finalSeconds - seekSeconds >= 0.7;
        }, 8), @"Real playback resumes and subsequently advances the listening total");
        __block BOOL observedSeekJump = NO;
        Main(^{
            for (NSUInteger index = 1; index < samples.count; index++) {
                id before = samples[index - 1][@"elapsed"], after = samples[index][@"elapsed"];
                if ([before isKindOfClass:NSNumber.class] && [after isKindOfClass:NSNumber.class] && [after doubleValue] - [before doubleValue] > 5) observedSeekJump = YES;
            }
        });
        Check(observedSeekJump && finalSeconds - pausedSeconds < 3.5 && seekSeconds - pausedSeconds < 0.65,
              @"Measured seek jump is observed but the skipped media interval is not counted as listening");

        Main(^{
            beforeLyrics = samples.count;
            [NSUserDefaults.standardUserDefaults setBool:YES forKey:@"show_lyrics_in_now_playing"];
            MPNowPlayingInfoCenter.defaultCenter.nowPlayingInfo = @{MPNowPlayingInfoPropertyExternalContentIdentifier:trackID,
                MPMediaItemPropertyTitle:@"A self-authored lyric line", MPMediaItemPropertyArtist:[realTitle stringByAppendingFormat:@" - %@", realArtist]};
        });
        Check(Until(^BOOL{
            if(samples.count <= beforeLyrics)return NO;
            NSDictionary *track = [samples.lastObject[@"track"] isKindOfClass:NSDictionary.class] ? samples.lastObject[@"track"] : nil;
            return [track[@"title"] isEqual:realTitle] && [track[@"artist"] isEqual:realArtist];
        }, 4), @"NSUserActivity restores the real song title and only its exact lyric-mode artist prefix is removed; internal hyphens survive");
        Main(^{
            beforeNoLyrics = samples.count;
            MPNowPlayingInfoCenter.defaultCenter.nowPlayingInfo = @{MPNowPlayingInfoPropertyExternalContentIdentifier:trackID,
                MPMediaItemPropertyTitle:realTitle, MPMediaItemPropertyArtist:artistWithoutLyrics};
        });
        Check(Until(^BOOL{
            if(samples.count <= beforeNoLyrics)return NO;
            NSDictionary *track = [samples.lastObject[@"track"] isKindOfClass:NSDictionary.class] ? samples.lastObject[@"track"] : nil;
            return [track[@"title"] isEqual:realTitle] && [track[@"artist"] isEqual:artistWithoutLyrics];
        }, 4), @"Lyrics preference enabled with no current lyric retains the complete real artist, even when it starts with the song-title prefix");

        Main(^{
            beforeWrongID = samples.count;
            MPNowPlayingInfoCenter.defaultCenter.nowPlayingInfo = @{MPNowPlayingInfoPropertyExternalContentIdentifier:@"wy_unrelated_fixture",
                MPMediaItemPropertyTitle:@"Unrelated title", MPMediaItemPropertyArtist:@"Unrelated artist"};
        });
        Check(Until(^BOOL{return samples.count > beforeWrongID && samples.lastObject[@"track"] == NSNull.null;}, 4),
              @"Mismatched activity and Now Playing identity is rejected rather than attributed to the previous song");
        Main(^{
            [player pause]; [player removeTimeObserver:timeObserver]; timeObserver = nil;
            sampleCountAfterRemoval = samples.count; captureReport = diagnostics();
        });
        [NSThread sleepForTimeInterval:0.4];
        __block BOOL removed = NO;
        Main(^{ removed = samples.count == sampleCountAfterRemoval; });
        Check(removed && originalRunsFirst && samplesMatchPlayer, @"Original callback order, actual player sample values and observer removal are preserved");
        Check([captureReport[@"fixtureCapabilityForced"] boolValue] && ![captureReport[@"mainImageMatched"] boolValue],
              @"Simulator reports its explicit fixture gate; it must not claim the original executable callsite ran");
        return @{@"fixture_capability_forced":@YES, @"original_executable_callsite_validated":@NO,
            @"production_sample_handler_replaced":@NO, @"media":@"self-authored local 24-second PCM WAV; actual AVPlayer clock",
            @"initial_metadata_publications":@1, @"original_callback_count":@(originalCalls), @"sample_count":@(sampleCountAfterRemoval),
            @"original_block_runs_first":@(originalRunsFirst), @"samples_equal_actual_player":@(samplesMatchPlayer),
            @"normal_listening_seconds":@(normalSeconds), @"paused_listening_seconds":@(pausedSeconds),
            @"after_seek_listening_seconds":@(seekSeconds), @"resumed_listening_seconds":@(finalSeconds),
            @"pause_media_delta":@(pauseEnd - pauseStart), @"resumed_actual_media_position":@(resumedElapsed),
            @"seek_jump_observed_and_excluded":@(observedSeekJump), @"lyric_title_restored_from_activity":@YES,
            @"lyrics_enabled_but_no_lyric_artist_preserved":@YES, @"mismatched_activity_rejected":@YES,
            @"capture_diagnostics":captureReport ?: @{}};
    } @finally {
        Main(^{
            setSampleObserver(nil);
            [player pause]; if (timeObserver) { [player removeTimeObserver:timeObserver]; timeObserver = nil; }
            [player replaceCurrentItemWithPlayerItem:nil]; [activity invalidate]; allowPlayer(nil); allowActivity(NO);
            MPNowPlayingInfoCenter.defaultCenter.nowPlayingInfo = oldInfo;
            if(oldLyricsSetting)[NSUserDefaults.standardUserDefaults setObject:oldLyricsSetting forKey:@"show_lyrics_in_now_playing"];
            else [NSUserDefaults.standardUserDefaults removeObjectForKey:@"show_lyrics_in_now_playing"];
            if(oldCategory && oldMode)[AVAudioSession.sharedInstance setCategory:oldCategory mode:oldMode options:oldOptions error:nil];
            [AVAudioSession.sharedInstance setActive:NO withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation error:nil];
        });
        [NSFileManager.defaultManager removeItemAtURL:temporary error:nil];
    }
}];
}
