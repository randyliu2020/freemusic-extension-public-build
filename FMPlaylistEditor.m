#import "FMPlaylistEditor.h"
#import "FMLXMCLocalStore.h"
#import "FMLXMCLocalProtocol.h"
#import <objc/runtime.h>

static void FMEditNativeRefresh(UIView *root) {
    if (!root) return;
    NSMutableArray<UIView *> *queue=[NSMutableArray arrayWithObject:root];
    for (NSUInteger i=0;i<queue.count && i<400;i++) {
        UIView *view=queue[i];
        if (view.hidden || view.alpha<0.01) continue;
        if ([view isKindOfClass:UIScrollView.class]) {
            UIRefreshControl *pull=((UIScrollView *)view).refreshControl;
            if (pull && !pull.isRefreshing) { [pull sendActionsForControlEvents:UIControlEventValueChanged]; return; }
        }
        if (queue.count<600) [queue addObjectsFromArray:view.subviews];
    }
}

@interface FMPlaylistEditController : UITableViewController
@property(nonatomic,copy) NSDictionary *playlist;
@property(nonatomic,copy) NSArray<NSDictionary *> *rows;
@property(nonatomic,weak) UIViewController *library;
@property(nonatomic,strong) NSURLSessionDataTask *detailTask;
@property(nonatomic,copy) NSString *loadMessage;
@end

@implementation FMPlaylistEditController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.tableView.rowHeight=UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight=55;
    if(self.playlist) {
        self.title=self.playlist[@"title"];
        UIBarButtonItem *rename=[[UIBarButtonItem alloc] initWithTitle:@"改名" style:UIBarButtonItemStylePlain target:self action:@selector(rename)];
        self.navigationItem.rightBarButtonItems=@[self.editButtonItem,rename];
    } else {
        self.title=@"管理歌单";
        self.navigationItem.rightBarButtonItem=self.editButtonItem;
        self.navigationItem.leftBarButtonItem=[[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(close)];
    }
}
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reloadRows];
}
- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    if (self.isMovingFromParentViewController || self.navigationController.isBeingDismissed) {
        [self.detailTask cancel]; self.detailTask=nil;
    }
}
- (void)close {
    __weak UIViewController *owner=self.library;
    [self.navigationController dismissViewControllerAnimated:YES completion:^{ FMEditNativeRefresh(owner.viewIfLoaded); }];
}
- (void)reloadRows {
    FMLXMCLocalStore *store=FMLXMCLocalStore.sharedStore;
    if (!self.playlist) self.rows=store.editorPlaylists;
    else {
        NSString *key=self.playlist[@"key"];
        self.rows=[store editorTracks:key];
        for (NSDictionary *row in store.editorPlaylists) if ([row[@"key"] isEqual:key]) { self.playlist=row; self.title=row[@"title"]; break; }
        if (!self.rows && !self.detailTask && [self.playlist[@"id"] longLongValue]>0) {
            self.loadMessage=@"正在读取歌曲…";
            __weak typeof(self) weak=self;
            self.detailTask=[FMLXMCLocalProtocol loadEditorTracksForKey:key completion:^(NSError *error) {
                typeof(self) strong=weak; if (!strong) return;
                strong.detailTask=nil; strong.rows=[store editorTracks:key];
                strong.loadMessage=error.localizedDescription;
                [strong.tableView reloadData];strong.editButtonItem.enabled=strong.rows.count>0;
            }];
        }
    }
    self.editButtonItem.enabled=self.rows.count>0;
    [self.tableView reloadData];
}
- (void)showFailure:(NSError *)error {
    if (!self.viewIfLoaded.window) return;
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"未能保存" message:error.localizedDescription preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];[self presentViewController:alert animated:YES completion:nil];
}
- (void)rename {
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"歌单名称" message:nil preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field){field.text=self.playlist[@"title"];field.clearButtonMode=UITextFieldViewModeWhileEditing;}];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action){
        NSError *error=nil;
        if (![FMLXMCLocalStore.sharedStore renameEditorPlaylist:self.playlist[@"key"] title:alert.textFields.firstObject.text error:&error])
            dispatch_async(dispatch_get_main_queue(),^{[self showFailure:error];});
        [self reloadRows];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return self.rows.count; }
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (self.playlist && !self.rows) return self.loadMessage?:@"暂时无法读取歌曲";
    if (!self.rows.count) return self.playlist ? @"这张歌单暂时没有歌曲。" : @"资料库还没有歌单。";
    return self.playlist ? @"点“编辑”可拖动歌曲排序或从歌单移除。改动仅保存在此设备。" : @"点歌单可修改名称和歌曲，点“编辑”可拖动歌单排序。";
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)path {
    UITableViewCell *cell=[tableView dequeueReusableCellWithIdentifier:@"playlist.edit.row"];
    if (!cell) cell=[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"playlist.edit.row"];
    NSDictionary *row=self.rows[path.row];
    cell.textLabel.text=row[@"title"];
    cell.detailTextLabel.text=self.playlist ? row[@"singer"] : [NSString stringWithFormat:@"%@ 首",row[@"count"]?:@0];
    cell.accessoryType=self.playlist ? UITableViewCellAccessoryNone : UITableViewCellAccessoryDisclosureIndicator;
    cell.showsReorderControl=YES;
    return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)path {
    [tableView deselectRowAtIndexPath:path animated:YES];if (self.playlist || self.editing) return;
    FMPlaylistEditController *next=[[FMPlaylistEditController alloc] initWithStyle:UITableViewStyleInsetGrouped];
    next.library=self.library; next.playlist=self.rows[path.row];
    [self.navigationController pushViewController:next animated:YES];
}
- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)path { return YES; }
- (BOOL)tableView:(UITableView *)tableView canMoveRowAtIndexPath:(NSIndexPath *)path { return self.rows.count>1; }
- (UITableViewCellEditingStyle)tableView:(UITableView *)tableView editingStyleForRowAtIndexPath:(NSIndexPath *)path {
    return self.playlist ? UITableViewCellEditingStyleDelete : UITableViewCellEditingStyleNone;
}
- (NSString *)tableView:(UITableView *)tableView titleForDeleteConfirmationButtonForRowAtIndexPath:(NSIndexPath *)path { return @"移出歌单"; }
- (BOOL)apply:(NSArray *)desired {
    NSError *error=nil; FMLXMCLocalStore *store=FMLXMCLocalStore.sharedStore;
    NSArray *keys=[desired valueForKey:@"key"];
    BOOL saved=self.playlist ? [store saveEditorTracks:keys replacing:[self.rows valueForKey:@"key"] playlist:self.playlist[@"key"] error:&error] :
        [store saveEditorListOrder:keys error:&error];
    if (!saved) { [self reloadRows];[self showFailure:error]; return NO; }
    self.rows=desired; return YES;
}
- (void)tableView:(UITableView *)tableView moveRowAtIndexPath:(NSIndexPath *)from toIndexPath:(NSIndexPath *)to {
    NSMutableArray *rows=[self.rows mutableCopy]; id item=rows[from.row];[rows removeObjectAtIndex:from.row];[rows insertObject:item atIndex:to.row];[self apply:rows];
}
- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)style forRowAtIndexPath:(NSIndexPath *)path {
    if (!self.playlist || style!=UITableViewCellEditingStyleDelete) return;
    NSMutableArray *rows=[self.rows mutableCopy];[rows removeObjectAtIndex:path.row];
    if ([self apply:rows]) { [tableView deleteRowsAtIndexPaths:@[path] withRowAnimation:UITableViewRowAnimationAutomatic];self.editButtonItem.enabled=rows.count>0; }
}
@end

@interface FMPlaylistEditorLauncher : NSObject
@property(nonatomic,weak) UIViewController *owner;
- (void)open:(id)sender;
@end
@implementation FMPlaylistEditorLauncher
- (void)open:(id)sender {
    UIViewController *controller=self.owner;
    if (!controller.viewIfLoaded.window || controller.presentedViewController) return;
    FMPlaylistEditController *list=[[FMPlaylistEditController alloc] initWithStyle:UITableViewStyleInsetGrouped];list.library=controller;
    UINavigationController *nav=[[UINavigationController alloc] initWithRootViewController:list];
    nav.modalPresentationStyle=UIModalPresentationFullScreen;[controller presentViewController:nav animated:YES completion:nil];
}
@end

static char FMEditorButtonKey,FMEditorLauncherKey;
void FMPlaylistEditorAttach(UIViewController *libraryRoot) {
    if (!libraryRoot || !NSThread.isMainThread) return;
    UINavigationItem *item=libraryRoot.navigationItem;
    UIBarButtonItem *existing=objc_getAssociatedObject(item,&FMEditorButtonKey);
    if (existing && [item.leftBarButtonItems containsObject:existing]) return;
    if (@available(iOS 16.0,*)) for (UIBarButtonItemGroup *group in item.leadingItemGroups)
        if (existing && [group.barButtonItems containsObject:existing]) return;
    FMPlaylistEditorLauncher *launcher=objc_getAssociatedObject(item,&FMEditorLauncherKey);
    if (!launcher) {
        launcher=[FMPlaylistEditorLauncher new];launcher.owner=libraryRoot;
        objc_setAssociatedObject(item,&FMEditorLauncherKey,launcher,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    UIBarButtonItem *button=existing?:[[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"list.bullet.indent"]
        style:UIBarButtonItemStylePlain target:launcher action:@selector(open:)];
    button.accessibilityLabel=@"管理歌单";button.accessibilityIdentifier=@"FMX.library.editPlaylists";
    if (@available(iOS 16.0,*)) {
        NSMutableArray *groups=[item.leadingItemGroups mutableCopy]?:[NSMutableArray array];
        if (!groups.count && item.leftBarButtonItems.count)
            [groups addObject:[[UIBarButtonItemGroup alloc] initWithBarButtonItems:item.leftBarButtonItems representativeItem:nil]];
        [groups addObject:[[UIBarButtonItemGroup alloc] initWithBarButtonItems:@[button] representativeItem:nil]];item.leadingItemGroups=groups;
    } else item.leftBarButtonItems=[(item.leftBarButtonItems?:@[]) arrayByAddingObject:button];
    objc_setAssociatedObject(item,&FMEditorButtonKey,button,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
