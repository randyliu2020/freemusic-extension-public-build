// Self-authored Simulator host. It is not the original FreeMusic executable.
// Every source, cover, media URL and account-like value below is a fixture.
#import <UIKit/UIKit.h>
#import <MediaPlayer/MediaPlayer.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <math.h>
#import "LXSourceRuntime.h"
#import "FMQishuiSearch.h"
#import "FMExtensionProtocol.h"
#import "FMListeningHistory.h"
#import "FMQualityResolver.h"
#import "FMReplayCache.h"

@interface FMXManager : NSObject
@property(atomic,strong) LXSourceRuntime *runtime;
@property(atomic,copy) NSString *status;
@property(atomic,copy) NSString *playbackStatus;
@property(nonatomic,copy) NSString *playbackRequest;
@property(nonatomic,copy) NSString *selectedFile;
@property(nonatomic,copy) NSString *loadingFile;
@property(nonatomic,copy) NSString *replayNamespace;
@property(nonatomic,copy) NSArray<NSDictionary *> *files;
+ (instancetype)shared;
- (NSURL *)directory;
- (void)refreshFiles;
- (void)activate:(NSDictionary *)file;
- (void)disable;
- (void)retireRuntime;
- (void)restoreSavedSource;
@end

typedef void (*InstallFunction)(void);
typedef NSDictionary *(*StatusFunction)(void);
typedef void (*SystemPolicyFunction)(NSNumber *);
typedef void (*AggregatePreferenceFunction)(BOOL);
typedef UIImage *(*PreviewFunction)(UIImage *, BOOL);
typedef void (*MovieFunction)(UIImage *, BOOL, NSURL *, BOOL (^)(void), void (^)(NSURL *, NSError *));
static InstallFunction InstallArtwork, RefreshArtwork;
static StatusFunction ArtworkStatus;
static PreviewFunction PreviewArtwork;
static MovieFunction WriteMovie;
static SystemPolicyFunction SetSystemAllowed;
static AggregatePreferenceFunction SetAggregateEnabled;
static InstallFunction InstallSearchPreferences;
static NSDictionary *SettingsEntryDiagnostics(void *extensionHandle) {
    NSDictionary *(*readDiagnostics)(void)=extensionHandle?(NSDictionary*(*)(void))dlsym(extensionHandle,"FMSettingsEntryDiagnostics"):NULL;
    NSDictionary *snapshot=readDiagnostics?readDiagnostics():nil;NSMutableDictionary *numbers=NSMutableDictionary.dictionary;
    if([snapshot isKindOfClass:NSDictionary.class])for(id key in snapshot)if([key isKindOfClass:NSString.class] && [snapshot[key] isKindOfClass:NSNumber.class])numbers[key]=snapshot[key];
    return numbers;
}

static void Main(dispatch_block_t block) {
    if (NSThread.isMainThread) { block(); return; }
    // A test assertion on the main queue must return to the test runner's
    // exception handler. Unwinding out of a dispatch block terminates the host
    // and turns the actual failure into an uninformative phase timeout.
    __block NSException *failure = nil;
    dispatch_sync(dispatch_get_main_queue(), ^{
        @try { block(); } @catch (NSException *exception) { failure = exception; }
    });
    if (failure) @throw failure;
}
static void Check(BOOL value, NSString *reason) {
    if (!value) @throw [NSException exceptionWithName:@"FMXSmokeFailure" reason:reason ?: @"Failed assertion" userInfo:nil];
}
static NSURL *SmokeWriteQualityWave(void) {
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
}
static BOOL Until(BOOL (^condition)(void), NSTimeInterval timeout) {
    NSTimeInterval end = NSProcessInfo.processInfo.systemUptime + timeout;
    while (NSProcessInfo.processInfo.systemUptime < end) {
        __block BOOL result = NO; Main(^{ result = condition(); });
        if (result) return YES;
        [NSThread sleepForTimeInterval:0.05];
    }
    return NO;
}
// Test-only observations of production runtime state. No production observer,
// update-alert forwarding or exported debug hook is installed for these checks.
static NSDictionary *SmokeRuntimeResources(LXSourceRuntime *runtime) {
    if(!runtime)return @{};
    // KVC resolves isInvalidated, which locks internally: read it before taking
    // the private lock used for the mutable collection snapshots below.
    BOOL invalidated=[[runtime valueForKey:@"invalidated"] boolValue];
    NSLock *lock=[runtime valueForKey:@"_lock"];
    [lock lock];
    @try {
        return @{@"invalidated":@(invalidated),@"timers":@([[runtime valueForKey:@"_timers"] count]),
            @"http":@([[runtime valueForKey:@"_HTTPTasks"] count]),@"pending":@([[runtime valueForKey:@"_pending"] count]),
            @"workers":@([[runtime valueForKey:@"_isolatedResolutions"] count])};
    } @finally {[lock unlock];}
}
static NSArray<LXSourceRuntime *> *SmokeIsolatedWorkers(LXSourceRuntime *runtime) {
    NSLock *lock=[runtime valueForKey:@"_lock"];NSMutableArray *workers=NSMutableArray.array;
    [lock lock];
    @try {
        for(id attempt in [[runtime valueForKey:@"_isolatedResolutions"] allValues]){
            LXSourceRuntime *worker=[attempt valueForKey:@"worker"];if(worker)[workers addObject:worker];
        }
    } @finally {[lock unlock];}
    return workers;
}
static UIButton *FindLauncher(UIView *view) {
    if ([view isKindOfClass:UIButton.class] && [view.accessibilityLabel isEqual:@"打开音源扩展"]) return (UIButton *)view;
    for (UIView *child in view.subviews) { UIButton *button=FindLauncher(child); if (button) return button; }
    return nil;
}
static UIView *FindIdentifier(UIView *view, NSString *identifier) {
    if([view.accessibilityIdentifier isEqual:identifier]) return view;
    for(UIView *child in view.subviews){UIView *match=FindIdentifier(child,identifier);if(match)return match;}
    return nil;
}
static BOOL VisibleInWindow(UIView *view) {
    if(!view.window || view.hidden || view.alpha<0.01) return NO;
    for(UIView *parent=view.superview;parent;parent=parent.superview)if(parent.hidden || parent.alpha<0.01)return NO;
    CGRect rect=[view convertRect:view.bounds toView:view.window];
    return !CGRectIsEmpty(CGRectIntersection(rect,view.window.bounds));
}
static BOOL ButtonReceivesHit(UIButton *button) {
    if(!VisibleInWindow(button)||!button.enabled)return NO;
    CGPoint center=CGPointMake(CGRectGetMidX(button.bounds),CGRectGetMidY(button.bounds));
    UIView *hit=[button.window hitTest:[button convertPoint:center toView:button.window] withEvent:nil];
    return hit==button || [hit isDescendantOfView:button];
}
static BOOL TapVisibleButton(UIButton *button) {
    if(!ButtonReceivesHit(button))return NO;
    [button sendActionsForControlEvents:UIControlEventTouchUpInside];
    return YES;
}
static BOOL IsSettingsEntryItem(UIBarButtonItem *item) {
    return [item.accessibilityIdentifier isEqual:@"FMX.SettingsEntry"] || [item.customView.accessibilityIdentifier isEqual:@"FMX.SettingsEntry"];
}
static NSArray<UIBarButtonItemGroup *> *ToolbarGroups(UINavigationItem *item) {
    NSMutableArray *groups=NSMutableArray.array;
    if(@available(iOS 16.0,*))for(NSArray *part in @[item.leadingItemGroups ?: @[],item.centerItemGroups ?: @[],item.trailingItemGroups ?: @[]])for(UIBarButtonItemGroup *group in part)if(![groups containsObject:group])[groups addObject:group];
    return groups;
}
static NSArray<UIBarButtonItem *> *AllToolbarItems(UINavigationItem *item) {
    NSMutableArray *items=NSMutableArray.array;
    for(NSArray *part in @[item.leftBarButtonItems ?: @[],item.rightBarButtonItems ?: @[]])for(UIBarButtonItem *button in part)if(![items containsObject:button])[items addObject:button];
    for(UIBarButtonItemGroup *group in ToolbarGroups(item))for(UIBarButtonItem *button in group.barButtonItems)if(![items containsObject:button])[items addObject:button];
    return items;
}
static UIBarButtonItem *FindSettingsEntry(UIViewController *controller) {
    for(UIBarButtonItem *item in AllToolbarItems(controller.navigationItem))if(IsSettingsEntryItem(item))return item;
    return nil;
}
static NSArray<UIBarButtonItem *> *OriginalToolbarItems(UIViewController *controller) {
    NSMutableArray *items=NSMutableArray.array;
    for(UIBarButtonItem *item in AllToolbarItems(controller.navigationItem))if(!IsSettingsEntryItem(item))[items addObject:item];
    return items;
}
static NSArray<UIBarButtonItemGroup *> *OriginalToolbarGroups(UIViewController *controller) {
    NSMutableArray *groups=NSMutableArray.array;
    for(UIBarButtonItemGroup *group in ToolbarGroups(controller.navigationItem)){BOOL hasOriginal=NO;for(UIBarButtonItem *item in group.barButtonItems)if(!IsSettingsEntryItem(item))hasOriginal=YES;if(hasOriginal)[groups addObject:group];}
    return groups;
}
static NSString *FixtureObjectIdentity(id object) {
    if(!object)return @"";
    static NSMapTable *identities;static NSUInteger next=0;
    if(!identities)identities=[NSMapTable mapTableWithKeyOptions:NSPointerFunctionsWeakMemory|NSPointerFunctionsObjectPointerPersonality valueOptions:NSPointerFunctionsStrongMemory];
    NSString *identity=[identities objectForKey:object];if(!identity){identity=[NSString stringWithFormat:@"object-%lu",(unsigned long)++next];[identities setObject:identity forKey:object];}return identity;
}
static NSDictionary *ToolbarItemDiagnostic(UIBarButtonItem *item) {
    return @{@"identity":FixtureObjectIdentity(item),@"class":NSStringFromClass(item.class),@"title":item.title ?: @"",@"identifier":item.accessibilityIdentifier ?: @"",@"label":item.accessibilityLabel ?: @"",@"custom_view_class":item.customView?NSStringFromClass(item.customView.class):@"",@"enabled":@(item.enabled),@"extension_item":@(IsSettingsEntryItem(item))};
}
static NSArray *ToolbarItemsDiagnostic(NSArray<UIBarButtonItem *> *items) {
    NSMutableArray *result=NSMutableArray.array;for(UIBarButtonItem *item in items)[result addObject:ToolbarItemDiagnostic(item)];return result;
}
static NSArray *ToolbarGroupsDiagnostic(NSArray<UIBarButtonItemGroup *> *groups) {
    NSMutableArray *result=NSMutableArray.array;for(UIBarButtonItemGroup *group in groups)[result addObject:@{@"identity":FixtureObjectIdentity(group),@"class":NSStringFromClass(group.class),@"barButtonItems":ToolbarItemsDiagnostic(group.barButtonItems),@"representativeItem":group.representativeItem?ToolbarItemDiagnostic(group.representativeItem):(id)NSNull.null}];return result;
}
static NSDictionary *NavigationItemDiagnostic(UINavigationItem *item) {
    NSMutableDictionary *result=[@{@"identity":FixtureObjectIdentity(item),@"title":item.title ?: @"",@"leftBarButtonItems":ToolbarItemsDiagnostic(item.leftBarButtonItems),@"rightBarButtonItems":ToolbarItemsDiagnostic(item.rightBarButtonItems)} mutableCopy];
    if(@available(iOS 16.0,*)){result[@"leadingItemGroups"]=ToolbarGroupsDiagnostic(item.leadingItemGroups);result[@"centerItemGroups"]=ToolbarGroupsDiagnostic(item.centerItemGroups);result[@"trailingItemGroups"]=ToolbarGroupsDiagnostic(item.trailingItemGroups);}
    return result;
}
static void SaveToolbarEvidence(NSURL *output,NSDictionary *before,NSDictionary *afterEntry,NSDictionary *afterPop,BOOL capturedBefore,BOOL itemsPreserved,BOOL groupsPreserved) {
    NSDictionary *evidence=@{@"baseline_captured_before_entry":@(capturedBefore),@"before":before ?: @{},@"after_entry":afterEntry ?: @{},@"after_pop":afterPop ?: @{},@"item_objects_preserved":@(itemsPreserved),@"group_objects_preserved":@(groupsPreserved),@"ui_tap_validated":@NO};
    [[NSJSONSerialization dataWithJSONObject:evidence options:NSJSONWritingPrettyPrinted error:nil] writeToURL:[output URLByAppendingPathComponent:@"swiftui-toolbar-preservation.json"] atomically:YES];
}
static UIViewController *FrontController(UIViewController *root) {
    if(root.presentedViewController)return FrontController(root.presentedViewController);
    if([root isKindOfClass:UINavigationController.class])return FrontController(((UINavigationController*)root).topViewController);
    return root;
}
static void AssertNoEntryFor(UIWindow *window, NSTimeInterval seconds) {
    NSTimeInterval end=NSProcessInfo.processInfo.systemUptime+seconds;
    do {
        __block BOOL absent=NO;
        Main(^{
            UIView *entry=FindIdentifier(window,@"FMX.SettingsEntry");
            absent=FindLauncher(window)==nil && !VisibleInWindow(entry) && FindSettingsEntry(FrontController(window.rootViewController))==nil;
        });
        Check(absent,@"No floating or settings extension entry on an unrelated surface");
        [NSThread sleepForTimeInterval:0.05];
    }while(NSProcessInfo.processInfo.systemUptime<end);
}
static void AssertRemainsTop(UIViewController *controller,NSTimeInterval seconds) {
    NSTimeInterval end=NSProcessInfo.processInfo.systemUptime+seconds;
    do {__block BOOL top=NO;Main(^{top=controller.navigationController.topViewController==controller && VisibleInWindow(controller.viewIfLoaded);});
        Check(top,@"SwiftUI state reconciliation must not remove the pushed extension panel");[NSThread sleepForTimeInterval:0.05];
    }while(NSProcessInfo.processInfo.systemUptime<end);
}
static UIViewController *FindVisibleController(UIViewController *root,BOOL(^predicate)(UIViewController *),NSUInteger depth) {
    if(!root || depth>24)return nil;
    UIViewController *found=FindVisibleController(root.presentedViewController,predicate,depth+1);if(found)return found;
    if(VisibleInWindow(root.viewIfLoaded) && predicate(root))return root;
    for(UIViewController *child in root.childViewControllers){found=FindVisibleController(child,predicate,depth+1);if(found)return found;}
    return nil;
}

// Production-shaped navigation surfaces, authored independently of the IPA.
// Their own callbacks are counted so the test proves old controls still work.
@interface SmokeSettingsViewController : UITableViewController
@property(nonatomic) NSUInteger originalRowActivations;
@property(nonatomic) NSUInteger originalButtonActivations;
@property(nonatomic,strong) UIButton *originalButton;
@end
@implementation SmokeSettingsViewController
- (void)viewDidLoad {
    [super viewDidLoad];self.title=@"设置";self.tableView.accessibilityIdentifier=@"smoke.original-settings-list";
    self.originalButton=[UIButton buttonWithType:UIButtonTypeSystem];self.originalButton.frame=CGRectMake(0,0,44,44);self.originalButton.accessibilityIdentifier=@"smoke.original-settings-info";[self.originalButton setImage:[UIImage systemImageNamed:@"info.circle"] forState:UIControlStateNormal];[self.originalButton addTarget:self action:@selector(originalAction:) forControlEvents:UIControlEventTouchUpInside];
    self.navigationItem.rightBarButtonItem=[[UIBarButtonItem alloc] initWithCustomView:self.originalButton];
}
- (void)originalAction:(id)sender {self.originalButtonActivations++;}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {return 4;}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell=[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    cell.textLabel.text=@[@"自定义音源",@"音质",@"音乐缓存",@"关于 FreeMusic"][indexPath.row];
    cell.accessibilityIdentifier=[NSString stringWithFormat:@"smoke.original-setting-%ld",(long)indexPath.row];
    cell.accessoryType=UITableViewCellAccessoryDisclosureIndicator;return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {self.originalRowActivations++;[tableView deselectRowAtIndexPath:indexPath animated:NO];}
@end
@interface SmokeSearchViewController : UIViewController
@property(nonatomic) NSUInteger didAppearCount;
@end
@implementation SmokeSearchViewController
- (void)viewDidLoad {
    [super viewDidLoad];self.title=@"搜索";self.view.backgroundColor=UIColor.systemBackgroundColor;
    UILabel *label=[UILabel new];label.text=@"搜索结果：设置 / 自定义音源";label.translatesAutoresizingMaskIntoConstraints=NO;[self.view addSubview:label];
    [NSLayoutConstraint activateConstraints:@[[label.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],[label.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor]]];
}
- (void)viewDidAppear:(BOOL)animated {[super viewDidAppear:animated];self.didAppearCount++;}
@end
@interface SmokeHomeViewController : UIViewController
@property(nonatomic,strong) UIButton *settingsButton;
@property(nonatomic,strong) UIButton *searchButton;
@property(nonatomic,strong) UILabel *progressLabel;
@property(nonatomic) NSUInteger settingsActivations;
@property(nonatomic) NSUInteger searchActivations;
@property(nonatomic) NSUInteger didAppearCount;
@end
@implementation SmokeHomeViewController
- (void)viewDidLoad {
    [super viewDidLoad];self.title=@"FreeMusic";self.view.backgroundColor=UIColor.systemBackgroundColor;
    self.settingsButton=[UIButton buttonWithType:UIButtonTypeSystem];self.settingsButton.accessibilityIdentifier=@"smoke.original-settings";self.settingsButton.accessibilityLabel=@"设置";
    [self.settingsButton setImage:[UIImage systemImageNamed:@"gearshape"] forState:UIControlStateNormal];self.settingsButton.frame=CGRectMake(0,0,44,44);[self.settingsButton addTarget:self action:@selector(openSettings:) forControlEvents:UIControlEventTouchUpInside];
    self.navigationItem.rightBarButtonItem=[[UIBarButtonItem alloc] initWithCustomView:self.settingsButton];
    self.searchButton=[UIButton buttonWithType:UIButtonTypeSystem];self.searchButton.accessibilityIdentifier=@"smoke.original-search";[self.searchButton setTitle:@"搜索歌曲" forState:UIControlStateNormal];self.searchButton.translatesAutoresizingMaskIntoConstraints=NO;[self.searchButton addTarget:self action:@selector(openSearch:) forControlEvents:UIControlEventTouchUpInside];[self.view addSubview:self.searchButton];
    self.progressLabel=[UILabel new];self.progressLabel.numberOfLines=0;self.progressLabel.textAlignment=NSTextAlignmentCenter;self.progressLabel.font=[UIFont systemFontOfSize:18];self.progressLabel.translatesAutoresizingMaskIntoConstraints=NO;self.progressLabel.text=@"Self-authored Simulator home\nStarting…";[self.view addSubview:self.progressLabel];
    [NSLayoutConstraint activateConstraints:@[[self.searchButton.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:24],[self.searchButton.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],[self.searchButton.heightAnchor constraintEqualToConstant:48],[self.searchButton.widthAnchor constraintEqualToConstant:200],[self.progressLabel.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:24],[self.progressLabel.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-24],[self.progressLabel.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor]]];
}
- (void)openSettings:(id)sender {self.settingsActivations++;[self.navigationController pushViewController:[[SmokeSettingsViewController alloc] initWithStyle:UITableViewStyleInsetGrouped] animated:YES];}
- (void)openSearch:(id)sender {self.searchActivations++;[self.navigationController pushViewController:[SmokeSearchViewController new] animated:YES];}
- (void)viewDidAppear:(BOOL)animated {[super viewDidAppear:animated];self.didAppearCount++;}
@end
static NSDictionary *HomeSearchNavigationSnapshot(SmokeHomeViewController *home,UIWindow *window) {
    NSCAssert(NSThread.isMainThread,@"Navigation fixture observations require main");
    UINavigationController *navigation=home.navigationController;UIViewController *top=navigation.topViewController;
    id<UIViewControllerTransitionCoordinator> transition=navigation.transitionCoordinator;
    NSMutableArray *stack=NSMutableArray.array;for(UIViewController *controller in navigation.viewControllers)[stack addObject:NSStringFromClass(controller.class)];
    return @{@"uptime":@(NSProcessInfo.processInfo.systemUptime),@"application_state":@(UIApplication.sharedApplication.applicationState),
        @"scene_activation_state":window.windowScene?@(window.windowScene.activationState):(id)NSNull.null,@"key_window":@(window.isKeyWindow),
        @"home_visible":@(VisibleInWindow(home.viewIfLoaded)),@"home_did_appear_count":@(home.didAppearCount),
        @"home_moving_to_parent":@(home.isMovingToParentViewController),@"home_moving_from_parent":@(home.isMovingFromParentViewController),
        @"search_button_hittable":@(ButtonReceivesHit(home.searchButton)),@"search_activations":@(home.searchActivations),
        @"navigation_stack":stack,@"top_class":top?NSStringFromClass(top.class):@"",@"top_visible":@(VisibleInWindow(top.viewIfLoaded)),
        @"search_did_appear_count":[top isKindOfClass:SmokeSearchViewController.class]?@(((SmokeSearchViewController*)top).didAppearCount):@0,
        @"top_being_presented":@(top.isBeingPresented),@"top_being_dismissed":@(top.isBeingDismissed),
        @"transition_present":@(transition!=nil),@"transition_animated":@(transition.isAnimated),
        @"transition_interactive":@(transition.isInteractive),@"transition_cancelled":@(transition.isCancelled),
        @"transition_duration":@(transition.transitionDuration),@"transition_percent_complete":@(transition.percentComplete)};
}
static void SaveHomeSearchNavigationEvidence(NSURL *output,NSDictionary *evidence) {
    [[NSJSONSerialization dataWithJSONObject:evidence options:NSJSONWritingPrettyPrinted error:nil]
        writeToURL:[output URLByAppendingPathComponent:@"home-search-navigation.json"] atomically:YES];
}
static NSIndexPath *FindRow(UITableViewController *panel, NSString *title) {
    for (NSInteger section=0; section<[panel numberOfSectionsInTableView:panel.tableView]; section++) {
        for (NSInteger row=0; row<[panel tableView:panel.tableView numberOfRowsInSection:section]; row++) {
            NSIndexPath *path=[NSIndexPath indexPathForRow:row inSection:section];
            UITableViewCell *cell=[panel tableView:panel.tableView cellForRowAtIndexPath:path];
            if ([cell.textLabel.text isEqual:title]) return path;
        }
    }
    return nil;
}
static NSArray *FixtureArtworkKeys(id receiver, SEL selector) {
    if (@available(iOS 26.0,*)) return @[MPNowPlayingInfoProperty1x1AnimatedArtwork,MPNowPlayingInfoProperty3x4AnimatedArtwork];
    return @[];
}
static UIImage *MakeCover(BOOL alternate) {
    UIGraphicsImageRendererFormat *format=[UIGraphicsImageRendererFormat defaultFormat]; format.scale=1; format.opaque=YES;
    return [[[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(720,720) format:format] imageWithActions:^(UIGraphicsImageRendererContext *renderer) {
        [[UIColor colorWithRed:0.9 green:0.06 blue:0.06 alpha:1] setFill]; UIRectFill(CGRectMake(0,0,720,360));
        [[UIColor colorWithRed:0.05 green:0.12 blue:0.9 alpha:1] setFill]; UIRectFill(CGRectMake(0,360,720,360));
        [UIColor.systemYellowColor setFill]; [[UIBezierPath bezierPathWithOvalInRect:CGRectMake(100,70,270,240)] fill];
        [(alternate ? UIColor.systemPinkColor : UIColor.systemGreenColor) setFill]; UIRectFill(CGRectMake(440,430,100,170));
        [UIColor.whiteColor setStroke]; UIBezierPath *path=[UIBezierPath bezierPath]; path.lineWidth=14;
        [path moveToPoint:CGPointMake(45,650)]; [path addLineToPoint:CGPointMake(665,70)]; [path stroke];
        [@"FIXTURE" drawAtPoint:CGPointMake(80,560) withAttributes:@{NSFontAttributeName:[UIFont boldSystemFontOfSize:64],NSForegroundColorAttributeName:UIColor.blackColor}];
    }];
}
static NSArray *PixelAt(CGImageRef image, double x, double y) {
    CGRect rect=CGRectMake(floor(CGImageGetWidth(image)*x),floor(CGImageGetHeight(image)*y),1,1);
    CGImageRef pixel=CGImageCreateWithImageInRect(image,rect);Check(pixel!=NULL,@"Crop orientation sample");
    uint8_t rgba[4]={0};CGColorSpaceRef color=CGColorSpaceCreateDeviceRGB();
    CGContextRef context=CGBitmapContextCreate(rgba,1,1,8,4,color,kCGImageAlphaPremultipliedLast|kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(color);Check(context!=NULL,@"Orientation sample bitmap");
    CGContextDrawImage(context,CGRectMake(0,0,1,1),pixel);CGContextRelease(context);CGImageRelease(pixel);
    return @[@(rgba[0]),@(rgba[1]),@(rgba[2])];
}
static void CheckUpright(CGImageRef image) {
    NSArray *top=PixelAt(image,0.94,0.20),*bottom=PixelAt(image,0.94,0.80);
    Check([top[0] intValue]>120 && [top[0] intValue]>2*[top[2] intValue] && [bottom[2] intValue]>120 && [bottom[2] intValue]>2*[bottom[0] intValue],
          [NSString stringWithFormat:@"Expected red top / blue bottom; got top=%@ bottom=%@",top,bottom]);
}
static NSData *SmallPixels(CGImageRef image) {
    NSMutableData *data=[NSMutableData dataWithLength:96*96*4];
    CGColorSpaceRef color=CGColorSpaceCreateDeviceRGB();
    CGContextRef context=CGBitmapContextCreate(data.mutableBytes,96,96,8,96*4,color,kCGImageAlphaPremultipliedLast|kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(color); Check(context!=NULL,@"Frame comparison bitmap");
    CGContextDrawImage(context,CGRectMake(0,0,96,96),image); CGContextRelease(context); return data;
}

// App requests cannot escape to a real service if interception breaks.
@interface SmokeDenyNetwork : NSURLProtocol @end
@implementation SmokeDenyNetwork
+ (BOOL)canInitWithRequest:(NSURLRequest *)request { return YES; }
+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request { return request; }
- (void)startLoading {
    [self.client URLProtocol:self didFailWithError:[NSError errorWithDomain:@"FMXSmoke.NoRealNetwork" code:1 userInfo:@{NSLocalizedDescriptionKey:@"Production parse interception did not handle the fixture; real networking is prohibited"}]];
}
- (void)stopLoading {}
@end

// Only used during the search integration test. Every child NSURLSession still
// goes through the production interceptor, then receives authored JSON here.
// No request can reach a built-in network transport while these factories apply.
static NSDictionary *(^SmokeSearchResponse)(NSURLRequest *);
static NSMutableArray<NSDictionary *> *SmokeSearchRequests;
static IMP SmokeOriginalDefaultFactory,SmokeOriginalEphemeralFactory;
@interface SmokeSearchTransport : NSURLProtocol @end
@implementation SmokeSearchTransport
+ (BOOL)canInitWithRequest:(NSURLRequest *)request {return YES;}
+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request {return request;}
- (void)startLoading {
    NSDictionary *payload=nil;
    @synchronized(SmokeSearchTransport.class) {
        [SmokeSearchRequests addObject:@{@"url":self.request.URL.absoluteString ?: @"",@"method":self.request.HTTPMethod ?: @"GET",@"marked_internal":@([NSURLProtocol propertyForKey:@"FMX.internalRequest" inRequest:self.request]!=nil)}];
        if(SmokeSearchResponse)payload=SmokeSearchResponse(self.request);
    }
    if(!payload){
        NSURLComponents *parts=[NSURLComponents componentsWithURL:self.request.URL resolvingAgainstBaseURL:NO];
        NSMutableArray *keys=NSMutableArray.array;for(NSURLQueryItem *item in parts.queryItems)if(item.name)[keys addObject:item.name];
        NSString *diagnostic=[NSString stringWithFormat:@"Fixture rejected %@ %@%@; query keys=%@; external network denied",self.request.HTTPMethod ?: @"GET",parts.host ?: @"",parts.path ?: @"",[keys sortedArrayUsingSelector:@selector(compare:)]];
        NSLog(@"%@",diagnostic); // Endpoint and field names only: never tokens, headers or query/body values.
        [self.client URLProtocol:self didFailWithError:[NSError errorWithDomain:@"FMXSmoke.NoRealNetwork" code:2 userInfo:@{NSLocalizedDescriptionKey:diagnostic}]];return;
    }
    NSData *data=[NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
    NSHTTPURLResponse *response=[[NSHTTPURLResponse alloc] initWithURL:self.request.URL statusCode:200 HTTPVersion:@"HTTP/1.1" headerFields:@{@"Content-Type":@"application/json"}];
    [self.client URLProtocol:self didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageNotAllowed];[self.client URLProtocol:self didLoadData:data];[self.client URLProtocolDidFinishLoading:self];
}
- (void)stopLoading {}
@end
static NSURLSessionConfiguration *SmokeSearchConfiguration(id receiver,SEL selector,IMP original) {
    NSURLSessionConfiguration *configuration=((id(*)(id,SEL))original)(receiver,selector);
    NSMutableArray *classes=[configuration.protocolClasses mutableCopy] ?: NSMutableArray.array;
    [classes removeObject:SmokeSearchTransport.class];NSUInteger index=[classes indexOfObject:NSClassFromString(@"FMExtensionProtocol")];
    [classes insertObject:SmokeSearchTransport.class atIndex:index==NSNotFound?0:index+1];configuration.protocolClasses=classes;return configuration;
}
static NSURLSessionConfiguration *SmokeSearchDefault(id receiver,SEL selector){return SmokeSearchConfiguration(receiver,selector,SmokeOriginalDefaultFactory);}
static NSURLSessionConfiguration *SmokeSearchEphemeral(id receiver,SEL selector){return SmokeSearchConfiguration(receiver,selector,SmokeOriginalEphemeralFactory);}
static void InstallSearchFixtureTransport(void) {
    SmokeSearchRequests=NSMutableArray.array;
    Method defaultFactory=class_getClassMethod(NSURLSessionConfiguration.class,@selector(defaultSessionConfiguration));
    Method ephemeralFactory=class_getClassMethod(NSURLSessionConfiguration.class,@selector(ephemeralSessionConfiguration));
    SmokeOriginalDefaultFactory=method_setImplementation(defaultFactory,(IMP)SmokeSearchDefault);SmokeOriginalEphemeralFactory=method_setImplementation(ephemeralFactory,(IMP)SmokeSearchEphemeral);
}
static void RestoreSearchFixtureTransport(void) {
    method_setImplementation(class_getClassMethod(NSURLSessionConfiguration.class,@selector(defaultSessionConfiguration)),SmokeOriginalDefaultFactory);
    method_setImplementation(class_getClassMethod(NSURLSessionConfiguration.class,@selector(ephemeralSessionConfiguration)),SmokeOriginalEphemeralFactory);
    @synchronized(SmokeSearchTransport.class){SmokeSearchResponse=nil;}
}
static NSDictionary *SmokeQuery(NSURLRequest *request) {
    NSMutableDictionary *query=NSMutableDictionary.dictionary;
    for(NSURLQueryItem *item in [NSURLComponents componentsWithURL:request.URL resolvingAgainstBaseURL:NO].queryItems)if(item.name && item.value)query[item.name]=item.value;
    return query;
}
static NSData *SmokeRequestBody(NSURLRequest *request) {
    if(request.HTTPBody)return request.HTTPBody;
    NSInputStream *stream=request.HTTPBodyStream;if(!stream)return nil;
    NSMutableData *data=NSMutableData.data;uint8_t bytes[2048];[stream open];
    NSInteger count=0;while(data.length<=64*1024 && (count=[stream read:bytes maxLength:sizeof(bytes)])>0)[data appendBytes:bytes length:(NSUInteger)count];
    [stream close];return count<0 || data.length>64*1024?nil:data;
}
static NSDictionary *SmokeQishuiPayload(void) {
    NSDictionary *track=@{@"base_info":@{@"id":@"shared-fixture-id",@"name":@"Fixture Qishui",@"duration_ms":@123456},
        @"related_info":@{@"artist_links":@[@{@"name":@"Fixture Artist"}],@"album_link":@{@"name":@"Fixture Album"}},
        @"display_info":@{@"cover_url":@{@"urls":@[@"https://fixture.invalid/cover.jpg"]}}};
    return @{@"data":@{@"result_groups":@[@{@"id":@"tracks",@"has_more":@NO,@"next_cursor":@"0",@"data":@[@{@"entity":@{@"track":track}}]}]}};
}
static NSDictionary *FetchSearchFixture(NSURLRequest *request) {
    NSURLSession *session=[NSURLSession sessionWithConfiguration:NSURLSessionConfiguration.defaultSessionConfiguration];dispatch_semaphore_t done=dispatch_semaphore_create(0);
    __block NSData *body;__block NSError *failure;
    [[session dataTaskWithRequest:request completionHandler:^(NSData *data,NSURLResponse *response,NSError *error){body=data;failure=error;dispatch_semaphore_signal(done);}] resume];
    BOOL completed=dispatch_semaphore_wait(done,dispatch_time(DISPATCH_TIME_NOW,8*NSEC_PER_SEC))==0;[session invalidateAndCancel];
    Check(completed,@"Production search callback completes within fixture deadline");Check(!failure,failure.localizedDescription);
    NSDictionary *result=body?[NSJSONSerialization JSONObjectWithData:body options:0 error:nil]:nil;Check([result isKindOfClass:NSDictionary.class],@"Search fixture received a JSON object");return result;
}

// Two independent playlist payloads feed the same parser used by the player.
// Only the simulator's authored container and temporary audio are touched.
static NSDictionary *SmokeLocalPlaylistRoutes(
    FMXManager *manager, FMReplayCache *cache, void (*observe)(id), NSURLRequest *nativeRequest,
    NSUInteger (^workerCount)(void), NSUInteger (^networkCount)(void),
    dispatch_block_t willSelect, void (^bindPlayer)(NSURL *)) {
    NSFileManager *files = NSFileManager.defaultManager;
    NSURL *support = [files URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
    NSURL *documents = [files URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
    NSURL *downloads = [documents URLByAppendingPathComponent:@"Downloads" isDirectory:YES];
    NSURL *index = [support URLByAppendingPathComponent:@"downloaded_tracks.json"];
    BOOL indexWasPresent = [files fileExistsAtPath:index.path];
    NSData *previous = indexWasPresent ? [NSData dataWithContentsOfURL:index] : nil;
    NSArray *savedRows = previous ? [NSJSONSerialization JSONObjectWithData:previous options:0 error:nil] : @[];
    Check((!indexWasPresent || previous) && [savedRows isKindOfClass:NSArray.class], @"Read the original simulator download registry");
    Check([files createDirectoryAtURL:downloads withIntermediateDirectories:YES attributes:nil error:nil], @"Prepare the normal manual-download directory");

    NSString *identifier = NSUUID.UUID.UUIDString;
    NSString *wyID = [NSString stringWithFormat:@"900%u", arc4random()];
    NSURL *manual = [downloads URLByAppendingPathComponent:[NSString stringWithFormat:@"qq_%@.wav", identifier]];
    NSURL *authored = SmokeWriteQualityWave();
    NSDictionary *qq = @{@"server":@"qq", @"id":identifier, @"title":@"Fixture Local Recording",
                         @"singer":@"Authored A / Authored B", @"album":@"Fixture Collection", @"duration":@3};
    NSMutableDictionary *wy = [qq mutableCopy];
    wy[@"server"] = @"wy"; wy[@"id"] = wyID;
    wy[@"singer"] = @"Authored B / Authored A";
    __block NSString *low, *high;
    Main(^{
        low = [cache keyForNamespace:manager.replayNamespace platform:@"tx" trackID:identifier quality:@"128k"];
        high = [cache keyForNamespace:manager.replayNamespace platform:@"tx" trackID:identifier quality:@"flac24bit"];
        Check(manager.runtime.manifest[@"sources"][@"tx"] && manager.runtime.manifest[@"sources"][@"wy"],
              @"A real selected JS source advertises both fixture platforms");
    });
    NSURL *remote = [NSURL URLWithString:@"https://fixture.invalid/unrequested-high-quality-address"];
    NSURL *cached = nil;
    NSUInteger initialWorkers = workerCount(), initialNetwork = networkCount();
    NSMutableArray *origins = [NSMutableArray array];
    BOOL registryWritten = NO, manualWritten = NO;
    NSURL *(^requestFile)(NSDictionary *) = ^NSURL *(NSDictionary *song) {
        willSelect();
        NSMutableURLRequest *request = [nativeRequest mutableCopy];
        NSString *body = [NSString stringWithFormat:@"server=%@&id=%@&level=hires&qmc=1",song[@"server"],song[@"id"]];
        request.HTTPBody = [body dataUsingEncoding:NSUTF8StringEncoding];
        NSDictionary *result = FetchSearchFixture(request);
        NSURL *URL = [NSURL URLWithString:result[@"data"][@"url"] ?: @""];
        Check([result[@"code"] integerValue] == 200 && URL.isFileURL, @"The shared production parse entry returns a local file URL");
        return URL;
    };
    @try {
        Check([files copyItemAtURL:authored toURL:manual error:nil], @"Publish a unique authored manual download");
        manualWritten = YES;
        NSData *rows = [NSJSONSerialization dataWithJSONObject:[savedRows arrayByAddingObject:qq] options:0 error:nil];
        Check([rows writeToURL:index atomically:YES], @"Publish the normal completed-download registry");
        registryWritten = YES;
        Check([cache publishVerifiedAudio:authored fileExtension:@"wav" forKey:low], @"Publish an independent lower-quality copy in the automatic cache");
        cached = [cache audioForKey:low];
        [cache saveAddress:remote forKey:high];
        Check(cached.isFileURL && ![cached isEqual:manual] && [[cache addressForKey:high] isEqual:remote],
              @"A manual file, lower-quality complete cache and higher-quality remote address compete simultaneously");
        for (NSString *origin in @[@"favorites", @"imported-playlist"]) {
            NSArray *songs = [origin isEqual:@"favorites"] ? @[qq, wy] : @[wy, qq];
            NSDictionary *playlist = @{@"id":origin, @"tracks":songs};
            observe(@{@"data":playlist});
            for (NSDictionary *song in songs) {
                // The parse request carries only native identity; matching an
                // alternate platform requires metadata from the playlist.
                NSURL *URL = requestFile(song);
                Check([URL isEqual:manual], @"Exact and confirmed alternate-platform selections return the identical manual file");
                bindPlayer(URL);
                [origins addObject:@{@"playlist":origin, @"selection":song[@"server"],
                                     @"matched":@"same-manual-file"}];
            }
        }
        Check(manualWritten && [files removeItemAtURL:manual error:nil], @"Remove only the authored manual file to exercise the next tier");
        manualWritten = NO;
        for (NSNumber *withHigherAddress in @[@YES, @NO]) {
            if (!withHigherAddress.boolValue) [cache discardAddress:remote forKey:high];
            NSURL *URL = requestFile(qq);
            Check([URL isEqual:cached], @"Complete 128k cache wins before a higher remote URL or a higher fresh JS attempt");
            bindPlayer(URL);
        }
        NSUInteger workers = workerCount() - initialWorkers, network = networkCount() - initialNetwork;
        Check(workers == 0 && network == 0, @"All six local selections reached the player with zero JS resolutions and zero transport requests");
        return @{@"manual_playlist_routes":origins.copy, @"auto_128k_before_cached_high_url":@YES,
                 @"auto_128k_before_uncached_high_js":@YES, @"local_file_player_bindings":@(origins.count + 2),
                 @"local_js_resolutions":@(workers), @"local_transport_requests":@(network)};
    } @finally {
        if (cached) [cache discardAudio:cached forKey:low];
        [cache discardAddress:remote forKey:high];
        if (manualWritten) [files removeItemAtURL:manual error:nil];
        [files removeItemAtURL:authored error:nil];
        if (registryWritten) {
            BOOL restored = indexWasPresent ? [previous writeToURL:index atomically:YES] : [files removeItemAtURL:index error:nil];
            Check(restored, @"Restore the original simulator download registry");
        }
    }
}

@interface SmokeRunner : NSObject
@property(nonatomic,strong) UIWindow *window;
@property(nonatomic,strong) SmokeHomeViewController *home;
@property(nonatomic,strong) UILabel *label;
@property(nonatomic,strong) NSURL *output;
@property(nonatomic,strong) NSMutableArray *results;
@property(nonatomic,copy) NSString *activeTest;
@property(nonatomic,strong) NSArray *realArtworkKeys;
@property(nonatomic) BOOL forced;
@property(nonatomic) BOOL failed;
@property(nonatomic) BOOL requiresForced;
@property(nonatomic) void *extensionHandle;
@property(nonatomic) void *swiftUIFixtureHandle;
- (void)run;
@end

@implementation SmokeRunner
- (void)saveJSON:(BOOL)final {
    NSString *phase=self.forced ? @"forced" : @"natural";
    NSDictionary *report=@{@"schema":@1,@"phase":phase,@"complete":@(final),@"passed":@(!self.failed),
        @"host":@"self-authored Simulator app; original IPA not used",@"systemVersion":UIDevice.currentDevice.systemVersion,
        @"real-supported-animated-artwork-keys":self.realArtworkKeys ?: @[],@"forced-capability":@(self.forced),
        @"requires-forced-coordinator-pass":@(self.requiresForced),@"tests":self.results ?: @[],
        @"active_test":self.activeTest ?: @"",
        @"settings_entry_diagnostics":SettingsEntryDiagnostics(self.extensionHandle),
        @"lock-screen-system-display-validated":@NO,@"original-app-launch-validated":@NO,
        @"note":@"Forced capabilities, if used, exercise local coordinator logic only. This is not a lock-screen display or original-app launch test."};
    NSData *data=[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted|NSJSONWritingSortedKeys error:nil];
    NSString *name=[NSString stringWithFormat:@"smoke-%@%@.json",phase,final ? @"" : @"-progress"];
    [data writeToURL:[self.output URLByAppendingPathComponent:name] options:NSDataWritingAtomic error:nil];
}
- (void)test:(NSString *)name body:(NSDictionary *(^)(void))body {
    NSTimeInterval start=NSProcessInfo.processInfo.systemUptime;
    self.activeTest = name; [self saveJSON:NO];
    fprintf(stderr,"START %s\n",name.UTF8String); fflush(stderr);
    NSMutableDictionary *result=[@{@"name":name} mutableCopy];
    @try { NSDictionary *details=body(); result[@"passed"]=@YES; if(details) result[@"details"]=details; }
    @catch(NSException *exception) { result[@"passed"]=@NO; result[@"error"]=exception.reason ?: exception.name; self.failed=YES; }
    result[@"elapsed_seconds"]=@(NSProcessInfo.processInfo.systemUptime-start);
    self.activeTest = nil;
    [self.results addObject:result]; [self saveJSON:NO];
    fprintf(stderr,"%s %s %s\n",[result[@"passed"] boolValue]?"PASS":"FAIL",name.UTF8String,[result[@"error"] UTF8String] ?: ""); fflush(stderr);
    Main(^{ self.label.text=[NSString stringWithFormat:@"%@\n%@\n%@",self.forced ? @"Forced coordinator fixture" : @"Native extension smoke",name,[result[@"passed"] boolValue] ? @"PASS" : result[@"error"]]; });
}
- (void)screenshot:(NSString *)filename {
    Main(^{
        UIGraphicsImageRenderer *renderer=[[UIGraphicsImageRenderer alloc] initWithSize:self.window.bounds.size];
        UIImage *shot=[renderer imageWithActions:^(UIGraphicsImageRendererContext *context) { [self.window drawViewHierarchyInRect:self.window.bounds afterScreenUpdates:YES]; }];
        [UIImagePNGRepresentation(shot) writeToURL:[self.output URLByAppendingPathComponent:filename] atomically:YES];
    });
}
- (void)captureSurfaceDiagnostics:(NSString *)stem {
    [self screenshot:[stem stringByAppendingString:@".png"]];
    Main(^{
        NSMutableArray *records=NSMutableArray.array,*queue=[NSMutableArray arrayWithObject:self.window];NSHashTable *seen=[NSHashTable hashTableWithOptions:NSPointerFunctionsObjectPointerPersonality];
        for(NSUInteger cursor=0;cursor<queue.count && cursor<384;cursor++) {
            id object=queue[cursor];if([seen containsObject:object])continue;[seen addObject:object];NSMutableDictionary *row=[@{@"class":NSStringFromClass([object class])} mutableCopy];
            @try {
                if([object respondsToSelector:@selector(accessibilityIdentifier)])row[@"identifier"]=[object accessibilityIdentifier] ?: @"";
                if([object respondsToSelector:@selector(accessibilityLabel)])row[@"label"]=[object accessibilityLabel] ?: @"";
                if([object isKindOfClass:UILabel.class])row[@"text"]=((UILabel*)object).text ?: @"";
                if([object isKindOfClass:UIView.class]) {UIView *view=object;row[@"frame"]=NSStringFromCGRect([view convertRect:view.bounds toView:self.window]);row[@"hidden"]=@(view.hidden);row[@"alpha"]=@(view.alpha);row[@"visible"]=@(VisibleInWindow(view));[queue addObjectsFromArray:view.subviews];}
                NSArray *elements=[object respondsToSelector:@selector(accessibilityElements)]?[object accessibilityElements]:nil;
                if([elements isKindOfClass:NSArray.class]){row[@"public_elements"]=@(elements.count);[queue addObjectsFromArray:elements];}
                if([object respondsToSelector:@selector(accessibilityElementCount)] && [object respondsToSelector:@selector(accessibilityElementAtIndex:)]) {
                    NSInteger count=[object accessibilityElementCount];row[@"public_element_count"]=@(count);if(count>0 && count!=NSNotFound)for(NSInteger i=0;i<MIN(count,128);i++){id item=[object accessibilityElementAtIndex:i];if(item)[queue addObject:item];}
                }
            }@catch(NSException *exception){row[@"exception"]=exception.name;}
            [records addObject:row];
        }
        NSMutableArray *controllers=NSMutableArray.array,*pending=[NSMutableArray arrayWithObject:self.window.rootViewController];
        for(NSUInteger i=0;i<pending.count && i<64;i++){UIViewController *vc=pending[i];[controllers addObject:@{@"class":NSStringFromClass(vc.class),@"title":vc.navigationItem.title ?: @"",@"view_loaded":@(vc.isViewLoaded),@"visible":@(VisibleInWindow(vc.viewIfLoaded)),@"children":@(vc.childViewControllers.count),@"navigation_item":NavigationItemDiagnostic(vc.navigationItem)}];[pending addObjectsFromArray:vc.childViewControllers];if(vc.presentedViewController)[pending addObject:vc.presentedViewController];}
        NSDictionary *report=@{@"root_controller":NSStringFromClass(self.window.rootViewController.class),@"key_window":@(self.window.isKeyWindow),@"voice_over_running":@(UIAccessibilityIsVoiceOverRunning()),@"settings_entry_diagnostics":SettingsEntryDiagnostics(self.extensionHandle),@"records":records,@"controllers":controllers};
        [[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:nil] writeToURL:[self.output URLByAppendingPathComponent:[stem stringByAppendingString:@".json"]] atomically:YES];
    });
}
- (void)waitForPresentation:(UIViewController *)controller expanded:(BOOL)expanded {
    Check(Until(^BOOL{return controller.view.window!=nil && !controller.isBeingPresented && !controller.isBeingDismissed && controller.transitionCoordinator==nil;},8),@"UIKit presentation transition completed");
    // Only the independent test host requests the large sheet for an inspectable
    // screenshot. Production presentation code and its default detents stay intact.
    if(expanded) Main(^{
        UISheetPresentationController *sheet=controller.sheetPresentationController;
        if(sheet) [UIView performWithoutAnimation:^{sheet.detents=@[UISheetPresentationControllerDetent.largeDetent];sheet.selectedDetentIdentifier=UISheetPresentationControllerDetentIdentifierLarge;[controller.view layoutIfNeeded];}];
    });
    __block NSUInteger stable=0;
    Check(Until(^BOOL{
        CGRect visible=[controller.view convertRect:controller.view.bounds toView:self.window];
        BOOL ready=controller.view.window!=nil && !controller.isBeingPresented && !controller.isBeingDismissed && controller.transitionCoordinator==nil
            && (!expanded || CGRectGetHeight(visible)>=CGRectGetHeight(self.window.bounds)*0.8);
        stable=ready?stable+1:0;return stable>=4;
    },6),@"Presented surface is stable and visible before capture");
}
- (NSDictionary *)pendingParseCancelled:(BOOL)cancel {
    __block FMXManager *manager;__block LXSourceRuntime *runtime;
    Main(^{manager=[(id)NSClassFromString(@"FMXManager") shared];runtime=manager.runtime;});
    Check(runtime.manifest!=nil,@"Active fixture runtime for pending parse");
    NSTimeInterval budget=cancel?5.0:0.2;
    NSMutableURLRequest *request=[NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"https://aacert.com/ms/api.php?action=parse&_t=2"] cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:budget];
    request.HTTPMethod=@"POST";[request setValue:@"application/x-www-form-urlencoded" forHTTPHeaderField:@"Content-Type"];
    request.HTTPBody=[@"server=wy&id=fixture-pending&level=standard&title=Pending&singer=Test" dataUsingEncoding:NSUTF8StringEncoding];
    NSURLSessionConfiguration *configuration=NSURLSessionConfiguration.ephemeralSessionConfiguration;
    configuration.protocolClasses=@[SmokeDenyNetwork.class];configuration.timeoutIntervalForRequest=budget;configuration.timeoutIntervalForResource=8;
    NSArray *classes=configuration.protocolClasses;Class protocol=NSClassFromString(@"FMExtensionProtocol");
    Check([classes containsObject:protocol]&&[classes containsObject:SmokeDenyNetwork.class]&&[classes indexOfObject:protocol]<[classes indexOfObject:SmokeDenyNetwork.class],@"Pending parse remains behind production interceptor and ahead of deny fixture");
    NSURLSession *session=[NSURLSession sessionWithConfiguration:configuration];dispatch_semaphore_t done=dispatch_semaphore_create(0);
    __block NSError *failure=nil;__block NSUInteger callbacks=0;
    NSURLSessionDataTask *task=[session dataTaskWithRequest:request completionHandler:^(NSData *data,NSURLResponse *response,NSError *error){failure=error;callbacks++;dispatch_semaphore_signal(done);}];
    NSTimeInterval start=NSProcessInfo.processInfo.systemUptime;[task resume];
    BOOL started=YES;__block LXSourceRuntime *pendingWorker=nil;__block NSDictionary *workerBefore=nil,*workerAfter=nil;
    if(cancel) {
        started=Until(^BOOL{
            for(LXSourceRuntime *worker in SmokeIsolatedWorkers(runtime)){
                NSDictionary *resources=SmokeRuntimeResources(worker);
                // Only the fixture-pending JS branch creates this long timer.
                // A timer plus a pending musicUrl call proves real JS execution.
                if([resources[@"timers"] unsignedIntegerValue]==1 && [resources[@"pending"] unsignedIntegerValue]==1 && ![resources[@"invalidated"] boolValue]){
                    pendingWorker=worker;workerBefore=resources;return YES;
                }
            }
            return NO;
        },3);
        [task cancel];
    }
    BOOL completed=dispatch_semaphore_wait(done,dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC))==0;
    [session invalidateAndCancel];
    Check(started,@"Pending Promise handler actually started before client cancellation");
    Check(completed&&callbacks==1,@"Pending request completes exactly once");
    BOOL recognizedDomain=[failure.domain isEqual:NSURLErrorDomain] || (!cancel && [failure.domain isEqual:@"FMExtensionProtocol"]);
    Check(recognizedDomain && failure.code==(cancel?NSURLErrorCancelled:NSURLErrorTimedOut),[NSString stringWithFormat:@"Expected native cancellation/timeout NSError, got %@",failure]);
    NSTimeInterval elapsed=NSProcessInfo.processInfo.systemUptime-start;
    if(cancel) {
        Check(pendingWorker!=nil,@"Observe the distinct worker after its actual pending Promise branch started");
        Check(Until(^BOOL{
            workerAfter=SmokeRuntimeResources(pendingWorker);
            return [workerAfter[@"invalidated"] boolValue] && [workerAfter[@"timers"] unsignedIntegerValue]==0
                && [workerAfter[@"http"] unsignedIntegerValue]==0 && [workerAfter[@"pending"] unsignedIntegerValue]==0
                && [SmokeRuntimeResources(runtime)[@"workers"] unsignedIntegerValue]==0;
        },3),@"Client cancellation drains the worker's timers, network tasks and pending callbacks without retiring its parent");
        Check(Until(^BOOL{return manager.runtime==runtime && runtime.manifest!=nil && [manager.selectedFile isEqual:@"SmokeFixture.js"] && [[NSUserDefaults.standardUserDefaults objectForKey:@"FMX.selectedSource"] isEqual:@"SmokeFixture.js"];},3),@"Ordinary cancellation keeps source enabled and selected");
        __block NSUInteger stable=0;
        Check(Until(^BOOL{stable=[manager.playbackStatus isEqual:@"网易云：本次 JS 解析已取消"]?stable+1:0;return stable>=4;},3),@"Client cancellation remains visible after the runtime cancellation completion");
    } else {
        Check(Until(^BOOL{return manager.runtime==runtime && runtime.manifest!=nil && [manager.selectedFile isEqual:@"SmokeFixture.js"] && [[NSUserDefaults.standardUserDefaults objectForKey:@"FMX.selectedSource"] isEqual:@"SmokeFixture.js"];},3),@"Short outer timeout stops only this session and keeps the responsive source selected");
        Check(elapsed<3,@"Short request timeout must not wait for the inner total resolution budget");
        __block NSUInteger stable=0;
        Check(Until(^BOOL{stable=[manager.playbackStatus isEqual:@"网易云：解析超时，本次已停止"]?stable+1:0;return stable>=4;},3),@"Timeout remains visible after cancellation completion without disabling source");
    }
    NSDictionary *recovery=[self parseServer:@"wy"];
    Check(Until(^BOOL{return manager.runtime==runtime && runtime.manifest!=nil;},2),@"Subsequent production parse succeeds through the same responsive runtime");
    return @{@"request_timeout_seconds":@(budget),@"elapsed_seconds":@(elapsed),@"native_error_domain":failure.domain,@"native_error_code":@(failure.code),@"callback_count":@(callbacks),@"source_kept_enabled":@YES,@"subsequent_parse":recovery,@"real_network_used":@NO,
        @"isolated_worker_observed":@(pendingWorker!=nil),@"worker_resources_before":workerBefore ?: @{},@"worker_resources_after":workerAfter ?: @{},@"production_update_alert_forwarding_added":@NO};
}
- (NSDictionary *)parseServer:(NSString *)server {
    NSString *unique=[NSUUID.UUID.UUIDString stringByReplacingOccurrencesOfString:@"-" withString:@""];
    NSString *identifier=[server isEqual:@"kg"] ? unique : [@"fixture-" stringByAppendingString:unique];
    NSDictionary *fresh=[self parseServer:server identifier:identifier expectCached:NO];
    NSDictionary *replay=[self parseServer:server identifier:identifier expectCached:YES];
    Check([fresh[@"url"] isEqual:replay[@"url"]],@"A second production playback request returns the same cached URL");
    NSMutableDictionary *report=[fresh mutableCopy];
    report[@"second_request_cached_address"]=@YES;
    return report;
}
- (NSDictionary *)parseServer:(NSString *)server identifier:(NSString *)identifier expectCached:(BOOL)cached {
    BOOL kugou=[server isEqual:@"kg"];
    NSString *endpoint=kugou ? [@"https://m.kugou.com/app/i/getSongInfo.php?cmd=playInfo&hash=" stringByAppendingString:identifier] : @"https://aacert.com/ms/api.php?action=parse&_t=1";
    NSMutableURLRequest *request=[NSMutableURLRequest requestWithURL:[NSURL URLWithString:endpoint]];
    request.HTTPMethod=kugou ? @"GET" : @"POST";
    [request setValue:@"application/x-www-form-urlencoded" forHTTPHeaderField:@"Content-Type"];
    [request setValue:@"FreeMusicApp" forHTTPHeaderField:@"User-Agent"];
    if(!kugou)request.HTTPBody=[[NSString stringWithFormat:@"server=%@&id=%@&level=standard&title=Fixture&singer=Test&src_cookie=FIXTURE_NOT_FOR_SCRIPT",server,identifier] dataUsingEncoding:NSUTF8StringEncoding];
    NSURLSessionConfiguration *configuration=NSURLSessionConfiguration.ephemeralSessionConfiguration;
    configuration.protocolClasses=@[SmokeDenyNetwork.class]; configuration.timeoutIntervalForRequest=6;
    Class protocol=NSClassFromString(@"FMExtensionProtocol");
    NSArray *classes=configuration.protocolClasses;
    Check([classes containsObject:protocol] && [classes containsObject:SmokeDenyNetwork.class] && [classes indexOfObject:protocol]<[classes indexOfObject:SmokeDenyNetwork.class],@"Production interceptor precedes deny-all fixture");
    __block FMXManager *manager;__block NSString *previousStatus,*previousRequest;
    Main(^{manager=[(id)NSClassFromString(@"FMXManager") shared];previousStatus=manager.playbackStatus;previousRequest=manager.playbackRequest;});
    Check([(id)protocol canInitWithRequest:request],@"Standard fixture route can actually be handled");
    __block BOOL probeChanged=NO;
    Main(^{probeChanged=!(manager.playbackStatus==previousStatus || [manager.playbackStatus isEqual:previousStatus]) || !(manager.playbackRequest==previousRequest || [manager.playbackRequest isEqual:previousRequest]);});
    Check(!probeChanged,@"Capability probing must not claim that a JS playback request started");
    __block NSMutableArray<NSString *> *observedStatuses=NSMutableArray.array;__block id observer;
    Main(^{observer=[NSNotificationCenter.defaultCenter addObserverForName:@"FMX.changed" object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *notification){if(manager.playbackStatus)[observedStatuses addObject:manager.playbackStatus];}];});
    @try {
    NSURLSession *session=[NSURLSession sessionWithConfiguration:configuration];
    dispatch_semaphore_t done=dispatch_semaphore_create(0);
    __block NSDictionary *payload=nil; __block NSError *failure=nil;
    [[session dataTaskWithRequest:request completionHandler:^(NSData *data,NSURLResponse *response,NSError *error) {
        failure=error; payload=data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil; dispatch_semaphore_signal(done);
    }] resume];
    BOOL finished=dispatch_semaphore_wait(done,dispatch_time(DISPATCH_TIME_NOW,10*NSEC_PER_SEC))==0;
    [session invalidateAndCancel];
    Check(finished,@"Native parse callback deadline"); Check(!failure,failure.localizedDescription);
    Check([payload isKindOfClass:NSDictionary.class] && (kugou ? payload[@"bitRate"]==nil : [payload[@"code"] integerValue]==200),[payload description]);
    if(!kugou)Check([payload[@"data"][@"quality"] isEqual:@"未知"] && payload[@"data"][@"qmc"]==NSNull.null,@"JS URL is plain and requested quality is not presented as measured audio quality");
    NSString *source=[server isEqual:@"qq"] ? @"tx" : server;
    NSString *expected=[NSString stringWithFormat:@"https://fixture.invalid/%@/%@/128k",source,identifier];
    NSString *actual=kugou ? payload[@"url"] : payload[@"data"][@"url"];
    Check([actual isEqual:expected],@"LX source/id/quality mapping");
    NSString *label=@{@"wy":@"网易云",@"qq":@"QQ",@"kg":@"酷狗"}[server];
    NSString *expectedStatus=[label stringByAppendingString:cached ? @"：已复用当前音源的播放地址" : @"：JS 已返回播放地址，实际音质将在播放后确认"];
    __block NSUInteger stable=0;
    Check(Until(^BOOL{stable=[manager.playbackStatus isEqual:expectedStatus]?stable+1:0;return stable>=4;},3),@"Successful JS parsing remains reported as returned URL after protocol cleanup");
    __block NSArray<NSString *> *statuses;__block NSString *status;
    Main(^{statuses=observedStatuses.copy;status=manager.playbackStatus;});
    Check([statuses containsObject:[label stringByAppendingString:@"：正在从最高支持音质查找歌曲"]],@"Actual handler invocation reports lookup independently of source");
    if(cached)Check(![statuses containsObject:[label stringByAppendingString:@"：正在尝试 JS 音质 128k"]],@"Cached playback avoids executing musicUrl again");
    Check([statuses containsObject:expectedStatus],@"Actual returned URL produces a platform-specific result state");
    for(NSString *entry in statuses) for(NSString *privateValue in @[identifier,expected,@"fixture.invalid",@"http://",@"https://",@"FIXTURE_NOT_FOR_SCRIPT"])
        Check(![entry containsString:privateValue],@"Playback diagnostics must not disclose fixture identifiers, URLs, or credentials");
    return @{@"server":server,@"mapped_source":source,@"url":expected,@"playback_status":status,@"observed_playback_states":statuses,@"capability_probe_does_not_record_playback":@YES,@"playback_diagnostics_redacted":@YES,@"external_network_used":@NO};
    } @finally {Main(^{if(observer)[NSNotificationCenter.defaultCenter removeObserver:observer];});}
}
- (NSDictionary *)fourSourceSearch {
    NSArray *(*configurationKeys)(void)=(NSArray*(*)(void))dlsym(self.extensionHandle,"FMXQishuiConfigurationKeys");
    Check(configurationKeys!=NULL,@"Production Qishui configuration schema export exists");
    NSArray *keys=configurationKeys();Check(keys.count==18,@"Verified native Qishui public configuration schema");
    NSMutableDictionary *query=NSMutableDictionary.dictionary;for(NSString *key in keys)query[key]=@"fixture";
    __block NSString *keyword=@"";__block NSString *lastQishuiURL=nil;__block BOOL invalidRequest=NO;
    NSMutableArray *passes=NSMutableArray.array;
    InstallSearchFixtureTransport();
    @try {
        SmokeSearchResponse=^NSDictionary *(NSURLRequest *request) {
            NSDictionary *q=SmokeQuery(request);NSURLComponents *parts=[NSURLComponents componentsWithURL:request.URL resolvingAgainstBaseURL:NO];NSString *host=parts.host,*path=parts.path;
            if([host isEqual:@"aacert.com"] && [path isEqual:@"/ms/api.php"] && [q[@"action"] isEqual:@"search"]) {
                NSString *source=@{@"0":@"wy",@"2":@"kg",@"3":@"qq"}[q[@"platform"]];
                if(!source || ![q[@"keyword"] isEqual:keyword] || ![q[@"page"] isEqual:@"0"] || ![NSURLProtocol propertyForKey:@"FMX.internalRequest" inRequest:request]){invalidRequest=YES;return nil;}
                NSDictionary *track=@{@"id":@"shared-fixture-id",@"server":source,@"title":[@"Fixture " stringByAppendingString:source],@"singer":@"Fixture Artist",@"album":@"Fixture Album",@"duration":@123,@"cover":@"https://fixture.invalid/cover.jpg",@"fixture_marker":source};
                return @{@"code":@200,@"data":@[track],@"page":@0,@"count":@1,@"total":@1};
            }
            if([host isEqual:@"open.qishui.com"] && [path isEqual:@"/api/luna/v1/platform/client/token/get/"]) {
                if(![request.HTTPMethod isEqual:@"GET"] || ![q[@"device_id"] isEqual:@"1234567890123456789"] || ![q[@"trigger_type"] isEqual:@"fixture"]){invalidRequest=YES;return nil;}
                return @{@"client_token":@"SMOKE_SELF_AUTHORED_CLIENT_TOKEN"};
            }
            if([host isEqual:@"open.douyin.com"] && [path isEqual:@"/api/luna/v1/platform/search/"]) {
                NSData *body=SmokeRequestBody(request);NSDictionary *json=body?[NSJSONSerialization JSONObjectWithData:body options:0 error:nil]:nil;
                if(![request.HTTPMethod isEqual:@"POST"] || ![json[@"q"] isEqual:keyword] || ![json[@"cursor"] isEqual:@"0"] || ![json[@"search_type"] isEqual:@"track"] || ![[request valueForHTTPHeaderField:@"access-token"] isEqual:@"SMOKE_SELF_AUTHORED_CLIENT_TOKEN"]){invalidRequest=YES;return nil;}
                lastQishuiURL=request.URL.absoluteString;return SmokeQishuiPayload();
            }
            invalidRequest=YES;return nil;
        };
        FMQishuiSearchClient *client=[[(id)NSClassFromString(@"FMQishuiSearchClient") alloc] initWithConfiguration:@{@"query":query,@"trigger_type":@"fixture"} deviceID:@"1234567890123456789"];
        Check(client!=nil,@"Qishui collaborator is initialized from authored public configuration values");
        [(id)NSClassFromString(@"FMExtensionProtocol") setQishuiSearchClient:client];
        for(NSNumber *entry in @[@0,@2,@3,@4]) {
            __block NSInteger actualPlatform=NSNotFound;
            Main(^{SetAggregateEnabled(NO);[NSUserDefaults.standardUserDefaults setInteger:entry.integerValue forKey:@"searchPlatform"];SetAggregateEnabled(YES);actualPlatform=[NSUserDefaults.standardUserDefaults integerForKey:@"searchPlatform"];});
            Check(actualPlatform==(entry.integerValue==4?3:entry.integerValue),@"All original source selections enter the safe native unified decoder when aggregate is enabled");
            keyword=[NSString stringWithFormat:@"fixture-entry-%@",entry];NSUInteger before;
            @synchronized(SmokeSearchTransport.class){before=SmokeSearchRequests.count;}
            NSString *address=[NSString stringWithFormat:@"https://aacert.com/ms/api.php?action=search&keyword=%@&page=0&platform=%ld",keyword,(long)actualPlatform];
            NSMutableURLRequest *request=[NSMutableURLRequest requestWithURL:[NSURL URLWithString:address] cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:6];
            NSDictionary *response=FetchSearchFixture(request);NSArray *tracks=response[@"data"];
            Check([response[@"code"] integerValue]==200 && [tracks isKindOfClass:NSArray.class] && tracks.count==4,@"Each Home source selection produces exactly four authored source results");
            NSMutableSet *sources=NSMutableSet.set;NSDictionary *qishui=nil;
            for(NSDictionary *track in tracks){[sources addObject:track[@"server"]];if([track[@"server"] isEqual:@"qs"])qishui=track;else Check([track[@"fixture_marker"] isEqual:track[@"server"]],@"Native tracks retain their source-specific fields");}
            Check([sources isEqual:[NSSet setWithArray:@[@"wy",@"kg",@"qq",@"qs"]]],@"Same identifier from different sources must retain all source identities");
            Check([qishui[@"platform"] integerValue]==4 && [qishui[@"id"] isEqual:@"shared-fixture-id"] && fabs([qishui[@"duration"] doubleValue]-123.456)<0.001 && !qishui[@"url"],@"Qishui metadata maps to native source 4 without synthesizing a playback URL");
            NSArray *requests;@synchronized(SmokeSearchTransport.class){requests=[SmokeSearchRequests subarrayWithRange:NSMakeRange(before,SmokeSearchRequests.count-before)];}
            NSUInteger standard=0,qs=0;NSMutableSet *platforms=NSMutableSet.set;
            for(NSDictionary *entryRequest in requests){NSURLRequest *r=[NSURLRequest requestWithURL:[NSURL URLWithString:entryRequest[@"url"]]];if([r.URL.host isEqual:@"aacert.com"]){standard++;[platforms addObject:SmokeQuery(r)[@"platform"] ?: @""];}if([r.URL.host isEqual:@"open.douyin.com"])qs++;}
            Check(!invalidRequest && standard==3 && qs==1 && [platforms isEqual:[NSSet setWithArray:@[@"0",@"2",@"3"]]],@"Actual NSURLSession production fan-out reaches the three native backends and Qishui catalogue exactly once");
            [passes addObject:@{@"original_selected_platform":entry,@"native_decoder_platform":@(actualPlatform),@"returned_sources":[sources.allObjects sortedArrayUsingSelector:@selector(compare:)],@"backend_search_requests":@(standard+qs)}];
        }
        // This second SwiftUI visit measures the wrapper itself. Writing defaults
        // directly cannot establish what @AppStorage exposes to the native search.
        keyword=@"fixture-swiftui-wrapper";
        __block UIViewController *oldRoot,*hosting;__block BOOL commandSent=NO;__block NSDictionary *wrapperEvidence;
        Main(^{
            oldRoot=self.window.rootViewController;
            for(NSString *key in @[@"smoke.swiftui.settings-appearance-count",@"smoke.swiftui.selection-immediate",@"smoke.swiftui.selection-next-turn",@"smoke.swiftui.selection-stable",@"smoke.swiftui.dispatched-search-url",@"smoke.swiftui.search-response",@"smoke.swiftui.search-error",@"smoke.swiftui.search-complete"])[NSUserDefaults.standardUserDefaults removeObjectForKey:key];
            [NSUserDefaults.standardUserDefaults setBool:YES forKey:@"smoke.swiftui.dispatch-search"];
            void *(*factory)(void)=self.swiftUIFixtureHandle?(void*(*)(void))dlsym(self.swiftUIFixtureHandle,"SmokeMakeSwiftUISettingsFixture"):NULL;
            if(factory){hosting=(__bridge_transfer UIViewController*)factory();self.window.rootViewController=hosting;[self.window makeKeyAndVisible];}
        });
        @try {
            Check(hosting!=nil,@"SwiftUI wrapper fixture can be created for the actual search branch");
            BOOL appeared=Until(^BOOL{return VisibleInWindow(hosting.viewIfLoaded) && [NSUserDefaults.standardUserDefaults integerForKey:@"smoke.swiftui.settings-appearance-count"]>0;},6);
            [self captureSurfaceDiagnostics:@"swiftui-wrapper-list-before-command"];
            Check(appeared,@"Real SwiftUI settings component is mounted before exercising its wrapper");
            Main(^{void (*command)(void)=(void(*)(void))dlsym(self.swiftUIFixtureHandle,"SmokeSwiftUISelectQishui");if(command){command();commandSent=YES;}});
            Check(commandSent,@"Fixture Publisher invokes the actual View's shared @AppStorage callback; this is a component test, not a UI tap");
            Check(Until(^BOOL{return [NSUserDefaults.standardUserDefaults boolForKey:@"smoke.swiftui.search-complete"];},9),@"Search dispatched using the settled wrapper value completes through the fixture transport");
            Main(^{NSUserDefaults *d=NSUserDefaults.standardUserDefaults;NSData *data=[d dataForKey:@"smoke.swiftui.search-response"];id response=data?[NSJSONSerialization JSONObjectWithData:data options:0 error:nil]:nil;
                wrapperEvidence=@{@"immediate":[d objectForKey:@"smoke.swiftui.selection-immediate"] ?: NSNull.null,@"next_runloop":[d objectForKey:@"smoke.swiftui.selection-next-turn"] ?: NSNull.null,@"stable_after_350ms":[d objectForKey:@"smoke.swiftui.selection-stable"] ?: NSNull.null,@"actual_search_url":[d stringForKey:@"smoke.swiftui.dispatched-search-url"] ?: @"",@"response":response ?: NSNull.null,@"error":[d stringForKey:@"smoke.swiftui.search-error"] ?: @"",@"source_value_origin":@"SwiftUI @AppStorage setter and getter; not a defaults-only simulation",@"input_trigger":@"fixture Publisher invokes the same View callback as its button",@"ui_tap_validated":@NO};
            });
            [[NSJSONSerialization dataWithJSONObject:wrapperEvidence options:NSJSONWritingPrettyPrinted error:nil] writeToURL:[self.output URLByAppendingPathComponent:@"swiftui-app-storage.json"] atomically:YES];
            NSNumber *stable=wrapperEvidence[@"stable_after_350ms"];NSDictionary *response=[wrapperEvidence[@"response"] isKindOfClass:NSDictionary.class]?wrapperEvidence[@"response"]:@{};
            NSMutableSet *sources=NSMutableSet.set;if([response[@"data"] isKindOfClass:NSArray.class])for(NSDictionary *track in response[@"data"])if(track[@"server"])[sources addObject:track[@"server"]];
            Check([@[@0,@2,@3] containsObject:stable] && [sources isEqual:[NSSet setWithArray:@[@"wy",@"kg",@"qq",@"qs"]]] && [wrapperEvidence[@"error"] length]==0,[NSString stringWithFormat:@"@AppStorage must settle to the common decoder and dispatch a four-source search; immediate=%@ next=%@ stable=%@ sources=%@",wrapperEvidence[@"immediate"],wrapperEvidence[@"next_runloop"],stable,sources]);
        }@finally {Main(^{[NSUserDefaults.standardUserDefaults setBool:NO forKey:@"smoke.swiftui.dispatch-search"];self.window.rootViewController=oldRoot;[self.window makeKeyAndVisible];});}
        Check(lastQishuiURL.length>0,@"Observed authored Qishui search request address");
        Main(^{SetAggregateEnabled(NO);});
        __block BOOL restored=NO;Main(^{restored=[NSUserDefaults.standardUserDefaults integerForKey:@"searchPlatform"]==4;});Check(restored,@"Disabling aggregate restores original native Qishui selection");
        keyword=@"fixture-disabled";NSMutableURLRequest *native=[NSMutableURLRequest requestWithURL:[NSURL URLWithString:lastQishuiURL] cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:6];native.HTTPMethod=@"POST";
        [native setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];[native setValue:@"SMOKE_SELF_AUTHORED_CLIENT_TOKEN" forHTTPHeaderField:@"access-token"];
        native.HTTPBody=[NSJSONSerialization dataWithJSONObject:@{@"q":keyword,@"cursor":@"0",@"search_id":@"smoke-native-search",@"from_search_id":@"smoke-native-search",@"search_type":@"track",@"search_method":@"input",@"search_scene":@"normal",@"scene_name":@"search",@"ab_param":@"",@"last_viewed_media":@{},@"common_params":@{}} options:0 error:nil];
        Check(![(id)NSClassFromString(@"FMExtensionProtocol") canInitWithRequest:native],@"Aggregate disabled leaves the original Qishui search route unclaimed");
        NSUInteger before;@synchronized(SmokeSearchTransport.class){before=SmokeSearchRequests.count;}
        NSDictionary *nativeResponse=FetchSearchFixture(native);NSArray *remaining;
        @synchronized(SmokeSearchTransport.class){remaining=[SmokeSearchRequests subarrayWithRange:NSMakeRange(before,SmokeSearchRequests.count-before)];}
        Check([nativeResponse isEqual:SmokeQishuiPayload()] && remaining.count==1 && ![remaining.firstObject[@"marked_internal"] boolValue] && !invalidRequest,@"Original native Qishui response remains unchanged with no aggregate children after opt-out");
        return @{@"entry_results":passes,@"swiftui_app_storage":wrapperEvidence,@"disabled_native_qishui_response_preserved":@YES,@"cross_source_same_id_retained":@YES,@"external_network_used":@NO,@"configuration":@"self-authored fixture values; production dependency injection"};
    }@finally {
        [(id)NSClassFromString(@"FMExtensionProtocol") setQishuiSearchClient:nil];RestoreSearchFixtureTransport();Main(^{SetAggregateEnabled(YES);});
    }
}
- (NSDictionary *)moviePortrait:(BOOL)portrait cover:(UIImage *)cover {
    NSString *stem=portrait ? @"portrait" : @"square";
    NSURL *URL=[self.output URLByAppendingPathComponent:[stem stringByAppendingString:@".mp4"]];
    dispatch_semaphore_t done=dispatch_semaphore_create(0);
    __block NSURL *written=nil; __block NSError *failure=nil; __block NSUInteger completions=0;
    WriteMovie(cover,portrait,URL,^BOOL{return YES;},^(NSURL *value,NSError *error){written=value;failure=error;completions++;dispatch_semaphore_signal(done);});
    Check(dispatch_semaphore_wait(done,dispatch_time(DISPATCH_TIME_NOW,35*NSEC_PER_SEC))==0,@"Video generation deadline");
    Check(written.isFileURL && !failure,failure.localizedDescription ?: @"No local movie"); Check(completions==1,@"Movie completion count");
    NSNumber *bytes=nil; [URL getResourceValue:&bytes forKey:NSURLFileSizeKey error:nil];
    Check(bytes.unsignedLongLongValue>0 && [NSFileManager.defaultManager isReadableFileAtPath:URL.path],@"Readable local movie");
    AVURLAsset *asset=[AVURLAsset URLAssetWithURL:URL options:nil];
    dispatch_semaphore_t loaded=dispatch_semaphore_create(0);
    [asset loadValuesAsynchronouslyForKeys:@[@"duration",@"tracks"] completionHandler:^{dispatch_semaphore_signal(loaded);}];
    Check(dispatch_semaphore_wait(loaded,dispatch_time(DISPATCH_TIME_NOW,10*NSEC_PER_SEC))==0,@"Movie metadata deadline");
    NSError *metadataError=nil;
    Check([asset statusOfValueForKey:@"tracks" error:&metadataError]==AVKeyValueStatusLoaded,metadataError.localizedDescription ?: @"Movie tracks unavailable");
    AVAssetTrack *track=[asset tracksWithMediaType:AVMediaTypeVideo].firstObject;
    CGSize size=track.naturalSize; double duration=CMTimeGetSeconds(asset.duration);
    Check(track && fabs(size.width-720)<0.1 && fabs(size.height-(portrait?960:720))<0.1,@"Movie dimensions");
    Check(isfinite(duration)&&fabs(duration-6)<0.12,@"Movie duration is approximately 6 seconds");
    AVAssetImageGenerator *generator=[AVAssetImageGenerator assetImageGeneratorWithAsset:asset]; generator.appliesPreferredTrackTransform=YES;
    generator.requestedTimeToleranceBefore=kCMTimeZero; generator.requestedTimeToleranceAfter=kCMTimeZero;
    CGImageRef first=[generator copyCGImageAtTime:CMTimeMake(0,20) actualTime:NULL error:&failure];
    CGImageRef later=[generator copyCGImageAtTime:CMTimeMake(50,20) actualTime:NULL error:&failure];
    if (!first || !later) { if(first)CGImageRelease(first); if(later)CGImageRelease(later); Check(NO,failure.localizedDescription ?: @"Decode movie frames"); }
    CheckUpright(first);
    NSData *a=SmallPixels(first), *b=SmallPixels(later);
    [UIImagePNGRepresentation([UIImage imageWithCGImage:first]) writeToURL:[self.output URLByAppendingPathComponent:[stem stringByAppendingString:@"-first.png"]] atomically:YES];
    [UIImagePNGRepresentation([UIImage imageWithCGImage:later]) writeToURL:[self.output URLByAppendingPathComponent:[stem stringByAppendingString:@"-later.png"]] atomically:YES];
    CGImageRelease(first); CGImageRelease(later);
    const uint8_t *aa=a.bytes,*bb=b.bytes; double sum=0; NSUInteger changed=0;
    for(NSUInteger i=0;i<96*96;i++) { NSUInteger delta=0; for(NSUInteger c=0;c<3;c++)delta+=(NSUInteger)abs((int)aa[i*4+c]-(int)bb[i*4+c]);sum+=delta;if(delta>24)changed++; }
    double mean=sum/(96*96*3), fraction=(double)changed/(96*96);
    Check(mean>0.5 && fraction>0.005,@"Decoded later frame must visibly differ from first frame");
    return @{@"width":@(size.width),@"height":@(size.height),@"duration_seconds":@(duration),@"bytes":bytes,
             @"mean_rgb_difference_0_to_255":@(mean),@"changed_pixel_fraction":@(fraction),@"red_top_blue_bottom_verified":@YES,@"file":URL.lastPathComponent};
}
- (void)coordinatorTests:(UIImage *)cover {
    if (!self.forced && self.realArtworkKeys.count==0) {
        self.requiresForced=YES;
        [self test:@"unforced_unsupported_simulator_preserves_static_artwork" body:^NSDictionary *{
            __block NSDictionary *status; __block BOOL same=NO;
            Main(^{
                InstallArtwork(); status=ArtworkStatus();
                MPMediaItemArtwork *art=[[MPMediaItemArtwork alloc] initWithBoundsSize:cover.size requestHandler:^UIImage *(CGSize size){return cover;}];
                MPNowPlayingInfoCenter.defaultCenter.nowPlayingInfo=@{MPMediaItemPropertyTitle:@"Static fallback fixture",MPMediaItemPropertyArtwork:art};
                same=[MPNowPlayingInfoCenter.defaultCenter.nowPlayingInfo[MPMediaItemPropertyTitle] isEqual:@"Static fallback fixture"] && MPNowPlayingInfoCenter.defaultCenter.nowPlayingInfo[MPMediaItemPropertyArtwork]==art;
                MPNowPlayingInfoCenter.defaultCenter.nowPlayingInfo=nil;
            });
            Check(![status[@"supported"] boolValue] && ![status[@"installed"] boolValue] && same,@"Natural unsupported path must preserve original static state without installing hook");
            return @{@"status":status,@"coordinator_requires_separate_forced_run":@YES};
        }];
        return;
    }
    [self test:@"now_playing_coordinator_preserves_state_and_does_not_recurse" body:^NSDictionary *{
        __block MPMediaItemArtwork *artA,*artB; __block NSDictionary *initial;
        Main(^{
            [NSUserDefaults.standardUserDefaults setBool:YES forKey:@"FMX.dynamicArtwork"]; InstallArtwork(); SetSystemAllowed(@YES); RefreshArtwork();
            artA=[[MPMediaItemArtwork alloc] initWithBoundsSize:cover.size requestHandler:^UIImage *(CGSize size){return cover;}];
            UIImage *other=MakeCover(YES); artB=[[MPMediaItemArtwork alloc] initWithBoundsSize:other.size requestHandler:^UIImage *(CGSize size){return other;}];
        });
        Check(Until(^BOOL{return [ArtworkStatus()[@"enabled"] boolValue] && [ArtworkStatus()[@"generationAllowed"] boolValue];},3),@"Artwork enabled");
        Main(^{MPNowPlayingInfoCenter.defaultCenter.nowPlayingInfo=@{MPMediaItemPropertyTitle:@"Track A",MPMediaItemPropertyArtist:@"Fixture",MPNowPlayingInfoPropertyExternalContentIdentifier:@"fixture-track-A",MPMediaItemPropertyArtwork:artA};});
        Check(Until(^BOOL{return [ArtworkStatus()[@"prepared"] boolValue];},12),[NSString stringWithFormat:@"Artwork preparation: %@",ArtworkStatus()]);
        __block BOOL preserved=NO; __block NSArray *keys;
        Main(^{
            initial=MPNowPlayingInfoCenter.defaultCenter.nowPlayingInfo;keys=ArtworkStatus()[@"keys"];
            preserved=[initial[MPMediaItemPropertyTitle] isEqual:@"Track A"] && initial[MPMediaItemPropertyArtwork]==artA;
            for(NSString *key in keys) if(!initial[key])preserved=NO;
            for(NSUInteger i=0;i<10;i++) MPNowPlayingInfoCenter.defaultCenter.nowPlayingInfo=@{MPMediaItemPropertyTitle:[NSString stringWithFormat:@"Repeat %lu",(unsigned long)i],MPNowPlayingInfoPropertyExternalContentIdentifier:@"fixture-track-A",MPMediaItemPropertyArtwork:artA};
            NSDictionary *last=MPNowPlayingInfoCenter.defaultCenter.nowPlayingInfo;
            preserved=preserved && [last[MPMediaItemPropertyTitle] isEqual:@"Repeat 9"] && last[MPMediaItemPropertyArtwork]==artA;
            for(NSString *key in keys) if(last[key]!=initial[key])preserved=NO;
        });
        Check(preserved,@"Repeated setter preserves metadata and reuses animated objects");
        __block MPMediaItemArtwork *sameImageNewObject;
        Main(^{sameImageNewObject=[[MPMediaItemArtwork alloc] initWithBoundsSize:cover.size requestHandler:^UIImage *(CGSize size){return cover;}];MPNowPlayingInfoCenter.defaultCenter.nowPlayingInfo=@{MPMediaItemPropertyTitle:@"Same image new wrapper",MPNowPlayingInfoPropertyExternalContentIdentifier:@"fixture-track-A",MPMediaItemPropertyArtwork:sameImageNewObject};});
        Check(Until(^BOOL{return [ArtworkStatus()[@"prepared"] boolValue] && ![ArtworkStatus()[@"preparing"] boolValue];},12),@"Rehashed same-image artwork");
        Main(^{NSDictionary *same=MPNowPlayingInfoCenter.defaultCenter.nowPlayingInfo;preserved=same[MPMediaItemPropertyArtwork]==sameImageNewObject;for(NSString *key in keys)if(same[key]!=initial[key])preserved=NO;
            MPNowPlayingInfoCenter.defaultCenter.nowPlayingInfo=nil;
            MPNowPlayingInfoCenter.defaultCenter.nowPlayingInfo=@{MPMediaItemPropertyTitle:@"Obsolete A",MPNowPlayingInfoPropertyExternalContentIdentifier:@"fixture-track-A",MPMediaItemPropertyArtwork:artA};
            MPNowPlayingInfoCenter.defaultCenter.nowPlayingInfo=@{MPMediaItemPropertyTitle:@"Latest B",MPNowPlayingInfoPropertyExternalContentIdentifier:@"fixture-track-B",MPMediaItemPropertyArtwork:artB};});
        Check(preserved,@"Fresh static wrapper for identical pixels keeps animated object identity");
        Check(Until(^BOOL{return [ArtworkStatus()[@"prepared"] boolValue] && [MPNowPlayingInfoCenter.defaultCenter.nowPlayingInfo[MPMediaItemPropertyTitle] isEqual:@"Latest B"];},12),@"Latest artwork wins after rapid track change");
        Main(^{
            NSDictionary *latest=MPNowPlayingInfoCenter.defaultCenter.nowPlayingInfo;
            preserved=latest[MPMediaItemPropertyArtwork]==artB;
            MPMediaItemAnimatedArtwork *existing=[[MPMediaItemAnimatedArtwork alloc] initWithArtworkID:@"smoke-host-owned"
                previewImageRequestHandler:^(CGSize requested,void(^complete)(UIImage *)){complete(cover);}
                videoAssetFileURLRequestHandler:^(CGSize requested,void(^complete)(NSURL *)){complete(nil);}];
            MPNowPlayingInfoCenter.defaultCenter.nowPlayingInfo=@{MPMediaItemPropertyTitle:@"Existing animation",MPMediaItemPropertyArtwork:artB,keys.firstObject:existing};
            preserved=preserved && MPNowPlayingInfoCenter.defaultCenter.nowPlayingInfo[keys.firstObject]==existing;
            MPNowPlayingInfoCenter.defaultCenter.nowPlayingInfo=@{MPMediaItemPropertyTitle:@"Disable fixture",MPMediaItemPropertyArtwork:artB};
        });
        Check(preserved,@"Stale work cannot replace latest artwork; host-provided animation stays intact");
        Check(Until(^BOOL{return [ArtworkStatus()[@"prepared"] boolValue];},12),@"Prepare before disabling");
        Main(^{SetSystemAllowed(@NO);});
        Check(Until(^BOOL{return ![ArtworkStatus()[@"generationAllowed"] boolValue];},3),@"Simulated energy/reduce-motion policy reaches coordinator");
        Main(^{NSDictionary *staticInfo=MPNowPlayingInfoCenter.defaultCenter.nowPlayingInfo;preserved=[staticInfo[MPMediaItemPropertyTitle] isEqual:@"Disable fixture"] && staticInfo[MPMediaItemPropertyArtwork]==artB;for(NSString *key in keys)if(staticInfo[key])preserved=NO;SetSystemAllowed(@YES);});
        Check(preserved,@"Reduced-motion/energy restriction retains title/static artwork and removes owned animation");
        Check(Until(^BOOL{return [ArtworkStatus()[@"generationAllowed"] boolValue] && [ArtworkStatus()[@"prepared"] boolValue];},12),@"Animation can prepare after policy recovers");
        Main(^{[NSUserDefaults.standardUserDefaults setBool:NO forKey:@"FMX.dynamicArtwork"];RefreshArtwork();});
        Check(Until(^BOOL{return ![ArtworkStatus()[@"enabled"] boolValue];},3),@"Disable reaches coordinator");
        Main(^{
            NSDictionary *last=MPNowPlayingInfoCenter.defaultCenter.nowPlayingInfo;
            preserved=[last[MPMediaItemPropertyTitle] isEqual:@"Disable fixture"] && last[MPMediaItemPropertyArtwork]==artB;
            for(NSString *key in keys) if(last[key])preserved=NO;
            MPNowPlayingInfoCenter.defaultCenter.nowPlayingInfo=nil;
            SetSystemAllowed(nil);
        });
        Check(preserved,@"Disable removes owned animated entries and retains title/static artwork");
        return @{@"forced_capability":@(self.forced),@"keys":keys,@"setter_repetitions":@10,@"energy_policy_used_test_override":@YES,@"same_pixels_new_artwork_wrapper_reused":@YES,@"system_lock_screen_verified":@NO};
    }];
}
- (void)run {
    self.results=NSMutableArray.array;
    self.forced=[NSProcessInfo.processInfo.arguments containsObject:@"--force-artwork-capability"];
    NSURL *documents=[NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
    self.output=[documents URLByAppendingPathComponent:@"smoke" isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:self.output withIntermediateDirectories:YES attributes:nil error:nil];
    __block UIImage *cover;
    Main(^{ cover=MakeCover(NO); if(@available(iOS 26.0,*))self.realArtworkKeys=[MPNowPlayingInfoCenter.supportedAnimatedArtworkKeys copy];else self.realArtworkKeys=@[]; });
    [self test:@"load_production_extension_in_independent_host" body:^NSDictionary *{
        __block NSString *error; __block Method capabilityMethod=NULL; __block IMP originalCapability=NULL;
        Main(^{
            if(!self.forced) {
                NSUserDefaults *defaults=NSUserDefaults.standardUserDefaults;
                for(NSString *key in @[@"FMX.settingsAndQishuiConfigured",@"FMX.managesSearchPlatform",@"FMX.singleSearchPlatform",@"FMX.settings.schemaVersion",@"FMX.settings.preUpgradeBackup",@"FMX.settings.upgradeJournal"])[defaults removeObjectForKey:key];
                [defaults setBool:NO forKey:@"FMX.aggregateSearch"];[defaults setInteger:4 forKey:@"searchPlatform"];
            }
            if(self.forced) {
                capabilityMethod=class_getClassMethod(MPNowPlayingInfoCenter.class,@selector(supportedAnimatedArtworkKeys));
                if(capabilityMethod) originalCapability=method_setImplementation(capabilityMethod,(IMP)FixtureArtworkKeys);
            }
            NSString *path=[NSBundle.mainBundle.privateFrameworksPath stringByAppendingPathComponent:@"FMExtension.dylib"];
            self.extensionHandle=dlopen(path.fileSystemRepresentation,RTLD_NOW|RTLD_GLOBAL);
            if(!self.extensionHandle)error=@(dlerror() ?: "unknown dlopen error");
            if(self.extensionHandle) {
                InstallArtwork=(InstallFunction)dlsym(self.extensionHandle,"FMLockScreenInstall"); RefreshArtwork=(InstallFunction)dlsym(self.extensionHandle,"FMLockScreenRefresh");
                ArtworkStatus=(StatusFunction)dlsym(self.extensionHandle,"FMLockScreenStatus"); PreviewArtwork=(PreviewFunction)dlsym(self.extensionHandle,"FMLockScreenTestPreview"); WriteMovie=(MovieFunction)dlsym(self.extensionHandle,"FMLockScreenTestWriteMovie");
                SetSystemAllowed=(SystemPolicyFunction)dlsym(self.extensionHandle,"FMLockScreenTestSetSystemAllowed");
                SetAggregateEnabled=(AggregatePreferenceFunction)dlsym(self.extensionHandle,"FMSearchPreferencesSetAggregateEnabled");
                InstallSearchPreferences=(InstallFunction)dlsym(self.extensionHandle,"FMSearchPreferencesInstall");
                if(InstallArtwork)InstallArtwork();
            }
            if(capabilityMethod && originalCapability)method_setImplementation(capabilityMethod,originalCapability);
        });
        Check(self.extensionHandle!=NULL,error); Check(InstallArtwork&&RefreshArtwork&&ArtworkStatus&&PreviewArtwork&&WriteMovie&&SetSystemAllowed&&SetAggregateEnabled&&InstallSearchPreferences,@"All dynamic module test exports");
        Check(NSClassFromString(@"FMXManager") && NSClassFromString(@"FMExtensionProtocol"),@"Production classes loaded");
        return @{@"same_production_source_files":@[@"FMExtension.m",@"FMExtensionProtocol.m",@"FMSettingsEntry.m",@"FMSearchPreferences.m",@"LXSourceRuntime.m",@"FMLockScreen.m"],@"forced-capability":@(self.forced)};
    }];
    if(self.failed){[self saveJSON:YES];return;}
    if(!self.forced) {
        __block UITableViewController *panel=nil;
        __block SmokeSettingsViewController *settings=nil;
        [self test:@"aggregate_preferences_save_normalize_and_restore_native_source" body:^NSDictionary *{
            Check(Until(^BOOL{NSUserDefaults *d=NSUserDefaults.standardUserDefaults;return [d integerForKey:@"FMX.settings.schemaVersion"]==1 && [d boolForKey:@"FMX.settingsAndQishuiConfigured"] && ![d boolForKey:@"FMX.aggregateSearch"] && [d integerForKey:@"searchPlatform"]==4 && ![d boolForKey:@"FMX.managesSearchPlatform"];},5),@"Versioned upgrade preserves an explicit aggregate opt-out and original Qishui selection");
            Main(^{SetAggregateEnabled(YES);NSUserDefaults *d=NSUserDefaults.standardUserDefaults;Check([d integerForKey:@"searchPlatform"]==3 && [d integerForKey:@"FMX.singleSearchPlatform"]==4,@"Explicitly enabling aggregate safely normalizes the original decoder");});
            __block BOOL restored=NO,normalizes=NO,stableOptOut=NO,otherSuite=NO;
            Main(^{NSUserDefaults *d=NSUserDefaults.standardUserDefaults;SetAggregateEnabled(NO);restored=[d integerForKey:@"searchPlatform"]==4 && ![d boolForKey:@"FMX.managesSearchPlatform"];
                InstallSearchPreferences();stableOptOut=![d boolForKey:@"FMX.aggregateSearch"] && [d integerForKey:@"searchPlatform"]==4;
                [d setInteger:2 forKey:@"searchPlatform"];SetAggregateEnabled(YES);normalizes=[d integerForKey:@"searchPlatform"]==2 && [d integerForKey:@"FMX.singleSearchPlatform"]==2;
                [d setInteger:4 forKey:@"searchPlatform"];normalizes=normalizes && [d integerForKey:@"searchPlatform"]==3;
                [d setObject:@4 forKey:@"searchPlatform"];normalizes=normalizes && [d integerForKey:@"searchPlatform"]==3;
                NSUserDefaults *suite=[[NSUserDefaults alloc] initWithSuiteName:@"org.codex.fmx.smoke.other"];[suite setInteger:4 forKey:@"searchPlatform"];otherSuite=[suite integerForKey:@"searchPlatform"]==4;[suite removePersistentDomainForName:@"org.codex.fmx.smoke.other"];
                SetAggregateEnabled(NO);restored=restored && [d integerForKey:@"searchPlatform"]==2;
                [d setInteger:4 forKey:@"searchPlatform"];SetAggregateEnabled(YES);
            });
            Check(restored && normalizes && stableOptOut && otherSuite,@"Aggregate preferences restore the saved source, normalize both setter paths, and leave opt-out/other suites alone");
            return @{@"migrated_from_native_platform":@4,@"aggregate_native_decoder_platform":@3,@"original_source_restored_on_disable":@YES,@"upgrade_preserves_explicit_opt_out":@YES,@"repeat_install_preserves_opt_out":@YES,@"other_suite_untouched":@YES};
        }];
        [self test:@"home_search_and_unrelated_modal_have_no_extension_overlay" body:^NSDictionary *{
            // Cold Simulator startup can expose a hittable view before its scene
            // and first navigation presentation have settled. Wait for the actual
            // foreground/lifecycle state, retaining the normal animated push.
            NSMutableDictionary *navigationEvidence=NSMutableDictionary.dictionary;__block NSUInteger readySamples=0;
            BOOL ready=Until(^BOOL{
                BOOL settled=self.window.isKeyWindow && self.window.windowScene.activationState==UISceneActivationStateForegroundActive &&
                    UIApplication.sharedApplication.applicationState==UIApplicationStateActive && self.home.didAppearCount>0 &&
                    self.home.navigationController.topViewController==self.home && self.home.navigationController.transitionCoordinator==nil &&
                    VisibleInWindow(self.home.viewIfLoaded) && ButtonReceivesHit(self.home.searchButton);
                readySamples=settled?readySamples+1:0;return readySamples>=4;
            },8);
            Main(^{navigationEvidence[@"before_search"]=HomeSearchNavigationSnapshot(self.home,self.window);});
            navigationEvidence[@"initial_ready"]=@(ready);navigationEvidence[@"consecutive_ready_samples"]=@(readySamples);
            SaveHomeSearchNavigationEvidence(self.output,navigationEvidence);
            Check(ready,@"Foreground home completes its first appearance and navigation before the search tap");
            AssertNoEntryFor(self.window,1);[self screenshot:@"home-no-overlay.png"];
            __block BOOL tapped=NO;Main(^{tapped=TapVisibleButton(self.home.searchButton);navigationEvidence[@"after_button_action"]=HomeSearchNavigationSnapshot(self.home,self.window);});
            navigationEvidence[@"button_received_hit"]=@(tapped);SaveHomeSearchNavigationEvidence(self.output,navigationEvidence);
            Check(tapped,@"Original home search button receives its hit without extension obstruction");
            BOOL searchReady=Until(^BOOL{return [self.home.navigationController.topViewController isKindOfClass:SmokeSearchViewController.class] && self.home.searchActivations==1 && self.home.navigationController.transitionCoordinator==nil;},5);
            Main(^{navigationEvidence[@"after_navigation_wait"]=HomeSearchNavigationSnapshot(self.home,self.window);});
            navigationEvidence[@"search_ready"]=@(searchReady);SaveHomeSearchNavigationEvidence(self.output,navigationEvidence);
            Check(searchReady,@"Original search navigation remains functional");
            AssertNoEntryFor(self.window,0.8);[self screenshot:@"search-no-entry.png"];
            Main(^{[self.home.navigationController popToRootViewControllerAnimated:NO];
                UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"设置" message:@"自定义音源和音质只是提示文字，并非原设置页。" preferredStyle:UIAlertControllerStyleAlert];
                [alert addAction:[UIAlertAction actionWithTitle:@"关闭" style:UIAlertActionStyleCancel handler:nil]];[self.home presentViewController:alert animated:NO completion:nil];});
            Check(Until(^BOOL{return [FrontController(self.window.rootViewController) isKindOfClass:UIAlertController.class];},3),@"Unrelated modal is presented");
            AssertNoEntryFor(self.window,0.8);Main(^{[self.home dismissViewControllerAnimated:NO completion:nil];});
            Check(Until(^BOOL{return self.home.presentedViewController==nil;},3),@"Unrelated modal closes");
            return @{@"legacy_floating_button_absent":@YES,@"original_search_callback_count":@1,@"modal_with_settings_words_rejected":@YES,@"navigation_evidence":navigationEvidence};
        }];
        [self test:@"settings_title_without_settings_sections_is_rejected" body:^NSDictionary *{
            Main(^{SmokeSearchViewController *impostor=[SmokeSearchViewController new];[impostor loadViewIfNeeded];impostor.title=@"设置";[self.home.navigationController pushViewController:impostor animated:NO];});
            AssertNoEntryFor(self.window,0.8);[self screenshot:@"settings-title-impostor.png"];
            Main(^{[self.home.navigationController popToRootViewControllerAnimated:NO];});return @{@"strict_settings_content_required":@YES};
        }];
        [self test:@"original_settings_navigation_and_controls_remain_usable" body:^NSDictionary *{
            Check(Until(^BOOL{return self.home.navigationController.topViewController==self.home && self.home.navigationController.transitionCoordinator==nil && ButtonReceivesHit(self.home.settingsButton);},5),@"Original home gear becomes hittable after the completed pop/layout");
            __block BOOL tapped=NO;Main(^{tapped=TapVisibleButton(self.home.settingsButton);});
            Check(tapped,@"Original home gear receives its hit without extension obstruction");
            Check(Until(^BOOL{UIViewController *top=self.home.navigationController.topViewController;if([top isKindOfClass:SmokeSettingsViewController.class])settings=(SmokeSettingsViewController*)top;return settings!=nil && self.home.settingsActivations==1 && self.home.navigationController.transitionCoordinator==nil && FindSettingsEntry(settings)!=nil;},8),@"Original settings page receives exactly the extension entry");
            Main(^{tapped=TapVisibleButton(settings.originalButton);});
            Check(tapped,@"Original settings navigation button remains visible, hit-testable and unmodified");
            __block BOOL originalRowVisible=NO;Main(^{
                NSIndexPath *path=[NSIndexPath indexPathForRow:0 inSection:0];UITableViewCell *cell=[settings.tableView cellForRowAtIndexPath:path];
                CGPoint center=CGPointMake(CGRectGetMidX(cell.bounds),CGRectGetMidY(cell.bounds));UIView *hit=[self.window hitTest:[cell convertPoint:center toView:self.window] withEvent:nil];
                originalRowVisible=VisibleInWindow(cell) && (hit==cell || [hit isDescendantOfView:cell]);
                if(originalRowVisible)[settings tableView:settings.tableView didSelectRowAtIndexPath:path];
            });
            Check(originalRowVisible && settings.originalRowActivations==1 && settings.originalButtonActivations==1,@"Existing original settings content and button callbacks stay intact");
            [self screenshot:@"original-settings-with-extension.png"];
            return @{@"original_gear_callback_count":@1,@"original_settings_button_callback_count":@1,@"original_row_callback_count":@1};
        }];
        [self test:@"settings_entry_opens_existing_panel_and_aggregate_switch" body:^NSDictionary *{
            __block BOOL opened=NO;Main(^{UIBarButtonItem *entry=FindSettingsEntry(settings);if([entry.customView isKindOfClass:UIButton.class])opened=TapVisibleButton((UIButton*)entry.customView);else if(entry.target && entry.action)opened=[UIApplication.sharedApplication sendAction:entry.action to:entry.target from:entry forEvent:nil];});
            Check(opened,@"Settings extension action is callable through its native control");
            Check(Until(^BOOL{UIViewController *top=FrontController(self.window.rootViewController);if([top isKindOfClass:NSClassFromString(@"FMXPanel")]){panel=(UITableViewController*)top;return YES;}return NO;},5),@"Existing source panel opens from the original settings page");
            Main(^{
                NSIndexPath *artwork = FindRow(panel, @"网易云下载封面");
                Check(artwork != nil, @"Source status shows NetEase download artwork");
                UITableViewCell *row = [panel tableView:panel.tableView cellForRowAtIndexPath:artwork];
                Check([row.accessibilityIdentifier isEqual:@"FMX.neteaseDownloadedArtwork"] && row.detailTextLabel.text.length > 0,
                      @"Download artwork status is present even before any downloads are registered");
            });
            __block UIViewController *surface;Main(^{surface=panel.navigationController;});
            [self waitForPresentation:surface expanded:YES];
            __block BOOL changed=NO;
            Main(^{ NSIndexPath *path=FindRow(panel,@"聚合搜索"); if(!path)return; [panel.tableView scrollToRowAtIndexPath:path atScrollPosition:UITableViewScrollPositionTop animated:NO];[panel.tableView layoutIfNeeded];UITableViewCell *cell=[panel.tableView cellForRowAtIndexPath:path];UISwitch *toggle=[cell.accessoryView isKindOfClass:UISwitch.class]?(UISwitch*)cell.accessoryView:nil;if(toggle){toggle.on=YES;[toggle sendActionsForControlEvents:UIControlEventValueChanged];changed=[NSUserDefaults.standardUserDefaults boolForKey:@"FMX.aggregateSearch"];}});
            Check(changed,@"Aggregate switch writes the production preference");[self screenshot:@"source-panel.png"];return @{@"native_actions_exercised":@YES,@"capture_after_presentation_completed":@YES,@"test_host_expanded_sheet":@YES,@"entry_route":@"home original gear > original settings > extension"};
        }];
        [self test:@"native_document_picker_presents" body:^NSDictionary *{
            Check(panel!=nil,@"Source panel available");
            __block BOOL selected=NO; Main(^{NSIndexPath *path=FindRow(panel,@"从文件导入 JS 音源");if(path){[panel tableView:panel.tableView didSelectRowAtIndexPath:path];selected=YES;}});
            Check(selected&&Until(^BOOL{return [panel.presentedViewController isKindOfClass:UIDocumentPickerViewController.class];},6),@"UIDocumentPicker presents");
            __block UIViewController *picker;Main(^{picker=panel.presentedViewController;});
            [self waitForPresentation:picker expanded:NO];
            [self screenshot:@"document-picker.png"];Main(^{[panel dismissViewControllerAnimated:NO completion:nil];});
            Check(Until(^BOOL{return panel.presentedViewController==nil;},3),@"Dismiss document picker");return @{@"real_file_selected":@NO};
        }];
        [self test:@"monthly_yearly_insights_open_from_settings_and_preserve_playback_metadata" body:^NSDictionary *{
            __block UITableViewController *insights=nil;
            Main(^{NSIndexPath *path=FindRow(panel,@"听歌画像");Check(path!=nil,@"Insights entry in Settings extension");[panel tableView:panel.tableView didSelectRowAtIndexPath:path];});
            Check(Until(^BOOL{UIViewController *top=panel.navigationController.topViewController;if([top isKindOfClass:NSClassFromString(@"FMInsightsViewController")])insights=(id)top;return insights!=nil && insights.navigationController.transitionCoordinator==nil;},5),@"Monthly/annual insights opens");
            __block BOOL monthly=NO,yearly=NO,preserved=NO;
            Main(^{UISegmentedControl *kind=[insights valueForKey:@"periodKind"];monthly=kind.numberOfSegments==2 && [[[insights valueForKey:@"summary"] objectForKey:@"period"] length]==7;kind.selectedSegmentIndex=1;[kind sendActionsForControlEvents:UIControlEventValueChanged];yearly=[[[insights valueForKey:@"summary"] objectForKey:@"period"] length]==4;
                NSDictionary *raw=@{MPMediaItemPropertyTitle:@"Insights sample",MPMediaItemPropertyArtist:@"Fixture",MPNowPlayingInfoPropertyExternalContentIdentifier:@"insights-fixture",MPNowPlayingInfoPropertyElapsedPlaybackTime:@0,MPNowPlayingInfoPropertyPlaybackRate:@1};MPNowPlayingInfoCenter.defaultCenter.nowPlayingInfo=raw;preserved=[MPNowPlayingInfoCenter.defaultCenter.nowPlayingInfo isEqual:raw];});
            Check(monthly&&yearly&&preserved,@"Period controls work and recorder chains metadata without rewriting");
            [self screenshot:@"listening-insights.png"];
            Main(^{MPNowPlayingInfoCenter.defaultCenter.nowPlayingInfo=nil;[insights.navigationController popViewControllerAnimated:NO];});
            Check(Until(^BOOL{return panel.navigationController.topViewController==panel;},3),@"Return to source settings");
            return @{@"month_and_year_controls":@YES,@"local_only":@YES,@"original_metadata_unchanged":@YES,@"original_app_used":@NO};
        }];
        [self test:@"returning_home_removes_entry_and_original_settings_opens_again" body:^NSDictionary *{
            Main(^{if(panel.navigationController.topViewController==panel)[panel.navigationController popViewControllerAnimated:NO];});
            Check(Until(^BOOL{return settings.navigationController.topViewController==settings;},3),@"Pop extension panel back to the same original settings controller");
            Main(^{[self.home.navigationController popToRootViewControllerAnimated:NO];});
            AssertNoEntryFor(self.window,0.8);[self screenshot:@"home-after-settings.png"];
            __block BOOL tapped=NO;Main(^{tapped=TapVisibleButton(self.home.settingsButton);});Check(tapped,@"Original gear remains unblocked after closing extension");
            Check(Until(^BOOL{return [self.home.navigationController.topViewController isKindOfClass:SmokeSettingsViewController.class] && self.home.settingsActivations==2 && FindSettingsEntry(self.home.navigationController.topViewController)!=nil && self.home.navigationController.transitionCoordinator==nil;},5),@"Original settings can be opened a second time");
            __block NSUInteger count=0;Main(^{UIViewController *top=self.home.navigationController.topViewController;for(UIBarButtonItem *item in AllToolbarItems(top.navigationItem))if(IsSettingsEntryItem(item))count++;[self.home.navigationController popToRootViewControllerAnimated:NO];});
            Check(count==1,@"Exactly one extension entry on repeated settings visits");AssertNoEntryFor(self.window,0.5);
            return @{@"original_gear_callback_count":@2,@"settings_extension_entry_count":@1,@"home_overlay_absent_after_return":@YES};
        }];
        [self test:@"real_swiftui_initial_settings_list_entry_and_state" body:^NSDictionary *{
            __block UIViewController *oldRoot,*hosting,*owner;__block NSString *loadError;
            __block BOOL activated=NO;__block NSString *ownerClass;
            __block NSArray<UIBarButtonItem *> *originalToolbar;__block BOOL originalToolbarPreserved=NO;
            __block NSArray<UIBarButtonItemGroup *> *originalGroups;__block BOOL originalGroupsPreserved=NO,capturedBeforeEntry=NO;
            __block NSDictionary *toolbarBefore,*toolbarAfterEntry,*toolbarAfterPop;
            __block NSDictionary *settingsDiagnosticsBefore,*settingsDiagnosticsAfter;
            Main(^{
                oldRoot=self.window.rootViewController;
                settingsDiagnosticsBefore=SettingsEntryDiagnostics(self.extensionHandle);
                for(NSString *key in @[@"smoke.swiftui.open-settings-count",@"smoke.swiftui.settings-appearance-count",@"smoke.swiftui.original-action-count",@"smoke.swiftui.original-info-count"])[NSUserDefaults.standardUserDefaults removeObjectForKey:key];
                NSString *path=[NSBundle.mainBundle.privateFrameworksPath stringByAppendingPathComponent:@"SmokeSettingsFixture.dylib"];
                self.swiftUIFixtureHandle=dlopen(path.fileSystemRepresentation,RTLD_NOW|RTLD_GLOBAL);
                if(!self.swiftUIFixtureHandle){loadError=@(dlerror() ?: "SwiftUI fixture load failed");return;}
                void *(*factory)(void)=(void*(*)(void))dlsym(self.swiftUIFixtureHandle,"SmokeMakeSwiftUISettingsFixture");
                if(!factory){loadError=@"SwiftUI fixture factory export missing";return;}
                hosting=(__bridge_transfer UIViewController*)factory();self.window.rootViewController=hosting;[self.window makeKeyAndVisible];
            });
            @try {
                Check(hosting!=nil,loadError ?: @"SwiftUI hosting controller unavailable");
                BOOL identified=Until(^BOOL{
                    UIViewController *candidate=FindVisibleController(hosting,^BOOL(UIViewController *value){return [value.navigationItem.title isEqual:@"设置"] && value.navigationController.topViewController==value;},0);
                    if(candidate && !originalToolbar && OriginalToolbarItems(candidate).count>0){originalToolbar=OriginalToolbarItems(candidate);originalGroups=OriginalToolbarGroups(candidate);toolbarBefore=NavigationItemDiagnostic(candidate.navigationItem);capturedBeforeEntry=FindSettingsEntry(candidate)==nil;}
                    owner=FindVisibleController(hosting,^BOOL(UIViewController *value){return FindSettingsEntry(value)!=nil;},0);
                    return owner!=nil && owner.transitionCoordinator==nil && [NSUserDefaults.standardUserDefaults integerForKey:@"smoke.swiftui.settings-appearance-count"]>0;
                },30);
                [self captureSurfaceDiagnostics:@"swiftui-initial-settings-list"];
                Check(identified,@"Production settings entry recognizes the real SwiftUI NavigationStack/insetGrouped List/navigationTitle without an external accessibility client");
                Main(^{ownerClass=NSStringFromClass(owner.class);if(!originalToolbar){originalToolbar=OriginalToolbarItems(owner);originalGroups=OriginalToolbarGroups(owner);toolbarBefore=NavigationItemDiagnostic(owner.navigationItem);}toolbarAfterEntry=NavigationItemDiagnostic(owner.navigationItem);settingsDiagnosticsAfter=SettingsEntryDiagnostics(self.extensionHandle);
                    NSArray *items=OriginalToolbarItems(owner),*groups=OriginalToolbarGroups(owner);originalToolbarPreserved=originalToolbar.count>0;for(UIBarButtonItem *item in originalToolbar)if(![items containsObject:item])originalToolbarPreserved=NO;originalGroupsPreserved=YES;for(UIBarButtonItemGroup *group in originalGroups)if(![groups containsObject:group])originalGroupsPreserved=NO;
                });
                SaveToolbarEvidence(self.output,toolbarBefore,toolbarAfterEntry,nil,capturedBeforeEntry,originalToolbarPreserved,originalGroupsPreserved);
                Check(originalToolbar.count>0,@"The actual SwiftUI settings toolbar retains its original item beside the extension");
                Check(originalToolbarPreserved && originalGroupsPreserved,@"Adding the extension must preserve each original modern toolbar group and item object");
                [self screenshot:@"swiftui-original-settings.png"];
                Main(^{UIBarButtonItem *entry=FindSettingsEntry(owner);activated=entry.target && entry.action && [UIApplication.sharedApplication sendAction:entry.action to:entry.target from:entry forEvent:nil];});
                Check(activated,@"Appended entry action is callable on the SwiftUI settings navigation item");
                __block UIViewController *swiftPanel;
                Check(Until(^BOOL{swiftPanel=FindVisibleController(hosting,^BOOL(UIViewController *candidate){return [candidate isKindOfClass:NSClassFromString(@"FMXPanel")];},0);return swiftPanel!=nil;},5),@"Production extension panel opens from the actual SwiftUI navigation surface");
                __block UIViewController *surface;Main(^{surface=swiftPanel.navigationController;});[self waitForPresentation:surface expanded:YES];[self screenshot:@"swiftui-source-panel.png"];
                for(NSNumber *enabled in @[@NO,@YES]) {
                    __block BOOL switched=NO;Main(^{UITableViewController *table=(UITableViewController*)swiftPanel;NSIndexPath *path=FindRow(table,@"聚合搜索");if(!path)return;[table.tableView scrollToRowAtIndexPath:path atScrollPosition:UITableViewScrollPositionTop animated:NO];[table.tableView layoutIfNeeded];UITableViewCell *cell=[table.tableView cellForRowAtIndexPath:path];UISwitch *toggle=[cell.accessoryView isKindOfClass:UISwitch.class]?(UISwitch*)cell.accessoryView:nil;if(toggle){toggle.on=enabled.boolValue;[toggle sendActionsForControlEvents:UIControlEventValueChanged];switched=[NSUserDefaults.standardUserDefaults boolForKey:@"FMX.aggregateSearch"]==enabled.boolValue;}});
                    Check(switched,@"Real panel aggregate toggle updates the AppStorage-observed native preference");AssertRemainsTop(swiftPanel,0.8);
                }
                Main(^{[NSUserDefaults.standardUserDefaults setInteger:0 forKey:@"searchPlatform"];});AssertRemainsTop(swiftPanel,0.8);
                Main(^{if(swiftPanel.navigationController.topViewController==swiftPanel)[swiftPanel.navigationController popViewControllerAnimated:NO];});
                Check(Until(^BOOL{return owner.navigationController.topViewController==owner && FindSettingsEntry(owner)!=nil;},5),@"Extension pops back to the same SwiftUI settings surface and restores its entry");
                [[NSJSONSerialization dataWithJSONObject:@{@"production_entry_identified":@YES,@"push_survived_app_storage_updates":@YES,@"pop_returns_same_owner":@YES,@"initial_navigation_state":@"settings",@"external_accessibility_client_used":@NO,@"home_button_click_validated":@NO} options:NSJSONWritingPrettyPrinted error:nil] writeToURL:[self.output URLByAppendingPathComponent:@"swiftui-entry-state.json"] atomically:YES];
                [self captureSurfaceDiagnostics:@"swiftui-settings-after-pop"];
                Main(^{NSArray *after=OriginalToolbarItems(owner),*groups=OriginalToolbarGroups(owner);originalToolbarPreserved=originalToolbar.count>0;for(UIBarButtonItem *item in originalToolbar)if(![after containsObject:item])originalToolbarPreserved=NO;originalGroupsPreserved=YES;for(UIBarButtonItemGroup *group in originalGroups)if(![groups containsObject:group])originalGroupsPreserved=NO;toolbarAfterPop=NavigationItemDiagnostic(owner.navigationItem);
                    void (*command)(void)=(void(*)(void))dlsym(self.swiftUIFixtureHandle,"SmokeSwiftUIRunOriginalActions");if(command){command();activated=YES;}else activated=NO;
                });
                SaveToolbarEvidence(self.output,toolbarBefore,toolbarAfterEntry,toolbarAfterPop,capturedBeforeEntry,originalToolbarPreserved,originalGroupsPreserved);
                Check(originalToolbarPreserved && originalGroupsPreserved,@"Original SwiftUI toolbar group and item objects remain after the extension push/preferences/pop cycle");
                Check(activated && Until(^BOOL{return [NSUserDefaults.standardUserDefaults integerForKey:@"smoke.swiftui.original-action-count"]==1 && [NSUserDefaults.standardUserDefaults integerForKey:@"smoke.swiftui.original-info-count"]==1;},3),@"Mounted original SwiftUI View executes its shared List and toolbar callbacks via the fixture Publisher component test");
            }@finally {Main(^{if(hosting.presentedViewController)[hosting dismissViewControllerAnimated:NO completion:nil];self.window.rootViewController=oldRoot;[self.window makeKeyAndVisible];});}
            AssertNoEntryFor(self.window,0.5);
            return @{@"real_swiftui_navigation_stack":@YES,@"real_swiftui_inset_grouped_list":@YES,@"initial_navigation_state":@"settings",@"swiftui_home_button_click_validated":@NO,@"ui_tap_validated":@NO,@"external_accessibility_client_used":@NO,@"native_platform_app_storage_and_picker":@YES,@"push_survives_aggregate_and_native_preference_updates":@YES,@"settings_owner_runtime_class":ownerClass ?: @"",@"settings_entry_diagnostics_before":settingsDiagnosticsBefore ?: @{},@"settings_entry_diagnostics":settingsDiagnosticsAfter ?: @{},@"vision_matched_this_list":@([settingsDiagnosticsAfter[@"visionMatchedPages"] unsignedIntegerValue]>[settingsDiagnosticsBefore[@"visionMatchedPages"] unsignedIntegerValue]),@"toolbar_baseline_captured_before_entry":@(capturedBeforeEntry),@"toolbar_before":toolbarBefore ?: @{},@"toolbar_after_entry":toolbarAfterEntry ?: @{},@"toolbar_after_pop":toolbarAfterPop ?: @{},@"original_toolbar_objects_preserved":@(originalToolbarPreserved),@"original_toolbar_groups_preserved":@(originalGroupsPreserved),@"original_button_callback_test":@"fixture Publisher invokes callbacks shared with real buttons; component test only",@"original_list_callbacks":@1,@"original_toolbar_callbacks":@1,@"extension_push_pop_returns_same_owner":@YES,@"original_app_code_used":@NO};
        }];
        [self test:@"home_aggregate_four_sources_and_native_qishui_opt_out" body:^NSDictionary *{return [self fourSourceSearch];}];
#include "V3NavigationTests.inc"
#include "V3InteractionTests.inc"
#include "V3ListeningCaptureTests.inc"
        [self test:@"lxmc_original_swiftui_alert_picker_binding_and_import_request" body:^NSDictionary *{
            void *(*factory)(void)=(void*(*)(void))dlsym(self.swiftUIFixtureHandle,"LXSmokeMakeImportFixture");
            void *(*copyState)(void)=(void*(*)(void))dlsym(self.swiftUIFixtureHandle,"LXSmokeCopyState");
            void (*submit)(void)=(void(*)(void))dlsym(self.swiftUIFixtureHandle,"LXSmokeImportCurrent");
            Check(factory&&copyState&&submit,@"Authored SwiftUI LXMC fixture exports");
            __block UIViewController *oldRoot,*host;__block UIAlertController *alert;__block UIDocumentPickerViewController *picker;__block NSDictionary *state;
            InstallSearchFixtureTransport();SmokeSearchResponse=^NSDictionary *(NSURLRequest *request){
                NSDictionary *query=SmokeQuery(request);
                if([request.URL.host isEqual:@"aacert.com"] && [request.URL.path isEqual:@"/ms/api.php"] && [query[@"action"] isEqual:@"playlist_list"])return @{@"code":@200,@"data":@[]};
                return nil;
            };
            @try {
                Main(^{oldRoot=self.window.rootViewController;host=CFBridgingRelease(factory());self.window.rootViewController=host;[self.window makeKeyAndVisible];});
                Check(Until(^BOOL{UIViewController *front=FrontController(host);if([front isKindOfClass:UIAlertController.class])alert=(id)front;return alert && [alert.textFields.firstObject.rightView.accessibilityIdentifier isEqual:@"FMX.LXMC.SelectFile"];},8),@"Real SwiftUI alert exposes native LXMC accessory");
                Main(^{UIButton *button=(id)alert.textFields.firstObject.rightView;[button sendActionsForControlEvents:UIControlEventTouchUpInside];});
                Check(Until(^BOOL{if([alert.presentedViewController isKindOfClass:UIDocumentPickerViewController.class])picker=(id)alert.presentedViewController;return picker!=nil && picker.transitionCoordinator==nil;},6),@"Original alert presents the public file picker");
                NSDictionary *fixture=@{@"type":@"playListPart_v2",@"data":@{@"id":@"authored-fixture",@"name":@"LX Smoke Playlist",@"list":@[
                    @{@"source":@"wy",@"name":@"Fixture one",@"singer":@"Fixture artist",@"meta":@{@"songId":@"12345"}},
                    @{@"source":@"tx",@"name":@"Fixture two",@"singer":@"Fixture artist",@"meta":@{@"songId":@"Ab0123456789Cd"}}
                ]}};
                NSURL *file=[self.output URLByAppendingPathComponent:@"authored-playlist.lxmc"];
                Check([[NSJSONSerialization dataWithJSONObject:fixture options:0 error:nil] writeToURL:file atomically:YES],@"Write authored playlist fixture");
                Main(^{[picker.delegate documentPicker:picker didPickDocumentsAtURLs:@[file]];});
                Check(Until(^BOOL{state=CFBridgingRelease(copyState());return [state[@"binding_is_local_bridge"] boolValue]&&alert.presentedViewController==nil;},8),@"File selection updates the original SwiftUI TextField binding and restores alert");
                Main(^{Check([alert.message containsString:@"LX Smoke Playlist"]&&[alert.message containsString:@"2"],@"Native alert shows selected playlist summary");});
                [self screenshot:@"lxmc-selected-native-alert.png"];
                Main(^{submit();});
                Check(Until(^BOOL{state=CFBridgingRelease(copyState());return [state[@"completed"] boolValue];},8),@"Original import View callback submits through NSURLSession");
                Check([state[@"response_code"] integerValue]==200&&[state[@"native_tracks_count"] integerValue]==2&&[state[@"expected_fixture_title"] boolValue]&&[state[@"native_servers"] isEqual:@[@"wy",@"qq"]],@"Production bridge returns native title and track identity contract");
                Check([state[@"swift_codable_native_chain"] boolValue] && [state[@"native_record_ids_valid"] boolValue] && [state[@"negative_id_swiftui_list"] boolValue] && [state[@"library_contains_saved_id"] boolValue],@"Native Swift Codable import/create/bulk/list/get chain persists a playlist visible to its SwiftUI list");
                @synchronized(SmokeSearchTransport.class){
                    Check(SmokeSearchRequests.count==1,@"Only the cloud library list reaches the authored transport");
                    NSURLRequest *listed=[NSURLRequest requestWithURL:[NSURL URLWithString:SmokeSearchRequests.firstObject[@"url"]]];
                    Check([SmokeQuery(listed)[@"action"] isEqual:@"playlist_list"],@"Import, create, bulk and local tracks never reach remote transport");
                }
                __block UIAlertController *resultAlert;
                Check(Until(^BOOL{UIViewController *front=FrontController(host);if([front isKindOfClass:UIAlertController.class] && [front.view.accessibilityIdentifier isEqual:@"FMX.LXMC.Result"])resultAlert=(id)front;return resultAlert && resultAlert.transitionCoordinator==nil;},5),@"Successful atomic import presents its production result notice");
                Main(^{[resultAlert dismissViewControllerAnimated:NO completion:nil];});
                [[NSJSONSerialization dataWithJSONObject:state options:NSJSONWritingPrettyPrinted error:nil] writeToURL:[self.output URLByAppendingPathComponent:@"lxmc-import.json"] atomically:YES];
            } @finally {RestoreSearchFixtureTransport();Main(^{if(host.presentedViewController)[host dismissViewControllerAnimated:NO completion:nil];self.window.rootViewController=oldRoot;[self.window makeKeyAndVisible];});}
            return @{@"real_swiftui_alert":@YES,@"file_choice_simulated_through_public_delegate":@YES,@"swiftui_binding_observed":@YES,@"native_response_contract":@YES,@"swift_codable_native_chain":@YES,@"persisted_playlist_visible":@YES,@"negative_playlist_and_record_ids":@YES,@"production_result_notice":@YES,@"external_network_used":@NO,@"backend_playlist_created":@NO,@"ui_tap_validated":@NO};
        }];
#include "V8LXMCImportTests.inc"
        [self test:@"manager_loads_self_authored_LX_fixture" body:^NSDictionary *{
            __block FMXManager *manager; __block NSURL *directory;Main(^{manager=[(id)NSClassFromString(@"FMXManager") shared];directory=[manager directory];});
            NSString *source=@"/* @name Smoke fixture */\nconst {on,send,EVENT_NAMES}=lx;on(EVENT_NAMES.request,({source,action,info})=>{if(action!=='musicUrl'||info.musicInfo.src_cookie||info.musicInfo.cookie)return Promise.reject(Error('fixture contract'));const id=source==='kg'?info.musicInfo.hash:info.musicInfo.songmid;if(id==='fixture-pending'){setTimeout(()=>{},60000);return new Promise(()=>{});}return Promise.resolve('https://fixture.invalid/'+source+'/'+id+'/'+info.type)});send(EVENT_NAMES.inited,{sources:{wy:{type:'music',actions:['musicUrl'],qualitys:['128k']},tx:{type:'music',actions:['musicUrl'],qualitys:['128k']},kg:{type:'music',actions:['musicUrl'],qualitys:['128k']}}});";
            NSError *error=nil;Check([source writeToURL:[directory URLByAppendingPathComponent:@"SmokeFixture.js"] atomically:YES encoding:NSUTF8StringEncoding error:&error],error.localizedDescription);
            Main(^{[manager activate:@{@"file":@"SmokeFixture.js",@"name":@"Self-authored smoke fixture"}];});
            Check(Until(^BOOL{return manager.runtime.manifest[@"sources"][@"wy"] && manager.runtime.manifest[@"sources"][@"tx"];},15),manager.status);
            __block BOOL noPlayback=NO;Main(^{noPlayback=manager.playbackStatus==nil && manager.playbackRequest==nil;});
            Check(noPlayback,@"Enabling a source does not claim an actual JS playback request occurred");
            return @{@"source_script":@"self-authored",@"no_imported_source_executed":@YES,@"no_playback_record_before_first_request":@YES};
        }];
        [self test:@"native_protocol_to_LX_wy" body:^NSDictionary *{return [self parseServer:@"wy"];}];
        [self test:@"native_protocol_to_LX_qq_to_tx" body:^NSDictionary *{return [self parseServer:@"qq"];}];
        [self test:@"native_protocol_to_LX_kg_standard_hash" body:^NSDictionary *{return [self parseServer:@"kg"];}];
        [self test:@"ordinary_client_cancellation_keeps_manager_source_enabled" body:^NSDictionary *{return [self pendingParseCancelled:YES];}];
        [self test:@"short_outer_timeout_keeps_responsive_runtime_and_recovers" body:^NSDictionary *{return [self pendingParseCancelled:NO];}];
        [self test:@"manager_rejects_sources_without_a_routable_quality_intersection" body:^NSDictionary *{
            __block FMXManager *manager;__block NSURL *directory;Main(^{manager=[(id)NSClassFromString(@"FMXManager") shared];directory=[manager directory];});
            NSArray *manifests=@[@{@"kw":@{@"type":@"music",@"actions":@[@"musicUrl"],@"qualitys":@[@"128k"]}},@{@"wy":@{@"type":@"music",@"actions":@[@"musicUrl"],@"qualitys":@[]}},@{@"kg":@{@"type":@"music",@"actions":@[@"musicUrl"],@"qualitys":@[@"flac"]}}];
            for(NSUInteger i=0;i<manifests.count;i++) {
                NSString *json=[[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:manifests[i] options:0 error:nil] encoding:NSUTF8StringEncoding];
                NSString *script=[NSString stringWithFormat:@"lx.on('request',()=>Promise.resolve('https://fixture.invalid/unused'));lx.send('inited',{sources:%@});",json];
                NSString *filename=[NSString stringWithFormat:@"NoRoute%lu.js",(unsigned long)i];NSError *error=nil;
                Check([script writeToURL:[directory URLByAppendingPathComponent:filename] atomically:YES encoding:NSUTF8StringEncoding error:&error],error.localizedDescription);
                Main(^{[manager activate:@{@"file":filename,@"name":@"No routable fixture"}];});
                Check(Until(^BOOL{return manager.runtime==nil && [manager.status containsString:@"没有本版可用平台"];},5),@"Valid LX manifest without a usable native route must be rejected");
                __block BOOL clear=NO;Main(^{clear=manager.selectedFile==nil && [[NSUserDefaults.standardUserDefaults objectForKey:@"FMX.selectedSource"] isEqual:@"SmokeFixture.js"] && [NSUserDefaults.standardUserDefaults boolForKey:@"FMX.sourceActivationPending"];});Check(clear,@"Rejected source is not active; last working selection survives with automatic retry paused");
            }
            return @{@"rejected_fixtures":@[@"kw-only",@"wy-empty-quality",@"kg-flac-only"]};
        }];
        [self test:@"manager_displays_only_the_routable_manifest_intersection" body:^NSDictionary *{
            __block FMXManager *manager;__block NSURL *directory;Main(^{manager=[(id)NSClassFromString(@"FMXManager") shared];directory=[manager directory];});
            NSString *script=@"lx.on('request',()=>Promise.resolve('https://fixture.invalid/unused'));lx.send('inited',{sources:{kw:{type:'music',actions:['musicUrl'],qualitys:['128k']},tx:{type:'music',actions:['musicUrl'],qualitys:['320k']},kg:{type:'music',actions:['musicUrl'],qualitys:['flac']}}});";
            NSError *error=nil;Check([script writeToURL:[directory URLByAppendingPathComponent:@"MixedFixture.js"] atomically:YES encoding:NSUTF8StringEncoding error:&error],error.localizedDescription);
            Main(^{[manager activate:@{@"file":@"MixedFixture.js",@"name":@"Mixed fixture"}];});
            Check(Until(^BOOL{return manager.runtime.manifest!=nil && [manager.status containsString:@"已启用"];},5),@"Mixed source initializes with its usable QQ intersection");
            __block NSString *status;Main(^{status=manager.status;});
            Check([status hasSuffix:@"· QQ"] && ![status containsString:@"酷狗"] && ![status containsString:@"酷我"],@"Status must list only QQ, not unsupported manifest platforms/qualities");
            return @{@"displayed_route":@"QQ",@"status":status};
        }];
        [self test:@"disable_clears_runtime_and_saved_selection" body:^NSDictionary *{
            __block BOOL clean=NO;Main(^{FMXManager *manager=[(id)NSClassFromString(@"FMXManager") shared];[manager disable];clean=manager.runtime==nil && manager.playbackStatus==nil && manager.playbackRequest==nil && [NSUserDefaults.standardUserDefaults objectForKey:@"FMX.selectedSource"]==nil;});
            Check(clean,@"Manager disable must clear runtime, remembered source, and playback diagnostics");return nil;
        }];
#include "V5PlaybackCacheTests.inc"
#include "V6QualityRoutingTests.inc"
#include "V6AdaptivePlaybackTests.inc"
#include "V8PlaybackSequenceTests.inc"
#include "V6PlaybackQualityTests.inc"
#include "V8SourceSelectionTests.inc"
        [self test:@"square_and_portrait_previews" body:^NSDictionary *{
            CheckUpright(cover.CGImage);
            for(NSNumber *portrait in @[@NO,@YES]){UIImage *preview=PreviewArtwork(cover,portrait.boolValue);Check(preview.CGImage && CGImageGetWidth(preview.CGImage)==720 && CGImageGetHeight(preview.CGImage)==(portrait.boolValue?960:720),@"Preview pixel dimensions");CheckUpright(preview.CGImage);[UIImagePNGRepresentation(preview) writeToURL:[self.output URLByAppendingPathComponent:portrait.boolValue?@"portrait-preview.png":@"square-preview.png"] atomically:YES];}return @{@"red_top_blue_bottom_verified":@YES};
        }];
        [self test:@"square_movie_readable_with_real_frame_motion" body:^NSDictionary *{return [self moviePortrait:NO cover:cover];}];
        [self test:@"portrait_movie_readable_with_real_frame_motion" body:^NSDictionary *{return [self moviePortrait:YES cover:cover];}];
        [self test:@"movie_cancellation_cleans_partial_output" body:^NSDictionary *{
            NSURL *URL=[self.output URLByAppendingPathComponent:@"cancelled.mp4"];dispatch_semaphore_t done=dispatch_semaphore_create(0);__block NSUInteger checks=0,completions=0;__block NSError *failure=nil;__block NSURL *result=nil;
            WriteMovie(cover,NO,URL,^BOOL{return ++checks<12;},^(NSURL *value,NSError *error){result=value;failure=error;completions++;dispatch_semaphore_signal(done);});
            Check(dispatch_semaphore_wait(done,dispatch_time(DISPATCH_TIME_NOW,30*NSEC_PER_SEC))==0,@"Cancellation deadline");
            Check(!result && failure && completions==1 && ![NSFileManager.defaultManager fileExistsAtPath:URL.path],@"Cancelled render must fail once and remove partial file");return @{@"continuation_checks":@(checks),@"completion_count":@(completions)};
        }];
    }
    [self coordinatorTests:cover];
    [self screenshot:self.forced ? @"forced-coordinator-host.png" : @"final-host.png"];
    [self saveJSON:YES];
}
@end

@interface SmokeSceneDelegate : UIResponder <UIWindowSceneDelegate>
@property(nonatomic,strong) UIWindow *window;
@property(nonatomic,strong) SmokeRunner *runner;
@end
@implementation SmokeSceneDelegate
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
    self.window=[[UIWindow alloc] initWithWindowScene:(UIWindowScene*)scene];
    NSArray *arguments=NSProcessInfo.processInfo.arguments;
    BOOL lyricFixture=[arguments containsObject:@"--ui-fixture=lyrics"],searchFixture=[arguments containsObject:@"--ui-fixture=swiftui-search"],playerSwipeFixture=[arguments containsObject:@"--ui-fixture=player-swipe"];
    if(lyricFixture||searchFixture||playerSwipeFixture) {
        NSString *frameworks=NSBundle.mainBundle.privateFrameworksPath;
        void *extension=dlopen([[frameworks stringByAppendingPathComponent:@"FMExtension.dylib"] fileSystemRepresentation],RTLD_NOW|RTLD_GLOBAL);
        void *fixture=dlopen([[frameworks stringByAppendingPathComponent:@"SmokeSettingsFixture.dylib"] fileSystemRepresentation],RTLD_NOW|RTLD_GLOBAL);
        void *(*factory)(void)=fixture?(void*(*)(void))dlsym(fixture,lyricFixture?"FMInteractionMakeLyricFixture":playerSwipeFixture?"FMInteractionMakePlayerSwipeFixture":"FMInteractionMakeSwiftUISearchFixture"):NULL;
        NSAssert(extension&&factory,@"UI-test fixture libraries load");
        self.window.rootViewController=CFBridgingRelease(factory());[self.window makeKeyAndVisible];
        void (*install)(void)=(void(*)(void))dlsym(extension,"FMInteractionInstall");if(install)install();
        return;
    }
    SmokeHomeViewController *home=[SmokeHomeViewController new];
    self.window.rootViewController=[[UINavigationController alloc] initWithRootViewController:home];[self.window makeKeyAndVisible];[home loadViewIfNeeded];
    self.runner=[SmokeRunner new];self.runner.window=self.window;self.runner.home=home;self.runner.label=home.progressLabel;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC),dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{@autoreleasepool{[self.runner run];}});
}
@end
@interface SmokeAppDelegate : UIResponder <UIApplicationDelegate> @end
@implementation SmokeAppDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {return YES;}
- (UISceneConfiguration *)application:(UIApplication *)application configurationForConnectingSceneSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
    UISceneConfiguration *configuration=[[UISceneConfiguration alloc] initWithName:@"Smoke" sessionRole:session.role];configuration.delegateClass=SmokeSceneDelegate.class;return configuration;
}
@end
int main(int argc,char *argv[]) { @autoreleasepool { return UIApplicationMain(argc,argv,nil,NSStringFromClass(SmokeAppDelegate.class)); } }
