// Actual local media, a genuine Swift String bridge and an authored Published
// manager. This does not run the original app or claim a physical badge test.
{
NSURL *(^makeQualityWave)(void)=^NSURL *{
    NSURL *file=[NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"FMX-quality-%@.wav",NSUUID.UUID.UUIDString]]];
    const uint32_t sampleRate=22050, sampleCount=sampleRate*3, audioBytes=sampleCount*2;
    NSMutableData *wave=NSMutableData.data;
    void (^u16)(uint16_t)=^(uint16_t n){uint8_t bytes[2]={(uint8_t)n,(uint8_t)(n>>8)};[wave appendBytes:bytes length:2];};
    void (^u32)(uint32_t)=^(uint32_t n){uint8_t bytes[4]={(uint8_t)n,(uint8_t)(n>>8),(uint8_t)(n>>16),(uint8_t)(n>>24)};[wave appendBytes:bytes length:4];};
    [wave appendBytes:"RIFF" length:4];u32(36+audioBytes);[wave appendBytes:"WAVEfmt " length:8];
    u32(16);u16(1);u16(1);u32(sampleRate);u32(sampleRate*2);u16(2);u16(16);[wave appendBytes:"data" length:4];u32(audioBytes);
    for(uint32_t i=0;i<sampleCount;i++)u16((uint16_t)(int16_t)(500*sin(2*M_PI*220*i/sampleRate)));
    Check([wave writeToURL:file atomically:YES],@"Write authored PCM media");
    return file;
};
[self test:@"v6_quality_evidence_and_native_display_bridge" body:^NSDictionary *{
    NSDictionary *(*describe)(NSArray *)=dlsym(self.extensionHandle,"FMPlaybackQualityDescribeFormats");
    void (*observe)(id,AVPlayer *,NSString *)=dlsym(self.extensionHandle,"FMPlaybackQualityDisplayObserve");
    void (*configure)(id,void *,BOOL)=dlsym(self.extensionHandle,"FMPlaybackQualityTestConfigureReceiver");
    void (*bridge)(const void *,const void *,const void *)=dlsym(self.extensionHandle,"FMPlaybackQualityBridgeSetLabel");
    NSDictionary *(*diagnostics)(void)=dlsym(self.extensionHandle,"FMPlaybackQualityDisplayDiagnostics");
    void *(*create)(void)=dlsym(self.swiftUIFixtureHandle,"FMPlaybackQualityFixtureCreate");
    void *(*copyState)(const void *)=dlsym(self.swiftUIFixtureHandle,"FMPlaybackQualityFixtureCopyState");
    void *setter=dlsym(self.swiftUIFixtureHandle,"FMPlaybackQualityFixtureSetIndirect");
    Check(describe && observe && configure && bridge && diagnostics && create && copyState && setter,@"Quality exports exist");
    NSDictionary *(^format)(uint32_t,double)=^NSDictionary *(uint32_t codec,double rate){
        return @{@"formatID":@(codec),@"sampleRate":@44100,@"bitDepth":@16,@"estimatedBitsPerSecond":@(rate)};
    };
    // Numeric AudioFormatIDs in fixtures are self-authored format facts, not
    // request labels. These policy checks complement the real WAV probe below.
    Check([describe(@[]) [@"label"] isEqual:@"未知"],@"Missing actual evidence is unknown");
    Check([describe(@[@{@"requestedQuality":@"flac24bit",@"URL":@"https://example.invalid/a.flac"}]) [@"label"] isEqual:@"未知"],@"Request and suffix cannot prove lossless");
    Check([describe(@[format(0x666c6163,900000)]) [@"label"] isEqual:@"FLAC"],@"Actual FLAC codec is recognized");
    Check([describe(@[format(0x616c6163,900000)]) [@"label"] isEqual:@"ALAC"],@"Actual ALAC codec is recognized");
    Check([describe(@[format(0x6c70636d,1411200)]) [@"losslessCodec"] boolValue]==NO,@"PCM does not prove lossless source provenance");
    Check([describe(@[format(0x61616320,128000)]) [@"label"] isEqual:@"AAC~128k"],@"Estimated AAC rate is marked approximate");
    Check([describe(@[format(0x2e6d7033,320000)]) [@"label"] isEqual:@"MP3~320k"],@"Actual MP3 rate is reported, independent of requested FLAC");
    Check([describe(@[format(0x61616320,128000),format(0x666c6163,900000)]) [@"label"] isEqual:@"未知"],@"Mixed codecs do not claim a single quality");
    Check([describe(@[format(0x61616320,128000),format(0x61616320,256000)]) [@"label"] isEqual:@"AAC"],@"Mixed bitrates avoid misleading one-rate label");

    __block id manager=nil;
    Main(^{ manager=CFBridgingRelease(create()); });
    NSDictionary *(^state)(void)=^NSDictionary *{return CFBridgingRelease(copyState((__bridge const void *)manager));};
    Main(^{
        NSString *longUnicode=@"未知・真实媒体音质（桥接生命周期）";
        bridge(setter,(__bridge const void *)manager,(__bridge const void *)longUnicode);
        Check([state()[@"label"] isEqual:longUnicode],@"Swift bridge handles non-small Unicode String ownership");
        Check([state()[@"selectedQuality"] isEqual:@"flac24bit"] && [state()[@"changes"] unsignedIntegerValue]==1,@"Only display Published property changes, preference remains unchanged");
    });

    NSURL *file=makeQualityWave();
    __block AVPlayer *player=nil;
    Main(^{
        player=[AVPlayer playerWithURL:file];
        configure(manager,setter,NO);
        observe(manager,player,@"flac24bit");
    });
    Check(Until(^BOOL{return player.currentItem.status!=AVPlayerItemStatusUnknown;},10),@"Real local asset loads");
    Main(^{Check([state()[@"changes"] unsignedIntegerValue]==1,@"Wrong image fails closed without display writes");configure(manager,setter,YES);observe(manager,player,@"flac24bit");});
    Check(Until(^BOOL{return [state()[@"label"] isEqual:@"PCM"];},10),@"AVAsset describes actual PCM despite FLAC requested quality");
    __block NSDictionary *evidence=nil;
    Main(^{
        evidence=diagnostics()[@"evidence"];
        Check([evidence[@"sampleRate"] doubleValue]==22050 && [evidence[@"bitDepth"] integerValue]==16,@"Actual ASBD sample rate and depth are retained");
        Check([state()[@"selectedQuality"] isEqual:@"flac24bit"],@"Actual quality never mutates the user's selected quality");
        Check(player.currentItem.asset && player.rate==0 && CMTimeGetSeconds(player.currentTime)<0.01,@"Inspection does not start, seek or replace playback");
        NSUInteger writes=[state()[@"changes"] unsignedIntegerValue];
        observe(manager,player,nil);
        Check([state()[@"changes"] unsignedIntegerValue]==writes,@"Native-only setup retires JS inspection without writing its badge");
        configure(nil,NULL,NO);
    });
    return @{@"actualEvidence":evidence,@"scope":@"authored Simulator manager and actual AVAsset PCM; original badge not run"};
}];

[self test:@"v6_quality_stale_probe_cannot_overwrite_new_item" body:^NSDictionary *{
    void (*observe)(id,AVPlayer *,NSString *)=dlsym(self.extensionHandle,"FMPlaybackQualityDisplayObserve");
    void (*configure)(id,void *,BOOL)=dlsym(self.extensionHandle,"FMPlaybackQualityTestConfigureReceiver");
    void (*hold)(BOOL)=dlsym(self.extensionHandle,"FMPlaybackQualityTestHoldCompletedProbes");
    NSUInteger (*pending)(void)=dlsym(self.extensionHandle,"FMPlaybackQualityTestPendingProbes");
    void (*releaseOldest)(void)=dlsym(self.extensionHandle,"FMPlaybackQualityTestReleaseOldestProbe");
    NSDictionary *(*diagnostics)(void)=dlsym(self.extensionHandle,"FMPlaybackQualityDisplayDiagnostics");
    void *(*create)(void)=dlsym(self.swiftUIFixtureHandle,"FMPlaybackQualityFixtureCreate");
    void *(*copyState)(const void *)=dlsym(self.swiftUIFixtureHandle,"FMPlaybackQualityFixtureCopyState");
    void *setter=dlsym(self.swiftUIFixtureHandle,"FMPlaybackQualityFixtureSetIndirect");
    Check(observe && configure && hold && pending && releaseOldest && diagnostics && create && copyState && setter,@"Delayed genuine probe fixture exports exist");
    NSURL *file=makeQualityWave();
    __block id manager=nil;__block AVPlayer *player=nil;__block NSUInteger staleBefore=0;
    NSDictionary *(^state)(void)=^NSDictionary *{return CFBridgingRelease(copyState((__bridge const void *)manager));};
    Main(^{
        manager=CFBridgingRelease(create());player=[AVPlayer playerWithURL:file];
        configure(manager,setter,YES);hold(YES);observe(manager,player,@"flac");
    });
    Check(Until(^BOOL{return pending()>0;},10),@"Hold a genuinely completed old asset probe");
    Main(^{
        staleBefore=[diagnostics()[@"staleResults"] unsignedIntegerValue];
        NSURL *missing=[NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:@"FMX-quality-no-such-media.flac"]];
        [player replaceCurrentItemWithPlayerItem:[AVPlayerItem playerItemWithURL:missing]];
        observe(manager,player,@"flac24bit");
    });
    Check(Until(^BOOL{return [state()[@"label"] isEqual:@"未知"];},5),@"Replacement begins unknown even with a FLAC suffix and request");
    Main(^{
        while(pending())releaseOldest();
        Check([state()[@"label"] isEqual:@"未知"],@"Old PCM probe cannot label the replacement item");
        Check([diagnostics()[@"staleResults"] unsignedIntegerValue]>staleBefore,@"Production serial/item identity check rejected delayed result");
        hold(NO);configure(nil,NULL,NO);
    });
    return @{@"scope":@"actual AVAsset completion delayed after item replacement; no forged format callback"};
}];
}
