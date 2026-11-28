#import <UIKit/UIKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import "LXSourceRuntime.h"
#import "FMExtensionProtocol.h"
#import "FMLockScreen.h"
#import "FMSettingsEntry.h"
#import "FMSearchPreferences.h"
#import "FMQishuiSearch.h"
#import "FMInsights.h"
#import "FMInteraction.h"
#import "FMSongMenu.h"
#import "FMLXMCUI.h"
#import "FMNavigation.h"
#import "FMPlaybackCache.h"
#import "FMQualityResolver.h"
#import "FMPreferredDownloadStore.h"
#import "FMReplayCache.h"
#import "FMReplayMedia.h"
#import "FMAdaptivePlayback.h"
#import "FMTrackMetadata.h"
#import "FMDownloadIntegration.h"
#import "FMDownloadArtworkIntegration.h"
#import "FMNativeDownloadCoverDisplay.h"
#import "FMPlaybackSequence.h"
#import "FMSettingsMigration.h"

static NSString *const FMXChanged = @"FMX.changed";
static NSString *const FMXSelected = @"FMX.selectedSource";
static NSString *const FMXActivationPending = @"FMX.sourceActivationPending";

// Keep activation, UI and route selection aligned with metadata this host can supply.
static NSArray<NSString *> *FMXRoutableQualities(NSDictionary *manifest, NSString *source) {
    if (![@[@"wy", @"tx", @"kg"] containsObject:source]) return @[];
    NSArray *advertised = manifest[@"sources"][source][@"qualitys"];
    if (![advertised isKindOfClass:NSArray.class]) return @[];
    if ([source isEqual:@"kg"]) return [advertised containsObject:@"128k"] ? @[@"128k"] : @[];
    NSMutableArray *supported = NSMutableArray.array;
    for (NSString *quality in @[@"128k", @"320k", @"flac", @"flac24bit"])
        if ([advertised containsObject:quality]) [supported addObject:quality];
    return supported;
}

static NSArray<NSString *> *FMXRoutableSourceNames(NSDictionary *manifest) {
    NSMutableArray *names = NSMutableArray.array;
    NSDictionary *labels = @{@"wy":@"网易云", @"tx":@"QQ", @"kg":@"酷狗（标准音质）"};
    for (NSString *source in @[@"wy", @"tx", @"kg"])
        if (FMXRoutableQualities(manifest, source).count) [names addObject:labels[source]];
    return names;
}

static NSSet<NSString *> *FMXCacheServers(NSDictionary *manifest) {
    NSMutableSet *servers = NSMutableSet.set;
    for (NSString *source in @[@"wy", @"tx", @"kg"])
        if (FMXRoutableQualities(manifest, source).count)
            [servers addObject:[source isEqual:@"tx"] ? @"qq" : source];
    return servers;
}

@interface FMXManager : NSObject
@property (atomic, strong) LXSourceRuntime *runtime;
@property (atomic, copy) NSString *status;
@property (atomic, copy) NSString *playbackStatus;
@property (nonatomic, copy) NSString *playbackRequest;
@property (nonatomic, copy) NSArray<NSDictionary *> *files;
@property (nonatomic, copy) NSString *selectedFile;
@property (nonatomic, copy) NSString *loadingFile;
@property (nonatomic, copy) NSString *replayNamespace;
@property (nonatomic) NSUInteger generation;
+ (instancetype)shared;
- (NSURL *)directory;
- (void)refreshFiles;
- (void)activate:(NSDictionary *)file;
- (void)disable;
- (void)retireRuntime;
- (void)restoreSavedSource;
@end

@implementation FMXManager
+ (instancetype)shared { static FMXManager *manager; static dispatch_once_t once; dispatch_once(&once, ^{ manager = [FMXManager new]; manager.status = @"未启用 JS 音源"; }); return manager; }
- (NSURL *)directory {
    NSURL *base = [[NSFileManager defaultManager] URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
    NSURL *dir = [base URLByAppendingPathComponent:@"FMExtensionSources" isDirectory:YES];
    [[NSFileManager defaultManager] createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return dir;
}
- (void)refreshFiles {
    NSArray *list = [[NSFileManager defaultManager] contentsOfDirectoryAtURL:self.directory includingPropertiesForKeys:nil options:NSDirectoryEnumerationSkipsHiddenFiles error:nil];
    NSMutableArray *files = [NSMutableArray array];
    for (NSURL *url in list) if ([url.pathExtension.lowercaseString isEqual:@"js"]) {
        NSString *name = [[NSUserDefaults standardUserDefaults] stringForKey:[@"FMX.name." stringByAppendingString:url.lastPathComponent]] ?: url.lastPathComponent;
        [files addObject:@{@"file":url.lastPathComponent, @"name":name}];
    }
    self.files = [files sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) { return [a[@"name"] localizedStandardCompare:b[@"name"]]; }];
}
- (void)changed { [[NSNotificationCenter defaultCenter] postNotificationName:FMXChanged object:nil]; }
- (void)retireRuntime {
    // Advance the native cache namespace before retiring requests. A completed
    // old request may still run its host callback after this transition.
    FMPlaybackCacheSourceTransition(FMXCacheServers(self.runtime.manifest));
    [FMReplayMedia sourceDidChange];
    FMAdaptivePlaybackSourceTransition();
    FMPlaybackSequenceSourceTransition();
    FMDownloadIntegrationSourceTransition();
    self.generation++;
    LXSourceRuntime *old = self.runtime; self.runtime = nil; [old invalidate];
    self.selectedFile = nil;
    self.replayNamespace = nil;
    self.loadingFile = nil;
    self.playbackRequest = nil; self.playbackStatus = nil;
}
- (void)disable {
    [self retireRuntime];
    [[FMReplayCache sharedCache] selectSourceFile:nil script:nil];
    [NSUserDefaults.standardUserDefaults removeObjectForKey:FMXSelected];
    [NSUserDefaults.standardUserDefaults removeObjectForKey:FMXActivationPending];
    [NSUserDefaults.standardUserDefaults synchronize];
    self.status = @"未启用 JS 音源"; [self changed];
}
- (void)restoreSavedSource {
    [self refreshFiles];
    if ([NSUserDefaults.standardUserDefaults boolForKey:FMXActivationPending]) {
        self.status = @"上次音源启用未完成，原选择已保留；请点选音源重试";
        [self changed]; return;
    }
    NSString *selected = [NSUserDefaults.standardUserDefaults stringForKey:FMXSelected];
    if (!selected.length) return;
    for (NSDictionary *file in self.files) if ([file[@"file"] isEqual:selected]) { [self activate:file]; return; }
    self.status = @"已保存的音源文件暂不可用，原选择已保留；请重新导入"; [self changed];
}
- (void)activate:(NSDictionary *)file {
    NSString *filename = file[@"file"];
    if (![filename isKindOfClass:NSString.class] || !filename.length ||
        ![filename.lastPathComponent isEqual:filename] || [filename containsString:@"\\"] ||
        ![filename.pathExtension.lowercaseString isEqual:@"js"]) return;
    NSURL *url = [self.directory URLByAppendingPathComponent:filename];
    NSNumber *size; [url getResourceValue:&size forKey:NSURLFileSizeKey error:nil];
    if (size.unsignedLongLongValue > 2*1024*1024) { self.status = @"文件超过 2 MB"; [self changed]; return; }
    NSString *script = [NSString stringWithContentsOfURL:url encoding:NSUTF8StringEncoding error:nil];
    NSString *bootstrap = [NSString stringWithContentsOfFile:[[NSBundle mainBundle] pathForResource:@"LXBootstrap" ofType:@"js"] encoding:NSUTF8StringEncoding error:nil];
    if (!script || !bootstrap) { self.status = @"无法读取音源文件"; [self changed]; return; }
    // Retiring a runtime is not a user decision to forget the saved source.
    // Persist the interruption marker before evaluating user JavaScript. A crash
    // or timeout cannot cause the same script to loop automatically at startup.
    [NSUserDefaults.standardUserDefaults setBool:YES forKey:FMXActivationPending];
    if (![NSUserDefaults.standardUserDefaults synchronize]) {
        self.status = @"无法保存音源启用状态，原选择已保留"; [self changed]; return;
    }
    [self retireRuntime];
    self.replayNamespace = [[FMReplayCache sharedCache] selectSourceFile:filename script:script];
    NSUInteger generation = self.generation;
    LXSourceRuntime *runtime = [[LXSourceRuntime alloc] initWithBootstrapScript:bootstrap];
    self.runtime = runtime;
    self.loadingFile = filename;
    __weak FMXManager *weakManager = self;
    __weak LXSourceRuntime *weakRuntime = runtime;
    runtime.updateAlertHandler = ^(NSDictionary *alert) {
        FMXManager *manager = weakManager;
        if (!manager || manager.runtime != weakRuntime) return;
        manager.status = [@"音源更新提示：" stringByAppendingString:alert[@"log"] ?: @""];
        [manager changed];
    };
    self.status = @"正在初始化音源…"; [self changed];
    // Commit selection only after initialization, without erasing the last
    // working selection while this one is being evaluated.
    [runtime loadSource:script name:file[@"name"] timeout:12 completion:^(NSDictionary *manifest, NSError *error) {
        if (self.generation != generation || self.runtime != runtime) return;
        self.loadingFile = nil;
        NSArray *sources = FMXRoutableSourceNames(manifest);
        if (error || !sources.count) {
            self.runtime = nil; self.selectedFile = nil; [runtime invalidate];
            self.replayNamespace = nil;
            [[FMReplayCache sharedCache] selectSourceFile:nil script:nil];
            FMPlaybackCacheSourceTransition(NSSet.set);
            self.status = error ? [@"初始化失败：" stringByAppendingString:error.localizedDescription]
                : @"此音源没有本版可用平台：仅支持网易云、QQ 和酷狗基础音源，酷狗须含标准音质。";
        }
        else {
            // Native parsing may have filled caches while the new JS was still
            // initializing. Establish its own generation only once usable.
            FMPlaybackCacheSourceTransition(FMXCacheServers(manifest));
            NSError *saveError=nil;
            BOOL saved=FMSettingsCommitSourceSelection(NSUserDefaults.standardUserDefaults,filename,&saveError);
            self.selectedFile = filename;
            self.status = saved ? [NSString stringWithFormat:@"已启用 %@ · %@", file[@"name"], [sources componentsJoinedByString:@" / "]]
                                : saveError.localizedDescription;
        }
        [self changed];
    }];
}
@end

static NSString *FMXCoverStatusText(NSDictionary *state) {
    if (![state[@"scanned"] boolValue]) return @"暂未读到本机下载列表";
    NSUInteger total = [state[@"wyRegistered"] unsignedIntegerValue];
    if (!total) return @"尚未找到已登记的网易云下载";
    NSMutableArray<NSString *> *parts = [NSMutableArray arrayWithObject:
        [NSString stringWithFormat:@"%lu 首中已有 %lu 首可显示", (unsigned long)total,
            (unsigned long)[state[@"wyUsable"] unsignedIntegerValue]]];
    for (NSArray<NSString *> *field in @[@[@"wyPending", @"待处理"], @[@"wyMissingAudio", @"未找到本地音频"], @[@"wyFailed", @"暂未取得封面"]]) {
        NSUInteger count = [state[field[0]] unsignedIntegerValue];
        if (count) [parts addObject:[NSString stringWithFormat:@"%@ %lu 首", field[1], (unsigned long)count]];
    }
    return [parts componentsJoinedByString:@" · "];
}

@interface FMXPanel : UITableViewController <UIDocumentPickerDelegate>
@end
@implementation FMXPanel
- (void)viewDidLoad {
    [super viewDidLoad]; self.title = @"音源与扩展";
    self.view.tintColor = UIColor.systemPinkColor;
    self.navigationController.navigationBar.tintColor = UIColor.systemPinkColor;
    if (self.navigationController.viewControllers.firstObject == self)
        self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(close)];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(reload) name:FMXChanged object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(reload) name:FMPlaybackItemDidChange object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(reload) name:FMXQishuiSearchStatusDidChangeNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(coverStatusChanged:)
        name:FMDownloadArtworkStatusDidChangeNotification object:nil];
    [self reload];
}
- (void)coverStatusChanged:(NSNotification *)note {
    if (!self.viewIfLoaded.window) return;
    NSIndexPath *path = [NSIndexPath indexPathForRow:1 inSection:3];
    UITableViewCell *cell = [self.tableView cellForRowAtIndexPath:path];
    if (cell) {
        NSString *text = FMXCoverStatusText(FMDownloadArtworkStatus());
        if (![cell.detailTextLabel.text isEqualToString:text])
            [self.tableView reloadRowsAtIndexPaths:@[path] withRowAnimation:UITableViewRowAnimationNone];
    }
}
- (void)dealloc { [[NSNotificationCenter defaultCenter] removeObserver:self]; }
- (void)close { [self dismissViewControllerAnimated:YES completion:nil]; }
- (void)reload { [[FMXManager shared] refreshFiles]; [self.tableView reloadData]; }
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 5; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return section == 0 ? 3 : section == 1 ? [FMXManager shared].files.count + 1 : (section == 2 || section == 3) ? 2 : 1; }
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section { return @[@"搜索", @"JS 音源", @"锁屏", @"音源状态", @"听歌记录"][section]; }
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == 0) return @"开启后，首页搜索汇总网易云、QQ、酷狗和汽水。单独搜索某个平台时，请关闭聚合搜索。汽水歌曲使用原 App 的播放方式。";
    if (section == 1) return @"支持网易云、QQ 和酷狗的基础洛雪音源。酷狗 JS 使用标准音质；部分脚本需要额外歌曲信息或尚未支持的功能。仅启用你信任的脚本。";
    if (section == 2) return @"用当前封面在手机上生成轻微缩放的循环动画。系统需要时才生成；低电量或减少动态效果开启时显示静态封面。需要 iOS 26 或更高版本。";
    if (section == 4) return @"按实际听歌记录查看月度、年度偏好，只保存在本机。";
    return @"扩展 v12。播放时优先读取这首歌的本地下载，其次使用当前音源下已缓存的完整音频。仅有播放地址时仍需联网。";
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)path {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    cell.textLabel.numberOfLines = 0; cell.detailTextLabel.numberOfLines = 0;
    if (path.section == 0 && path.row == 0) {
        cell.textLabel.text = @"聚合搜索"; UISwitch *toggle = [UISwitch new]; toggle.on = [[NSUserDefaults standardUserDefaults] boolForKey:@"FMX.aggregateSearch"];
        toggle.onTintColor = UIColor.systemPinkColor;
        [toggle addTarget:self action:@selector(toggleSearch:) forControlEvents:UIControlEventValueChanged]; cell.accessoryView = toggle; cell.selectionStyle = UITableViewCellSelectionStyleNone;
    } else if (path.section == 0 && path.row == 1) { cell.textLabel.text = @"从文件导入 JS 音源"; cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator; }
    else if (path.section == 0) {
        cell.textLabel.text = @"汽水搜索";
        cell.detailTextLabel.text = FMXQishuiSearchStatus()[@"message"];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    }
    else if (path.section == 1) {
        if (path.row == 0) { cell.textLabel.text = @"停用 JS，使用原播放方式"; if (![FMXManager shared].runtime) cell.accessoryType = UITableViewCellAccessoryCheckmark; }
        else {
            NSDictionary *file = [FMXManager shared].files[path.row - 1]; cell.textLabel.text = file[@"name"];
            if ([file[@"file"] isEqual:[FMXManager shared].selectedFile] && [FMXManager shared].runtime.manifest) cell.accessoryType = UITableViewCellAccessoryCheckmark;
        }
    } else if (path.section == 2 && path.row == 0) {
        cell.textLabel.text = @"动态锁屏封面"; UISwitch *toggle = [UISwitch new];
        toggle.onTintColor = UIColor.systemPinkColor;
        toggle.on = [[NSUserDefaults standardUserDefaults] boolForKey:@"FMX.dynamicArtwork"];
        [toggle addTarget:self action:@selector(toggleArtwork:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = toggle; cell.selectionStyle = UITableViewCellSelectionStyleNone;
    } else if (path.section == 2) {
        NSDictionary *state = FMLockScreenStatus();
        cell.textLabel.text = ![state[@"enabled"] boolValue] ? @"已关闭" : ![state[@"supported"] boolValue] ? @"系统当前未提供动态封面能力" : ![state[@"generationAllowed"] boolValue] ? @"当前使用静态封面" : [state[@"prepared"] boolValue] ? @"封面已就绪" : @"播放歌曲后准备动态封面";
        cell.detailTextLabel.text = [state[@"videoError"] length] ? @"动画生成未完成，继续显示静态封面" : nil;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    } else if (path.section == 4) { cell.textLabel.text = @"听歌画像"; cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator; }
    else if (path.section == 3 && path.row == 1) {
        cell.textLabel.text = @"网易云下载封面";
        cell.detailTextLabel.text = FMXCoverStatusText(FMDownloadArtworkStatus());
        cell.accessibilityIdentifier = @"FMX.neteaseDownloadedArtwork";
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    } else {
        FMXManager *manager = [FMXManager shared];
        cell.textLabel.text = manager.status;
        NSMutableArray<NSString *> *lines = [NSMutableArray array];
        NSNumber *local = FMPlaybackSequenceIsLocalItem();
        if (local) [lines addObject:local.boolValue ? @"当前播放 · 本地文件" : @"当前播放 · 在线音频"];
        if (manager.playbackStatus.length) {
            [lines addObject:[@"最近一次查找（含下一首预载） · " stringByAppendingString:manager.playbackStatus]];
        } else if (manager.runtime) {
            [lines addObject:@"本次启用后尚无音源查找记录"];
        }
        cell.detailTextLabel.text = [lines componentsJoinedByString:@"\n"];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    }
    return cell;
}
- (void)toggleSearch:(UISwitch *)toggle { FMSearchPreferencesSetAggregateEnabled(toggle.on); }
- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)path { return path.section == 1 && path.row > 0; }
- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)style forRowAtIndexPath:(NSIndexPath *)path {
    if (style != UITableViewCellEditingStyleDelete || path.section != 1 || path.row < 1) return;
    FMXManager *manager = [FMXManager shared];
    NSDictionary *file = manager.files[path.row - 1]; NSString *name = file[@"file"];
    NSError *error;
    if ([[NSFileManager defaultManager] removeItemAtURL:[manager.directory URLByAppendingPathComponent:name] error:&error]) {
        BOOL retired=[manager.selectedFile isEqual:name] || [manager.loadingFile isEqual:name];
        if (retired) [manager retireRuntime];
        BOOL removedSavedChoice=[[NSUserDefaults.standardUserDefaults stringForKey:FMXSelected] isEqual:name];
        if (retired || (removedSavedChoice && !manager.runtime)) [[FMReplayCache sharedCache] selectSourceFile:nil script:nil];
        if (removedSavedChoice) {
            [NSUserDefaults.standardUserDefaults removeObjectForKey:FMXSelected];
            if (!manager.runtime) [NSUserDefaults.standardUserDefaults removeObjectForKey:FMXActivationPending];
            [NSUserDefaults.standardUserDefaults synchronize];
        }
        if (retired) {
            // Deleting an uncommitted source must not forget a different last
            // working choice. Keep its interruption guard for deliberate retry.
            BOOL saved=[NSUserDefaults.standardUserDefaults stringForKey:FMXSelected].length>0;
            if (!saved) { [NSUserDefaults.standardUserDefaults removeObjectForKey:FMXActivationPending]; [NSUserDefaults.standardUserDefaults synchronize]; }
            manager.status=saved?@"音源已删除，原选择已保留；请重新选择音源":@"未启用 JS 音源";
            [manager changed];
        }
        [[NSUserDefaults standardUserDefaults] removeObjectForKey:[@"FMX.name." stringByAppendingString:name]];
        [self reload];
    } else [self showError:error.localizedDescription];
}
- (void)toggleArtwork:(UISwitch *)toggle {
    [[NSUserDefaults standardUserDefaults] setBool:toggle.on forKey:@"FMX.dynamicArtwork"];
    FMLockScreenRefresh();
    dispatch_async(dispatch_get_main_queue(), ^{ [self.tableView reloadData]; });
}
- (void)showError:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"导入失败" message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)path {
    [tableView deselectRowAtIndexPath:path animated:YES];
    if (path.section == 4) { [self.navigationController pushViewController:FMInsightsController() animated:YES]; return; }
    if (path.section == 0 && path.row == 1) {
        UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeJavaScript, UTTypePlainText] asCopy:YES]; picker.delegate = self; picker.allowsMultipleSelection = YES;
        [self presentViewController:picker animated:YES completion:nil];
    } else if (path.section == 1 && path.row == 0) [[FMXManager shared] disable];
    else if (path.section == 1 && path.row > 0) {
        NSDictionary *file = [FMXManager shared].files[path.row - 1];
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"启用此音源？" message:@"脚本会在 App 内运行并可发起网络请求。请确认来源可信。" preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
        [alert addAction:[UIAlertAction actionWithTitle:@"启用" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) { [[FMXManager shared] activate:file]; }]];
        [self presentViewController:alert animated:YES completion:nil];
    }
}
- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSString *failure;
    for (NSURL *url in urls) {
        BOOL access = [url startAccessingSecurityScopedResource];
        NSNumber *size; [url getResourceValue:&size forKey:NSURLFileSizeKey error:nil];
        if (![url.pathExtension.lowercaseString isEqual:@"js"] || !size || size.unsignedLongLongValue > 2*1024*1024) failure = @"仅支持不超过 2 MB 的 .js 文件。";
        else {
            NSData *data = [NSData dataWithContentsOfURL:url options:NSDataReadingMappedIfSafe error:nil];
            if (!data || data.length > 2*1024*1024 || ![[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]) failure = @"文件不是有效的 UTF-8 脚本。";
            else {
                NSString *name = [[NSUUID UUID].UUIDString stringByAppendingPathExtension:@"js"];
                NSError *error;
                if (![data writeToURL:[[FMXManager shared].directory URLByAppendingPathComponent:name] options:NSDataWritingAtomic error:&error]) failure = error.localizedDescription;
                else [[NSUserDefaults standardUserDefaults] setObject:url.lastPathComponent forKey:[@"FMX.name." stringByAppendingString:name]];
            }
        }
        if (access) [url stopAccessingSecurityScopedResource];
    }
    [self reload];
    if (failure) dispatch_async(dispatch_get_main_queue(), ^{ [self showError:failure]; });
}
@end

static NSString *FMXLXSource(NSString *server) { if ([server isEqual:@"qq"]) return @"tx"; if ([server isEqual:@"wy"]) return @"wy"; if ([server isEqual:@"kg"]) return @"kg"; return nil; }
// Combine IDs and same-recording metadata without copying credentials from a parse request.
static NSDictionary *FMXRecordingRequest(NSDictionary *parameters, NSDictionary *musicInfo) {
    NSMutableDictionary *track = [@{@"server":parameters[@"server"] ?: @"", @"id":parameters[@"id"] ?: @""} mutableCopy];
    NSDictionary *fields = @{@"title":@"name", @"singer":@"singer", @"album":@"albumName", @"isrc":@"isrc"};
    for (NSString *key in fields) {
        id value = parameters[key] ?: musicInfo[fields[key]];
        if ([value isKindOfClass:NSString.class] && [value length]) track[key] = value;
    }
    id duration = parameters[@"duration"];
    if ([duration isKindOfClass:NSNumber.class]) track[@"duration"] = duration;
    else {
        NSString *interval = musicInfo[@"interval"];
        NSArray *parts = [interval isKindOfClass:NSString.class] ? [interval componentsSeparatedByString:@":"] : nil;
        if (parts.count == 2 && [parts[0] length] && [parts[1] length] == 2) {
            NSCharacterSet *invalid = [[NSCharacterSet characterSetWithCharactersInString:@"0123456789"] invertedSet];
            if ([parts[0] rangeOfCharacterFromSet:invalid].location == NSNotFound && [parts[1] rangeOfCharacterFromSet:invalid].location == NSNotFound && [parts[1] integerValue] < 60 && [parts[0] integerValue] <= 10080)
                track[@"duration"] = @([parts[0] integerValue] * 60 + [parts[1] integerValue]);
        }
    }
    return track;
}
// Record only actual handler invocations. Capability probes are not playback.
// Do not retain song IDs, URLs, credentials, or arbitrary server error strings.
static void FMXPlaybackStatus(LXSourceRuntime *runtime, NSString *identifier, NSString *source, NSString *state, BOOL starting) {
    dispatch_async(dispatch_get_main_queue(), ^{
        FMXManager *manager = [FMXManager shared];
        if (manager.runtime != runtime) return;
        if (starting) manager.playbackRequest = identifier;
        if (![manager.playbackRequest isEqual:identifier]) return;
        NSString *label = @{@"tx":@"QQ", @"wy":@"网易云", @"kg":@"酷狗"}[source];
        if (!label) return;
        manager.playbackStatus = [NSString stringWithFormat:@"%@：%@", label, state];
        [manager changed];
    });
}
__attribute__((constructor)) static void FMXInitialize(void) {
    @autoreleasepool {
        if (![[NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] isEqual:@"4.2.9"] || ![[NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleVersion"] isEqual:@"4381"] || ![NSBundle.mainBundle.executablePath.lastPathComponent isEqual:@"FreeMusic"]) return;
        NSError *settingsError=nil;
        BOOL settingsReady=FMSettingsPrepareStandard(&settingsError);
        FMPlaybackCacheInstall();
        FMAdaptivePlaybackInstall();
        FMPlaybackSequenceInstall();
        [FMReplayMedia installAutomaticTransferTracking];
        FMDownloadIntegrationInstall();
        FMNativeDownloadCoverDisplayInstall();
        // Drop addresses/preloaded players selected before a manual file appeared
        // (or before it was removed). Keep the current playback and JS source.
        [NSNotificationCenter.defaultCenter addObserverForName:FMDownloadCatalogueDidChangeNotification
            object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note){
                FMPlaybackCacheSourceTransition([NSSet set]);
            }];
        FMDownloadArtworkInstall();
        [FMExtensionProtocol setTrackMetadataObserver:^(id payload){FMTrackMetadataObserveResponse(payload);}];
        // Capture must install before the host registers its original AVPlayer
        // time observer. UI setup remains deferred to the main run loop below.
        FMInsightsInstall();
        [FMExtensionProtocol setParseHandler:^FMXParseCancellation(NSURLRequest *request, NSDictionary<NSString *,NSString *> *parameters, FMXProtocolCompletion completion) {
            // Keep source/generation, the quality session and its lifetime on main.
            // A successful metadata request must retain the remaining candidates
            // for a later *actual* player failure, not cancel them at URL delivery.
            __block FMQualityResolver *session;
            __block BOOL cancelled = NO;
            __block LXSourceRuntime *selectedRuntime;
            __block NSString *selectedSource, *diagnostic;
            FMPreferredDownloadStore *downloads = FMPreferredDownloadStore.sharedStore;
            NSUInteger downloadSelection = downloads.playbackSelection;
            void (^rejectLocalForSelection)(NSURL *) = ^(NSURL *URL) {
                if (downloads.playbackSelection != downloadSelection) return;
                [downloads rejectURL:URL forSelection:downloadSelection];
                FMPlaybackCacheDeferDownloadRetry(parameters[@"server"],parameters[@"id"]);
            };
            dispatch_async(dispatch_get_main_queue(), ^{
                if (cancelled) return;
                LXSourceRuntime *runtime = [FMXManager shared].runtime;
                NSString *source = FMXLXSource(parameters[@"server"]);
                BOOL directKugou = [request.URL.host.lowercaseString isEqual:@"m.kugou.com"];
                NSArray *qualities = FMXRoutableQualities(runtime.manifest, source);
                NSDictionary *info = FMTrackMetadataForParameters(parameters, source ?: parameters[@"server"]);
                NSDictionary *recording = FMXRecordingRequest(parameters, info);
                if (!runtime || !source || !qualities.count) {
                    NSURL *local = [downloads lookupTrack:recording];
                    if (local) {
                        // A discovered file can still fail during actual playback. Bind a
                        // local-only session so its normal failure callback rejects this
                        // file revision, then restores the original player's failure path.
                        session = [[FMQualityResolver alloc] initWithPlatform:parameters[@"server"] ?: @"" supportedQualities:@[] timeout:5
                            isCurrent:^BOOL{ return [FMXManager shared].runtime == runtime; }
                            resolve:^dispatch_block_t(NSString *quality, NSTimeInterval timeout, FMQualityAttemptCompletion done) {
                                done(nil,nil); return nil;
                            }];
                        session.preferredDownload = ^NSURL *{ return [downloads lookupTrack:recording]; };
                        session.rejectPreferredDownload = rejectLocalForSelection;
                        [session nextWithCompletion:^(NSURL *url, NSString *quality, NSError *error) {
                            if (cancelled) return;
                            if (!url || error) { completion(nil,nil); return; }
                            FMAdaptivePlaybackRegisterURL(url, session, quality,
                                [NSString stringWithFormat:@"%@:%@", parameters[@"server"], parameters[@"id"]]);
                            completion(directKugou ? @{@"url":url.absoluteString} : @{@"code":@200, @"data":@{@"url":url.absoluteString, @"quality":@"未知", @"qmc":NSNull.null}}, nil);
                        }];
                    } else {
                        // The download or registry can disappear after the original probe.
                        completion(nil, nil);
                    }
                    return;
                }
                NSString *trackID = parameters[@"id"];
                FMReplayCache *cache = [FMReplayCache sharedCache];
                NSString *namespaceID = [FMXManager shared].replayNamespace;
                // This selection owns its original keys, even if a menu clear
                // takes place while an asynchronous JS result or transfer is pending.
                NSMutableDictionary *issuedKeys = [NSMutableDictionary dictionary];
                for (NSString *quality in qualities) {
                    NSString *key = [cache keyForNamespace:namespaceID platform:source trackID:trackID quality:quality];
                    if (key) issuedKeys[quality] = key;
                }
                NSDictionary *selectionKeys = issuedKeys.copy;
                NSString *(^cacheKey)(NSString *) = ^NSString *(NSString *quality) {
                    return selectionKeys[quality];
                };
                BOOL (^currentSource)(void) = ^BOOL {
                    return [FMXManager shared].runtime == runtime && runtime.manifest != nil;
                };
                NSString *diagnosticID = NSUUID.UUID.UUIDString;
                selectedRuntime = runtime; selectedSource = source; diagnostic = diagnosticID;
                FMXPlaybackStatus(runtime, diagnosticID, source, @"正在检查本地下载和播放缓存", YES);
                NSTimeInterval budget = MIN(35, request.timeoutInterval > 0 ? MAX(1, request.timeoutInterval - 1) : 35);
                session = [[FMQualityResolver alloc] initWithPlatform:source supportedQualities:qualities timeout:budget
                    isCurrent:currentSource
                    resolve:^dispatch_block_t(NSString *quality, NSTimeInterval timeout, FMQualityAttemptCompletion resolved) {
                        FMXPlaybackStatus(runtime, diagnosticID, source, [NSString stringWithFormat:@"正在尝试 JS 音质 %@", quality], NO);
                        NSString *identifier = [runtime resolveIsolatedMusicURLForSource:source musicInfo:info quality:quality timeout:timeout completion:resolved];
                        return ^{ [runtime cancelRequestWithIdentifier:identifier]; };
                    }];
                session.preferredDownload = ^NSURL *{ return [downloads lookupTrack:recording]; };
                session.rejectPreferredDownload = rejectLocalForSelection;
                [session setReplayLookup:^NSURL *(NSString *quality, FMQualityCandidateOrigin origin) {
                    NSString *key = cacheKey(quality);
                    if (!key) return nil;
                    return origin == FMQualityCandidateFromAudioCache ? [cache audioForKey:key] : [cache addressForKey:key];
                } saveAddress:^(NSString *quality, NSURL *url) {
                    NSString *key = cacheKey(quality);
                    if (key) [cache saveAddress:url forKey:key];
                } discardFailed:^(NSString *quality, NSURL *url) {
                    NSString *key = cacheKey(quality);
                    if (!key) return;
                    if (url.isFileURL) [cache discardAudio:url forKey:key];
                    else [cache discardAddress:url forKey:key];
                }];
                session.willUseRemoteURL = ^(NSString *quality, NSURL *url) {
                    NSString *key = cacheKey(quality);
                    if (key) [FMReplayMedia registerRemoteURL:url key:key];
                };
                session.didBindPlayer = ^(AVPlayer *player, NSURL *url, NSString *quality) {
                    NSString *key = cacheKey(quality);
                    if (key && !url.isFileURL) [FMReplayMedia observePlayer:player remoteURL:url key:key isCurrent:currentSource];
                };
                [session nextWithCompletion:^(NSURL *url, NSString *requestedQuality, NSError *error) {
                    if (cancelled) return;
                    if (error || !url) {
                        FMXPlaybackStatus(runtime, diagnosticID, source, @"JS 可用音质均未取得播放地址", NO);
                        FMXManager *manager = [FMXManager shared];
                        if (manager.runtime == runtime && !runtime.manifest) {
                            [NSUserDefaults.standardUserDefaults setBool:YES forKey:FMXActivationPending];
                            [NSUserDefaults.standardUserDefaults synchronize];
                            [manager retireRuntime];
                            manager.status = @"JS 音源无响应，已暂停；原选择已保留，请重新启用或更换音源";
                            [manager changed];
                        }
                        completion(directKugou ? @{@"url":@""} : @{@"code":@502, @"msg":@"JS 音源未取得可播放地址"}, nil);
                        return;
                    }
                    FMAdaptivePlaybackRegisterURL(url, session, requestedQuality,
                        [NSString stringWithFormat:@"%@:%@", source, parameters[@"id"] ?: @""]);
                    FMDownloadIntegrationRegisterURL(url,
                        [NSString stringWithFormat:@"%@:%@",source,parameters[@"id"]?:@""],
                        ^FMQualityResolver *{
                            // A download owns its own attempts; it must never consume the player's session.
                            return [[FMQualityResolver alloc] initWithPlatform:source supportedQualities:qualities timeout:35
                                isCurrent:^BOOL{return [FMXManager shared].runtime==runtime&&runtime.manifest!=nil;}
                                resolve:^dispatch_block_t(NSString *quality,NSTimeInterval timeout,FMQualityAttemptCompletion resolved){
                                    NSString *identifier=[runtime resolveIsolatedMusicURLForSource:source musicInfo:info quality:quality timeout:timeout completion:resolved];
                                    return ^{[runtime cancelRequestWithIdentifier:identifier];};
                                }];
                        },^BOOL{return [FMXManager shared].runtime==runtime&&runtime.manifest!=nil;});
                    NSString *status;
                    switch (session.lastCandidateOrigin) {
                        case FMQualityCandidateFromManualDownload: status=@"已使用本地下载"; break;
                        case FMQualityCandidateFromAudioCache: status=@"已命中当前音源的本地歌曲缓存"; break;
                        case FMQualityCandidateFromAddressCache: status=@"已复用当前音源的播放地址"; break;
                        default: status=@"JS 已返回播放地址，实际音质将在播放后确认"; break;
                    }
                    FMXPlaybackStatus(runtime, diagnosticID, source, status, NO);
                    // Plain URL responses deliberately contain no QMC metadata.
                    // The original decoder's nil-QMC branch passes them directly
                    // to the player even when the user's selected level sent qmc=1.
                    // Requested quality is not misrepresented as measured audio.
                    completion(directKugou ? @{@"url":url.absoluteString} : @{@"code":@200, @"data":@{@"url":url.absoluteString, @"quality":@"未知", @"qmc":NSNull.null}}, nil);
                }];
            });
            return ^(NSError *reason) {
                if (!reason) return;
                dispatch_async(dispatch_get_main_queue(), ^{
                    cancelled = YES; [session cancel];
                    if (selectedRuntime && selectedSource && diagnostic)
                        FMXPlaybackStatus(selectedRuntime, diagnostic, selectedSource,
                            reason.code == NSURLErrorTimedOut ? @"解析超时，本次已停止" : @"本次 JS 解析已取消", NO);
                });
            };
        } canHandle:^BOOL(NSURLRequest *request, NSDictionary<NSString *,NSString *> *parameters) {
            NSString *source = FMXLXSource(parameters[@"server"]);
            NSDictionary *manifest = [FMXManager shared].runtime.manifest;
            if (source && [parameters[@"id"] length] && FMXRoutableQualities(manifest, source).count) return YES;
            NSDictionary *info = FMTrackMetadataForParameters(parameters, source ?: parameters[@"server"]);
            return [FMPreferredDownloadStore.sharedStore lookupTrack:FMXRecordingRequest(parameters, info)] != nil;
        }];
        [FMExtensionProtocol install];
        dispatch_async(dispatch_get_main_queue(), ^{
            FMSearchPreferencesInstall();
            FMLockScreenInstall();
            FMInteractionInstall();
            FMSongMenuInstall();
            FMLXMCUIInstall();
            FMNavigationInstall();
            FMSettingsEntryInstall(^(UIViewController *settingsController) {
                if (settingsController.presentedViewController) return;
                FMXPanel *panel = [[FMXPanel alloc] initWithStyle:UITableViewStyleInsetGrouped];
                UINavigationController *navigation = settingsController.navigationController;
                if (navigation && navigation.visibleViewController == settingsController)
                    [navigation pushViewController:panel animated:YES];
                else
                    [settingsController presentViewController:[[UINavigationController alloc] initWithRootViewController:panel] animated:YES completion:nil];
            });
            FMXManager *manager = [FMXManager shared]; [manager refreshFiles];
            if(!settingsReady) {
                manager.status=@"设置迁移未完成，原设置已保留";
                [manager changed];
                return;
            }
            [manager restoreSavedSource];
        });
    }
}
