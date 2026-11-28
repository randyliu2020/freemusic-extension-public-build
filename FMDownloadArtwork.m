#import "FMDownloadArtwork.h"
#import "FMTrackMetadata.h"
#import <AVFoundation/AVFoundation.h>
#import <ImageIO/ImageIO.h>
#import <CommonCrypto/CommonDigest.h>
#import <TargetConditionals.h>
#import <sys/stat.h>

static const NSUInteger FMMaxImage = 8 * 1024 * 1024;
static const NSUInteger FMMaxDetail = 256 * 1024;

static BOOL FMInside(NSURL *file, NSURL *root) {
    if (!file.isFileURL || !root.isFileURL) return NO;
    NSString *path = file.URLByResolvingSymlinksInPath.URLByStandardizingPath.path;
    NSString *base = root.URLByResolvingSymlinksInPath.URLByStandardizingPath.path;
    return base.length && [path hasPrefix:[base stringByAppendingString:@"/"]];
}
static unsigned long long FMRegularSize(NSURL *url) {
    struct stat info;
    if (!url.isFileURL || lstat(url.fileSystemRepresentation, &info) || !S_ISREG(info.st_mode) || info.st_size <= 0) return 0;
    return (unsigned long long)info.st_size;
}
static NSData *FMSmallFile(NSURL *url) {
    unsigned long long size = FMRegularSize(url);
    if (!size || size > FMMaxImage) return nil;
    return [NSData dataWithContentsOfURL:url options:NSDataReadingMappedIfSafe error:nil];
}
static BOOL FMValidSize(CGImageSourceRef source) {
    NSDictionary *p = CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(source, 0, NULL));
    NSUInteger w = [p[(id)kCGImagePropertyPixelWidth] unsignedIntegerValue];
    NSUInteger h = [p[(id)kCGImagePropertyPixelHeight] unsignedIntegerValue];
    return w >= 16 && h >= 16 && w <= 16384 && h <= 16384 && w * (uint64_t)h <= 80000000;
}
static NSData *FMJPEG(NSData *input) {
    if (!input.length || input.length > FMMaxImage) return nil;
    CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)input, NULL);
    if (!source) return nil;
    CGImageRef image = NULL;
    if (CGImageSourceGetCount(source) && CGImageSourceGetStatus(source) == kCGImageStatusComplete && FMValidSize(source)) {
        NSDictionary *options = @{(id)kCGImageSourceCreateThumbnailFromImageAlways:@YES,
                                  (id)kCGImageSourceCreateThumbnailWithTransform:@YES,
                                  (id)kCGImageSourceThumbnailMaxPixelSize:@1024};
        image = CGImageSourceCreateThumbnailAtIndex(source, 0, (__bridge CFDictionaryRef)options);
    }
    CFRelease(source);
    if (!image) return nil;
    NSMutableData *data = NSMutableData.data;
    CGImageDestinationRef out = CGImageDestinationCreateWithData((__bridge CFMutableDataRef)data, CFSTR("public.jpeg"), 1, NULL);
    BOOL ok = NO;
    if (out) {
        CGImageDestinationAddImage(out, image, (__bridge CFDictionaryRef)@{(id)kCGImageDestinationLossyCompressionQuality:@0.87});
        ok = CGImageDestinationFinalize(out);
        CFRelease(out);
    }
    CGImageRelease(image);
    return ok ? data : nil;
}
static BOOL FMValidDiskImage(NSURL *url, BOOL requireJPEG) {
    NSData *bytes = FMSmallFile(url);
    if (!bytes) return NO;
    CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)bytes, NULL);
    if (!source) return NO;
    CFStringRef type = CGImageSourceGetType(source);
    BOOL ok = type && (!requireJPEG || CFEqual(type, CFSTR("public.jpeg"))) && CGImageSourceGetCount(source)
              && CGImageSourceGetStatus(source) == kCGImageStatusComplete && FMValidSize(source);
    if (ok) {
        NSDictionary *options = @{(id)kCGImageSourceCreateThumbnailFromImageAlways:@YES,
                                  (id)kCGImageSourceThumbnailMaxPixelSize:@8,
                                  (id)kCGImageSourceShouldCacheImmediately:@YES};
        CGImageRef thumbnail = CGImageSourceCreateThumbnailAtIndex(source,0,(__bridge CFDictionaryRef)options);
        ok = thumbnail != NULL;
        if (thumbnail) CGImageRelease(thumbnail);
    }
    CFRelease(source);
    return ok;
}

static uint32_t FMRead32(const uint8_t *p) {
    return (uint32_t)p[0]<<24 | (uint32_t)p[1]<<16 | (uint32_t)p[2]<<8 | p[3];
}
static NSData *FMPictureBlock(NSData *block) {
    NSUInteger size = block.length;
    if (size < 32) return nil;
    const uint8_t *p = block.bytes;
    uint32_t kind = FMRead32(p);
    if (kind != 0 && kind != 3) return nil;
    NSUInteger cursor = 4;
    for (int i = 0; i < 2; i++) {
        if (size - cursor < 4) return nil;
        NSUInteger len = FMRead32(p + cursor);
        cursor += 4;
        if (len > size - cursor) return nil;
        cursor += len;
    }
    if (size - cursor < 20) return nil;
    cursor += 16;
    NSUInteger len = FMRead32(p + cursor);
    cursor += 4;
    if (!len || len != size - cursor || len > FMMaxImage) return nil;
    return FMJPEG([block subdataWithRange:NSMakeRange(cursor, len)]);
}
// Read only FLAC metadata headers and the bounded PICTURE block. Some Apple
// decoders expose the audio stream without publishing FLAC album art metadata.
static NSData *FMEmbeddedFLAC(NSURL *url) {
    NSFileHandle *file = [NSFileHandle fileHandleForReadingFromURL:url error:nil];
    if (!file) return nil;
    @try {
        if (![[file readDataOfLength:4] isEqual:[@"fLaC" dataUsingEncoding:NSASCIIStringEncoding]]) return nil;
        NSUInteger offset = 4;
        for (int i = 0; i < 128 && offset < 32 * 1024 * 1024; i++) {
            NSData *header = [file readDataOfLength:4];
            if (header.length != 4) break;
            const uint8_t *p = header.bytes;
            NSUInteger length = (NSUInteger)p[1]<<16 | (NSUInteger)p[2]<<8 | p[3];
            if ((p[0] & 0x7f) == 6 && length <= FMMaxImage + 65536) {
                NSData *data = FMPictureBlock([file readDataOfLength:length]);
                if (data) return data;
            }
            if (p[0] & 0x80) break;
            offset += 4 + length;
            [file seekToFileOffset:offset];
        }
    } @catch (__unused NSException *error) {
    } @finally { [file closeFile]; }
    return nil;
}
static NSData *FMEmbedded(NSURL *file) {
    NSData *flac = FMEmbeddedFLAC(file);
    if (flac) return flac;
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:file options:@{AVURLAssetPreferPreciseDurationAndTimingKey:@NO}];
    NSArray *items = [AVMetadataItem metadataItemsFromArray:asset.commonMetadata filteredByIdentifier:AVMetadataCommonIdentifierArtwork];
    for (AVMetadataItem *item in items) {
        NSData *result = FMJPEG(item.dataValue);
        if (!result && [item.value isKindOfClass:NSDictionary.class]) {
            id bytes = ((NSDictionary *)item.value)[@"data"];
            if ([bytes isKindOfClass:NSData.class]) result = FMJPEG(bytes);
        }
        if (result) return result;
    }
    return nil;
}
static NSString *FMPlatformName(NSString *platform) {
    if (![platform isKindOfClass:NSString.class]) return nil;
    NSString *value = platform.lowercaseString;
    return (@{@"wy":@"wy", @"netease":@"wy", @"qq":@"tx", @"tx":@"tx", @"kg":@"kg", @"kugou":@"kg",
              @"kw":@"kw", @"kuwo":@"kw", @"mg":@"mg", @"migu":@"mg", @"qishui":@"qishui", @"qs":@"qishui"})[value];
}
static NSURL *FMPublicURL(NSURL *url, NSString *platform, BOOL metadata) {
    NSURLComponents *parts = url ? [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO] : nil;
    NSString *host = parts.host.lowercaseString;
    if (!host.length || parts.user || parts.password || parts.port || url.absoluteString.length > 4096 ||
        ![@[@"https",@"http"] containsObject:parts.scheme.lowercaseString]) return nil;
    if (metadata) {
        if (![platform isEqual:@"wy"] || ![host isEqual:@"music.163.com"] ||
            ![@[@"/api/song/detail/", @"/api/song/detail"] containsObject:parts.path]) return nil;
    } else {
        NSDictionary *domains = @{@"wy":@[@"music.126.net",@"music.163.com"], @"tx":@[@"gtimg.cn",@"gtimg.com",@"y.qq.com",@"qqmusic.qq.com"],
                                  @"kg":@[@"kugou.com"], @"kw":@[@"kuwo.cn"], @"mg":@[@"migu.cn"]};
        BOOL match = NO;
        for (NSString *domain in domains[platform]) {
            if ([host isEqual:domain] || [host hasSuffix:[@"." stringByAppendingString:domain]]) { match = YES; break; }
        }
        if (!match) return nil;
    }
    parts.scheme = @"https";
    return parts.URL;
}

// A streaming delegate enforces the byte limit even when Content-Length is
// wrong or absent. Redirects are checked against the original platform policy.
@interface FMArtReader : NSObject <NSURLSessionDataDelegate>
@property (nonatomic, copy) NSString *platform;
@property (nonatomic) BOOL metadata;
@property (nonatomic) NSUInteger limit;
@property (nonatomic, strong) NSMutableData *buffer;
@property (nonatomic, strong) dispatch_semaphore_t done;
@property (nonatomic) BOOL received;
@property (atomic) BOOL succeeded;
@end
@implementation FMArtReader
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task willPerformHTTPRedirection:(NSHTTPURLResponse *)response
        newRequest:(NSURLRequest *)request completionHandler:(void (^)(NSURLRequest *))completionHandler {
    NSURL *url = FMPublicURL(request.URL, self.platform, self.metadata);
    completionHandler(url ? [NSURLRequest requestWithURL:url] : nil);
}
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveResponse:(NSURLResponse *)response
 completionHandler:(void (^)(NSURLSessionResponseDisposition))completionHandler {
    NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)response).statusCode : 0;
    self.received = status == 200 && response.expectedContentLength <= (long long)self.limit;
    completionHandler(self.received ? NSURLSessionResponseAllow : NSURLSessionResponseCancel);
}
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveData:(NSData *)data {
    if (!self.received) return;
    if (data.length > self.limit - self.buffer.length) { self.received = NO; [task cancel]; return; }
    [self.buffer appendData:data];
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    self.succeeded = self.received && !error && self.buffer.length > 0;
    dispatch_semaphore_signal(self.done);
}
@end

@interface FMDownloadArtwork ()
@property (nonatomic, strong) NSURL *directory;
@property (nonatomic, strong) NSURL *downloads;
@property (nonatomic, strong) NSURL *nativeAssets;
@property (nonatomic, strong) NSURL *legacyCache;
@property (nonatomic, strong) NSURLSessionConfiguration *configuration;
@property (nonatomic, strong) NSOperationQueue *workers;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSMutableArray *> *pending;
@property (nonatomic, strong) NSCache<NSString *, NSDate *> *retry;
@end

@implementation FMDownloadArtwork
+ (BOOL)isUsableJPEGAtURL:(NSURL *)file {
    return FMValidDiskImage(file, YES);
}
+ (BOOL)isUsableImageAtURL:(NSURL *)file {
    return FMValidDiskImage(file, NO);
}
+ (instancetype)sharedStore {
    static FMDownloadArtwork *store;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSFileManager *fm = NSFileManager.defaultManager;
        NSURL *support = [fm URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
        NSURL *documents = [fm URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
        store = [[self alloc] initWithDirectory:[support URLByAppendingPathComponent:@"FMDownloadArtwork-v1"]
                                     downloads:[documents URLByAppendingPathComponent:@"Downloads"]
                                 configuration:NSURLSessionConfiguration.ephemeralSessionConfiguration];
    });
    return store;
}
- (instancetype)initWithDirectory:(NSURL *)directory downloads:(NSURL *)downloads configuration:(NSURLSessionConfiguration *)configuration {
    if ((self = [super init])) {
        _directory = directory;
        _downloads = downloads;
        _nativeAssets = [directory.URLByDeletingLastPathComponent URLByAppendingPathComponent:@"DownloadAssets"];
        NSURL *library = directory.URLByDeletingLastPathComponent.URLByDeletingLastPathComponent;
        _legacyCache = [[library URLByAppendingPathComponent:@"Caches"] URLByAppendingPathComponent:@"MusicCache"];
        _configuration = [configuration copy];
        _configuration.HTTPCookieStorage = nil;
        _configuration.HTTPShouldSetCookies = NO;
        _configuration.URLCredentialStorage = nil;
        _configuration.URLCache = nil;
        _configuration.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
        _configuration.timeoutIntervalForRequest = 4;
        _configuration.timeoutIntervalForResource = 6;
        _workers = NSOperationQueue.new;
        _workers.maxConcurrentOperationCount = 2;
        _workers.qualityOfService = NSQualityOfServiceUtility;
        _pending = NSMutableDictionary.dictionary;
        _retry = NSCache.new;
        _retry.countLimit = 512;
    }
    return self;
}
- (NSData *)fetch:(NSURL *)url platform:(NSString *)platform metadata:(BOOL)metadata {
    if (!(url = FMPublicURL(url, platform, metadata))) return nil;
    FMArtReader *reader = FMArtReader.new;
    reader.platform = platform;
    reader.metadata = metadata;
    reader.limit = metadata ? FMMaxDetail : FMMaxImage;
    reader.done = dispatch_semaphore_create(0);
    reader.buffer = NSMutableData.data;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:self.configuration delegate:reader delegateQueue:nil];
    NSURLSessionDataTask *task = [session dataTaskWithURL:url];
    [task resume];
    BOOL completed = dispatch_semaphore_wait(reader.done, dispatch_time(DISPATCH_TIME_NOW, 7 * NSEC_PER_SEC)) == 0;
    [session invalidateAndCancel];
    return completed && reader.succeeded ? reader.buffer.copy : nil;
}
- (NSURL *)detailArtwork:(NSString *)trackID {
    if (!trackID.length || trackID.length > 19 ||
        [trackID rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"0123456789"].invertedSet].location != NSNotFound) return nil;
    NSURLComponents *endpoint = [NSURLComponents componentsWithString:@"https://music.163.com/api/song/detail/"];
    endpoint.queryItems = @[[NSURLQueryItem queryItemWithName:@"id" value:trackID],
                            [NSURLQueryItem queryItemWithName:@"ids" value:[NSString stringWithFormat:@"[%@]",trackID]]];
    NSData *json = [self fetch:endpoint.URL platform:@"wy" metadata:YES];
    id response = json.length ? [NSJSONSerialization JSONObjectWithData:json options:0 error:nil] : nil;
    NSArray *songs = [response isKindOfClass:NSDictionary.class] ? response[@"songs"] : nil;
    if (![songs isKindOfClass:NSArray.class]) return nil;
    for (id song in songs) {
        if (![song isKindOfClass:NSDictionary.class]) continue;
        id number = song[@"id"];
        NSString *identifier = [number isKindOfClass:NSNumber.class] ? [number stringValue] : number;
        if (![identifier isKindOfClass:NSString.class] || ![identifier isEqual:trackID]) continue;
        for (NSString *field in @[@"album",@"al"]) {
            id album = song[field];
            NSString *url = [album isKindOfClass:NSDictionary.class] ? album[@"picUrl"] : nil;
            if ([url isKindOfClass:NSString.class] && url.length) {
                NSURL *safe = FMPublicURL([NSURL URLWithString:url], @"wy", NO);
                if (safe) return safe;
            }
        }
    }
    return nil;
}
- (NSURL *)resolve:(NSString *)source identifier:(NSString *)trackID key:(NSString *)key
             audio:(NSURL *)audio cover:(NSURL *)cover {
    if (!FMRegularSize(audio)) return nil;
    NSURL *destination = [self.directory URLByAppendingPathComponent:[key stringByAppendingPathExtension:@"jpg"]];
    if (FMValidDiskImage(destination,YES)) return destination;
    NSString *observed = FMTrackMetadataForParameters(@{@"id":trackID},source)[@"img"];
    NSMutableArray<NSURL *> *remote = NSMutableArray.array;
    for (NSURL *candidate in @[cover ?: NSNull.null, observed.length ? ([NSURL URLWithString:observed] ?: NSNull.null) : NSNull.null]) {
        if (![candidate isKindOfClass:NSURL.class]) continue;
        NSURL *safe = FMPublicURL(candidate,source,NO);
        if (safe && ![remote containsObject:safe]) [remote addObject:safe];
    }
    NSData *jpeg = nil;
    if (cover.isFileURL && (FMInside(cover,self.downloads) || FMInside(cover,self.nativeAssets) || FMInside(cover,self.legacyCache))) jpeg = FMJPEG(FMSmallFile(cover));
    NSString *basename = audio.lastPathComponent.stringByDeletingPathExtension;
    NSURL *sidecar = [self.nativeAssets URLByAppendingPathComponent:[basename stringByAppendingString:@"_cover.jpg"]];
    if (!jpeg && FMInside(sidecar,self.nativeAssets)) jpeg = FMJPEG(FMSmallFile(sidecar));
    if (!jpeg) jpeg = FMEmbedded(audio);
    for (NSURL *known in remote) {
        if (jpeg) break;
        NSCachedURLResponse *cached = [NSURLCache.sharedURLCache cachedResponseForRequest:[NSURLRequest requestWithURL:known]];
        jpeg = FMJPEG(cached.data);
    }
    // Cool down repeated failures while still allowing local/embedded recovery
    // and a newly supplied exact cover URL. Never persist a negative result.
    NSString *retryKey = [key stringByAppendingString:remote.firstObject.absoluteString ?: @""];
    NSDate *deadline = [self.retry objectForKey:retryKey];
    if (!jpeg && (!deadline || deadline.timeIntervalSinceNow <= 0)) {
        for (NSURL *url in remote) {
            jpeg = FMJPEG([self fetch:url platform:source metadata:NO]);
            if (jpeg) break;
        }
        if (!jpeg && [source isEqual:@"wy"]) {
            NSURL *url = [self detailArtwork:trackID];
            if (url && ![remote containsObject:url]) jpeg = FMJPEG([self fetch:url platform:source metadata:NO]);
        }
        if (!jpeg) [self.retry setObject:[NSDate dateWithTimeIntervalSinceNow:60] forKey:retryKey];
    }
    if (!jpeg || !FMRegularSize(audio)) return nil;
    if (![NSFileManager.defaultManager createDirectoryAtURL:self.directory withIntermediateDirectories:YES attributes:nil error:nil]) return nil;
    [self.directory setResourceValue:@YES forKey:NSURLIsExcludedFromBackupKey error:nil];
    NSDataWritingOptions options = NSDataWritingAtomic;
#if TARGET_OS_IOS
    options |= NSDataWritingFileProtectionCompleteUntilFirstUserAuthentication;
#endif
    return [jpeg writeToURL:destination options:options error:nil] ? destination : nil;
}
- (void)resolvePlatform:(NSString *)platform trackID:(NSString *)trackID audioFile:(NSURL *)audio
               coverURL:(NSURL *)coverURL completion:(void (^)(NSURL *))completion {
    [self resolvePlatform:platform trackID:trackID audioFile:audio coverURL:coverURL registered:NO completion:completion];
}
- (void)resolveRegisteredPlatform:(NSString *)platform trackID:(NSString *)trackID audioFile:(NSURL *)audio
                         coverURL:(NSURL *)coverURL completion:(void (^)(NSURL *))completion {
    [self resolvePlatform:platform trackID:trackID audioFile:audio coverURL:coverURL registered:YES completion:completion];
}
- (void)resolvePlatform:(NSString *)platform trackID:(NSString *)trackID audioFile:(NSURL *)audio
               coverURL:(NSURL *)coverURL registered:(BOOL)registered completion:(void (^)(NSURL *))completion {
    if (!completion) return;
    NSString *source = FMPlatformName(platform);
    BOOL allowedFile = !registered && FMInside(audio,self.downloads);
    if (registered && source && [trackID isKindOfClass:NSString.class] && trackID.length <= 256) {
        NSString *base = [NSString stringWithFormat:@"%@_%@",platform,trackID];
        NSString *name = audio.lastPathComponent.stringByDeletingPathExtension;
        struct stat dir;
        for (NSURL *root in @[self.downloads,self.nativeAssets,self.legacyCache]) {
            if (lstat(root.fileSystemRepresentation,&dir) || !S_ISDIR(dir.st_mode) || !FMInside(audio,root) ||
                ![audio.URLByDeletingLastPathComponent.URLByStandardizingPath.path isEqual:root.URLByStandardizingPath.path]) continue;
            BOOL decoded = [name isEqual:[base stringByAppendingString:@"_playback"]] && [audio.pathExtension.lowercaseString isEqual:@"caf"];
            allowedFile = [name isEqual:base] || decoded;
            break;
        }
    }
    if (!source || ![trackID isKindOfClass:NSString.class] || !trackID.length || trackID.length > 256 ||
        !allowedFile || ![@[@"mp3",@"m4a",@"aac",@"alac",@"mp4",@"flac",@"wav",@"caf",@"aif",@"aiff",@"aifc",@"ogg",@"oga",@"opus",@"ape",@"wv",@"mpc",@"tta",@"spx",@"wma",@"amr",@"dsf",@"dff"] containsObject:audio.pathExtension.lowercaseString]) {
        dispatch_async(dispatch_get_main_queue(),^{completion(nil);}); return;
    }
    if ([source isEqual:@"kg"]) trackID = trackID.uppercaseString;
    NSData *identity = [[NSString stringWithFormat:@"%@\n%@",source,trackID] dataUsingEncoding:NSUTF8StringEncoding];
    unsigned char hash[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(identity.bytes,(CC_LONG)identity.length,hash);
    NSMutableString *key = NSMutableString.string;
    for (NSUInteger i = 0; i < sizeof hash; i++) [key appendFormat:@"%02x",hash[i]];
    @synchronized (self.pending) {
        if (self.pending[key]) { [self.pending[key] addObject:[completion copy]]; return; }
        if (self.pending.count >= 32) { dispatch_async(dispatch_get_main_queue(),^{completion(nil);}); return; }
        self.pending[key] = [NSMutableArray arrayWithObject:[completion copy]];
    }
    [self.workers addOperationWithBlock:^{
        NSURL *result = nil;
        @try { result = [self resolve:source identifier:trackID key:key audio:audio cover:coverURL]; }
        @catch (__unused NSException *exception) {}
        NSArray *callbacks;
        @synchronized (self.pending) { callbacks = [self.pending[key] copy]; [self.pending removeObjectForKey:key]; }
        dispatch_async(dispatch_get_main_queue(),^{ for (void (^callback)(NSURL *) in callbacks) callback(result); });
    }];
}
@end
