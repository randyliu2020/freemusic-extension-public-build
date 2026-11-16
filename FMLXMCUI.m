#import "FMLXMCUI.h"
#import "FMLXMC.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <objc/runtime.h>

static const void *FMUIAssociation = &FMUIAssociation;
static IMP FMOriginalAlertWillAppear;
static NSUInteger FMAlertsObserved, FMAlertsMatched, FMFieldsAttached, FMPickersPresented, FMSelectionsFilled;
// Memory only. A multi-list backup remains available when the user reopens the
// native import alert, so each list can be selected without losing the others.
static FMLXMCImportDocument *FMRecentDocument;
static NSTimeInterval FMRecentDocumentTime;

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
    return section == 0 ? @"一次新建一个歌单，不覆盖已有收藏。多个歌单可再次打开原导入入口逐一选择；保存仍使用原 App 的登录状态。" : nil;
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
    FMLXMCRevokeURL(self.bridgeURL); self.bridgeURL = nil;
    self.field.textColor = self.originalTextColor; self.field.tintColor = self.originalTintColor;
    [self.displayLabel removeFromSuperview]; self.displayLabel = nil;
    self.field.accessibilityValue = nil; self.field.text = @"";
    self.alert.message = self.originalMessage;
    [self.field sendActionsForControlEvents:UIControlEventEditingChanged];
}
- (void)fillPlaylist:(FMLXMCPlaylist *)playlist {
    if (!self.alert.view.window || self.alert.presentedViewController) return;
    NSError *error = nil;
    NSString *bridge = FMLXMCRegisterPlaylist(playlist, &error);
    if (!bridge) { [self showError:error]; return; }
    FMLXMCRevokeURL(self.bridgeURL); self.bridgeURL = bridge;
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
    self.alert.message = [NSString stringWithFormat:@"%@\n准备导入 %lu 首%@\n点击原“导入”按钮新建歌单，不覆盖已有收藏。", playlist.title, (unsigned long)playlist.tracks.count, skipped];
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
