#import "FMListeningHistory.h"
#import <math.h>
static int failures;
static void Check(BOOL ok,NSString *message){if(!ok){fprintf(stderr,"FAIL %s\n",message.UTF8String);failures++;}}
static NSDate *Date(NSString *iso){NSISO8601DateFormatter *f=NSISO8601DateFormatter.new;return [f dateFromString:iso];}
static NSDictionary *Track(NSString *identifier,NSString *title,NSString *artist){return @{@"id":identifier,@"title":title,@"artist":artist};}
int main(void){@autoreleasepool{
    NSURL *dir=[NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString] isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:nil error:nil];
    NSCalendar *cal=[[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian];cal.timeZone=[NSTimeZone timeZoneForSecondsFromGMT:0];
    NSURL *url=[dir URLByAppendingPathComponent:@"history.json"];
    FMListeningHistory *h=[[FMListeningHistory alloc] initWithURL:url calendar:cal];
    NSDictionary *a=Track(@"a",@"Song (Live)",@"Artist A"),*b=Track(@"b",@"Theme 电视剧片尾曲",@"Artist B");
    NSDate *t=Date(@"2026-11-30T23:59:55Z");
    [h observeTrack:a elapsed:0 rate:1 date:t uptime:100];
    [h observeTrack:a elapsed:10 rate:1 date:[t dateByAddingTimeInterval:10] uptime:110];
    NSDictionary *nov=[h summaryForDate:t yearly:NO],*dec=[h summaryForDate:[t dateByAddingTimeInterval:10] yearly:NO];
    Check(fabs([nov[@"seconds"] doubleValue]-5)<.01&&fabs([dec[@"seconds"] doubleValue]-5)<.01,@"Split actual time at month midnight");
    [h observeTrack:a elapsed:100 rate:1 date:[t dateByAddingTimeInterval:11] uptime:111];
    [h observeTrack:a elapsed:100 rate:1 date:[t dateByAddingTimeInterval:12] uptime:112];
    Check(fabs([[h summaryForDate:t yearly:YES][@"seconds"] doubleValue]-10)<.01,@"Seek and buffering add no time");
    [h observeTrack:a elapsed:102 rate:0 date:[t dateByAddingTimeInterval:14] uptime:114];
    [h observeTrack:a elapsed:102 rate:0 date:[t dateByAddingTimeInterval:24] uptime:124];
    [h observeTrack:a elapsed:102 rate:1 date:[t dateByAddingTimeInterval:25] uptime:125];
    [h observeTrack:a elapsed:107 rate:1 date:[t dateByAddingTimeInterval:30] uptime:130];
    Check(fabs([[h summaryForDate:t yearly:YES][@"seconds"] doubleValue]-17)<.01,@"Pause excluded and resume included");
    [h observeTrack:b elapsed:0 rate:2 date:[t dateByAddingTimeInterval:31] uptime:131];
    [h observeTrack:b elapsed:20 rate:2 date:[t dateByAddingTimeInterval:41] uptime:141];
    Check(fabs([[h summaryForDate:t yearly:YES][@"seconds"] doubleValue]-27)<.01,@"Track switch excludes transition; double speed counts wall listening time");
    [h observeTrack:b elapsed:200 rate:2 date:[t dateByAddingTimeInterval:141] uptime:241];
    [h observeTrack:b elapsed:202 rate:2 date:[t dateByAddingTimeInterval:2142] uptime:242];
    Check(fabs([[h summaryForDate:t yearly:YES][@"seconds"] doubleValue]-27)<.01,@"Long gaps and wall clock jumps excluded");
    [h observeTrack:b elapsed:NAN rate:1 date:t uptime:243];
    [h observeTrack:b elapsed:0 rate:1 date:t uptime:244];
    Check([[h summaryForDate:t yearly:YES][@"trackCount"] integerValue]==2,@"Two identities aggregated across days");
    Check([h save:nil],@"Atomic save succeeds");
    FMListeningHistory *reload=[[FMListeningHistory alloc] initWithURL:url calendar:cal];
    NSDictionary *annual=[reload summaryForDate:t yearly:YES];
    Check(fabs([annual[@"seconds"] doubleValue]-27)<.01&&[annual[@"activeDays"] integerValue]==2,@"Persisted annual aggregates match actual days");
    Check([annual[@"categories"] count]==2&&fabs([annual[@"classifiedSeconds"] doubleValue]-27)<.01,@"Explicit name tags classified without inferring unknown styles");
    [reload resetSample];NSDictionary *plain=Track(@"plain",@"Unclassified song",@"Artist C");
    [reload observeTrack:plain elapsed:0 rate:1 date:t uptime:300];[reload observeTrack:plain elapsed:5 rate:1 date:[t dateByAddingTimeInterval:5] uptime:305];
    Check(fabs([[reload summaryForDate:t yearly:YES][@"classifiedSeconds"] doubleValue]-27)<.01,@"Untagged track remains unknown");
    NSError *error=nil;Check([reload clear:&error]&&!error,@"Clear succeeds");Check([[reload summaryForDate:t yearly:YES][@"seconds"] doubleValue]==0,@"Clear deletes only module aggregates");
    [@"not-json" writeToURL:url atomically:YES encoding:NSUTF8StringEncoding error:nil];
    FMListeningHistory *bad=[[FMListeningHistory alloc] initWithURL:url calendar:cal];Check(bad.storageError.length>0&&! [bad save:nil],@"Corrupt storage is reported, not overwritten");
    Check([[NSString stringWithContentsOfURL:url encoding:NSUTF8StringEncoding error:nil] isEqual:@"not-json"],@"Original corrupt bytes preserved");
    [NSFileManager.defaultManager removeItemAtURL:dir error:nil];
    printf("Listening insights tests: %s (%d failures)\n",failures?"FAILED":"PASSED",failures);return failures?1:0;
}}
