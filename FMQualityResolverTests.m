#import "FMQualityResolver.h"

static NSUInteger failures;
static void Check(BOOL condition, NSString *name) { if (!condition) { ++failures; fprintf(stderr,"FAIL: %s\n",name.UTF8String); } }
static BOOL Wait(BOOL (^condition)(void), NSTimeInterval timeout) {
    NSTimeInterval end = NSProcessInfo.processInfo.systemUptime + timeout;
    while (!condition() && NSProcessInfo.processInfo.systemUptime < end)
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.002]];
    return condition();
}
static void Pump(NSTimeInterval duration) { NSTimeInterval end=NSProcessInfo.processInfo.systemUptime+duration; Wait(^BOOL{ return NSProcessInfo.processInfo.systemUptime>=end; },duration+0.1); }
static NSURL *URL(NSString *name) { return [NSURL URLWithString:[@"https://fixture.invalid/" stringByAppendingString:name]]; }
static NSError *Failure(void) { return [NSError errorWithDomain:@"Fixture" code:403 userInfo:nil]; }
static FMQualityResolver *Session(NSArray *qualities, NSTimeInterval budget, BOOL (^current)(void), FMQualityAttemptResolver resolve) {
    return [[FMQualityResolver alloc] initWithPlatform:@"tx" supportedQualities:qualities timeout:budget isCurrent:current resolve:resolve];
}
int main(void) { @autoreleasepool {
    NSArray *all=@[@"128k",@"flac",@"320k",@"flac24bit",@"unsupported",@"flac"];
    Check([[FMQualityResolver orderedQualitiesForPlatform:@"qq" supportedQualities:all] isEqual:@[@"flac24bit",@"flac",@"320k",@"128k"]],@"quality intersection is unique highest to lowest");
    Check([[FMQualityResolver orderedQualitiesForPlatform:@"kg" supportedQualities:all] isEqual:@[@"128k"]],@"Kugou is standard only");
    Check([FMQualityResolver orderedQualitiesForPlatform:@"qs" supportedQualities:all].count==0,@"unsupported platform has no candidate");
    __block NSUInteger calls=0, callbacks=0; __block NSURL *result; __block NSString *quality; __block NSError *error;
    NSMutableArray *attempted=NSMutableArray.array;
    FMQualityResolver *session=Session(all,35,^BOOL{ return YES; },^dispatch_block_t(NSString *q,NSTimeInterval limit,FMQualityAttemptCompletion done){
        Check(NSThread.isMainThread,@"resolver executes on main"); Check(limit>0 && limit<=20,@"attempt has official 20-second ceiling");
        if(calls==0)Check(limit==20,@"highest supported quality receives official ceiling rather than 35-second budget divided by four");
        ++calls; [attempted addObject:q]; done([q isEqual:@"320k"]?URL(@"medium"):nil,[q isEqual:@"320k"]?nil:Failure()); return nil;
    });
    [session nextWithCompletion:^(NSURL *u,NSString *q,NSError *e){ ++callbacks; result=u; quality=q; error=e; Check(NSThread.isMainThread,@"completion executes on main"); }];
    Check(Wait(^BOOL{ return callbacks==1; },2),@"fallback completes");
    Check(result && !error && [quality isEqual:@"320k"] && [attempted isEqual:@[@"flac24bit",@"flac",@"320k"]],@"higher failures fall to successful lower quality");
    callbacks=0; [session nextWithCompletion:^(NSURL *u,NSString *q,NSError *e){ ++callbacks; result=u; error=e; }];
    Check(Wait(^BOOL{ return callbacks==1; },2) && !result && error.code==FMQualityResolverExhausted && calls==4,@"playback failure next consumes only remaining quality");
    callbacks=0; [session nextWithCompletion:^(NSURL *u,NSString *q,NSError *e){ ++callbacks; error=e; }];
    Check(Wait(^BOOL{ return callbacks==1; },2) && calls==4,@"exhaustion never restarts attempted qualities");

    callbacks=0; calls=0;
    session=Session(all,2,^BOOL{ return YES; },^dispatch_block_t(NSString *q,NSTimeInterval t,FMQualityAttemptCompletion done){ ++calls; done(nil,Failure()); return nil; });
    [session nextWithCompletion:^(NSURL *u,NSString *q,NSError *e){ ++callbacks; result=u; error=e; }];
    Check(Wait(^BOOL{ return callbacks==1; },2) && !result && error.code==FMQualityResolverExhausted && calls==4,@"all failures exhaust every supported quality once in one next call");

    callbacks=0; calls=0;
    session=Session(@[@"320k",@"128k"],2,^BOOL{ return YES; },^dispatch_block_t(NSString *q,NSTimeInterval t,FMQualityAttemptCompletion done){ ++calls; done(URL(q),nil); return nil; });
    [session nextWithCompletion:^(NSURL *u,NSString *q,NSError *e){ ++callbacks; quality=q; }];
    Check(Wait(^BOOL{ return callbacks==1; },2) && [quality isEqual:@"320k"],@"initial candidate is highest");
    callbacks=0; [session nextWithCompletion:^(NSURL *u,NSString *q,NSError *e){ ++callbacks; quality=q; result=u; error=e; }];
    Check(Wait(^BOOL{ return callbacks==1; },2) && [quality isEqual:@"128k"] && result && !error && calls==2,@"next after actual playback failure can succeed lower");

    callbacks=0; calls=0;
    session=Session(@[@"flac",@"320k",@"128k"],2,^BOOL{ return YES; },^dispatch_block_t(NSString *q,NSTimeInterval t,FMQualityAttemptCompletion done){ ++calls; done(URL([q isEqual:@"128k"]?@"different":@"same"),nil); return nil; });
    [session nextWithCompletion:^(NSURL *u,NSString *q,NSError *e){ ++callbacks; }]; Wait(^BOOL{ return callbacks==1; },2);
    callbacks=0; [session nextWithCompletion:^(NSURL *u,NSString *q,NSError *e){ ++callbacks; result=u; quality=q; error=e; }];
    Check(Wait(^BOOL{ return callbacks==1; },2) && [quality isEqual:@"128k"] && calls==3 && !error,@"duplicate failed URL skipped without returning it for playback again");

    callbacks=0; calls=0; __block NSUInteger cancels=0; __block FMQualityAttemptCompletion late;
    session=Session(all,2,^BOOL{ return YES; },^dispatch_block_t(NSString *q,NSTimeInterval t,FMQualityAttemptCompletion done){ ++calls; late=[done copy]; return ^{ ++cancels; }; });
    [session nextWithCompletion:^(NSURL *u,NSString *q,NSError *e){ ++callbacks; result=u; error=e; }];
    [session cancel]; [session cancel]; late(URL(@"late"),nil); Pump(0.03);
    Check(callbacks==1 && !result && error.code==NSURLErrorCancelled && calls==1 && cancels==1,@"cancel once; late successful completion cannot resume or overwrite");

    callbacks=0; calls=0;
    session=Session(@[@"320k"],2,^BOOL{ return YES; },^dispatch_block_t(NSString *q,NSTimeInterval t,FMQualityAttemptCompletion done){ ++calls; done(URL(@"queued-success"),nil); return nil; });
    [session nextWithCompletion:^(NSURL *u,NSString *q,NSError *e){ ++callbacks; result=u; error=e; }];
    dispatch_async(dispatch_get_main_queue(), ^{ [session cancel]; });
    Check(Wait(^BOOL{ return callbacks==1; },2) && !result && error.code==NSURLErrorCancelled,@"cancel between successful resolution and queued delivery suppresses URL");

    callbacks=0; calls=0; __block BOOL current=YES;
    session=Session(all,2,^BOOL{ return current; },^dispatch_block_t(NSString *q,NSTimeInterval t,FMQualityAttemptCompletion done){ ++calls; late=[done copy]; return nil; });
    [session nextWithCompletion:^(NSURL *u,NSString *q,NSError *e){ ++callbacks; result=u; error=e; }]; current=NO; late(URL(@"old-source"),nil);
    Check(Wait(^BOOL{ return callbacks==1; },2) && !result && error.code==FMQualityResolverSourceChanged && calls==1,@"source generation change rejects old URL and stops ladder");

    callbacks=0; calls=0;
    session=Session(@[@"unsupported"],2,^BOOL{ return YES; },^dispatch_block_t(NSString *q,NSTimeInterval t,FMQualityAttemptCompletion done){ ++calls; return nil; });
    [session nextWithCompletion:^(NSURL *u,NSString *q,NSError *e){ ++callbacks; error=e; }];
    Check(Wait(^BOOL{ return callbacks==1; },2) && error.code==FMQualityResolverNoSupportedQuality && calls==0,@"no common supported quality never invokes a script");

    callbacks=0; calls=0; cancels=0; NSMutableArray *limits=NSMutableArray.array; NSMutableArray *lateCallbacks=NSMutableArray.array;
    session=Session(@[@"320k",@"128k"],0.16,^BOOL{ return YES; },^dispatch_block_t(NSString *q,NSTimeInterval t,FMQualityAttemptCompletion done){ ++calls; [limits addObject:@(t)]; [lateCallbacks addObject:[done copy]]; return ^{ ++cancels; }; });
    NSTimeInterval started=NSProcessInfo.processInfo.systemUptime;
    [session nextWithCompletion:^(NSURL *u,NSString *q,NSError *e){ ++callbacks; result=u; error=e; }];
    Check(Wait(^BOOL{ return callbacks==1; },2) && !result && error.code==NSURLErrorTimedOut && calls==1 && cancels==1,@"silent attempt consumes short caller deadline without inventing more time for lower quality");
    Check(NSProcessInfo.processInfo.systemUptime-started<1 && limits.count==1 && [limits[0] doubleValue]<=0.16,@"short deadline takes priority over official 20-second ceiling");
    for (FMQualityAttemptCompletion done in lateCallbacks) done(URL(@"after-deadline"),nil); Pump(0.03);
    Check(callbacks==1,@"all late deadline callbacks ignored");

    // Explicit metadata failure advances immediately but cannot refill the
    // current call's deadline. Use short real timers rather than a 20s sleep.
    callbacks=0;calls=0;cancels=0;[limits removeAllObjects];
    session=Session(@[@"320k",@"128k"],0.4,^BOOL{return YES;},^dispatch_block_t(NSString *q,NSTimeInterval t,FMQualityAttemptCompletion done){
        ++calls;[limits addObject:@(t)];
        if([q isEqual:@"320k"])dispatch_after(dispatch_time(DISPATCH_TIME_NOW,180*NSEC_PER_MSEC),dispatch_get_main_queue(),^{done(nil,Failure());});
        return ^{++cancels;};
    });
    started=NSProcessInfo.processInfo.systemUptime;
    [session nextWithCompletion:^(NSURL *u,NSString *q,NSError *e){++callbacks;result=u;error=e;}];
    Check(Wait(^BOOL{return callbacks==1;},2) && !result && error.code==NSURLErrorTimedOut && calls==2 && cancels==1,@"explicit high failure advances and lower silent attempt exhausts same deadline");
    Check(limits.count==2 && [limits[0] doubleValue]==0.4 && [limits[1] doubleValue]>0 && [limits[1] doubleValue]<0.3 && NSProcessInfo.processInfo.systemUptime-started<0.8,@"metadata failures within one next call share remaining budget without reset");

    // Successful URL delivery ends one resolution call. A later actual media
    // failure grants the unattempted quality the original bounded call budget.
    callbacks=0;calls=0;[limits removeAllObjects];
    session=Session(@[@"320k",@"128k"],0.6,^BOOL{return YES;},^dispatch_block_t(NSString *q,NSTimeInterval t,FMQualityAttemptCompletion done){
        ++calls;[limits addObject:@(t)];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,350*NSEC_PER_MSEC),dispatch_get_main_queue(),^{done(URL(q),nil);});return nil;
    });
    [session nextWithCompletion:^(NSURL *u,NSString *q,NSError *e){++callbacks;result=u;quality=q;error=e;}];
    Check(Wait(^BOOL{return callbacks==1;},2) && result && !error && [quality isEqual:@"320k"],@"first candidate can consume most of one resolution budget");
    Pump(0.05);callbacks=0;
    [session nextWithCompletion:^(NSURL *u,NSString *q,NSError *e){++callbacks;result=u;quality=q;error=e;}];
    Check(Wait(^BOOL{return callbacks==1;},2) && result && !error && [quality isEqual:@"128k"] && calls==2,@"actual media failure grants next quality enough fresh budget to complete");
    Check(limits.count==2 && [limits[0] doubleValue]==0.6 && [limits[1] doubleValue]==0.6,@"renewed next budget equals original short caller limit rather than 20 or 35 seconds");

    callbacks=0;calls=0;[limits removeAllObjects];
    session=Session(all,35,^BOOL{return YES;},^dispatch_block_t(NSString *q,NSTimeInterval t,FMQualityAttemptCompletion done){++calls;[limits addObject:@(t)];done(nil,Failure());return nil;});
    [session nextWithCompletion:^(NSURL *u,NSString *q,NSError *e){++callbacks;result=u;error=e;}];
    Check(Wait(^BOOL{return callbacks==1;},2) && !result && error.code==FMQualityResolverExhausted && calls==4,@"four explicit fast failures still visit every quality without waiting for timeout");
    Check(limits.count==4 && [limits[0] doubleValue]==20 && [limits[3] doubleValue]<=20 && [limits[3] doubleValue]>10,@"official ceiling permits more than former ten-second cap without lengthening total deadline");

    callbacks=0; calls=0;
    session=Session(@[@"320k",@"128k"],0.12,^BOOL{ return YES; },^dispatch_block_t(NSString *q,NSTimeInterval t,FMQualityAttemptCompletion done){ ++calls; done(URL(q),nil); return nil; });
    [session nextWithCompletion:^(NSURL *u,NSString *q,NSError *e){ ++callbacks; }]; Wait(^BOOL{ return callbacks==1; },2); Pump(0.2);
    callbacks=0; [session nextWithCompletion:^(NSURL *u,NSString *q,NSError *e){ ++callbacks; result=u; quality=q; error=e; }];
    Check(Wait(^BOOL{ return callbacks==1; },2) && result && !error && [quality isEqual:@"128k"],@"time spent playing is not charged to resolution budget");

    callbacks=0; __block NSUInteger busyCallbacks=0;
    session=Session(@[@"320k",@"128k"],2,^BOOL{ return YES; },^dispatch_block_t(NSString *q,NSTimeInterval t,FMQualityAttemptCompletion done){ late=[done copy]; return nil; });
    [session nextWithCompletion:^(NSURL *u,NSString *q,NSError *e){ ++callbacks; result=u; }];
    [session nextWithCompletion:^(NSURL *u,NSString *q,NSError *e){ ++busyCallbacks; Check(e.code==FMQualityResolverBusy,@"concurrent next reports busy"); }];
    late(URL(@"original"),nil);
    Check(Wait(^BOOL{ return callbacks==1 && busyCallbacks==1; },2) && result,@"concurrent next does not cancel original attempt");
    fprintf(stdout,"FMQualityResolver: %s (%lu failures)\n",failures?"FAILED":"PASS",(unsigned long)failures);
    return failures?1:0;
} }
