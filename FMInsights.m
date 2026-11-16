#import "FMInsights.h"
#import "FMListeningHistory.h"
#import "FMListeningCapture.h"
#import <MediaPlayer/MediaPlayer.h>
#import <objc/runtime.h>
#import <math.h>

static FMListeningHistory *FMHistory;
static dispatch_queue_t FMHistoryQueue;
static NSString *const FMHistoryEnabled=@"FMX.listeningInsightsEnabled";
static double FMLastSave;
static NSString *FMHistoryWriteError;

static void FMHistoryFlush(void) {
    NSError *error=nil;[FMHistory save:&error];FMHistoryWriteError=error.localizedDescription;FMLastSave=NSProcessInfo.processInfo.systemUptime;
}
static void FMHistoryObserve(NSDictionary *track,double position,double speed,NSDate *date,double uptime) {
    BOOL enabled=[NSUserDefaults.standardUserDefaults boolForKey:FMHistoryEnabled];
    dispatch_async(FMHistoryQueue, ^{
        if(enabled)[FMHistory observeTrack:track elapsed:position rate:speed date:date uptime:uptime];
        else [FMHistory resetSample];
        if(uptime-FMLastSave>=20 || speed==0 || !track)FMHistoryFlush();
    });
}
void FMInsightsInstall(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        [NSUserDefaults.standardUserDefaults registerDefaults:@{FMHistoryEnabled:@YES}];
        FMHistoryQueue=dispatch_queue_create("app.fmx.listening-history",DISPATCH_QUEUE_SERIAL);
        NSURL *base=[NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
        FMHistory=[[FMListeningHistory alloc] initWithURL:[[base URLByAppendingPathComponent:@"FMInsights" isDirectory:YES] URLByAppendingPathComponent:@"daily-listening-v1.json"] calendar:NSCalendar.currentCalendar];
        FMListeningCaptureInstall(^(NSDictionary *track,double elapsed,double rate,NSDate *date,double uptime){FMHistoryObserve(track,elapsed,rate,date,uptime);});
        for(NSString *name in @[UIApplicationDidEnterBackgroundNotification,UIApplicationWillTerminateNotification])
            [NSNotificationCenter.defaultCenter addObserverForName:name object:nil queue:nil usingBlock:^(NSNotification *n){dispatch_async(FMHistoryQueue,^{FMHistoryFlush();});}];
    });
}
static NSDictionary *FMSummary(NSDate *date,BOOL yearly) {
    FMInsightsInstall();__block NSDictionary *result;
    dispatch_sync(FMHistoryQueue,^{FMHistoryFlush();NSMutableDictionary *d=[[FMHistory summaryForDate:date yearly:yearly] mutableCopy];if(FMHistoryWriteError)d[@"storageError"]=FMHistoryWriteError;result=d;});
    return result;
}
NSDictionary *FMInsightsCurrentSummary(BOOL yearly){return FMSummary(NSDate.date,yearly);}
static NSString *FMDuration(double seconds){if(seconds<60)return [NSString stringWithFormat:@"%.0f 秒",seconds];if(seconds<3600)return [NSString stringWithFormat:@"%.1f 分钟",seconds/60];return [NSString stringWithFormat:@"%.1f 小时",seconds/3600];}

@interface FMInsightsViewController : UITableViewController
@property(nonatomic, copy) NSDate *period;
@property(nonatomic) BOOL yearly;
@property(nonatomic, copy) NSDictionary *summary;
@property(nonatomic, strong) UISegmentedControl *periodKind;
@end
@implementation FMInsightsViewController
- (void)viewDidLoad {
    [super viewDidLoad];self.title=@"听歌画像";self.period=NSDate.date;self.view.tintColor=UIColor.systemPinkColor;
    self.periodKind=[[UISegmentedControl alloc] initWithItems:@[@"月度",@"年度"]];self.periodKind.selectedSegmentIndex=0;
    self.periodKind.accessibilityIdentifier=@"FMX.Insights.Period";
    [self.periodKind addTarget:self action:@selector(changeKind:) forControlEvents:UIControlEventValueChanged];
    UIView *header=[[UIView alloc] initWithFrame:CGRectMake(0,0,360,65)];self.periodKind.translatesAutoresizingMaskIntoConstraints=NO;[header addSubview:self.periodKind];
    [NSLayoutConstraint activateConstraints:@[[self.periodKind.leadingAnchor constraintEqualToAnchor:header.leadingAnchor constant:20],[self.periodKind.trailingAnchor constraintEqualToAnchor:header.trailingAnchor constant:-20],[self.periodKind.centerYAnchor constraintEqualToAnchor:header.centerYAnchor]]];self.tableView.tableHeaderView=header;
    self.navigationItem.rightBarButtonItems=@[[[UIBarButtonItem alloc] initWithTitle:@"下一期" style:UIBarButtonItemStylePlain target:self action:@selector(next)],[[UIBarButtonItem alloc] initWithTitle:@"上一期" style:UIBarButtonItemStylePlain target:self action:@selector(previous)]];
    [self reload];
}
- (void)viewWillAppear:(BOOL)animated{[super viewWillAppear:animated];[self reload];}
- (void)reload{self.summary=FMSummary(self.period?:NSDate.date,self.yearly);NSCalendar *calendar=NSCalendar.currentCalendar;NSCalendarUnit unit=self.yearly?NSCalendarUnitYear:NSCalendarUnitMonth;NSDate *current=[calendar dateIntervalOfUnit:unit forDate:NSDate.date].start,*selected=[calendar dateIntervalOfUnit:unit forDate:self.period].start;self.navigationItem.rightBarButtonItems.firstObject.enabled=[selected compare:current]==NSOrderedAscending;[self.tableView reloadData];}
- (void)changeKind:(UISegmentedControl *)control{self.yearly=control.selectedSegmentIndex==1;[self reload];}
- (void)previous{self.period=[NSCalendar.currentCalendar dateByAddingUnit:self.yearly?NSCalendarUnitYear:NSCalendarUnitMonth value:-1 toDate:self.period options:0];[self reload];}
- (void)next{NSDate *next=[NSCalendar.currentCalendar dateByAddingUnit:self.yearly?NSCalendarUnitYear:NSCalendarUnitMonth value:1 toDate:self.period options:0];self.period=[next compare:NSDate.date]==NSOrderedDescending?NSDate.date:next;[self reload];}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView{return 6;}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section{if(section==0)return 2;if(section==1)return 1;if(section==2)return MAX(1,MIN(5,[self.summary[@"artists"] count]));if(section==3)return MAX(1,[self.summary[@"categories"] count]);if(section==4)return MAX(1,MIN(10,[self.summary[@"tracks"] count]));return 2;}
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section{return @[[NSString stringWithFormat:@"%@ · %@",self.summary[@"period"]?:@"",self.yearly?@"年度":@"月度"],@"偏好摘要",@"常听歌手",@"音乐类型",@"常听歌曲",@"记录管理"][section];}
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if(section==0)return [self.summary[@"storageError"] length]?self.summary[@"storageError"]:@"从新版启用后开始统计，按实际播放进度增加时间；暂停、缓冲和跳转不计入听歌时长。此前的累计播放次数无法准确还原到每个月。";
    if(section==2)return @"合作演唱按播放器提供的完整歌手名称统计，不猜测歌手身份。";
    if(section==3)return @"优先使用曲目自带曲风。名称标签仅依据歌名中明确的原声、现场、Remix、伴奏等标记，不代表音频曲风识别；其余保留为“尚无曲风信息”。";
    if(section==5)return @"画像只保存在本机，不上传。关闭记录保留已有统计；清空只影响这份画像，不删除收藏、歌单或原 App 最近播放。";
    return nil;
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)path {
    UITableViewCell *cell=[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];cell.textLabel.numberOfLines=0;cell.detailTextLabel.numberOfLines=0;cell.selectionStyle=UITableViewCellSelectionStyleNone;
    double total=[self.summary[@"seconds"] doubleValue];
    if(path.section==0){if(path.row==0){cell.textLabel.text=[@"听歌 " stringByAppendingString:FMDuration(total)];cell.detailTextLabel.text=[NSString stringWithFormat:@"%@ 首歌 · %@ 个听歌日",self.summary[@"trackCount"],self.summary[@"activeDays"]];}else {cell.textLabel.text=total>0?@"按实际聆听时长排序":@"这一期还没有听歌记录";cell.detailTextLabel.text=total>0?@"切换月度、年度，或查看上一期。":@"播放音乐后会逐步形成画像。";}}
    else if(path.section==1){NSArray *artists=self.summary[@"artists"],*tracks=self.summary[@"tracks"];if(total<60||!artists.count){cell.textLabel.text=@"记录还不够，先听几首歌吧";}else{NSDictionary *top=artists.firstObject,*song=tracks.firstObject;cell.textLabel.text=[NSString stringWithFormat:@"这一期你听得最多的是 %@",top[@"name"]];cell.detailTextLabel.text=[NSString stringWithFormat:@"占听歌时长 %.0f%%。常听歌曲是《%@》。这些是播放偏好，不推断性格或情绪。",[top[@"seconds"] doubleValue]*100/total,song[@"title"]];}}
    else if(path.section>=2&&path.section<=4){NSString *key=path.section==2?@"artists":path.section==3?@"categories":@"tracks";NSArray *rows=self.summary[key];if(!rows.count){cell.textLabel.text=@"暂无记录";cell.textLabel.textColor=UIColor.secondaryLabelColor;}else{NSDictionary *row=rows[path.row];cell.textLabel.text=path.section==4?row[@"title"]:row[@"name"];cell.detailTextLabel.text=path.section==4?[NSString stringWithFormat:@"%@ · %@",row[@"artist"],FMDuration([row[@"seconds"] doubleValue])]:[NSString stringWithFormat:@"%@ · %.0f%%",FMDuration([row[@"seconds"] doubleValue]),total>0?[row[@"seconds"] doubleValue]*100/total:0];}}
    else if(path.row==0){cell.textLabel.text=@"记录听歌偏好";UISwitch *toggle=UISwitch.new;toggle.onTintColor=UIColor.systemPinkColor;toggle.on=[NSUserDefaults.standardUserDefaults boolForKey:FMHistoryEnabled];[toggle addTarget:self action:@selector(toggle:) forControlEvents:UIControlEventValueChanged];cell.accessoryView=toggle;}
    else{cell.textLabel.text=@"清空本机画像记录";cell.textLabel.textColor=UIColor.systemRedColor;cell.selectionStyle=UITableViewCellSelectionStyleDefault;}
    return cell;
}
- (void)toggle:(UISwitch *)toggle{[NSUserDefaults.standardUserDefaults setBool:toggle.on forKey:FMHistoryEnabled];dispatch_async(FMHistoryQueue,^{[FMHistory resetSample];FMHistoryFlush();});}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)path {
    [tableView deselectRowAtIndexPath:path animated:YES];if(path.section!=5||path.row!=1)return;
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"清空画像记录？" message:@"将删除本机月度、年度画像记录。收藏、歌单和原 App 最近播放保持不变。" preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"清空" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action){dispatch_async(FMHistoryQueue,^{NSError *error=nil;[FMHistory clear:&error];FMHistoryWriteError=error.localizedDescription;dispatch_async(dispatch_get_main_queue(),^{[self reload];});});}]];
    [self presentViewController:alert animated:YES completion:nil];
}
@end
UIViewController *FMInsightsController(void){return [[FMInsightsViewController alloc] initWithStyle:UITableViewStyleInsetGrouped];}
