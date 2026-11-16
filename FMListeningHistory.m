#import "FMListeningHistory.h"
#import <math.h>

static NSString *FMText(id value, NSUInteger max) {
    if (![value isKindOfClass:NSString.class]) return @"";
    NSString *s=[value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return s.length>max ? [s substringToIndex:max] : s;
}
static NSDictionary *FMTrack(NSDictionary *raw) {
    if (![raw isKindOfClass:NSDictionary.class]) return nil;
    NSString *title=FMText(raw[@"title"],300), *artist=FMText(raw[@"artist"],300);
    if (!title.length) return nil;
    NSString *identifier=FMText(raw[@"id"],1024), *album=FMText(raw[@"album"],300);
    if (!identifier.length) identifier=[NSString stringWithFormat:@"%lu:%@|%lu:%@|%@",(unsigned long)title.length,title,(unsigned long)artist.length,artist,album];
    return @{@"id":identifier,@"title":title,@"artist":artist.length?artist:@"未知歌手",@"album":album,@"genre":FMText(raw[@"genre"],100)};
}
static NSString *FMCategory(NSDictionary *track) {
    NSString *genre=track[@"genre"];
    if (genre.length) return [@"曲风：" stringByAppendingString:genre];
    NSString *title=[track[@"title"] lowercaseString];
    for (NSArray *rule in @[@[@"影视相关",@"主题曲",@"片头曲",@"片尾曲",@"插曲",@"ost",@"电视剧",@"电影原声"],
        @[@"现场版本",@"(live",@"（live",@"[live",@"现场版",@"演唱会"],
        @[@"混音 / DJ",@"remix",@"dj版",@"dj 版",@"dj舞曲"],
        @[@"伴奏 / 纯音乐",@"纯音乐",@"伴奏",@"instrumental"],@[@"翻唱版本",@"翻唱",@"cover ",@"cover."]]) {
        for (NSUInteger i=1;i<rule.count;i++) if ([title containsString:rule[i]]) return [@"名称标签：" stringByAppendingString:rule[0]];
    }
    return @"尚无曲风信息";
}

@interface FMListeningHistory ()
@property(nonatomic, strong) NSURL *url;
@property(nonatomic, strong) NSCalendar *calendar;
@property(nonatomic, strong) NSMutableDictionary<NSString *,NSMutableDictionary *> *records;
@property(nonatomic, copy) NSDictionary *previousTrack;
@property(nonatomic, copy) NSDate *previousDate;
@property(nonatomic) double previousUptime;
@property(nonatomic) double previousElapsed;
@property(nonatomic) double previousRate;
@property(nonatomic, copy) NSString *storageError;
@property(nonatomic) BOOL dirty;
@end
@implementation FMListeningHistory
- (instancetype)initWithURL:(NSURL *)url calendar:(NSCalendar *)calendar {
    if (!(self=[super init])) return nil;
    _url=url; _calendar=[calendar copy]; _records=NSMutableDictionary.dictionary;
    if ([NSFileManager.defaultManager fileExistsAtPath:url.path]) {
        NSNumber *size=nil; [url getResourceValue:&size forKey:NSURLFileSizeKey error:nil];
        NSData *data=size.unsignedLongLongValue<=32*1024*1024 ? [NSData dataWithContentsOfURL:url] : nil;
        NSDictionary *root=data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        BOOL valid=[root isKindOfClass:NSDictionary.class] && [root[@"version"] isEqual:@1] && [root[@"rows"] isKindOfClass:NSArray.class] && [root[@"rows"] count]<=50000;
        if (valid) for (id item in root[@"rows"]) {
            if (![item isKindOfClass:NSDictionary.class]) {valid=NO;break;}
            NSString *day=FMText(item[@"day"],10); NSDictionary *track=FMTrack(item[@"track"]);
            id n=item[@"seconds"]; double seconds=[n isKindOfClass:NSNumber.class]?[n doubleValue]:NAN;
            if (day.length!=10 || !track || !isfinite(seconds) || seconds<0 || seconds>86400) {valid=NO;break;}
            NSString *key=[NSString stringWithFormat:@"%@|%@",day,track[@"id"]];
            if (_records[key]) {valid=NO;break;}
            _records[key]=[@{@"day":day,@"track":track,@"seconds":@(seconds)} mutableCopy];
        }
        if (!valid) {[_records removeAllObjects];_storageError=@"听歌记录文件无法读取，原文件已保留。";}
    }
    return self;
}
- (void)resetSample {self.previousTrack=nil;self.previousDate=nil;}
- (NSString *)dayKey:(NSDate *)date {
    NSDateComponents *c=[self.calendar components:NSCalendarUnitYear|NSCalendarUnitMonth|NSCalendarUnitDay fromDate:date];
    return [NSString stringWithFormat:@"%04ld-%02ld-%02ld",(long)c.year,(long)c.month,(long)c.day];
}
- (void)addSeconds:(double)seconds from:(NSDate *)start to:(NSDate *)end track:(NSDictionary *)track {
    double span=[end timeIntervalSinceDate:start]; if(span<=0||seconds<=0||self.storageError)return;
    NSDate *cursor=start;
    while ([cursor compare:end]==NSOrderedAscending) {
        NSDate *midnight=[self.calendar startOfDayForDate:cursor];
        NSDate *next=[self.calendar dateByAddingUnit:NSCalendarUnitDay value:1 toDate:midnight options:0];
        if (!next||[next compare:cursor]!=NSOrderedDescending) break;
        NSDate *stop=[next compare:end]==NSOrderedAscending?next:end;
        NSString *day=[self dayKey:cursor],*key=[NSString stringWithFormat:@"%@|%@",day,track[@"id"]];
        NSMutableDictionary *row=self.records[key];
        if (!row) {row=[@{@"day":day,@"track":track,@"seconds":@0} mutableCopy];self.records[key]=row;}
        row[@"track"]=track;row[@"seconds"]=@(MIN(86400,[row[@"seconds"] doubleValue]+seconds*[stop timeIntervalSinceDate:cursor]/span));
        self.dirty=YES;cursor=stop;
    }
    if (self.records.count>50000) {
        NSArray *keys=[self.records keysSortedByValueUsingComparator:^NSComparisonResult(NSDictionary *a,NSDictionary *b){return [a[@"day"] compare:b[@"day"]];}];
        [self.records removeObjectsForKeys:[keys subarrayWithRange:NSMakeRange(0,self.records.count-45000)]];
    }
}
- (void)observeTrack:(NSDictionary *)raw elapsed:(double)elapsed rate:(double)rate date:(NSDate *)date uptime:(double)uptime {
    NSDictionary *track=FMTrack(raw);
    if (!track||!date||!isfinite(uptime)||!isfinite(elapsed)||elapsed<0||!isfinite(rate)||rate<0||rate>4) {[self resetSample];return;}
    if ([self.previousTrack[@"id"] isEqual:track[@"id"]] && self.previousDate && self.previousRate>0) {
        double gap=uptime-self.previousUptime,wall=[date timeIntervalSinceDate:self.previousDate],advance=elapsed-self.previousElapsed;
        double expected=gap*self.previousRate;
        // Require measured media progress; a seek, stale metadata, long suspension,
        // clock jump or buffer stall must not inflate listening time.
        if(gap>0&&gap<=30&&wall>0&&fabs(wall-gap)<2&&advance>0&&advance<=expected+MAX(1.5,expected*0.15))
            [self addSeconds:MIN(gap,advance/self.previousRate) from:self.previousDate to:date track:self.previousTrack];
    }
    self.previousTrack=track;self.previousDate=date;self.previousUptime=uptime;self.previousElapsed=elapsed;self.previousRate=rate;
}
- (NSArray *)rank:(NSDictionary *)values {
    NSArray *keys=[values keysSortedByValueUsingComparator:^NSComparisonResult(NSNumber *a,NSNumber *b){return [b compare:a];}];
    NSMutableArray *rank=NSMutableArray.array;
    for(NSString *name in keys)[rank addObject:@{@"name":name,@"seconds":values[name]}];
    return rank;
}
- (NSDictionary *)summaryForDate:(NSDate *)date yearly:(BOOL)yearly {
    NSString *prefix=[[self dayKey:date] substringToIndex:yearly?4:7];
    NSMutableDictionary *songs=NSMutableDictionary.dictionary,*artists=NSMutableDictionary.dictionary,*types=NSMutableDictionary.dictionary;
    NSMutableSet *days=NSMutableSet.set; double total=0,classified=0;
    for(NSDictionary *row in self.records.allValues) {
        if(![row[@"day"] hasPrefix:prefix])continue;
        double seconds=[row[@"seconds"] doubleValue];if(seconds<=0)continue;
        NSDictionary *track=row[@"track"];NSString *key=track[@"id"],*artist=track[@"artist"],*type=FMCategory(track);
        NSMutableDictionary *song=songs[key];if(!song){song=[track mutableCopy];song[@"seconds"]=@0;songs[key]=song;}
        song[@"seconds"]=@([song[@"seconds"] doubleValue]+seconds);
        artists[artist]=@([artists[artist] doubleValue]+seconds);types[type]=@([types[type] doubleValue]+seconds);
        total+=seconds;if(![type isEqual:@"尚无曲风信息"])classified+=seconds;[days addObject:row[@"day"]];
    }
    NSArray *sorted=[songs.allValues sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a,NSDictionary *b){return [b[@"seconds"] compare:a[@"seconds"]];}];
    return @{@"period":prefix,@"seconds":@(total),@"trackCount":@(songs.count),@"activeDays":@(days.count),@"artists":[self rank:artists],@"categories":[self rank:types],@"tracks":sorted,@"classifiedSeconds":@(classified),@"storageError":self.storageError?:@""};
}
- (BOOL)save:(NSError **)error {
    if(self.storageError){if(error)*error=[NSError errorWithDomain:@"FMListeningHistory" code:1 userInfo:@{NSLocalizedDescriptionKey:self.storageError}];return NO;}
    if(!self.dirty)return YES;
    [NSFileManager.defaultManager createDirectoryAtURL:self.url.URLByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
    NSData *data=[NSJSONSerialization dataWithJSONObject:@{@"version":@1,@"rows":self.records.allValues} options:0 error:error];
    BOOL success=data&&[data writeToURL:self.url options:NSDataWritingAtomic error:error];
    if(success)self.dirty=NO;return success;
}
- (BOOL)clear:(NSError **)error {
    // Only this module's local aggregates are affected, never the native history.
    NSData *empty=[NSJSONSerialization dataWithJSONObject:@{@"version":@1,@"rows":@[]} options:0 error:error];
    [NSFileManager.defaultManager createDirectoryAtURL:self.url.URLByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
    if(![empty writeToURL:self.url options:NSDataWritingAtomic error:error])return NO;
    [self.records removeAllObjects];[self resetSample];self.storageError=nil;self.dirty=NO;return YES;
}
@end
