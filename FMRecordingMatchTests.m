#import "FMRecordingMatch.h"
#import "FMPreferredDownloadStore.h"
#import <AVFoundation/AVFoundation.h>
#import <fcntl.h>
#import <unistd.h>
#import <sys/stat.h>
#import <stdint.h>
#import <stdlib.h>
#import <string.h>

static NSMutableArray *checks;
static void Check(BOOL condition, NSString *name) {
    [checks addObject:@{@"name":name, @"passed":@(condition)}];
    if (!condition) fprintf(stderr, "FAILED %s\n", name.UTF8String);
}
static NSDictionary *With(NSDictionary *base, NSDictionary *changes) {
    NSMutableDictionary *row = base.mutableCopy;
    [row addEntriesFromDictionary:changes];
    return row.copy;
}
static void Sound(NSURL *url, NSUInteger seconds) {
    uint32_t count = (uint32_t)seconds * 16000;
    NSMutableData *wav = [NSMutableData dataWithLength:44 + count];
    uint8_t *p = wav.mutableBytes;
    memcpy(p, "RIFF", 4); memcpy(p+8, "WAVEfmt ", 8); memcpy(p+36, "data", 4);
    uint32_t riff = count + 36, fmt = 16, sampleRate = 8000, byteRate = 16000;
    uint16_t pcm = 1, channels = 1, block = 2, bits = 16;
    memcpy(p+4,&riff,4); memcpy(p+16,&fmt,4); memcpy(p+20,&pcm,2); memcpy(p+22,&channels,2);
    memcpy(p+24,&sampleRate,4); memcpy(p+28,&byteRate,4); memcpy(p+32,&block,2);
    memcpy(p+34,&bits,2); memcpy(p+40,&count,4);
    if (![wav writeToURL:url atomically:YES]) abort();
}
static void Registry(NSURL *index, NSArray *rows) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:rows options:0 error:nil];
    if (![data writeToURL:index atomically:YES]) abort();
}
static void SilentMP3(NSURL *url) {
    // One independent frame of authored 16 kHz mono silence, bit reservoir
    // disabled. 86 repetitions form a real 3.096 s Layer III stream.
    NSData *frame = [[NSData alloc] initWithBase64EncodedString:@"//MoxAAAAANIAAAAAExBTUUzLjEwMAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" options:0];
    NSMutableData *data = [NSMutableData data];
    for (int i=0; i<86; i++) [data appendData:frame];
    if (![data writeToURL:url atomically:YES]) abort();
}

static void EncodedSound(NSURL *url, BOOL caf) {
    AVAudioFormat *pcm = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:44100 channels:1];
    NSDictionary *settings = caf ? pcm.settings : @{AVFormatIDKey:@(kAudioFormatMPEG4AAC), AVSampleRateKey:@44100,
                                                     AVNumberOfChannelsKey:@1, AVEncoderBitRateKey:@64000};
    AVAudioFile *out = [[AVAudioFile alloc] initForWriting:url settings:settings
                                             commonFormat:AVAudioPCMFormatFloat32 interleaved:NO error:nil];
    if (!out) abort();
    AVAudioPCMBuffer *buf = [[AVAudioPCMBuffer alloc] initWithPCMFormat:out.processingFormat frameCapacity:4410];
    buf.frameLength = 4410; memset(buf.floatChannelData[0],0,4410*sizeof(float));
    for (int i=0; i<30; i++) if (![out writeFromBuffer:buf error:nil]) abort();
}

// Return an index to exactly the same inode, size and timestamps after an
// unsuccessful read, as happens when protected files become accessible.
static void RestoreFirstByte(NSURL *url, unsigned char byte, const struct stat *stamp) {
    int fd = open(url.fileSystemRepresentation,O_WRONLY);
    struct timespec times[2] = {stamp->st_atimespec,stamp->st_mtimespec};
    if (fd < 0 || pwrite(fd,&byte,1,0) != 1 || futimens(fd,times) != 0 || close(fd)) abort();
}

int main(int argc, const char **argv) {
    @autoreleasepool {
        if (argc != 2) return 2;
        checks = [NSMutableArray array];
        NSDictionary *fav = @{@"server":@"wy", @"id":@"123", @"title":@"Test （Radio Edit）",
                              @"singer":@"Artist A、Artist B", @"album":@"Volume One", @"duration":@8};
        NSDictionary *download = @{@"server":@"qq", @"id":@"mid001", @"title":@"TEST (Radio Edit)",
                                   @"singer":@"Artist B / Artist A", @"album":@"Volume One", @"duration":@9};
        Check([FMConfirmedLocalRecording(fav,@[download]) isEqual:download], @"full version title credits album and duration");
        for (NSString *changed in @[@"Test (Live)",@"Test (Instrumental)",@"Test (Remix)",@"Test"]) {
            Check(!FMConfirmedLocalRecording(fav,@[With(download,@{@"title":changed})]), changed);
        }
        Check(!FMConfirmedLocalRecording(fav,@[With(download,@{@"singer":@"Artist A"})]), @"solo and duet stay separate");
        Check(!FMConfirmedLocalRecording(fav,@[With(download,@{@"album":@"Another Release"})]), @"different album without recording identifier");
        Check(!FMConfirmedLocalRecording(fav,@[With(download,@{@"duration":@13})]), @"duration discrepancy");
        Check(!FMConfirmedLocalRecording(fav,@[With(download,@{@"duration":@0})]), @"absent duration");
        Check(!FMConfirmedLocalRecording(fav,@[download, With(download,@{@"id":@"mid002"})]), @"two plausible recordings");
        Check(!FMConfirmedLocalRecording(fav,@[With(download,@{@"server":@"netease"})]), @"same platform different identifier");
        Check(!FMConfirmedLocalRecording(@{@"server":@"wy",@"id":@"123",@"title":fav[@"title"]},@[download]), @"insufficient metadata");
        NSDictionary *isrc = With(fav,@{@"isrc":@"US-ABC-24-12345"});
        NSDictionary *otherLabel = With(download,@{@"isrc":@"USABC2412345",@"title":@"Alternate title",@"album":@"Anthology"});
        Check([FMConfirmedLocalRecording(isrc,@[download,otherLabel]) isEqual:otherLabel], @"shared recording identifier outranks metadata");
        Check(!FMConfirmedLocalRecording(isrc,@[With(download,@{@"isrc":@"USABC2412355"})]), @"conflicting identifiers");
        Check(!FMConfirmedLocalRecording(With(isrc,@{@"isrc":@"invalid"}),@[With(otherLabel,@{@"isrc":@"invalid"})]), @"malformed identifiers carry no evidence");
        NSURL *root = [NSFileManager.defaultManager.temporaryDirectory URLByAppendingPathComponent:NSUUID.UUID.UUIDString isDirectory:YES];
        NSURL *support = [root URLByAppendingPathComponent:@"support" isDirectory:YES];
        NSURL *documents = [root URLByAppendingPathComponent:@"docs" isDirectory:YES];
        NSURL *caches = [root URLByAppendingPathComponent:@"caches" isDirectory:YES];
        NSURL *music = [documents URLByAppendingPathComponent:@"Downloads" isDirectory:YES];
        for (NSURL *dir in @[music,support,caches]) if (![NSFileManager.defaultManager createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:nil error:nil]) abort();
        NSURL *index = [support URLByAppendingPathComponent:@"downloaded_tracks.json"];
        NSURL *qqFile = [music URLByAppendingPathComponent:@"qq_mid001.wav"];
        NSURL *wyFile = [music URLByAppendingPathComponent:@"wy_123.wav"];
        FMPreferredDownloadStore *store = [[FMPreferredDownloadStore alloc] initWithApplicationSupport:support documents:documents caches:caches];
        Registry(index,@[download]); Sound(qqFile,9);
        Check([[store lookupTrack:fav] isEqual:qqFile], @"cross-platform registered and validated audio");
        Check([[store lookupServer:@"tx" trackID:@"mid001"] isEqual:qqFile], @"same platform alias needs no metadata");
        Check(![store lookupTrack:With(fav,@{@"title":@"Test (Live)"})], @"same identifier changed credits are re-evaluated");
        Registry(index,@[fav,download]); Sound(wyFile,8);
        Check([[store lookupTrack:fav] isEqual:wyFile], @"exact identifier wins over cross-platform match");
        NSUInteger first = [store beginPlaybackSelection];
        [store rejectURL:wyFile forSelection:first];
        Check([[store lookupTrack:fav] isEqual:qqFile] && [NSFileManager.defaultManager fileExistsAtPath:wyFile.path], @"rejected exact file retained while confirmed alternate plays");
        Check(store.playbackSelection == first && [[store lookupTrack:fav] isEqual:qqFile], @"internal retries keep the failed local revision retired");
        [store beginPlaybackSelection];
        Check([[store lookupTrack:download] isEqual:qqFile], @"second selection plays the other local recording");
        NSUInteger back = [store beginPlaybackSelection];
        Check(back != first && [[store lookupTrack:fav] isEqual:wyFile], @"returning to a track retries its unchanged healthy manual file");
        [store rejectURL:wyFile forSelection:first];
        Check(store.playbackSelection == back && [[store lookupTrack:fav] isEqual:wyFile], @"late previous selection rejection cannot suppress current local file");
        [store rejectURL:wyFile forSelection:back];
        Sound(wyFile,8);
        Check([[store lookupTrack:fav] isEqual:wyFile], @"replaced previously rejected file");
        Sound(wyFile,1); [@"invalid" writeToURL:qqFile atomically:YES encoding:NSUTF8StringEncoding error:nil];
        Check(![store lookupTrack:fav], @"truncated and unreadable files fall through");
        NSURL *legacyAudio = [caches URLByAppendingPathComponent:@"MusicCache" isDirectory:YES];
        NSURL *assets = [support URLByAppendingPathComponent:@"DownloadAssets" isDirectory:YES];
        for (NSURL *dir in @[legacyAudio,assets])
            if (![NSFileManager.defaultManager createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:nil error:nil]) abort();
        NSDictionary *old = @{@"server":@"tx", @"id":@"MiD", @"title":@"fixture", @"duration":@3};
        NSURL *oldFile = [legacyAudio URLByAppendingPathComponent:@"qq_MiD.m4a"];
        EncodedSound(oldFile,NO); Registry(index,@[old]);
        Check([[store lookupServer:@"qq" trackID:@"MiD"] isEqual:oldFile], @"registered legacy MusicCache AAC found by native filename alias");
        Check(![store lookupServer:@"qq" trackID:@"mid"], @"case-distinct QQ recording never inherits legacy file");
        NSURL *unregistered = [legacyAudio URLByAppendingPathComponent:@"qq_absent.wav"]; Sound(unregistered,3);
        Check(![store lookupServer:@"qq" trackID:@"absent"], @"unregistered legacy automatic file cannot act as manual download");
        NSURL *sidecar = [assets URLByAppendingPathComponent:@"qq_MiD_playback.caf"]; EncodedSound(sidecar,YES);
        Check([[store lookupServer:@"qq" trackID:@"MiD"] isEqual:sidecar], @"native decoded playback CAF takes priority over old cached audio");
        NSURL *wyLegacyMP3 = [legacyAudio URLByAppendingPathComponent:@"wy_301.mp3"]; SilentMP3(wyLegacyMP3);
        NSURL *qqAutoMP3 = [legacyAudio URLByAppendingPathComponent:@"qq_301.mp3"]; SilentMP3(qqAutoMP3);
        NSDictionary *registeredWY = @{@"server":@"wy",@"id":@"301",@"duration":@3};
        Registry(index,@[registeredWY,old]);
        Check([[store lookupServer:@"wy" trackID:@"301"] isEqual:wyLegacyMP3],
              @"registered legacy MusicCache MP3 selected by exact provider and track ID");
        Check(![store lookupServer:@"qq" trackID:@"301"] && [NSFileManager.defaultManager fileExistsAtPath:qqAutoMP3.path],
              @"unregistered MP3 for same ID on other platform stays separate from registered manual file");
        NSDictionary *alias = @{@"server":@"qq",@"id":@"list-row",@"song_id":@"download-MID",@"platform":@3,@"duration":@3};
        NSURL *aliasMP3 = [music URLByAppendingPathComponent:@"qq_download-MID.mp3"]; SilentMP3(aliasMP3);
        Registry(index,@[alias]);
        Check([[store lookupServer:@"qq" trackID:@"list-row"] isEqual:aliasMP3] &&
              [[store lookupServer:@"qq" trackID:@"download-MID"] isEqual:aliasMP3],
              @"unique documented song_id binds a native list row to its download");
        Registry(index,@[alias,With(alias,@{@"id":@"another-list-row"})]);
        Check(![store lookupServer:@"qq" trackID:@"download-MID"], @"ambiguous alternate song_id is skipped");
        Registry(index,@[With(alias,@{@"platform":@0})]);
        Check(![store lookupServer:@"qq" trackID:@"download-MID"], @"contradictory platform never supplies a song_id alias");
        NSString *hash = @"1234567890ABCDEF1234567890ABCDEF";
        NSDictionary *kg = @{@"server":@"kg", @"id":hash, @"duration":@3};
        NSURL *kgFile = [music URLByAppendingPathComponent:[NSString stringWithFormat:@"kg_%@.wav",hash.lowercaseString]]; Sound(kgFile,3);
        Registry(index,@[old,kg]);
        Check([[store lookupServer:@"kugou" trackID:hash] isEqual:kgFile], @"case variants apply only to a true 32-character Kugou hash");
        struct stat stamp; if (stat(index.fileSystemRepresentation,&stamp)) abort();
        unsigned char good; int fd = open(index.fileSystemRepresentation,O_RDONLY);
        if (fd < 0 || read(fd,&good,1) != 1 || close(fd)) abort();
        FMPreferredDownloadStore *retry = [[FMPreferredDownloadStore alloc] initWithApplicationSupport:support documents:documents caches:caches];
        RestoreFirstByte(index,'!',&stamp);
        Check(![retry lookupServer:@"qq" trackID:@"MiD"], @"temporarily unreadable registry does not expose arbitrary files");
        RestoreFirstByte(index,good,&stamp);
        Check([[retry lookupServer:@"qq" trackID:@"MiD"] isEqual:sidecar], @"same-stamp recovered index is retried without relaunch");
        [NSFileManager.defaultManager removeItemAtURL:index error:nil];
        Registry([caches URLByAppendingPathComponent:@"downloaded_tracks.json"],@[old]);
        Check([[store lookupServer:@"qq" trackID:@"MiD"] isEqual:sidecar], @"older registry used when primary is absent");
        [NSFileManager.defaultManager removeItemAtURL:root error:nil];
        BOOL passed = YES; for (NSDictionary *item in checks) if (![item[@"passed"] boolValue]) passed=NO;
        NSDictionary *report = @{@"passed":@(passed), @"assertion_count":@(checks.count), @"checks":checks};
        NSData *json = [NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:nil];
        return [json writeToFile:[NSString stringWithUTF8String:argv[1]] atomically:YES] && passed ? 0 : 1;
    }
}
