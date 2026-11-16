#import "FMSettingsEntry.h"
#import <objc/runtime.h>
#import <Vision/Vision.h>
#import <math.h>

// The 4.2.7 host's Localizable.strings identifies Settings by settings.title and
// independent source/preferences/storage sections. Never rely on SwiftUI private
// hosting-controller names, a gear icon, or arbitrary text elsewhere in a window.
static NSString *const FMEntryIdentifier = @"FMX.SettingsEntry";

@interface FMSettingsRegistration : NSObject
@property(nonatomic, weak) UIViewController *owner;
@property(nonatomic, weak) UINavigationItem *item;
@property(nonatomic, copy) NSString *title;
@property(nonatomic, strong) UIBarButtonItem *button;
@property(nonatomic, strong) UIBarButtonItemGroup *group;
- (void)open:(id)sender;
@end

@interface FMSettingsProbe : NSObject
@property(nonatomic, weak) UINavigationItem *item;
@property(nonatomic, copy) NSString *title;
@property(nonatomic) NSTimeInterval time;
@property(nonatomic) NSUInteger mask;
@property(nonatomic) NSUInteger visionAttempts;
@property(nonatomic) NSTimeInterval nextVisionTime;
@property(nonatomic, weak) UIScrollView *visionList;
@property(nonatomic) CGPoint visionOffset;
@property(nonatomic) CGSize visionViewport, visionContentSize;
@property(nonatomic) NSUInteger visionPositionAttempts;
@end
@implementation FMSettingsProbe
@end

@interface FMSettingsCoordinator : NSObject
@property(nonatomic, copy) void (^openPanel)(UIViewController *);
@property(nonatomic, strong) NSMapTable<UIViewController *, FMSettingsRegistration *> *entries;
@property(nonatomic, strong) NSMapTable<UIViewController *, FMSettingsProbe *> *lastProbe;
@property(nonatomic, strong) NSSet<NSString *> *titles;
@property(nonatomic, strong) NSArray<NSSet<NSString *> *> *markerGroups;
@property(nonatomic, strong) NSHashTable<UIViewController *> *disappearing;
@property(nonatomic) NSUInteger attachedCount;
@property(nonatomic) BOOL needsEvidence;
@property(nonatomic) NSTimeInterval nextEvidenceTime;
@property(nonatomic, strong) dispatch_queue_t visionQueue;
@property(nonatomic, strong) VNRecognizeTextRequest *visionRequest;
@property(nonatomic, weak) UIViewController *visionOwner;
@property(nonatomic, weak) FMSettingsProbe *visionProbe;
@property(nonatomic) BOOL visionCancelled;
@property(nonatomic) NSUInteger visionAttempts, visionMatchedPages, visionFailures;
@property(nonatomic) NSUInteger visionLastImageWidth, visionLastImageHeight, visionLastImageContrast;
@property(nonatomic) NSUInteger visionLastLineCount, visionLastConfidentLineCount, visionLastMask, visionLastAccumulatedMask;
@property(nonatomic) NSInteger visionLastErrorCode;
@property(nonatomic) BOOL visionLastDrawSucceeded;
@property(nonatomic) NSTimeInterval nextVisionTime;
@property(nonatomic) BOOL visionRetryQueued;
@property(nonatomic) BOOL queued;
@property(nonatomic) BOOL updating;
- (void)schedule;
- (void)scan;
- (void)forget:(UIViewController *)owner;
- (void)detach:(FMSettingsRegistration *)registration;
- (void)openRegistration:(FMSettingsRegistration *)registration;
- (void)environmentChanged:(NSNotification *)notification;
- (void)beginVisionForOwner:(UIViewController *)owner probe:(FMSettingsProbe *)probe;
- (void)publishDiagnostics;
@end

static FMSettingsCoordinator *FMSettings;
static NSDictionary *FMSettingsSnapshot;

static NSString *FMText(id value) {
    return [value isKindOfClass:NSString.class]
        ? [(NSString *)value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] : @"";
}

static NSSet<NSString *> *FMLocalizedMarkers(NSArray<NSString *> *keys, NSArray<NSString *> *fallbacks) {
    NSMutableSet *values = [NSMutableSet setWithArray:fallbacks];
    for (NSString *key in keys) {
        [values addObject:key];
        NSString *localized = [NSBundle.mainBundle localizedStringForKey:key value:nil table:nil];
        if (localized.length) [values addObject:localized];
    }
    // FreeMusic has an in-app language selector. Read both shipped localizations,
    // independently of the system's current language and Bundle's selected one.
    for (NSString *language in @[@"zh-Hans", @"en"]) {
        NSString *path = [NSBundle.mainBundle pathForResource:@"Localizable" ofType:@"strings" inDirectory:nil forLocalization:language];
        NSDictionary *strings = path ? [NSDictionary dictionaryWithContentsOfFile:path] : nil;
        for (NSString *key in keys) if ([strings[key] isKindOfClass:NSString.class]) [values addObject:strings[key]];
    }
    return values;
}

static BOOL FMViewIsVisible(UIView *view, UIWindow *window) {
    if (!view || view.window != window) return NO;
    for (UIView *v = view; v; v = v.superview) if (v.hidden || v.alpha < 0.01) return NO;
    CGRect rect = [view convertRect:view.bounds toView:window];
    return !CGRectIsEmpty(rect) && CGRectIntersectsRect(rect, window.bounds);
}

// Follow only the active containment path. A presented alert, picker or player
// replaces its presenting path even for a sheet that leaves Settings visible.
static void FMCollectCandidates(UIViewController *controller, UIWindow *window,
                                NSMutableArray<UIViewController *> *result, NSUInteger depth) {
    if (!controller || depth > 20 || !FMViewIsVisible(controller.viewIfLoaded, window)) return;
    UIViewController *presented = controller.presentedViewController;
    if (presented && !presented.isBeingDismissed) {
        FMCollectCandidates(presented, window, result, depth + 1);
        return;
    }
    if ([controller isKindOfClass:UINavigationController.class]) {
        UINavigationController *navigation = (UINavigationController *)controller;
        UIViewController *top = navigation.topViewController;
        if (top.presentedViewController && !top.presentedViewController.isBeingDismissed) {
            FMCollectCandidates(top.presentedViewController, window, result, depth + 1);
            return;
        }
        if (!navigation.navigationBarHidden && navigation.visibleViewController == top &&
            navigation.navigationBar.topItem == top.navigationItem && FMViewIsVisible(top.viewIfLoaded, window)) {
            [result addObject:top];
        }
        FMCollectCandidates(top, window, result, depth + 1);
    } else if ([controller isKindOfClass:UITabBarController.class]) {
        FMCollectCandidates(((UITabBarController *)controller).selectedViewController, window, result, depth + 1);
    } else {
        // SwiftUI can place its navigation controller below a public container.
        // Controller trees are small; this never enumerates every view in a window.
        for (UIViewController *child in controller.childViewControllers) {
            if (child.presentedViewController && !child.presentedViewController.isBeingDismissed &&
                FMViewIsVisible(child.viewIfLoaded, window)) {
                [result removeAllObjects];
                FMCollectCandidates(child.presentedViewController, window, result, depth + 1);
                return;
            }
        }
        for (UIViewController *child in controller.childViewControllers)
            FMCollectCandidates(child, window, result, depth + 1);
    }
}

static NSArray<UIViewController *> *FMCurrentCandidates(void) {
    NSMutableArray *result = [NSMutableArray array];
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class] || scene.activationState != UISceneActivationStateForegroundActive) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (!window.isKeyWindow || window.windowLevel != UIWindowLevelNormal || window.hidden) continue;
            FMCollectCandidates(window.rootViewController, window, result, 0);
        }
    }
    return result;
}

static NSUInteger FMMarkerMask(NSString *text, NSArray<NSSet<NSString *> *> *groups) {
    if (!text.length || text.length > 512) return 0;
    // SwiftUI sometimes combines a row label and its value into one AX element.
    NSArray *parts = [text componentsSeparatedByCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"\n,，"]];
    NSUInteger mask = 0;
    for (NSUInteger i = 0; i < groups.count; ++i) {
        if ([groups[i] containsObject:text]) mask |= (1u << i);
        for (NSString *part in parts) if ([groups[i] containsObject:FMText(part)]) mask |= (1u << i);
    }
    return mask;
}

static NSUInteger FMSettingsContentMask(UIView *root, NSArray<NSSet<NSString *> *> *groups) {
    if (!root) return 0;
    NSMutableArray *queue = [NSMutableArray arrayWithObject:@[root, @0]];
    NSHashTable *seen = [NSHashTable hashTableWithOptions:NSPointerFunctionsObjectPointerPersonality];
    NSUInteger mask = 0;
    // Bounded breadth-first AX + UIView scan, only for an unverified Settings title.
    // After a page is identified, scrolling and progress updates skip this scan.
    for (NSUInteger cursor = 0; cursor < queue.count && cursor < 256; ++cursor) {
        NSArray *record = queue[cursor]; id object = record[0]; NSUInteger depth = [record[1] unsignedIntegerValue];
        if ([seen containsObject:object] || depth > 16) continue;
        [seen addObject:object];
        if ([object isKindOfClass:UIView.class]) {
            UIView *view = object;
            if (view.hidden || view.alpha < 0.01 || view.accessibilityElementsHidden) continue;
            if ([view isKindOfClass:UILabel.class]) mask |= FMMarkerMask(FMText(((UILabel *)view).text), groups);
            if ([view isKindOfClass:UIButton.class]) mask |= FMMarkerMask(FMText(((UIButton *)view).currentTitle), groups);
            for (UIView *child in view.subviews) if (queue.count < 768) [queue addObject:@[child, @(depth + 1)]];
        }
        @try {
            if ([object respondsToSelector:@selector(accessibilityLabel)]) mask |= FMMarkerMask(FMText([object accessibilityLabel]), groups);
            if ((mask & 1u) && (mask & 6u)) return mask;
            NSArray *elements = [object respondsToSelector:@selector(accessibilityElements)] ? [object accessibilityElements] : nil;
            if ([elements isKindOfClass:NSArray.class] && elements.count > 0) {
                for (id element in elements) if (element && queue.count < 768) [queue addObject:@[element, @(depth + 1)]];
            } else if ([object respondsToSelector:@selector(accessibilityElementCount)] &&
                       [object respondsToSelector:@selector(accessibilityElementAtIndex:)]) {
                NSInteger count = [object accessibilityElementCount];
                if (count > 0 && count != NSNotFound) for (NSInteger index = 0; index < MIN(count, 96) && queue.count < 768; ++index) {
                    id element = [object accessibilityElementAtIndex:index];
                    if (element) [queue addObject:@[element, @(depth + 1)]];
                }
            }
        } @catch (__unused NSException *exception) {
            // A host AX provider may not be ready during a transition; fail closed.
        }
    }
    return mask;
}

static UIScrollView *FMVisibleList(UIView *root) {
    if (!root.window) return nil;
    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:root];
    for (NSUInteger cursor = 0; cursor < queue.count && cursor < 256; ++cursor) {
        UIView *view = queue[cursor];
        if (!FMViewIsVisible(view, root.window)) continue;
        if ([view isKindOfClass:UICollectionView.class] || [view isKindOfClass:UITableView.class]) return (UIScrollView *)view;
        for (UIView *child in view.subviews) if (queue.count < 512) [queue addObject:child];
    }
    return nil;
}

// A 32px luminance span distinguishes a blank render from a populated frame.
// Only the scalar is retained; no pixels, text, or image fingerprints are logged.
static NSUInteger FMFrameContrast(CGImageRef image) {
    if (!image) return 0;
    uint8_t pixels[32 * 32 * 4] = {0};
    CGColorSpaceRef color = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(pixels, 32, 32, 8, 32 * 4, color, kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(color);
    if (!context) return 0;
    CGContextDrawImage(context, CGRectMake(0, 0, 32, 32), image);
    CGContextRelease(context);
    NSUInteger minimum = 255, maximum = 0;
    for (NSUInteger i = 0; i < 32 * 32; ++i) {
        NSUInteger luminance = (77 * pixels[i * 4] + 150 * pixels[i * 4 + 1] + 29 * pixels[i * 4 + 2]) >> 8;
        minimum = MIN(minimum, luminance); maximum = MAX(maximum, luminance);
    }
    return maximum - minimum;
}

@implementation FMSettingsRegistration
- (void)open:(id)sender { [FMSettings openRegistration:self]; }
@end

@implementation FMSettingsCoordinator
- (instancetype)init {
    if ((self = [super init])) {
        _entries = [NSMapTable weakToStrongObjectsMapTable];
        _lastProbe = [NSMapTable weakToStrongObjectsMapTable];
        _disappearing = [NSHashTable weakObjectsHashTable];
        _visionQueue = dispatch_queue_create("FMX.settings.visible-text", dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0));
        _titles = FMLocalizedMarkers(@[@"settings.title"], @[@"设置", @"Settings"]);
        _markerGroups = @[
            FMLocalizedMarkers(@[@"settings.source_settings", @"settings.custom_sources"], @[@"音源设置", @"自定义音源", @"Music Source Settings", @"Custom Sources"]),
            FMLocalizedMarkers(@[@"settings.preferences", @"settings.audio_quality", @"settings.language"], @[@"偏好设置", @"音质", @"语言", @"Preferences", @"Audio Quality", @"Language"]),
            FMLocalizedMarkers(@[@"settings.storage", @"settings.music_cache", @"settings.local_downloads"], @[@"存储", @"音乐缓存", @"本地下载", @"Storage", @"Music Cache", @"Local Downloads"])
        ];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(environmentChanged:) name:UIApplicationDidBecomeActiveNotification object:nil];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(environmentChanged:) name:UIWindowDidBecomeKeyNotification object:nil];
    }
    return self;
}
- (void)environmentChanged:(NSNotification *)notification { [self schedule]; }
- (void)publishDiagnostics {
    NSDictionary *snapshot = @{@"activeEntries":@(self.attachedCount), @"visionInFlight":@(self.visionRequest != nil),
        @"visionAttempts":@(self.visionAttempts), @"visionMatchedPages":@(self.visionMatchedPages), @"visionFailures":@(self.visionFailures),
        @"visionLastImageWidth":@(self.visionLastImageWidth), @"visionLastImageHeight":@(self.visionLastImageHeight),
        @"visionLastImageContrast":@(self.visionLastImageContrast), @"visionLastDrawSucceeded":@(self.visionLastDrawSucceeded),
        @"visionLastLineCount":@(self.visionLastLineCount), @"visionLastConfidentLineCount":@(self.visionLastConfidentLineCount),
        @"visionLastMask":@(self.visionLastMask), @"visionLastAccumulatedMask":@(self.visionLastAccumulatedMask),
        @"visionLastErrorCode":@(self.visionLastErrorCode)};
    @synchronized (FMSettingsCoordinator.class) { FMSettingsSnapshot = snapshot; }
}
- (void)beginVisionForOwner:(UIViewController *)owner probe:(FMSettingsProbe *)probe {
    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    if (self.visionRequest || probe.visionAttempts >= 8 || [self.disappearing containsObject:owner]) return;
    UIScrollView *list = FMVisibleList(owner.viewIfLoaded);
    if (!list) return;
    BOOL changed = probe.visionList != list || fabs(probe.visionOffset.x - list.contentOffset.x) >= 44 ||
        fabs(probe.visionOffset.y - list.contentOffset.y) >= 44 ||
        fabs(probe.visionViewport.width - list.bounds.size.width) >= 20 || fabs(probe.visionViewport.height - list.bounds.size.height) >= 20 ||
        fabs(probe.visionContentSize.width - list.contentSize.width) >= 44 || fabs(probe.visionContentSize.height - list.contentSize.height) >= 44;
    if (changed) probe.visionPositionAttempts = 0;
    if (probe.visionPositionAttempts >= 2) return;
    NSTimeInterval ready = MAX(probe.nextVisionTime, self.nextVisionTime);
    if (now < ready) {
        if (!self.visionRetryQueued) {
            self.visionRetryQueued = YES;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((ready - now) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                self.visionRetryQueued = NO; [self schedule];
            });
        }
        return;
    }
    // On current SwiftUI, list Text can be drawn without exposing UILabel or
    // in-process public AX elements. Read the actual pixels locally instead of
    // treating the Settings title alone as proof. No screenshot/text is persisted.
    probe.visionAttempts += 1; probe.nextVisionTime = now + 2.0; self.visionAttempts += 1;
    self.nextVisionTime = now + 2.0;
    probe.visionPositionAttempts += 1; probe.visionList = list; probe.visionOffset = list.contentOffset;
    probe.visionViewport = list.bounds.size; probe.visionContentSize = list.contentSize;
    CGSize size = owner.view.bounds.size;
    UIImage *image;
    self.visionLastDrawSucceeded = NO;
    if (isfinite(size.width) && isfinite(size.height) && size.width >= 100 && size.height >= 100 && size.width <= 4096 && size.height <= 4096) {
        UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat defaultFormat];
        format.opaque = YES;
        format.scale = MIN(2.0, sqrt(2000000.0 / (size.width * size.height)));
        UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:size format:format];
        __block BOOL drawn = NO;
        image = [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
            drawn = [owner.view drawViewHierarchyInRect:(CGRect){CGPointZero,size} afterScreenUpdates:NO];
        }];
        self.visionLastDrawSucceeded = drawn;
        if (!drawn) image = nil;
    }
    self.visionLastImageWidth = image.CGImage ? CGImageGetWidth(image.CGImage) : 0;
    self.visionLastImageHeight = image.CGImage ? CGImageGetHeight(image.CGImage) : 0;
    self.visionLastImageContrast = FMFrameContrast(image.CGImage);
    __weak UIViewController *weakOwner = owner;
    __weak FMSettingsProbe *weakProbe = probe;
    // At most two attempts at the same position and eight per uninterrupted visit.
    // Later scrolling/layout changes can supply a section that was initially absent.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        UIViewController *currentOwner = weakOwner; FMSettingsProbe *currentProbe = weakProbe;
        if (currentOwner && currentProbe && [self.lastProbe objectForKey:currentOwner] == currentProbe) [self schedule];
    });
    if (!image.CGImage) { self.visionFailures += 1; [self publishDiagnostics]; return; }
    VNRecognizeTextRequest *request = [[VNRecognizeTextRequest alloc] initWithCompletionHandler:nil];
    request.recognitionLevel = VNRequestTextRecognitionLevelAccurate;
    request.recognitionLanguages = @[@"zh-Hans", @"en-US"];
    request.usesLanguageCorrection = NO;
    request.minimumTextHeight = 0.008;
    // Do not bias recognition with target section names/customWords.
    self.visionRequest = request; self.visionOwner = owner; self.visionProbe = probe; self.visionCancelled = NO;
    [self publishDiagnostics];
    NSArray<NSSet<NSString *> *> *groups = self.markerGroups;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 6 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        if (self.visionRequest == request) { self.visionCancelled = YES; [request cancel]; }
    });
    dispatch_async(self.visionQueue, ^{
        @autoreleasepool {
            NSError *error;
            VNImageRequestHandler *handler = [[VNImageRequestHandler alloc] initWithCGImage:image.CGImage options:@{}];
            BOOL success = [handler performRequests:@[request] error:&error];
            NSUInteger mask = 0;
            NSUInteger confidentLines = 0, lines = request.results.count;
            if (success) for (VNRecognizedTextObservation *observation in request.results) {
                VNRecognizedText *text = [observation topCandidates:1].firstObject;
                if (text.confidence >= 0.65) { confidentLines += 1; mask |= FMMarkerMask(FMText(text.string), groups); }
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                if (self.visionRequest != request) return;
                BOOL cancelled = self.visionCancelled;
                self.visionRequest = nil; self.visionOwner = nil; self.visionProbe = nil; self.visionCancelled = NO;
                self.visionLastLineCount = lines; self.visionLastConfidentLineCount = confidentLines; self.visionLastMask = mask;
                self.visionLastErrorCode = error.code;
                UIViewController *currentOwner = weakOwner; FMSettingsProbe *currentProbe = weakProbe;
                if (!success && !cancelled) self.visionFailures += 1;
                if (success && !cancelled && currentOwner && currentProbe &&
                    [self.lastProbe objectForKey:currentOwner] == currentProbe &&
                    currentProbe.item == currentOwner.navigationItem && [currentProbe.title isEqual:FMText(currentOwner.navigationItem.title)] &&
                    [self.titles containsObject:currentProbe.title] && ![self.disappearing containsObject:currentOwner] &&
                    ![self.entries objectForKey:currentOwner] && [FMCurrentCandidates() containsObject:currentOwner]) {
                    currentProbe.mask |= mask;
                    self.visionLastAccumulatedMask = currentProbe.mask;
                    if ((currentProbe.mask & 1u) && (currentProbe.mask & 6u)) self.visionMatchedPages += 1;
                }
                [self publishDiagnostics];
                [self schedule];
            });
        }
    });
}
- (void)schedule {
    if (!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(), ^{ [self schedule]; }); return; }
    if (self.queued || self.updating) return;
    self.queued = YES;
    dispatch_async(dispatch_get_main_queue(), ^{ self.queued = NO; [self scan]; });
}
- (void)forget:(UIViewController *)owner {
    FMSettingsRegistration *registration = [self.entries objectForKey:owner];
    if (!registration) return;
    [self detach:registration];
    [self.entries removeObjectForKey:owner];
    [self.lastProbe removeObjectForKey:owner];
}
- (void)detach:(FMSettingsRegistration *)registration {
    UINavigationItem *item = registration.item;
    if (@available(iOS 16.0, *)) {
        NSMutableArray<UIBarButtonItemGroup *> *groups = [item.trailingItemGroups mutableCopy];
        if ([groups containsObject:registration.group]) {
            [groups removeObjectIdenticalTo:registration.group];
            item.trailingItemGroups = groups;
            return;
        }
        // Group APIs and the legacy right-item APIs replace one another. Never
        // write a legacy array over host-owned SwiftUI toolbar groups on cleanup.
        if (groups.count) return;
    }
    NSMutableArray *items = [item.rightBarButtonItems mutableCopy];
    if ([items containsObject:registration.button]) {
        [items removeObjectIdenticalTo:registration.button];
        [item setRightBarButtonItems:items.count ? items : nil animated:NO];
    }
}
- (void)scan {
    if (self.updating) return;
    self.updating = YES;
    NSArray<UIViewController *> *candidates = FMCurrentCandidates();
    if (self.visionRequest && !self.visionCancelled &&
        (!self.visionOwner || !self.visionProbe || ![candidates containsObject:self.visionOwner] || [self.disappearing containsObject:self.visionOwner] ||
         self.visionProbe.item != self.visionOwner.navigationItem || ![self.visionProbe.title isEqual:FMText(self.visionOwner.navigationItem.title)])) {
        self.visionCancelled = YES; [self.visionRequest cancel];
    }
    for (UIViewController *owner in self.lastProbe.keyEnumerator.allObjects) {
        FMSettingsProbe *probe = [self.lastProbe objectForKey:owner];
        if (![candidates containsObject:owner] || probe.item != owner.navigationItem ||
            ![probe.title isEqual:FMText(owner.navigationItem.title)]) [self.lastProbe removeObjectForKey:owner];
    }
    for (UIViewController *owner in self.entries.keyEnumerator.allObjects) {
        FMSettingsRegistration *registration = [self.entries objectForKey:owner];
        NSString *title = FMText(owner.navigationItem.title);
        if (registration.item != owner.navigationItem || ![registration.title isEqual:title] ||
            ![self.titles containsObject:title]) [self forget:owner];
        else if (![candidates containsObject:owner] || [self.disappearing containsObject:owner]) [self detach:registration];
    }
    self.attachedCount = 0;
    self.needsEvidence = NO;
    for (UIViewController *owner in candidates) {
        NSString *title = FMText(owner.navigationItem.title);
        if ([self.disappearing containsObject:owner] || ![self.titles containsObject:title] || [owner isKindOfClass:UIAlertController.class] ||
            [owner isKindOfClass:UIDocumentPickerViewController.class]) continue;
        FMSettingsRegistration *registration = [self.entries objectForKey:owner];
        if (!registration) {
            self.needsEvidence = YES;
            NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
            FMSettingsProbe *probe = [self.lastProbe objectForKey:owner];
            if (!probe || probe.item != owner.navigationItem || ![probe.title isEqual:title]) {
                probe = [FMSettingsProbe new]; probe.item = owner.navigationItem; probe.title = title;
                [self.lastProbe setObject:probe forKey:owner];
            }
            // Lazy Forms may expose source and preferences on different scroll
            // positions. Accumulate only within this same visible page/item/title;
            // a disappearance clears unverified evidence.
            if (!(probe.mask & 1u) || !(probe.mask & 6u)) {
                if (probe.time == 0 || now - probe.time >= 0.5) {
                    probe.time = now; self.nextEvidenceTime = now + 0.5;
                    probe.mask |= FMSettingsContentMask(owner.viewIfLoaded, self.markerGroups);
                }
                if (!(probe.mask & 1u) || !(probe.mask & 6u)) { [self beginVisionForOwner:owner probe:probe]; continue; }
            }
            registration = [FMSettingsRegistration new];
            registration.owner = owner; registration.item = owner.navigationItem; registration.title = title;
            registration.button = [[UIBarButtonItem alloc] initWithTitle:@"音源与扩展" style:UIBarButtonItemStylePlain target:registration action:@selector(open:)];
            registration.button.accessibilityIdentifier = FMEntryIdentifier;
            registration.button.accessibilityLabel = @"音源与扩展";
            registration.button.accessibilityHint = @"管理导入的 JS 音源和播放扩展";
            registration.group = [[UIBarButtonItemGroup alloc] initWithBarButtonItems:@[registration.button] representativeItem:nil];
            [self.entries setObject:registration forKey:owner];
        }
        BOOL grouped = NO;
        if (@available(iOS 16.0, *)) {
            NSArray<UIBarButtonItemGroup *> *groups = owner.navigationItem.trailingItemGroups;
            // Modern SwiftUI toolbars use groups while rightBarButtonItems is
            // empty. Setting that legacy property would remove their toolbar.
            // Append only our fixed group, leaving all host groups/items intact.
            if (groups.count || owner.navigationItem.rightBarButtonItems.count == 0) {
                if (![groups containsObject:registration.group])
                    owner.navigationItem.trailingItemGroups = [(groups ?: @[]) arrayByAddingObject:registration.group];
                grouped = YES;
            }
        }
        NSArray *current = owner.navigationItem.rightBarButtonItems ?: @[];
        if (!grouped && ![current containsObject:registration.button]) {
            // Work from the current array, not an old snapshot: SwiftUI can replace
            // its own toolbar actions while this page remains on screen.
            [owner.navigationItem setRightBarButtonItems:[current arrayByAddingObject:registration.button] animated:NO];
        }
        self.attachedCount += 1;
    }
    self.needsEvidence = NO;
    for (UIViewController *owner in candidates) {
        if (![self.disappearing containsObject:owner] && [self.titles containsObject:FMText(owner.navigationItem.title)] &&
            ![self.entries objectForKey:owner]) { self.needsEvidence = YES; break; }
    }
    self.updating = NO;
    [self publishDiagnostics];
}
- (void)openRegistration:(FMSettingsRegistration *)registration {
    UIViewController *owner = registration.owner;
    if (!owner || [self.entries objectForKey:owner] != registration || ![FMCurrentCandidates() containsObject:owner] ||
        owner.navigationItem != registration.item || ![registration.title isEqual:FMText(owner.navigationItem.title)] ||
        owner.navigationController.topViewController != owner || owner.navigationController.visibleViewController != owner ||
        owner.presentedViewController || [self.disappearing containsObject:owner] || owner.isBeingDismissed || owner.isMovingFromParentViewController || owner.transitionCoordinator) return;
    if (self.openPanel) self.openPanel(owner);
}
@end

static void (*FMOriginalDidAppear)(UIViewController *, SEL, BOOL);
static void (*FMOriginalWillDisappear)(UIViewController *, SEL, BOOL);
static void (*FMOriginalDidLayout)(UIViewController *, SEL);
static void (*FMOriginalSetTitle)(UINavigationItem *, SEL, NSString *);
static void (*FMOriginalSetItems)(UINavigationItem *, SEL, NSArray *, BOOL);
static void (*FMOriginalSetTrailingGroups)(UINavigationItem *, SEL, NSArray *);
static void (*FMOriginalScrollLayout)(UIScrollView *, SEL);

static void FMSettingsDidAppear(UIViewController *self, SEL cmd, BOOL animated) {
    FMOriginalDidAppear(self, cmd, animated);
    [FMSettings.disappearing removeObject:self];
    [FMSettings schedule];
    // A SwiftUI navigation destination's accessibility tree may settle after the
    // appearance callback. These are bounded, coalesced retries, not a poll loop.
    for (NSNumber *delay in @[@0.15, @0.65, @1.2]) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [FMSettings schedule]; });
}
static void FMSettingsWillDisappear(UIViewController *self, SEL cmd, BOOL animated) {
    [FMSettings.disappearing addObject:self];
    if (FMSettings.visionOwner == self && FMSettings.visionRequest) { FMSettings.visionCancelled = YES; [FMSettings.visionRequest cancel]; }
    [FMSettings.lastProbe removeObjectForKey:self];
    [FMSettings detach:[FMSettings.entries objectForKey:self]];
    FMOriginalWillDisappear(self, cmd, animated);
    [FMSettings schedule];
}
static void FMSettingsDidLayout(UIViewController *self, SEL cmd) {
    FMOriginalDidLayout(self, cmd);
    // No content scan for home/player layouts. A registered page requires only a
    // cheap containment/title check and may have its host toolbar refreshed.
    if (FMSettings.attachedCount || [FMSettings.titles containsObject:FMText(self.navigationItem.title)]) [FMSettings schedule];
}
static void FMSettingsSetTitle(UINavigationItem *self, SEL cmd, NSString *title) {
    FMOriginalSetTitle(self, cmd, title);
    if (FMSettings.entries.count || [FMSettings.titles containsObject:FMText(title)]) [FMSettings schedule];
}
static void FMSettingsSetItems(UINavigationItem *self, SEL cmd, NSArray *items, BOOL animated) {
    FMOriginalSetItems(self, cmd, items, animated);
    if ([FMSettings.titles containsObject:FMText(self.title)]) [FMSettings schedule];
}
static void FMSettingsSetTrailingGroups(UINavigationItem *self, SEL cmd, NSArray *groups) {
    FMOriginalSetTrailingGroups(self, cmd, groups);
    if ([FMSettings.titles containsObject:FMText(self.title)]) [FMSettings schedule];
}
static void FMSettingsScrollLayout(UIScrollView *self, SEL cmd) {
    FMOriginalScrollLayout(self, cmd);
    // Lazy SwiftUI Forms may materialize a second section only during scrolling.
    // Gate at two probes/second, and stop entirely once this Settings page is known.
    if (FMSettings.needsEvidence && NSProcessInfo.processInfo.systemUptime >= FMSettings.nextEvidenceTime) [FMSettings schedule];
}

void FMSettingsEntryRefresh(void) { [FMSettings schedule]; }

NSDictionary<NSString *, id> *FMSettingsEntryDiagnostics(void) {
    @synchronized (FMSettingsCoordinator.class) { return FMSettingsSnapshot ?: @{}; }
}

void FMSettingsEntryInstall(void (^openPanel)(UIViewController *)) {
    if (!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(), ^{ FMSettingsEntryInstall(openPanel); }); return; }
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        FMSettings = [FMSettingsCoordinator new];
        // Capture every previous implementation before publishing the hook.
        Method appear = class_getInstanceMethod(UIViewController.class, @selector(viewDidAppear:));
        Method disappear = class_getInstanceMethod(UIViewController.class, @selector(viewWillDisappear:));
        Method layout = class_getInstanceMethod(UIViewController.class, @selector(viewDidLayoutSubviews));
        Method title = class_getInstanceMethod(UINavigationItem.class, @selector(setTitle:));
        Method items = class_getInstanceMethod(UINavigationItem.class, @selector(setRightBarButtonItems:animated:));
        Method scrollLayout = class_getInstanceMethod(UIScrollView.class, @selector(layoutSubviews));
        FMOriginalDidAppear = (void *)method_getImplementation(appear);
        FMOriginalWillDisappear = (void *)method_getImplementation(disappear);
        FMOriginalDidLayout = (void *)method_getImplementation(layout);
        FMOriginalSetTitle = (void *)method_getImplementation(title);
        FMOriginalSetItems = (void *)method_getImplementation(items);
        FMOriginalScrollLayout = (void *)method_getImplementation(scrollLayout);
        method_setImplementation(appear, (IMP)FMSettingsDidAppear);
        method_setImplementation(disappear, (IMP)FMSettingsWillDisappear);
        method_setImplementation(layout, (IMP)FMSettingsDidLayout);
        method_setImplementation(title, (IMP)FMSettingsSetTitle);
        method_setImplementation(items, (IMP)FMSettingsSetItems);
        if (@available(iOS 16.0, *)) {
            Method trailingGroups = class_getInstanceMethod(UINavigationItem.class, @selector(setTrailingItemGroups:));
            FMOriginalSetTrailingGroups = (void *)method_getImplementation(trailingGroups);
            method_setImplementation(trailingGroups, (IMP)FMSettingsSetTrailingGroups);
        }
        // UIScrollView owns layoutSubviews on supported iOS versions. Add the
        // method defensively if a future version inherits it, never mutate UIView.
        if (!class_addMethod(UIScrollView.class, @selector(layoutSubviews), (IMP)FMSettingsScrollLayout, method_getTypeEncoding(scrollLayout)))
            method_setImplementation(scrollLayout, (IMP)FMSettingsScrollLayout);
    });
    FMSettings.openPanel = openPanel;
    [FMSettings schedule];
}
