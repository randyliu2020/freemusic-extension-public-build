#import "FMDownloadArtwork.h"
#import "FMTrackMetadata.h"
#import <ImageIO/ImageIO.h>
#import <CoreGraphics/CoreGraphics.h>

static NSMutableArray<NSString *> *passed;
static void Check(BOOL ok, NSString *what) {
    if (!ok) { NSLog(@"FAILED %@",what); exit(1); }
    [passed addObject:what];
}
static NSMutableArray<NSURL *> *requests;
static NSMutableDictionary<NSString *,id> *responses;
@interface ArtFixtureProtocol : NSURLProtocol @end
@implementation ArtFixtureProtocol
+ (BOOL)canInitWithRequest:(NSURLRequest *)request { return YES; }
+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request { return request; }
- (void)startLoading {
    NSURL *url = self.request.URL;
    NSData *data; NSInteger status;
    @synchronized (requests) {
        [requests addObject:url];
        id fixture = responses[url.absoluteString] ?: responses[url.path];
        data = [fixture isKindOfClass:NSData.class] ? fixture : [NSData data];
        status = fixture ? 200 : 404;
    }
    NSHTTPURLResponse *r = [[NSHTTPURLResponse alloc] initWithURL:url statusCode:status HTTPVersion:@"HTTP/1.1" headerFields:@{}];
    [self.client URLProtocol:self didReceiveResponse:r cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    if (data.length) [self.client URLProtocol:self didLoadData:data];
    [self.client URLProtocolDidFinishLoading:self];
}
- (void)stopLoading {}
@end

static NSData *PNG(void) {
    CGColorSpaceRef rgb = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(NULL,64,32,8,0,rgb,kCGImageAlphaNoneSkipLast);
    CGContextSetRGBFillColor(ctx,.25,.65,1,1);
    CGContextFillRect(ctx,CGRectMake(0,0,64,32));
    CGImageRef image = CGBitmapContextCreateImage(ctx);
    NSMutableData *bytes = NSMutableData.data;
    CGImageDestinationRef dest = CGImageDestinationCreateWithData((__bridge CFMutableDataRef)bytes,CFSTR("public.png"),1,NULL);
    CGImageDestinationAddImage(dest,image,NULL);
    Check(CGImageDestinationFinalize(dest),@"encode original PNG");
    CFRelease(dest); CGImageRelease(image); CGContextRelease(ctx); CGColorSpaceRelease(rgb);
    return bytes;
}
static void U32(NSMutableData *data, NSUInteger n) {
    uint8_t b[4] = {(uint8_t)(n>>24),(uint8_t)(n>>16),(uint8_t)(n>>8),(uint8_t)n};
    [data appendBytes:b length:4];
}
static NSData *FLAC(NSData *picture) {
    // Actual FLAC stream containing 640 samples of mono silence at 8 kHz.
    NSData *base = [[NSData alloc] initWithBase64EncodedString:@"ZkxhQ4AAACICQAJAAAAAAASVAfQA8AAAAAAAAAAAAAAAAAAAAAAAAAAA//gkCADKAAAAznb/+GQIAT9LAAAAOjk=" options:0];
    if (!picture) return base;
    NSMutableData *result = [[base subdataWithRange:NSMakeRange(0,42)] mutableCopy];
    ((uint8_t *)result.mutableBytes)[4] = 0;
    NSMutableData *block = NSMutableData.data;
    U32(block,3); U32(block,9); [block appendBytes:"image/png" length:9]; U32(block,0);
    U32(block,64); U32(block,32); U32(block,24); U32(block,0); U32(block,picture.length);
    [block appendData:picture];
    U32(result,0x86000000u | block.length); [result appendData:block];
    [result appendData:[base subdataWithRange:NSMakeRange(42,base.length-42)]];
    return result;
}
static NSData *MP3(NSData *picture) {
    NSData *audio = [[NSData alloc] initWithBase64EncodedString:@"//MkxAAAAANIAAAAAExBTUUzLjEwMFVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVV//MkxCMAAANIAAAAAFVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVV//MkxEYAAANIAAAAAFVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVV//MkxGkAAANIAAAAAFVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVV//MkxIwAAANIAAAAAFVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVV//MkxK8AAANIAAAAAFVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVV" options:0];
    NSMutableData *bytes = NSMutableData.data;
    NSUInteger frameSize = 13 + picture.length, tagSize = 10 + frameSize;
    const uint8_t header[] = {'I','D','3',3,0,0,(tagSize>>21)&127,(tagSize>>14)&127,(tagSize>>7)&127,tagSize&127};
    [bytes appendBytes:header length:sizeof(header)]; [bytes appendBytes:"APIC" length:4]; U32(bytes,frameSize);
    const uint8_t details[] = {0,0,0,'i','m','a','g','e','/','p','n','g',0,3,0};
    [bytes appendBytes:details length:sizeof(details)]; [bytes appendData:picture]; [bytes appendData:audio];
    return bytes;
}
static BOOL Wait(BOOL (^condition)(void)) {
    NSDate *limit = [NSDate dateWithTimeIntervalSinceNow:12];
    while (!condition() && limit.timeIntervalSinceNow > 0)
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    return condition();
}
static NSURL *Resolve(FMDownloadArtwork *store,NSString *p,NSString *i,NSURL *file,NSURL *cover) {
    __block BOOL done = NO; __block NSURL *value;
    [store resolvePlatform:p trackID:i audioFile:file coverURL:cover completion:^(NSURL *result) {
        Check(NSThread.isMainThread,@"completion main"); value=result; done=YES;
    }];
    Check(Wait(^BOOL{return done;}),@"artwork completion"); return value;
}
int main(int argc, const char **argv) { @autoreleasepool {
    passed = NSMutableArray.new;
    requests = NSMutableArray.new; responses = NSMutableDictionary.new;
    NSURL *root = [[NSURL fileURLWithPath:NSTemporaryDirectory() isDirectory:YES] URLByAppendingPathComponent:NSUUID.UUID.UUIDString];
    NSURL *downloads = [root URLByAppendingPathComponent:@"Downloads"];
    NSURL *library = [root URLByAppendingPathComponent:@"art"];
    NSURL *assets = [root URLByAppendingPathComponent:@"DownloadAssets"];
    NSFileManager *fm = NSFileManager.defaultManager;
    for (NSURL *folder in @[downloads,assets]) Check([fm createDirectoryAtURL:folder withIntermediateDirectories:YES attributes:nil error:nil],@"fixture directory");
    NSURLSessionConfiguration *cfg = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    cfg.protocolClasses = @[ArtFixtureProtocol.class];
    FMDownloadArtwork *(^openStore)(void) = ^{return [[FMDownloadArtwork alloc] initWithDirectory:library downloads:downloads configuration:cfg];};
    FMDownloadArtwork *store = openStore(); NSData *png = PNG(), *plain = FLAC(nil), *tagged = FLAC(png);
    NSURL *flac = [downloads URLByAppendingPathComponent:@"wy_11.flac"];
    Check([tagged writeToURL:flac atomically:YES],@"write FLAC");
    NSURL *embedded = Resolve(store,@"wy",@"11",flac,nil);
    Check([FMDownloadArtwork isUsableJPEGAtURL:embedded] && !requests.count,@"FLAC embedded artwork offline");
    Check([[NSData dataWithContentsOfURL:flac] isEqual:tagged],@"FLAC preserved byte-for-byte");
    NSURL *mp3 = [downloads URLByAppendingPathComponent:@"qq_12.mp3"];
    NSData *taggedMP3 = MP3(png); [taggedMP3 writeToURL:mp3 atomically:YES];
    Check([FMDownloadArtwork isUsableJPEGAtURL:Resolve(store,@"qq",@"12",mp3,nil)] && !requests.count,@"ID3 APIC embedded artwork offline");
    Check([[NSData dataWithContentsOfURL:mp3] isEqual:taggedMP3],@"MP3 preserved byte-for-byte");
    [plain writeToURL:flac atomically:YES];
    Check([embedded isEqual:Resolve(openStore(),@"netease",@"11",flac,nil)] && !requests.count,@"disk persists on new instance, no lookup");
    NSURL *sideAudio = [downloads URLByAppendingPathComponent:@"wy_13.flac"];
    [plain writeToURL:sideAudio atomically:YES];
    NSURL *sidecar = [assets URLByAppendingPathComponent:@"wy_13_cover.jpg"];
    [png writeToURL:sidecar atomically:YES];
    Check(![FMDownloadArtwork isUsableJPEGAtURL:sidecar],@"PNG is identified even with JPEG suffix");
    Check([FMDownloadArtwork isUsableImageAtURL:sidecar],@"native PNG under JPEG name is a usable image");
    Check([FMDownloadArtwork isUsableJPEGAtURL:Resolve(store,@"wy",@"13",sideAudio,nil)] && !requests.count,@"named native sidecar converted offline");
    Check([[NSData dataWithContentsOfURL:sidecar] isEqual:png],@"leave original sidecar to native publisher");
    NSString *image = @"https://p3.music.126.net/fixture/known.jpg";
    NSURL *remote = [NSURL URLWithString:image];
    NSURL *netFile = [downloads URLByAppendingPathComponent:@"wy_14.flac"];
    [plain writeToURL:netFile atomically:YES];
    responses[@"/api/song/detail/"] = [NSJSONSerialization dataWithJSONObject:@{@"songs":@[
        @{@"id":@15,@"al":@{@"picUrl":@"https://p9.music.126.net/wrong-song.jpg"}},
        @{@"id":@14,@"album":@{@"picUrl":@"http://p3.music.126.net/fixture/known.jpg"}}]} options:0 error:nil];
    responses[image] = png;
    __block NSUInteger delivered=0; __block NSURL *resolved;
    for (NSUInteger i=0;i<5;i++) [store resolvePlatform:@"wy" trackID:@"14" audioFile:netFile coverURL:nil completion:^(NSURL *url){resolved=url;delivered++;}];
    Check(Wait(^BOOL{return delivered==5;}) && [FMDownloadArtwork isUsableJPEGAtURL:resolved],@"coalesced real JPEG from exact album metadata");
    Check(requests.count==2 && [requests.lastObject isEqual:remote],@"only exact song id/image fetched and HTTPS used");
    NSURLComponents *first = [NSURLComponents componentsWithURL:requests.firstObject resolvingAgainstBaseURL:NO];
    Check([first.queryItems containsObject:[NSURLQueryItem queryItemWithName:@"ids" value:@"[14]"]],@"bounded detail query by ID");
    Check([Resolve(openStore(),@"wy",@"14",netFile,nil) isEqual:resolved] && requests.count==2,@"offline persisted result");
    NSURL *badFile = [downloads URLByAppendingPathComponent:@"wy_99.flac"];
    [plain writeToURL:badFile atomically:YES];
    Check(!Resolve(store,@"wy",@"99",badFile,nil) && requests.count==3,@"mismatched identifiers get no other song art");
    Check(!Resolve(store,@"wy",@"99",badFile,nil) && requests.count==3,@"per-track retry cooldown");
    Check([FMDownloadArtwork isUsableJPEGAtURL:Resolve(store,@"wy",@"99",badFile,remote)] && requests.count==4,@"new exact known cover bypasses failed URL cooldown");
    NSURL *outside = [root URLByAppendingPathComponent:@"wy_51.flac"];
    [tagged writeToURL:outside atomically:YES];
    Check(!Resolve(store,@"wy",@"51",outside,nil) && requests.count==4,@"outside downloads rejected");
    NSURL *linked = [downloads URLByAppendingPathComponent:@"linked.flac"];
    Check([fm createSymbolicLinkAtURL:linked withDestinationURL:outside error:nil],@"fixture link");
    Check(!Resolve(store,@"wy",@"51",linked,nil) && requests.count==4,@"symlink escape rejected");
    NSURL *qq = [downloads URLByAppendingPathComponent:@"qq_14.flac"];
    [plain writeToURL:qq atomically:YES];
    Check(!Resolve(store,@"qq",@"14",qq,[NSURL URLWithString:@"https://unrelated.invalid/ignore"]) && requests.count==4,@"platform isolation, no arbitrary network");
    NSString *qqImage=@"https://y.qq.com/fixture/cover";
    FMTrackMetadataObserveResponse(@{@"id":@"14",@"server":@"qq",@"title":@"authored",@"cover":qqImage});
    responses[qqImage]=png;
    NSURL *qqResult=Resolve(store,@"qq",@"14",qq,nil);
    Check([FMDownloadArtwork isUsableJPEGAtURL:qqResult] && ![resolved isEqual:qqResult] && requests.count==5,@"exact remembered QQ metadata and distinct platform output");
    NSURL *large=[downloads URLByAppendingPathComponent:@"qq_oversize.flac"]; [plain writeToURL:large atomically:YES];
    NSString *oversize=@"https://y.qq.com/oversize"; responses[oversize]=[NSMutableData dataWithLength:8*1024*1024+1];
    Check(!Resolve(store,@"qq",@"oversize",large,[NSURL URLWithString:oversize]),@"oversized transfer rejected");
    NSURL *corrupt=[downloads URLByAppendingPathComponent:@"invalid.png"];
    [[@"unusable" dataUsingEncoding:NSUTF8StringEncoding] writeToURL:corrupt atomically:YES];
    Check(![FMDownloadArtwork isUsableJPEGAtURL:corrupt],@"corrupt artwork fails native validator");
    Check([[NSData dataWithContentsOfURL:netFile] isEqual:plain],@"network recovery left original download byte-identical");
    [fm removeItemAtURL:root error:nil];
    if (argc > 1) {
        NSDictionary *report = @{@"passed":@YES, @"assertion_count":@(passed.count), @"checks":passed.copy};
        NSData *json = [NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:nil];
        NSString *path = [NSString stringWithUTF8String:argv[1]];
        if (!json || ![json writeToFile:path atomically:YES]) { NSLog(@"Could not save artwork verification report"); return 1; }
    }
    puts("download artwork: embedded FLAC and MP3, native sidecar, offline restart, exact-ID URL, platform isolation and bounded recovery passed");
    return 0;
} }
