#import "FMLockScreen.h"
#import <MediaPlayer/MediaPlayer.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreVideo/CoreVideo.h>
#import <CommonCrypto/CommonDigest.h>
#import <objc/runtime.h>
#import <stdatomic.h>
#import <stdbool.h>
#import <math.h>

#if __IPHONE_OS_VERSION_MAX_ALLOWED < 260000
#error FMLockScreen requires the public iPhoneOS 26 SDK or newer; do not substitute private declarations.
#endif

// Static cover -> gentle motion, not a publisher-provided animated album cover.
static NSString *const FMEnabledKey = @"FMX.dynamicArtwork";
static const NSInteger FMFramesPerSecond = 20;
static const NSInteger FMFrameCount = 120;
static const NSUInteger FMCacheByteLimit = 32 * 1024 * 1024;
static const NSUInteger FMClipByteLimit = 4 * 1024 * 1024;
static const NSUInteger FMCacheFileLimit = 24;
static char FMOwnedArtworkKey;
static atomic_bool FMRenderAllowed = true;
#if defined(FMX_LOCKSCREEN_TESTING)
static atomic_int FMTestSystemAllowed = -1;
#endif
static void (*FMOriginalSetInfo)(id, SEL, NSDictionary *);
static dispatch_queue_t FMRenderQueue;
static dispatch_queue_t FMPrepareQueue;

static NSError *FMError(NSInteger code, NSString *text) {
    return [NSError errorWithDomain:@"FMX.DynamicArtwork" code:code userInfo:@{NSLocalizedDescriptionKey:text}];
}

static CGSize FMSize(BOOL portrait) { return portrait ? CGSizeMake(720, 960) : CGSizeMake(720, 720); }

static NSString *FMHash(NSData *data) {
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
    NSMutableString *result = [NSMutableString stringWithCapacity:64];
    for (NSUInteger i = 0; i < sizeof(digest); i++) [result appendFormat:@"%02x", digest[i]];
    return result;
}

static UIImage *FMNormalizedSource(UIImage *source) {
    if (!source || !isfinite(source.size.width) || !isfinite(source.size.height)
        || source.size.width < 1 || source.size.height < 1) return nil;
    CGFloat ratio = MIN(1.0, 1024.0 / MAX(source.size.width, source.size.height));
    CGSize size = CGSizeMake(MAX(1, floor(source.size.width * ratio)), MAX(1, floor(source.size.height * ratio)));
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat defaultFormat];
    format.scale = 1; format.opaque = YES;
    return [[[UIGraphicsImageRenderer alloc] initWithSize:size format:format] imageWithActions:^(UIGraphicsImageRendererContext *context) {
        [UIColor.blackColor setFill]; UIRectFill((CGRect){CGPointZero, size});
        [source drawInRect:(CGRect){CGPointZero, size}];
    }];
}

// The same drawing function produces preview and video frames. The periodic
// trajectory has no discontinuity at the loop boundary and never distorts art.
static void FMDrawFrame(CGContextRef context, CGImageRef image, CGSize target, double phase) {
    CGContextSetRGBFillColor(context, 0, 0, 0, 1);
    CGContextFillRect(context, (CGRect){CGPointZero, target});
    CGFloat width = CGImageGetWidth(image), height = CGImageGetHeight(image);
    CGFloat zoom = 1.035 + 0.025 * (1.0 - cos(phase)) * 0.5;
    CGFloat scale = MAX(target.width / width, target.height / height) * zoom;
    CGSize drawn = CGSizeMake(width * scale, height * scale);
    // Pan is bounded by the spare pixels, so no exposed border can appear.
    CGFloat dx = (drawn.width - target.width) * 0.22 * sin(phase);
    CGFloat dy = (drawn.height - target.height) * 0.18 * sin(phase * 2.0);
    CGRect rect = CGRectMake((target.width - drawn.width) / 2 + dx,
                             (target.height - drawn.height) / 2 + dy, drawn.width, drawn.height);
    CGContextSetInterpolationQuality(context, kCGInterpolationHigh);
    CGContextDrawImage(context, rect, image);
}

static UIImage *FMPreview(UIImage *source, BOOL portrait) {
    if (!source.CGImage) return nil;
    CGSize size = FMSize(portrait);
    CGColorSpaceRef color = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(NULL, size.width, size.height, 8, (size_t)size.width * 4,
        color, kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst);
    CGColorSpaceRelease(color);
    if (!context) return nil;
    FMDrawFrame(context, source.CGImage, size, 0);
    CGImageRef frame = CGBitmapContextCreateImage(context);
    UIImage *image = frame ? [UIImage imageWithCGImage:frame scale:1 orientation:UIImageOrientationUp] : nil;
    if (frame) CGImageRelease(frame);
    CGContextRelease(context);
    return image;
}

// Called only on the serial utility render queue. Every exit closes/cancels the
// writer. A hard time budget is below the system artwork-request timeout.
static BOOL FMWriteLoop(UIImage *source, BOOL portrait, NSURL *url, BOOL (^keepGoing)(void), NSError **outError) {
    NSError *error = nil;
    if (!source.CGImage || !url.isFileURL || [NSFileManager.defaultManager fileExistsAtPath:url.path]) {
        if (outError) *outError = FMError(1, @"Invalid source or output already exists");
        return NO;
    }
    if (!keepGoing()) { if (outError) *outError = FMError(2, @"Artwork request cancelled"); return NO; }
    CGSize size = FMSize(portrait);
    AVAssetWriter *writer = [[AVAssetWriter alloc] initWithURL:url fileType:AVFileTypeMPEG4 error:&error];
    NSDictionary *settings = @{AVVideoCodecKey:AVVideoCodecTypeH264,
        AVVideoWidthKey:@((NSInteger)size.width), AVVideoHeightKey:@((NSInteger)size.height),
        AVVideoCompressionPropertiesKey:@{AVVideoAverageBitRateKey:@1200000,
            AVVideoExpectedSourceFrameRateKey:@(FMFramesPerSecond),
            AVVideoMaxKeyFrameIntervalKey:@(FMFramesPerSecond * 2),
            AVVideoProfileLevelKey:AVVideoProfileLevelH264MainAutoLevel}};
    AVAssetWriterInput *input = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo outputSettings:settings];
    input.expectsMediaDataInRealTime = NO;
    NSDictionary *attributes = @{(id)kCVPixelBufferPixelFormatTypeKey:@(kCVPixelFormatType_32BGRA),
        (id)kCVPixelBufferWidthKey:@((NSInteger)size.width), (id)kCVPixelBufferHeightKey:@((NSInteger)size.height),
        (id)kCVPixelBufferCGImageCompatibilityKey:@YES, (id)kCVPixelBufferCGBitmapContextCompatibilityKey:@YES};
    AVAssetWriterInputPixelBufferAdaptor *adaptor = [AVAssetWriterInputPixelBufferAdaptor assetWriterInputPixelBufferAdaptorWithAssetWriterInput:input sourcePixelBufferAttributes:attributes];
    if (!writer || ![writer canAddInput:input]) {
        if (outError) *outError = error ?: FMError(3, @"Video encoder unavailable"); return NO;
    }
    [writer addInput:input];
    if (![writer startWriting]) { if (outError) *outError = writer.error ?: FMError(3, @"Video encoder failed to start"); return NO; }
    [writer startSessionAtSourceTime:kCMTimeZero];
    NSTimeInterval deadline = NSProcessInfo.processInfo.systemUptime + 20;
    CGColorSpaceRef color = CGColorSpaceCreateDeviceRGB();
    BOOL success = YES;
    for (NSInteger frame = 0; frame < FMFrameCount && success; frame++) {
        @autoreleasepool {
            while (!input.readyForMoreMediaData && writer.status == AVAssetWriterStatusWriting
                   && keepGoing() && NSProcessInfo.processInfo.systemUptime < deadline) {
                [NSThread sleepForTimeInterval:0.003];
            }
            if (!keepGoing() || NSProcessInfo.processInfo.systemUptime >= deadline
                || writer.status != AVAssetWriterStatusWriting || !input.readyForMoreMediaData) {
                error = writer.error ?: FMError(4, @"Artwork cancelled or encoding deadline reached"); success = NO; break;
            }
            CVPixelBufferRef buffer = NULL;
            CVReturn status = adaptor.pixelBufferPool ? CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, adaptor.pixelBufferPool, &buffer) : kCVReturnError;
            if (status != kCVReturnSuccess || !buffer) { error = FMError(5, @"Video buffer allocation failed"); success = NO; break; }
            CVPixelBufferLockBaseAddress(buffer, 0);
            CGContextRef context = CGBitmapContextCreate(CVPixelBufferGetBaseAddress(buffer), (size_t)size.width,
                (size_t)size.height, 8, CVPixelBufferGetBytesPerRow(buffer), color,
                kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst);
            if (context) {
                FMDrawFrame(context, source.CGImage, size, 2.0 * M_PI * frame / FMFrameCount);
                CGContextRelease(context);
            } else { error = FMError(6, @"Video rendering context unavailable"); success = NO; }
            CVPixelBufferUnlockBaseAddress(buffer, 0);
            if (success && ![adaptor appendPixelBuffer:buffer withPresentationTime:CMTimeMake(frame, (int32_t)FMFramesPerSecond)]) {
                error = writer.error ?: FMError(7, @"Video frame append failed"); success = NO;
            }
            CVPixelBufferRelease(buffer);
        }
    }
    CGColorSpaceRelease(color);
    if (success) {
        [writer endSessionAtSourceTime:CMTimeMake(FMFrameCount, (int32_t)FMFramesPerSecond)];
        [input markAsFinished];
        dispatch_semaphore_t finished = dispatch_semaphore_create(0);
        [writer finishWritingWithCompletionHandler:^{ dispatch_semaphore_signal(finished); }];
        if (dispatch_semaphore_wait(finished, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)) != 0
            || writer.status != AVAssetWriterStatusCompleted || !keepGoing()) {
            error = writer.error ?: FMError(8, @"Artwork completion cancelled or timed out"); success = NO;
        }
    }
    if (!success) {
        [writer cancelWriting];
        [NSFileManager.defaultManager removeItemAtURL:url error:nil];
    } else {
        NSNumber *bytes = nil;
        [url getResourceValue:&bytes forKey:NSURLFileSizeKey error:nil];
        if (bytes.unsignedLongLongValue == 0 || bytes.unsignedLongLongValue > FMClipByteLimit) {
            [NSFileManager.defaultManager removeItemAtURL:url error:nil];
            error = FMError(9, @"Artwork video exceeds cache budget"); success = NO;
        }
    }
    if (!success && outError) *outError = error ?: FMError(10, @"Artwork generation failed");
    return success;
}

@class FMVideoCache;
@interface FMVideoLease : NSObject
@property(nonatomic, strong) NSURL *url;
@property(nonatomic, weak) FMVideoCache *cache;
@end

@interface FMVideoCache : NSObject
@property(nonatomic, strong) NSURL *directory;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *pins;
+ (instancetype)shared;
- (nullable FMVideoLease *)leaseForURL:(NSURL *)url;
- (void)releaseURL:(NSURL *)url;
- (BOOL)makeRoom;
@end

@implementation FMVideoLease
- (void)dealloc { [_cache releaseURL:_url]; }
@end

@implementation FMVideoCache
+ (instancetype)shared { static FMVideoCache *value; static dispatch_once_t once; dispatch_once(&once, ^{ value = [FMVideoCache new]; }); return value; }
- (instancetype)init {
    if ((self = [super init])) {
        _pins = NSMutableDictionary.dictionary;
        NSURL *base = [NSFileManager.defaultManager URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask].firstObject;
        _directory = [base URLByAppendingPathComponent:@"FMXDynamicArtwork-v1" isDirectory:YES];
        NSError *error = nil;
        if (!base || ![NSFileManager.defaultManager createDirectoryAtURL:_directory withIntermediateDirectories:YES
            attributes:@{NSFileProtectionKey:NSFileProtectionCompleteUntilFirstUserAuthentication} error:&error]) _directory = nil;
        [_directory setResourceValue:@YES forKey:NSURLIsExcludedFromBackupKey error:nil];
    }
    return self;
}
- (FMVideoLease *)leaseForURL:(NSURL *)url {
    @synchronized (self) {
        if (!self.directory || ![url.URLByDeletingLastPathComponent.path isEqual:self.directory.path]) return nil;
        [url removeAllCachedResourceValues];
        NSNumber *regular = nil, *bytes = nil;
        [url getResourceValue:&regular forKey:NSURLIsRegularFileKey error:nil];
        [url getResourceValue:&bytes forKey:NSURLFileSizeKey error:nil];
        if (!regular.boolValue || bytes.unsignedLongLongValue < 1 || bytes.unsignedLongLongValue > FMClipByteLimit) {
            if (regular.boolValue && ![self.pins[url.path] unsignedIntegerValue]) {
                [NSFileManager.defaultManager removeItemAtURL:url error:nil];
            }
            return nil;
        }
        self.pins[url.path] = @([self.pins[url.path] unsignedIntegerValue] + 1);
        [NSFileManager.defaultManager setAttributes:@{NSFileModificationDate:NSDate.date} ofItemAtPath:url.path error:nil];
        FMVideoLease *lease = [FMVideoLease new]; lease.url = url; lease.cache = self; return lease;
    }
}
- (void)releaseURL:(NSURL *)url {
    @synchronized (self) {
        NSUInteger count = [self.pins[url.path] unsignedIntegerValue];
        if (count <= 1) [self.pins removeObjectForKey:url.path]; else self.pins[url.path] = @(count - 1);
    }
}
- (BOOL)makeRoom {
    @synchronized (self) {
        if (!self.directory) return NO;
        NSArray<NSURL *> *files = [NSFileManager.defaultManager contentsOfDirectoryAtURL:self.directory
            includingPropertiesForKeys:@[NSURLIsRegularFileKey, NSURLFileSizeKey, NSURLContentModificationDateKey]
            options:NSDirectoryEnumerationSkipsHiddenFiles error:nil];
        NSMutableArray<NSDictionary *> *candidates = NSMutableArray.array;
        NSUInteger total = 0, count = 0;
        for (NSURL *url in files) {
            NSNumber *regular = nil, *bytes = nil; NSDate *date = nil;
            [url getResourceValue:&regular forKey:NSURLIsRegularFileKey error:nil];
            [url getResourceValue:&bytes forKey:NSURLFileSizeKey error:nil];
            [url getResourceValue:&date forKey:NSURLContentModificationDateKey error:nil];
            if (!regular.boolValue || ![url.pathExtension isEqual:@"mp4"]) continue;
            total += bytes.unsignedIntegerValue; count++;
            if (![self.pins[url.path] unsignedIntegerValue]) [candidates addObject:@{ @"url":url, @"bytes":bytes ?: @0, @"date":date ?: NSDate.distantPast }];
        }
        [candidates sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) { return [a[@"date"] compare:b[@"date"]]; }];
        for (NSDictionary *entry in candidates) {
            if (total + FMClipByteLimit <= FMCacheByteLimit && count < FMCacheFileLimit) break;
            if ([NSFileManager.defaultManager removeItemAtURL:entry[@"url"] error:nil]) { total -= [entry[@"bytes"] unsignedIntegerValue]; count--; }
        }
        return total + FMClipByteLimit <= FMCacheByteLimit && count < FMCacheFileLimit;
    }
}
@end

@interface FMAnimatedSource : NSObject
@property(nonatomic, strong) UIImage *image;
@property(nonatomic, strong) UIImage *squarePreview;
@property(nonatomic, strong) UIImage *portraitPreview;
@property(nonatomic, copy) NSString *digest;
@property(atomic) BOOL active;
@property(atomic, copy) NSString *lastVideoError;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSMutableArray *> *pending;
@property(nonatomic, strong) NSMutableDictionary<NSString *, FMVideoLease *> *leases;
- (void)requestPortrait:(BOOL)portrait completion:(void (^)(NSURL * _Nullable))completion;
@end

@implementation FMAnimatedSource
- (instancetype)init { if ((self = [super init])) { _pending = NSMutableDictionary.dictionary; _leases = NSMutableDictionary.dictionary; _active = YES; } return self; }
- (void)requestPortrait:(BOOL)portrait completion:(void (^)(NSURL *))completion {
    if (!self.active || !atomic_load(&FMRenderAllowed)) { completion(nil); return; }
    NSString *variant = portrait ? @"portrait" : @"square";
    NSURL *ready = nil; BOOL start = NO;
    NSTimeInterval requestDeadline = NSProcessInfo.processInfo.systemUptime + 24;
    @synchronized (self) {
        ready = self.leases[variant].url;
        if (!ready) {
            NSMutableArray *waiters = self.pending[variant];
            if (!waiters) { waiters = NSMutableArray.array; self.pending[variant] = waiters; start = YES; }
            [waiters addObject:[completion copy]];
        }
    }
    if (ready) { completion(ready); return; }
    if (!start) return;
    dispatch_async(FMRenderQueue, ^{
        @autoreleasepool {
            FMVideoCache *cache = FMVideoCache.shared;
            NSURL *final = [cache.directory URLByAppendingPathComponent:[NSString stringWithFormat:@"%@-%@-v1.mp4", self.digest, variant]];
            FMVideoLease *lease = nil;
            if (self.active && atomic_load(&FMRenderAllowed)) lease = [cache leaseForURL:final];
            if (!lease && self.active && atomic_load(&FMRenderAllowed) && [cache makeRoom]) {
                NSURL *temporary = [cache.directory URLByAppendingPathComponent:[NSString stringWithFormat:@"partial-%@.mp4", NSUUID.UUID.UUIDString]];
                NSError *error = nil;
                BOOL success = FMWriteLoop(self.image, portrait, temporary, ^BOOL{
                    return self.active && atomic_load(&FMRenderAllowed)
                        && NSProcessInfo.processInfo.systemUptime < requestDeadline;
                }, &error);
                self.lastVideoError = success ? nil : error.localizedDescription;
                if (success && self.active && atomic_load(&FMRenderAllowed)) {
                    if ([NSFileManager.defaultManager moveItemAtURL:temporary toURL:final error:nil]) {
                        [NSFileManager.defaultManager setAttributes:@{NSFileProtectionKey:NSFileProtectionCompleteUntilFirstUserAuthentication} ofItemAtPath:final.path error:nil];
                    }
                    lease = [cache leaseForURL:final];
                    if (!lease) self.lastVideoError = @"动态封面缓存未能写入，继续使用静态封面";
                }
                [NSFileManager.defaultManager removeItemAtURL:temporary error:nil];
            }
            NSArray *waiters = nil;
            @synchronized (self) {
                if (lease) self.leases[variant] = lease; // Pin before handing URL to the system.
                waiters = [self.pending[variant] copy]; [self.pending removeObjectForKey:variant];
            }
            NSURL *url = self.active && atomic_load(&FMRenderAllowed) ? lease.url : nil;
            for (id callback in waiters) {
                void (^waiter)(NSURL *) = callback;
                waiter(url); // exactly once per request
            }
        }
    });
}
@end

@interface FMLockCoordinator : NSObject
@property(nonatomic, weak) MPNowPlayingInfoCenter *center;
@property(nonatomic, copy) NSDictionary *rawInfo;
@property(nonatomic, copy) NSString *trackKey;
@property(nonatomic, strong) MPMediaItemArtwork *staticArtwork;
@property(nonatomic, strong) MPMediaItemArtwork *checkedArtwork;
@property(nonatomic, strong) FMAnimatedSource *source;
@property(nonatomic, copy) NSDictionary *animated;
@property(nonatomic) NSUInteger generation;
@property(nonatomic) NSUInteger artworkRevision;
@property(nonatomic) BOOL preparing;
@property(nonatomic) BOOL failed;
@property(nonatomic) BOOL enabled;
@property(nonatomic) BOOL allowed;
@property(nonatomic, copy) NSString *lastError;
@property(nonatomic, copy) NSArray<NSString *> *supported;
- (void)publish:(NSDictionary *)info center:(MPNowPlayingInfoCenter *)center;
- (void)startPreparationIfNeeded;
- (void)prepare:(MPMediaItemArtwork *)artwork generation:(NSUInteger)generation revision:(NSUInteger)revision;
- (void)finishPreparation:(nullable FMAnimatedSource *)source artwork:(MPMediaItemArtwork *)artwork
    generation:(NSUInteger)generation revision:(NSUInteger)revision error:(nullable NSString *)error;
- (NSDictionary *)mergedInfo;
- (void)reset;
- (void)refresh;
@end

static FMLockCoordinator *FMCoordinator;

static NSArray<NSString *> *FMAnimatedKeys(void) API_AVAILABLE(ios(26.0)) {
    return @[MPNowPlayingInfoProperty1x1AnimatedArtwork, MPNowPlayingInfoProperty3x4AnimatedArtwork];
}

static NSDictionary *FMCleanOwnedKeys(NSDictionary *info) {
    if (!info) return nil;
    NSMutableDictionary *clean = [info mutableCopy];
    if (@available(iOS 26.0, *)) {
        for (NSString *key in FMAnimatedKeys()) {
            id value = clean[key];
            if (value && [objc_getAssociatedObject(value, &FMOwnedArtworkKey) boolValue]) [clean removeObjectForKey:key];
        }
    }
    return clean;
}

static NSString *FMTrackKey(NSDictionary *info) {
    id external = info[MPNowPlayingInfoPropertyExternalContentIdentifier];
    if ([external isKindOfClass:NSString.class] && [external length]) return [@"external:" stringByAppendingString:external];
    id persistent = info[MPMediaItemPropertyPersistentID];
    if ([persistent isKindOfClass:NSNumber.class] && [persistent unsignedLongLongValue]) return [@"persistent:" stringByAppendingString:[persistent stringValue]];
    // The inspected host provides an external ID. This fallback is for hosts
    // without one; length-prefix fields so different metadata cannot collide.
    NSMutableString *key = [NSMutableString stringWithString:@"metadata:"];
    for (NSString *field in @[MPMediaItemPropertyTitle, MPMediaItemPropertyArtist,
        MPMediaItemPropertyAlbumTitle, MPMediaItemPropertyPlaybackDuration]) {
        id value = info[field];
        NSString *text = [value isKindOfClass:NSString.class] ? value : ([value isKindOfClass:NSNumber.class] ? [value stringValue] : @"");
        [key appendFormat:@"%lu:%@;", (unsigned long)text.length, text];
    }
    return key;
}

@implementation FMLockCoordinator
- (NSDictionary *)mergedInfo {
    if (!self.rawInfo) return nil;
    if (!self.enabled || !self.allowed || !self.animated.count) return self.rawInfo;
    NSMutableDictionary *merged = [self.rawInfo mutableCopy];
    for (NSString *key in self.animated) if (!merged[key]) merged[key] = self.animated[key];
    return merged;
}
- (void)reset {
    self.generation++; self.source.active = NO; self.source = nil; self.animated = nil;
    self.trackKey = nil; self.staticArtwork = nil; self.checkedArtwork = nil;
    self.artworkRevision++; self.preparing = NO; self.failed = NO; self.lastError = nil;
}
- (void)publish:(NSDictionary *)info center:(MPNowPlayingInfoCenter *)center {
    @synchronized (self) {
        NSDictionary *raw = FMCleanOwnedKeys(info);
        self.rawInfo = raw; self.center = center;
        BOOL hostAnimated = NO;
        if (@available(iOS 26.0, *)) for (NSString *key in FMAnimatedKeys()) if (raw[key]) hostAnimated = YES;
        MPMediaItemArtwork *artwork = raw[MPMediaItemPropertyArtwork];
        if (![artwork isKindOfClass:MPMediaItemArtwork.class]) artwork = nil;
        BOOL usable = self.enabled && self.allowed && self.supported.count && artwork && !hostAnimated;
        NSString *trackKey = usable ? FMTrackKey(raw) : nil;
        if (!usable || ![self.trackKey isEqual:trackKey]) [self reset];
        if (usable) {
            self.trackKey = trackKey;
            if (self.staticArtwork != artwork) {
                self.staticArtwork = artwork; self.artworkRevision++; self.failed = NO;
            }
        }
        // Serializing original setter calls under this lock prevents a completed
        // older preparation from publishing stale track metadata over a new song.
        FMOriginalSetInfo(center, @selector(setNowPlayingInfo:), [self mergedInfo]);
        if (usable) [self startPreparationIfNeeded];
    }
}
- (void)startPreparationIfNeeded {
    if (!self.enabled || !self.allowed || self.preparing || !self.staticArtwork || self.checkedArtwork == self.staticArtwork) return;
    self.preparing = YES;
    MPMediaItemArtwork *artwork = self.staticArtwork;
    NSUInteger generation = self.generation, revision = self.artworkRevision;
    dispatch_async(dispatch_get_main_queue(), ^{ [self prepare:artwork generation:generation revision:revision]; });
}
- (void)prepare:(MPMediaItemArtwork *)artwork generation:(NSUInteger)generation revision:(NSUInteger)revision {
    @synchronized (self) {
        if (generation != self.generation || !self.enabled || !self.allowed) return;
        if (revision != self.artworkRevision) {
            self.preparing = NO; [self startPreparationIfNeeded]; return;
        }
    }
    UIImage *image = nil;
    @try {
        CGSize bounds = artwork.bounds.size;
        if (isfinite(bounds.width) && isfinite(bounds.height) && bounds.width >= 1 && bounds.height >= 1) {
            CGFloat scale = MIN(1.0, 1024.0 / MAX(bounds.width, bounds.height));
            image = [artwork imageWithSize:CGSizeMake(MAX(1, floor(bounds.width * scale)), MAX(1, floor(bounds.height * scale)))];
        }
    } @catch (NSException *exception) { image = nil; }
    if (!image) { [self finishPreparation:nil artwork:artwork generation:generation revision:revision
        error:@"静态封面暂不可用，继续使用原播放器封面"]; return; }
    dispatch_async(FMPrepareQueue, ^{
        @autoreleasepool {
            @synchronized (self) {
                if (generation != self.generation) return;
                if (revision != self.artworkRevision) {
                    dispatch_async(dispatch_get_main_queue(), ^{ [self finishPreparation:nil artwork:artwork generation:generation revision:revision error:nil]; });
                    return;
                }
            }
            FMAnimatedSource *source = [FMAnimatedSource new];
            source.image = FMNormalizedSource(image);
            NSData *pixels = source.image ? UIImagePNGRepresentation(source.image) : nil;
            source.digest = pixels ? FMHash(pixels) : nil;
            source.squarePreview = FMPreview(source.image, NO);
            source.portraitPreview = FMPreview(source.image, YES);
            dispatch_async(dispatch_get_main_queue(), ^{
                [self finishPreparation:source artwork:artwork generation:generation revision:revision error:nil];
            });
        }
    });
}
- (void)finishPreparation:(FMAnimatedSource *)source artwork:(MPMediaItemArtwork *)artwork
    generation:(NSUInteger)generation revision:(NSUInteger)revision error:(NSString *)error {
    @synchronized (self) {
        if (generation != self.generation || !self.enabled || !self.allowed) { source.active = NO; return; }
        self.preparing = NO;
        if (revision != self.artworkRevision) {
            source.active = NO; [self startPreparationIfNeeded]; return;
        }
        self.checkedArtwork = artwork;
        if (!source.digest || !source.squarePreview || !source.portraitPreview) {
            source.active = NO; self.source.active = NO; self.source = nil; self.animated = nil;
            self.failed = YES; self.lastError = error ?: @"封面预览生成失败，继续使用静态封面";
            MPNowPlayingInfoCenter *center = self.center;
            if (center) FMOriginalSetInfo(center, @selector(setNowPlayingInfo:), self.rawInfo);
            return;
        }
        self.failed = NO; self.lastError = nil;
        if ([self.source.digest isEqual:source.digest]) {
            source.active = NO; // Preserve existing animated identity, files and in-flight video.
            return;
        }
        if (@available(iOS 26.0, *)) {
            NSMutableDictionary *entries = NSMutableDictionary.dictionary;
            for (NSString *key in self.supported) {
                BOOL portrait = [key isEqual:MPNowPlayingInfoProperty3x4AnimatedArtwork];
                if (!portrait && ![key isEqual:MPNowPlayingInfoProperty1x1AnimatedArtwork]) continue;
                NSString *identifier = [NSString stringWithFormat:@"fmx-motion-v1-%@-%@", source.digest, portrait ? @"3x4" : @"1x1"];
                UIImage *preview = portrait ? source.portraitPreview : source.squarePreview;
                MPMediaItemAnimatedArtwork *animated = [[MPMediaItemAnimatedArtwork alloc] initWithArtworkID:identifier
                    previewImageRequestHandler:^(CGSize requested, void (^completion)(UIImage *)) { completion(preview); }
                    videoAssetFileURLRequestHandler:^(CGSize requested, void (^completion)(NSURL *)) { [source requestPortrait:portrait completion:completion]; }];
                objc_setAssociatedObject(animated, &FMOwnedArtworkKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                entries[key] = animated;
            }
            self.source.active = NO;
            self.source = source; self.animated = entries;
            MPNowPlayingInfoCenter *center = self.center;
            if (center) FMOriginalSetInfo(center, @selector(setNowPlayingInfo:), [self mergedInfo]);
        }
    }
}
- (void)refresh {
    NSAssert(NSThread.isMainThread, @"Refresh on main thread");
    BOOL allowed = !NSProcessInfo.processInfo.lowPowerModeEnabled
        && NSProcessInfo.processInfo.thermalState < NSProcessInfoThermalStateSerious
        && !UIAccessibilityIsReduceMotionEnabled();
#if defined(FMX_LOCKSCREEN_TESTING)
    int override = atomic_load(&FMTestSystemAllowed);
    if (override >= 0) allowed = override != 0;
#endif
    BOOL enabled = [NSUserDefaults.standardUserDefaults boolForKey:FMEnabledKey];
    atomic_store(&FMRenderAllowed, allowed && enabled);
    @synchronized (self) {
        if (self.enabled == enabled && self.allowed == allowed) return;
        self.enabled = enabled; self.allowed = allowed;
        NSDictionary *raw = self.rawInfo; MPNowPlayingInfoCenter *center = self.center;
        [self reset];
        if (center) [self publish:raw center:center];
    }
}
@end

static void FMInterceptSetInfo(MPNowPlayingInfoCenter *center, SEL selector, NSDictionary *info) {
    if (center != MPNowPlayingInfoCenter.defaultCenter || !FMCoordinator) { FMOriginalSetInfo(center, selector, info); return; }
    [FMCoordinator publish:info center:center];
}

void FMLockScreenInstall(void) {
    if (!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(), ^{ FMLockScreenInstall(); }); return; }
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        [NSUserDefaults.standardUserDefaults registerDefaults:@{FMEnabledKey:@YES}];
        FMRenderQueue = dispatch_queue_create("app.fmx.artwork.video", dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0));
        FMPrepareQueue = dispatch_queue_create("app.fmx.artwork.preview", dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0));
        FMCoordinator = [FMLockCoordinator new];
        if (@available(iOS 26.0, *)) FMCoordinator.supported = MPNowPlayingInfoCenter.supportedAnimatedArtworkKeys;
        else FMCoordinator.supported = @[];
        [FMCoordinator refresh];
        if (!FMCoordinator.supported.count) return; // iOS <26 stays completely untouched.
        Method method = class_getInstanceMethod(MPNowPlayingInfoCenter.class, @selector(setNowPlayingInfo:));
        if (!method) { FMCoordinator.lastError = @"系统封面接口不可用"; return; }
        // Publish the predecessor before exposing the hook to other threads.
        FMOriginalSetInfo = (void (*)(id, SEL, NSDictionary *))method_getImplementation(method);
        method_setImplementation(method, (IMP)FMInterceptSetInfo);
        NSNotificationCenter *notifications = NSNotificationCenter.defaultCenter;
        for (NSNotificationName name in @[NSUserDefaultsDidChangeNotification, NSProcessInfoPowerStateDidChangeNotification,
            NSProcessInfoThermalStateDidChangeNotification, UIAccessibilityReduceMotionStatusDidChangeNotification]) {
            [notifications addObserverForName:name object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *notification) { [FMCoordinator refresh]; }];
        }
        NSDictionary *current = MPNowPlayingInfoCenter.defaultCenter.nowPlayingInfo;
        if (current) [FMCoordinator publish:current center:MPNowPlayingInfoCenter.defaultCenter];
    });
}

void FMLockScreenRefresh(void) {
    dispatch_async(dispatch_get_main_queue(), ^{ FMLockScreenInstall(); [FMCoordinator refresh]; });
}

NSDictionary<NSString *, id> *FMLockScreenStatus(void) {
    FMLockCoordinator *coordinator = FMCoordinator;
    if (!coordinator) return @{ @"installed":@NO };
    @synchronized (coordinator) {
        return @{ @"installed":@(FMOriginalSetInfo != NULL), @"supported":@(coordinator.supported.count > 0),
            @"enabled":@(coordinator.enabled), @"generationAllowed":@(atomic_load(&FMRenderAllowed)),
            @"prepared":@(coordinator.source != nil), @"preparing":@(coordinator.preparing),
            @"keys":coordinator.supported ?: @[], @"error":coordinator.lastError ?: @"",
            @"videoError":coordinator.source.lastVideoError ?: @"",
            @"origin":@"静态封面在手机本地生成轻微动态效果，并非唱片官方动画" };
    }
}

#if defined(FMX_LOCKSCREEN_TESTING)
void FMLockScreenTestSetSystemAllowed(NSNumber *allowed) {
    atomic_store(&FMTestSystemAllowed, allowed ? (allowed.boolValue ? 1 : 0) : -1);
    FMLockScreenRefresh();
}
UIImage *FMLockScreenTestPreview(UIImage *image, BOOL portrait) { return FMPreview(FMNormalizedSource(image), portrait); }
void FMLockScreenTestWriteMovie(UIImage *image, BOOL portrait, NSURL *outputURL,
    BOOL (^shouldContinue)(void), void (^completion)(NSURL *, NSError *)) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        @autoreleasepool {
            NSError *error = nil;
            BOOL result = FMWriteLoop(FMNormalizedSource(image), portrait, outputURL, shouldContinue, &error);
            completion(result ? outputURL : nil, error);
        }
    });
}
#endif
