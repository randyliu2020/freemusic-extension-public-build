#import "FMPlaybackQualityDisplay.h"
#import <AudioToolbox/AudioToolbox.h>
#import <CommonCrypto/CommonDigest.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <math.h>

extern void FMPlaybackQualityBridgeSetLabel(const void *, const void *, const void *);

@class FMPQObservation;
static NSMapTable *FMPQSessions;
static BOOL FMPQImageMatched;
static void *FMPQNativeSetter;
static NSUInteger FMPQProbes, FMPQWrites, FMPQStaleResults, FMPQRejected;
static NSDictionary *FMPQLastEvidence;
#if defined(FMX_PLAYBACK_QUALITY_TESTING) && FMX_PLAYBACK_QUALITY_TESTING && TARGET_OS_SIMULATOR
static BOOL FMPQFixtureConfigured, FMPQFixtureAllowed, FMPQHoldProbes;
static __weak id FMPQFixtureReceiver;
static void *FMPQFixtureSetter;
static NSMutableArray *FMPQHeldProbes;
#endif

static double FMPQNumber(id value) {
    if (![value isKindOfClass:NSNumber.class]) return 0;
    double number = [value doubleValue];
    return isfinite(number) && number > 0 ? number : 0;
}
static NSString *FMPQCodec(AudioFormatID format) {
    switch (format) {
        case kAudioFormatFLAC: return @"FLAC";
        case kAudioFormatAppleLossless: return @"ALAC";
        case kAudioFormatLinearPCM: return @"PCM";
        case kAudioFormatMPEGLayer3: return @"MP3";
        case kAudioFormatMPEG4AAC:
        case kAudioFormatMPEG4AAC_HE:
        case kAudioFormatMPEG4AAC_HE_V2:
        case kAudioFormatMPEG4AAC_LD:
        case kAudioFormatMPEG4AAC_ELD:
        case kAudioFormatMPEG4AAC_ELD_SBR: return @"AAC";
        case kAudioFormatOpus: return @"Opus";
        default: return nil;
    }
}
NSDictionary *FMPlaybackQualityDescribeFormats(NSArray<NSDictionary *> *formats) {
    NSDictionary *unknown = @{@"label":@"未知", @"confirmed":@NO, @"losslessCodec":@NO,
                              @"basis":@"unavailable-or-ambiguous-audio-format"};
    if (![formats isKindOfClass:NSArray.class] || !formats.count) return unknown;
    NSString *codec = nil;
    double sampleRate = 0, bitDepth = 0, estimatedRate = 0;
    BOOL first = YES;
    for (id raw in formats) {
        if (![raw isKindOfClass:NSDictionary.class]) return unknown;
        double rawFormat = FMPQNumber(raw[@"formatID"]);
        if (rawFormat > UINT32_MAX || rawFormat != floor(rawFormat)) return unknown;
        NSString *current = FMPQCodec((AudioFormatID)rawFormat);
        if (!current || (codec && ![codec isEqual:current])) return unknown;
        codec = current;
        double rate = FMPQNumber(raw[@"sampleRate"]);
        double depth = FMPQNumber(raw[@"bitDepth"]);
        double estimate = FMPQNumber(raw[@"estimatedBitsPerSecond"]);
        if (rate > 768000) rate = 0;
        if (depth > 64 || depth != floor(depth)) depth = 0;
        if (estimate > 100000000) estimate = 0;
        if (first) { sampleRate=rate; bitDepth=depth; estimatedRate=estimate; first=NO; }
        else {
            if (sampleRate != rate) sampleRate=0;
            if (bitDepth != depth) bitDepth=0;
            // Differing formats/bitrates cannot justify one numeric badge.
            if (fabs(estimatedRate-estimate)>0.5) estimatedRate=0;
        }
    }
    BOOL lossless = [codec isEqual:@"FLAC"] || [codec isEqual:@"ALAC"];
    BOOL compressedLossy = !lossless && ![codec isEqual:@"PCM"];
    NSString *label = codec;
    // AVAssetTrack reports an estimate, not a network throughput measurement.
    // Keep the original small badge compact and explicitly mark the estimate.
    if (compressedLossy && estimatedRate>=1000 && estimatedRate<=1000000)
        label=[NSString stringWithFormat:@"%@~%.0fk",codec,estimatedRate/1000.0];
    return @{@"label":label, @"codec":codec, @"confirmed":@YES,
             @"losslessCodec":@(lossless), @"sampleRate":@(sampleRate),
             @"bitDepth":@(bitDepth), @"estimatedBitsPerSecond":@(estimatedRate),
             @"basis":@"current-item-enabled-audio-format-descriptions"};
}

static BOOL FMPQDigest(const uint8_t *data, size_t length, const char *expected) {
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data,(CC_LONG)length,digest);
    char hex[65];
    for (NSUInteger i=0;i<32;i++) snprintf(hex+i*2,3,"%02x",digest[i]);
    return !strcmp(hex,expected);
}
static void FMPQPrepare(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        FMPQSessions=NSMapTable.weakToStrongObjectsMapTable;
        FMPQLastEvidence=FMPlaybackQualityDescribeFormats(@[]);
#if defined(FMX_PLAYBACK_QUALITY_TESTING) && FMX_PLAYBACK_QUALITY_TESTING && TARGET_OS_SIMULATOR
        FMPQHeldProbes=NSMutableArray.array;
#endif
        const struct mach_header_64 *header=(const struct mach_header_64 *)_dyld_get_image_header(0);
        if (!header || header->magic!=MH_MAGIC_64 || header->cputype!=CPU_TYPE_ARM64 ||
            header->filetype!=MH_EXECUTE || header->ncmds>1024 || header->sizeofcmds>65536) return;
        const uint8_t uuid[16]={0x21,0x2e,0x31,0x08,0x9a,0x0c,0x33,0x09,0xbe,0xdc,0x7e,0x99,0x6e,0x81,0x99,0xd1};
        const uint8_t *cursor=(const uint8_t *)(header+1), *end=cursor+header->sizeofcmds;
        BOOL uuidMatches=NO, rangeMatches=NO;
        for (uint32_t index=0; index<header->ncmds; index++) {
            if ((size_t)(end-cursor)<sizeof(struct load_command)) return;
            const struct load_command *command=(const struct load_command *)cursor;
            if (command->cmdsize<sizeof(*command) || command->cmdsize>(size_t)(end-cursor)) return;
            if (command->cmd==LC_UUID && command->cmdsize==sizeof(struct uuid_command))
                uuidMatches=!memcmp(((const struct uuid_command *)command)->uuid,uuid,16);
            if (command->cmd==LC_SEGMENT_64 && command->cmdsize>=sizeof(struct segment_command_64)) {
                const struct segment_command_64 *segment=(const struct segment_command_64 *)command;
                if (!strncmp(segment->segname,"__TEXT",16) && segment->fileoff==0 &&
                    segment->vmaddr==0x100000000ull && segment->filesize>=0x4254d8 &&
                    segment->vmsize>=0x4254d8 && (segment->initprot&5)==5) rangeMatches=YES;
            }
            cursor+=command->cmdsize;
        }
        if (!uuidMatches || !rangeMatches) return;
        const uint8_t *base=(const uint8_t *)header;
        // Original 4.2.9 display-only Published setter/getter, key paths and
        // player-header Text construction. No original bytecode is bundled.
        if (!FMPQDigest(base+0x664a8,0x7c,"2cdaf67a4ac9d4198b88278f81db6b9aed4ecd49f5cc352a04b61ba7d8890ee6") ||
            !FMPQDigest(base+0x66494,0x14,"f3fe3e1616ae0d64c392ce048f370c3d1b5abba19ec18e8248c024c116a7d2dd") ||
            !FMPQDigest(base+0x417ae8,0x50,"5c75fc2f3d8e4e42d10f6a8e186706dbc42f03b92ee66af346bb3a06787dbf30") ||
            !FMPQDigest(base+0x425488,0x50,"6e0d5bc22201a3dbedbb5c25e3b6d7041c33a0db0405fd6bf66a774bab0adce0") ||
            !FMPQDigest(base+0x1b195c,0x64,"fad2b26e3702703e3976ecf47a030368f49ddeb8818d6fa54c8374a181602c04")) return;
        FMPQNativeSetter=(void *)(base+0x664a8);
        FMPQImageMatched=YES;
    });
}
static void *FMPQSetterFor(id manager) {
#if defined(FMX_PLAYBACK_QUALITY_TESTING) && FMX_PLAYBACK_QUALITY_TESTING && TARGET_OS_SIMULATOR
    if (FMPQFixtureConfigured)
        return FMPQFixtureAllowed && manager==FMPQFixtureReceiver ? FMPQFixtureSetter : NULL;
#endif
    Class nativeClass=NSClassFromString(@"_TtC9FreeMusic18AudioPlayerManager");
    return FMPQImageMatched && nativeClass && [manager isKindOfClass:nativeClass] ? FMPQNativeSetter : NULL;
}
static void FMPQWrite(id manager, NSDictionary *evidence) {
    if (!NSThread.isMainThread || !manager) return;
    void *setter=FMPQSetterFor(manager);
    NSString *label=evidence[@"label"];
    if (!setter || ![label isKindOfClass:NSString.class]) return;
    FMPlaybackQualityBridgeSetLabel(setter,(__bridge const void *)manager,(__bridge const void *)label);
    FMPQWrites++;
    FMPQLastEvidence=evidence;
}

static void *FMPQItemContext=&FMPQItemContext;
static void *FMPQPlayerContext=&FMPQPlayerContext;
@interface FMPQObservation : NSObject
@property(nonatomic,weak) id manager;
@property(nonatomic,weak) AVPlayer *player;
@property(nonatomic,strong) AVPlayerItem *item;
@property(nonatomic,copy) NSString *requestedQuality;
@property(nonatomic,strong) id accessLogToken;
@property(nonatomic) NSUInteger serial;
@property(nonatomic) BOOL observing, stopped;
- (void)start;
- (void)stop;
- (void)probe;
- (BOOL)isCurrent;
@end

@implementation FMPQObservation
- (BOOL)isCurrent {
    return !self.stopped && self.manager && self.player.currentItem==self.item &&
           [FMPQSessions objectForKey:self.manager]==self && FMPQSetterFor(self.manager);
}
- (void)start {
    if (![self isCurrent]) return;
    self.observing=YES;
    [self.item addObserver:self forKeyPath:@"status" options:0 context:FMPQItemContext];
    [self.item addObserver:self forKeyPath:@"tracks" options:0 context:FMPQItemContext];
    [self.player addObserver:self forKeyPath:@"currentItem" options:0 context:FMPQPlayerContext];
    __weak FMPQObservation *weakSelf=self;
    self.accessLogToken=[NSNotificationCenter.defaultCenter addObserverForName:AVPlayerItemNewAccessLogEntryNotification object:self.item queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
        [weakSelf probe];
    }];
    FMPQWrite(self.manager,FMPlaybackQualityDescribeFormats(@[]));
    [self probe];
}
- (void)stop {
    if (self.stopped) return;
    self.stopped=YES;
    self.serial++;
    if (self.observing) {
        [self.item removeObserver:self forKeyPath:@"status" context:FMPQItemContext];
        [self.item removeObserver:self forKeyPath:@"tracks" context:FMPQItemContext];
        [self.player removeObserver:self forKeyPath:@"currentItem" context:FMPQPlayerContext];
        self.observing=NO;
    }
    if (self.accessLogToken) [NSNotificationCenter.defaultCenter removeObserver:self.accessLogToken];
    self.accessLogToken=nil;
}
- (void)dealloc { [self stop]; }
- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    if (context!=FMPQItemContext && context!=FMPQPlayerContext) {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context]; return;
    }
    __weak FMPQObservation *weakSelf=self;
    dispatch_async(dispatch_get_main_queue(), ^{
        FMPQObservation *strongSelf=weakSelf;
        if (!strongSelf) return;
        if (![strongSelf isCurrent]) { [strongSelf stop]; return; }
        strongSelf.serial++;
        FMPQWrite(strongSelf.manager,FMPlaybackQualityDescribeFormats(@[]));
        [strongSelf probe];
    });
}
- (void)finish:(NSArray<NSDictionary *> *)formats serial:(NSUInteger)serial {
    __weak FMPQObservation *weakSelf=self;
    dispatch_block_t apply=^{
        FMPQObservation *strongSelf=weakSelf;
        if (![strongSelf isCurrent] || strongSelf.serial!=serial) { FMPQStaleResults++; return; }
        FMPQWrite(strongSelf.manager,FMPlaybackQualityDescribeFormats(formats));
    };
#if defined(FMX_PLAYBACK_QUALITY_TESTING) && FMX_PLAYBACK_QUALITY_TESTING && TARGET_OS_SIMULATOR
    if (FMPQHoldProbes) { [FMPQHeldProbes addObject:[apply copy]]; return; }
#endif
    apply();
}
- (void)probe {
    if (![self isCurrent] || self.item.status!=AVPlayerItemStatusReadyToPlay) return;
    NSUInteger serial=++self.serial;
    FMPQProbes++;
    AVPlayerItem *item=self.item;
    __weak FMPQObservation *weakSelf=self;
    [item.asset loadTracksWithMediaType:AVMediaTypeAudio completionHandler:^(NSArray<AVAssetTrack *> *tracks, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            FMPQObservation *strongSelf=weakSelf;
            if (![strongSelf isCurrent] || strongSelf.serial!=serial) { FMPQStaleResults++; return; }
            NSMutableSet *enabledIDs=NSMutableSet.set;
            for (AVPlayerItemTrack *itemTrack in item.tracks)
                if (itemTrack.enabled && itemTrack.assetTrack) [enabledIDs addObject:@(itemTrack.assetTrack.trackID)];
            NSMutableArray<AVAssetTrack *> *selected=NSMutableArray.array;
            for (AVAssetTrack *track in tracks)
                if ([enabledIDs containsObject:@(track.trackID)]) [selected addObject:track];
            if (error || !selected.count) { [strongSelf finish:@[] serial:serial]; return; }
            dispatch_group_t group=dispatch_group_create();
            NSMutableArray *formats=NSMutableArray.array;
            __block BOOL failed=NO;
            for (AVAssetTrack *track in selected) {
                dispatch_group_enter(group);
                [track loadValuesAsynchronouslyForKeys:@[@"formatDescriptions",@"estimatedDataRate"] completionHandler:^{
                    NSError *formatError=nil;
                    BOOL loaded=[track statusOfValueForKey:@"formatDescriptions" error:&formatError]==AVKeyValueStatusLoaded;
                    BOOL rateLoaded=[track statusOfValueForKey:@"estimatedDataRate" error:NULL]==AVKeyValueStatusLoaded;
                    NSArray *descriptions=loaded ? track.formatDescriptions : nil;
                    double estimated=rateLoaded ? track.estimatedDataRate : 0;
                    NSMutableArray *trackFormats=NSMutableArray.array;
                    for (id value in descriptions) {
                        CMFormatDescriptionRef description=(__bridge CMFormatDescriptionRef)value;
                        if (CMFormatDescriptionGetMediaType(description)!=kCMMediaType_Audio) continue;
                        const AudioStreamBasicDescription *asbd=CMAudioFormatDescriptionGetStreamBasicDescription(description);
                        if (!asbd) continue;
                        UInt32 bits=asbd->mBitsPerChannel;
                        // For compressed lossless formats, ASBD may use flags
                        // for source bit depth. A missing depth stays unknown.
                        if (!bits && asbd->mFormatID==kAudioFormatAppleLossless) {
                            switch (asbd->mFormatFlags) {
                                case kAppleLosslessFormatFlag_16BitSourceData: bits=16; break;
                                case kAppleLosslessFormatFlag_20BitSourceData: bits=20; break;
                                case kAppleLosslessFormatFlag_24BitSourceData: bits=24; break;
                                case kAppleLosslessFormatFlag_32BitSourceData: bits=32; break;
                            }
                        }
                        [trackFormats addObject:@{@"formatID":@(asbd->mFormatID), @"sampleRate":@(asbd->mSampleRate),
                                                  @"bitDepth":@(bits), @"estimatedBitsPerSecond":@(estimated)}];
                    }
                    @synchronized(formats) {
                        if (!loaded || !trackFormats.count) failed=YES;
                        [formats addObjectsFromArray:trackFormats];
                    }
                    dispatch_group_leave(group);
                }];
            }
            dispatch_group_notify(group,dispatch_get_main_queue(), ^{
                [weakSelf finish:failed ? @[] : [formats copy] serial:serial];
            });
        });
    }];
}
@end

void FMPlaybackQualityDisplayObserve(id manager, AVPlayer *player, NSString *requestedQuality) {
    FMPQPrepare();
    if (!NSThread.isMainThread) return;
    if (!FMPQSetterFor(manager)) { FMPQRejected++; return; }
    FMPQObservation *previous=[FMPQSessions objectForKey:manager];
    [previous stop];
    [FMPQSessions removeObjectForKey:manager];
    // The native setup observer also reports non-JS playback. Retire a previous
    // probe in that case, but preserve the original app's display and behavior.
    if (![requestedQuality isKindOfClass:NSString.class] || !requestedQuality.length) return;
    if (![player isKindOfClass:AVPlayer.class] || !player.currentItem) { FMPQRejected++; return; }
    FMPQObservation *observation=FMPQObservation.new;
    observation.manager=manager;
    observation.player=player;
    observation.item=player.currentItem;
    // Diagnostic context only. It is never passed to the evidence classifier.
    observation.requestedQuality=[requestedQuality isKindOfClass:NSString.class] ? requestedQuality : nil;
    [FMPQSessions setObject:observation forKey:manager];
    // Native setup's caller subsequently writes its requested-quality label.
    // Wait one main turn so that it cannot overwrite our initial unknown badge.
    dispatch_async(dispatch_get_main_queue(), ^{ [observation start]; });
}
NSDictionary *FMPlaybackQualityDisplayDiagnostics(void) {
    FMPQPrepare();
    if (!NSThread.isMainThread) return @{@"mainThreadRequired":@YES};
    return @{@"imageMatched":@(FMPQImageMatched), @"probes":@(FMPQProbes), @"writes":@(FMPQWrites),
             @"staleResults":@(FMPQStaleResults), @"rejected":@(FMPQRejected),
             @"evidence":FMPQLastEvidence ?: @{}};
}
#if defined(FMX_PLAYBACK_QUALITY_TESTING) && FMX_PLAYBACK_QUALITY_TESTING && TARGET_OS_SIMULATOR
void FMPlaybackQualityTestConfigureReceiver(id receiver, void *setter, BOOL allowed) {
    FMPQPrepare();
    NSCAssert(NSThread.isMainThread,@"Fixture configuration is main-thread only");
    for (FMPQObservation *observation in FMPQSessions.objectEnumerator) [observation stop];
    [FMPQSessions removeAllObjects];
    FMPQFixtureConfigured=YES;
    FMPQFixtureReceiver=receiver;
    FMPQFixtureSetter=setter;
    FMPQFixtureAllowed=allowed && receiver && setter;
}
void FMPlaybackQualityTestHoldCompletedProbes(BOOL hold) {
    FMPQPrepare(); NSCAssert(NSThread.isMainThread,@"Main thread required"); FMPQHoldProbes=hold;
}
NSUInteger FMPlaybackQualityTestPendingProbes(void) {
    FMPQPrepare(); NSCAssert(NSThread.isMainThread,@"Main thread required"); return FMPQHeldProbes.count;
}
void FMPlaybackQualityTestReleaseOldestProbe(void) {
    FMPQPrepare(); NSCAssert(NSThread.isMainThread,@"Main thread required");
    if (!FMPQHeldProbes.count) return;
    dispatch_block_t block=FMPQHeldProbes.firstObject;
    [FMPQHeldProbes removeObjectAtIndex:0]; block();
}
#endif
