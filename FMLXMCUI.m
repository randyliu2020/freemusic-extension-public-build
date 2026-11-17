#import "FMLXMCUI.h"
#import "FMLXMC.h"
#import "FMLXMCLocalStore.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <objc/runtime.h>

static const void *FMUIAssociation = &FMUIAssociation;
static IMP FMOriginalAlertWillAppear;
static NSUInteger FMAlertsObserved, FMAlertsMatched, FMFieldsAttached, FMPickersPresented, FMSelectionsFilled;
// Memory only. A multi-list backup remains available when the user reopens the
// native import alert, so each list can be selected without losing the others.
static FMLXMCImportDocument *FMRecentDocument;
static NSTimeInterval FMRecentDocumentTime;
static NSString *FMActiveImportSelection;
static NSMutableArray<NSDictionary *> *FMImportResults;
static __weak UIAlertController *FMCurrentImportResult;

static void FMShowImportResult(void) {
    if((FMCurrentImportResult.presentingViewController||FMCurrentImportResult.view.window)||!FMImportResults.count||UIApplication.sharedApplication.applicationState!=UIApplicationStateActive)return;
    UIWindow *window=nil;for(UIScene *scene in UIApplication.sharedApplication.connectedScenes)if(scene.activationState==UISceneActivationStateForegroundActive&&[scene isKindOfClass:UIWindowScene.class])for(UIWindow *candidate in ((UIWindowScene *)scene).windows)if(candidate.isKeyWindow)window=candidate;
    UIViewController *front=window.rootViewController;while(front.presentedViewController)front=front.presentedViewController;
    // A local commit can finish before SwiftUI's Import alert has completed its
    // dismissal. Never stack the result onto an alert that is about to leave,
    // or onto another user decision. Retry from the settled library controller.
    if(!front.view.window||front.transitionCoordinator||front.isBeingPresented||front.isBeingDismissed||[front isKindOfClass:UIAlertController.class]){dispatch_after(dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC/3),dispatch_get_main_queue(),^{FMShowImportResult();});return;}
    NSDictionary *result=FMImportResults.firstObject;[FMImportResults removeObjectAtIndex:0];
    NSString *title=[result[@"success"] boolValue]?([result[@"replaced"] boolValue]?@"歌单已覆盖":@"歌单导入成功"):@"导入未完成";
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:title message:result[@"message"] preferredStyle:UIAlertControllerStyleAlert];
    alert.view.accessibilityIdentifier=@"FMX.LXMC.Result";
    FMCurrentImportResult=alert;
    [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action){FMCurrentImportResult=nil;dispatch_after(dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC/3),dispatch_get_main_queue(),^{FMShowImportResult();});}]];
    [front presentViewController:alert animated:YES completion:nil];
}

@interface FMLXMCDuplicateChooser : UITableViewController
@property(nonatomic,copy) NSArray<NSDictionary *> *targets;
@property(nonatomic) BOOL manual;
@property(nonatomic,copy) void (^onDecision)(NSNumber *identifier,BOOL cancel);
@end
@implementation FMLXMCDuplicateChooser
- (void)viewDidLoad{[super viewDidLoad];self.title=self.manual?@"选择导入方式":@"歌单已存在";self.tableView.accessibilityIdentifier=@"FMX.LXMC.DuplicateChoices";self.navigationItem.leftBarButtonItem=[[UIBarButtonItem alloc]initWithBarButtonSystemItem:UIBarButtonSystemItemCancel target:self action:@selector(cancel)];}
- (void)cancel{void(^decision)(NSNumber *,BOOL)=self.onDecision;[self dismissViewControllerAnimated:YES completion:^{if(decision)decision(nil,YES);}];}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView{return 2;}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section{return section?2:self.targets.count;}
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section{return section?nil:@"覆盖所选本机歌单";}
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section{return section?@"仅在这部手机保存。已有云端歌单不改变，也不会自动迁移。":(self.manual?@"文件没有可靠来源标识，无法自动确认同一歌单。只有你明确选择的本机歌单才会覆盖。":@"检测到相同来源或相同内容。覆盖会替换歌曲列表；保存失败时保留原歌单。");}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)path{
    UITableViewCell *cell=[[UITableViewCell alloc]initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];cell.textLabel.numberOfLines=2;
    if(!path.section){NSDictionary *target=self.targets[path.row];cell.textLabel.text=[NSString stringWithFormat:@"覆盖“%@”",target[@"title"]];cell.detailTextLabel.text=[NSString stringWithFormat:@"%@ 首 · 本机歌单",target[@"count"]];cell.accessibilityIdentifier=[NSString stringWithFormat:@"FMX.LXMC.Replace.%ld",(long)path.row];}
    else{cell.textLabel.text=path.row?@"取消":@"另存为新歌单";cell.accessibilityIdentifier=path.row?@"FMX.LXMC.Cancel":@"FMX.LXMC.SaveCopy";}return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)path{
    [tableView deselectRowAtIndexPath:path animated:YES];NSNumber *identifier=path.section?nil:self.targets[path.row][@"id"];BOOL cancelled=path.section&&path.row==1;void(^decision)(NSNumber *,BOOL)=self.onDecision;
    [self dismissViewControllerAnimated:YES completion:^{if(decision)decision(identifier,cancelled);}];
}
@end

@interface FMLXMCChooser : UITableViewController
@property(nonatomic, strong) FMLXMCImportDocument *document;
@property(nonatomic, copy) void (^onChoose)(FMLXMCPlaylist * _Nullable);
@end
@implementation FMLXMCChooser
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"选择 LX 歌单";
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemCancel target:self action:@selector(cancel)];
    self.tableView.accessibilityIdentifier = @"FMX.LXMC.Lists";
}
- (void)cancel { [self dismissViewControllerAnimated:YES completion:nil]; }
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 2; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return section == 0 ? self.document.playlists.count : 1; }
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    return section == 0 ? @"一次导入一个歌单，保存在这部手机。重复导入可选择覆盖、另存或取消；云端歌单不改变。多个歌单可再次打开此入口逐一选择。" : nil;
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    cell.textLabel.numberOfLines = 2; cell.detailTextLabel.numberOfLines = 0;
    if (indexPath.section == 1) { cell.textLabel.text = @"选择另一个 .lxmc 文件"; return cell; }
    FMLXMCPlaylist *playlist = self.document.playlists[indexPath.row];
    cell.textLabel.text = playlist.title;
    cell.detailTextLabel.text = [NSString stringWithFormat:@"可导入 %lu 首，共 %lu 首；跳过 %lu 首", (unsigned long)playlist.tracks.count, (unsigned long)playlist.inputCount, (unsigned long)(playlist.inputCount - playlist.tracks.count)];
    cell.selectionStyle = playlist.tracks.count ? UITableViewCellSelectionStyleDefault : UITableViewCellSelectionStyleNone;
    cell.textLabel.textColor = playlist.tracks.count ? UIColor.labelColor : UIColor.secondaryLabelColor;
    cell.accessibilityIdentifier = [NSString stringWithFormat:@"FMX.LXMC.List.%ld", (long)indexPath.row];
    return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    FMLXMCPlaylist *playlist = indexPath.section == 0 ? self.document.playlists[indexPath.row] : nil;
    if (indexPath.section == 0 && !playlist.tracks.count) return;
    void (^chosen)(FMLXMCPlaylist *) = self.onChoose;
    [self dismissViewControllerAnimated:YES completion:^{ if (chosen) chosen(playlist); }];
}
@end

@interface FMLXMCAlertSession : NSObject <UIDocumentPickerDelegate>
@property(nonatomic, weak) UIAlertController *alert;
@property(nonatomic, weak) UITextField *field;
@property(nonatomic, strong) UILabel *displayLabel;
@property(nonatomic, strong) UIColor *originalTextColor;
@property(nonatomic, strong) UIColor *originalTintColor;
@property(nonatomic, copy) NSString *originalMessage;
@property(nonatomic, copy) NSString *bridgeURL;
@property(nonatomic) BOOL working;
- (void)open;
@end

@implementation FMLXMCAlertSession
- (void)showError:(NSError *)error {
    if (!self.alert.view.window) return;
    self.alert.message = error.localizedDescription ?: @"无法读取 LX 歌单。";
}
- (void)open {
    if (self.working || self.alert.presentedViewController || !self.alert.view.window) return;
    [self.field resignFirstResponder];
    if (FMRecentDocument && NSProcessInfo.processInfo.systemUptime - FMRecentDocumentTime < 1800) [self showLists:FMRecentDocument];
    else [self pickFile];
}
- (void)pickFile {
    UIAlertController *alert = self.alert;
    if (!alert.view.window || alert.presentedViewController) return;
    // Present from the CURRENT alert, not from its already-presenting parent.
    // The full-screen picker temporarily covers the native alert without toggling
    // SwiftUI's isPresented binding or losing the original Import button closure.
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeData] asCopy:YES];
    picker.allowsMultipleSelection = NO; picker.delegate = self;
    picker.modalPresentationStyle = UIModalPresentationFullScreen;
    objc_setAssociatedObject(picker, FMUIAssociation, self, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [alert presentViewController:picker animated:YES completion:^{ FMPickersPresented++; }];
}
- (void)showLists:(FMLXMCImportDocument *)document {
    if (!self.alert.view.window || self.alert.presentedViewController) return;
    FMLXMCChooser *chooser = [[FMLXMCChooser alloc] initWithStyle:UITableViewStyleInsetGrouped];
    chooser.document = document;
    __weak typeof(self) weakSelf = self;
    chooser.onChoose = ^(FMLXMCPlaylist *playlist) { if (playlist) [weakSelf fillPlaylist:playlist]; else [weakSelf pickFile]; };
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:chooser];
    nav.modalPresentationStyle = UIModalPresentationFullScreen;
    [self.alert presentViewController:nav animated:YES completion:nil];
}
- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
    self.working = NO;
    [controller dismissViewControllerAnimated:YES completion:nil];
}
- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSURL *url = urls.firstObject;
    if (!url || ![url.pathExtension.lowercaseString isEqualToString:@"lxmc"]) {
        [controller dismissViewControllerAnimated:YES completion:^{ [self showError:[NSError errorWithDomain:FMLXMCErrorDomain code:20 userInfo:@{NSLocalizedDescriptionKey:@"请选择 .lxmc 歌单文件。"}]]; }];
        return;
    }
    self.working = YES;
    BOOL scoped = [url startAccessingSecurityScopedResource];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *error = nil;
        FMLXMCImportDocument *document = FMLXMCReadFile(url, &error);
        if (scoped) [url stopAccessingSecurityScopedResource];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.working = NO;
            [controller dismissViewControllerAnimated:YES completion:^{
                if (!document) { [self showError:error]; return; }
                FMRecentDocument = document; FMRecentDocumentTime = NSProcessInfo.processInfo.systemUptime;
                if (document.playlists.count == 1) [self fillPlaylist:document.playlists.firstObject];
                else [self showLists:document];
            }];
        });
    });
}
- (void)clearSelectionForEditing {
    if (!self.bridgeURL) return;
    if([FMActiveImportSelection isEqual:self.bridgeURL])FMActiveImportSelection=nil;
    [FMLXMCLocalStore.sharedStore revokeImportURL:self.bridgeURL]; self.bridgeURL = nil;
    self.field.textColor = self.originalTextColor; self.field.tintColor = self.originalTintColor;
    [self.displayLabel removeFromSuperview]; self.displayLabel = nil;
    self.field.accessibilityValue = nil; self.field.text = @"";
    self.alert.message = self.originalMessage;
    [self.field sendActionsForControlEvents:UIControlEventEditingChanged];
}
- (void)fillPlaylist:(FMLXMCPlaylist *)playlist {
    if (!self.alert.view.window || self.alert.presentedViewController) return;
    NSArray *targets=[FMLXMCLocalStore.sharedStore matchesForPlaylist:playlist];
    BOOL manual=!playlist.sourceIdentity&&!targets.count;
    if(manual)targets=FMLXMCLocalStore.sharedStore.nativePlaylists;
    if(!targets.count){[self preparePlaylist:playlist replacing:nil];return;}
    FMLXMCDuplicateChooser *chooser=[[FMLXMCDuplicateChooser alloc]initWithStyle:UITableViewStyleInsetGrouped];chooser.targets=targets;chooser.manual=manual;
    __weak typeof(self) weak=self;chooser.onDecision=^(NSNumber *identifier,BOOL cancel){if(cancel){[weak clearSelectionForEditing];return;}[weak preparePlaylist:playlist replacing:identifier];};
    UINavigationController *navigation=[[UINavigationController alloc]initWithRootViewController:chooser];navigation.modalPresentationStyle=UIModalPresentationFullScreen;[self.alert presentViewController:navigation animated:YES completion:nil];
}
- (void)preparePlaylist:(FMLXMCPlaylist *)playlist replacing:(NSNumber *)identifier {
    if (!self.alert.view.window || self.alert.presentedViewController) return;
    [FMLXMCLocalStore.sharedStore revokeImportURL:self.bridgeURL];self.bridgeURL=nil;
    NSError *error = nil;
    NSString *bridge = [FMLXMCLocalStore.sharedStore preparePlaylist:playlist replacing:identifier error:&error];
    if (!bridge) { [self showError:error]; return; }
    self.bridgeURL = bridge;
    FMActiveImportSelection=bridge;
    UITextField *field = self.field;
    [field resignFirstResponder];
    field.text = bridge;
    // The native binding receives the local bridge URL. The user sees the actual
    // playlist title; no synthetic URL is copied to the clipboard or shown.
    field.textColor = UIColor.clearColor; field.tintColor = UIColor.clearColor;
    [self.displayLabel removeFromSuperview];
    UILabel *label = [UILabel new]; label.translatesAutoresizingMaskIntoConstraints = NO;
    label.text = playlist.title; label.font = field.font; label.textColor = UIColor.labelColor;
    label.userInteractionEnabled = NO; label.isAccessibilityElement = NO;
    [field addSubview:label];
    [NSLayoutConstraint activateConstraints:@[
        [label.leadingAnchor constraintEqualToAnchor:field.leadingAnchor constant:6],
        [label.trailingAnchor constraintEqualToAnchor:field.trailingAnchor constant:-86],
        [label.centerYAnchor constraintEqualToAnchor:field.centerYAnchor]
    ]];
    self.displayLabel = label;
    field.accessibilityValue = [NSString stringWithFormat:@"%@，%lu 首", playlist.title, (unsigned long)playlist.tracks.count];
    NSMutableArray *details = [NSMutableArray array];
    if (playlist.duplicateCount) [details addObject:[NSString stringWithFormat:@"重复 %lu 首", (unsigned long)playlist.duplicateCount]];
    if (playlist.invalidCount) [details addObject:[NSString stringWithFormat:@"资料不完整 %lu 首", (unsigned long)playlist.invalidCount]];
    NSDictionary *names = @{@"kw":@"酷我", @"mg":@"咪咕", @"local":@"本地文件"};
    for (NSString *source in [playlist.unsupportedSources.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        [details addObject:[NSString stringWithFormat:@"%@暂不支持 %@ 首", names[source] ?: source, playlist.unsupportedSources[source]]];
    }
    NSString *skipped = details.count ? [@"\n跳过：" stringByAppendingString:[details componentsJoinedByString:@"；"]] : @"";
    self.alert.message = [NSString stringWithFormat:@"%@\n准备导入 %lu 首%@\n%@\n仅保存在这部手机，已有云端歌单不改变。", playlist.title, (unsigned long)playlist.tracks.count, skipped,identifier?@"点击“导入”覆盖所选本机歌单；失败时保留原内容。":@"点击“导入”另存为本机歌单。"];
    [field sendActionsForControlEvents:UIControlEventEditingChanged];
    FMSelectionsFilled++;
}
@end

static void FMAttach(UIAlertController *alert) {
    FMAlertsObserved++;
    if (objc_getAssociatedObject(alert, FMUIAssociation) || alert.preferredStyle != UIAlertControllerStyleAlert ||
        ![alert.title isEqualToString:@"导入外部歌单"] || alert.textFields.count != 1) return;
    UITextField *field = alert.textFields.firstObject;
    if (![field.placeholder isEqualToString:@"支持QQ音乐/网易云/酷狗歌单的URL"]) return;
    // The original Cancel action must remain intact. When its alert is reopened,
    // retire a selection that was never submitted; an in-flight native import is
    // not revoked when SwiftUI destroys the old alert after pressing Import.
    [FMLXMCLocalStore.sharedStore revokeImportURL:FMActiveImportSelection];FMActiveImportSelection=nil;
    FMAlertsMatched++;
    if (field.rightView) return; // Do not replace original controls.
    FMLXMCAlertSession *session = [FMLXMCAlertSession new];
    session.alert = alert; session.field = field;
    session.originalMessage = alert.message;
    session.originalTextColor = field.textColor; session.originalTintColor = field.tintColor;
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    [button setTitle:@"选 LX 文件" forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    button.frame = CGRectMake(0, 0, 80, 36);
    button.accessibilityIdentifier = @"FMX.LXMC.SelectFile";
    [button addTarget:session action:@selector(open) forControlEvents:UIControlEventTouchUpInside];
    field.rightView = button; field.rightViewMode = UITextFieldViewModeAlways;
    [field addTarget:session action:@selector(clearSelectionForEditing) forControlEvents:UIControlEventEditingDidBegin];
    objc_setAssociatedObject(alert, FMUIAssociation, session, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    FMFieldsAttached++;
}
static void FMAlertWillAppear(UIAlertController *self, SEL selector, BOOL animated) {
    ((void (*)(id, SEL, BOOL))FMOriginalAlertWillAppear)(self, selector, animated);
    FMAttach(self);
}
void FMLXMCUIInstall(void) {
    NSCAssert(NSThread.isMainThread, @"Install LXMC UI on main thread");
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        FMImportResults=[NSMutableArray array];
        [NSNotificationCenter.defaultCenter addObserverForName:FMLXMCLocalImportDidFinish object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note){if(FMImportResults.count<16)[FMImportResults addObject:note.userInfo];dispatch_after(dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC/3),dispatch_get_main_queue(),^{FMShowImportResult();});}];
        [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note){FMShowImportResult();}];
        SEL selector = @selector(viewWillAppear:);
        Method original = class_getInstanceMethod(UIAlertController.class, selector);
        FMOriginalAlertWillAppear = method_getImplementation(original);
        // Replace only UIAlertController, even when the original is inherited.
        class_replaceMethod(UIAlertController.class, selector, (IMP)FMAlertWillAppear, method_getTypeEncoding(original));
    });
}
NSDictionary *FMLXMCUIDiagnostics(void) {
    NSCAssert(NSThread.isMainThread, @"Read LXMC UI diagnostics on main thread");
    return @{@"alertsObserved":@(FMAlertsObserved), @"alertsMatched":@(FMAlertsMatched), @"fieldsAttached":@(FMFieldsAttached), @"pickersPresented":@(FMPickersPresented), @"selectionsFilled":@(FMSelectionsFilled)};
}
