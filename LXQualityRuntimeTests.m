#import "LXSourceRuntime.h"
#import "FMQualityResolver.h"

static NSUInteger failures;
static void Check(BOOL condition,NSString *name) { if(!condition) { ++failures; fprintf(stderr,"FAIL: %s\n",name.UTF8String); } }
static BOOL Wait(BOOL (^condition)(void),NSTimeInterval timeout) {
    NSTimeInterval end=NSProcessInfo.processInfo.systemUptime+timeout;
    while(!condition() && NSProcessInfo.processInfo.systemUptime<end)
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.002]];
    return condition();
}
static void Pump(NSTimeInterval duration) { NSTimeInterval end=NSProcessInfo.processInfo.systemUptime+duration; Wait(^BOOL{ return NSProcessInfo.processInfo.systemUptime>=end; },duration+0.1); }
static LXSourceRuntime *Load(NSString *bootstrap) {
    LXSourceRuntime *runtime=[[LXSourceRuntime alloc] initWithBootstrapScript:bootstrap];
    NSString *script=@"lx.on('request',p=>{const q=p.info.type;if(q==='flac24bit')return new Promise(r=>setTimeout(()=>r('https://fixture.invalid/late-high'),180));if(q==='flac')return Promise.resolve('https://fixture.invalid/lower');if(q==='320k')return Promise.reject(new Error('fixture failure'));return new Promise(()=>{});});lx.send('inited',{sources:{tx:{name:'Authored fixture',type:'music',actions:['musicUrl'],qualitys:['flac24bit','flac','320k','128k']}}});";
    __block BOOL loaded=NO; __block NSError *error;
    [runtime loadSource:script name:@"Fixture" timeout:2 completion:^(NSDictionary *manifest,NSError *e){ loaded=YES; error=e; }];
    Check(Wait(^BOOL{ return loaded; },3) && !error && runtime.manifest,@"authored source loads without network");
    return runtime;
}
int main(int argc,const char *argv[]) { @autoreleasepool {
    if(argc!=2) { fprintf(stderr,"usage: LXQualityRuntimeTests LXBootstrap.js\n"); return 2; }
    NSString *bootstrap=[NSString stringWithContentsOfFile:[NSString stringWithUTF8String:argv[1]] encoding:NSUTF8StringEncoding error:nil];
    if(!bootstrap.length) return 2;
    LXSourceRuntime *runtime=Load(bootstrap);
    __block NSUInteger callbacks=0; __block NSError *error; __block NSURL *result;
    [runtime resolveMusicURLForSource:@"tx" musicInfo:@{@"songmid":@"authored"} quality:@"flac24bit" timeout:0.04 invalidateOnTimeout:NO completion:^(NSURL *u,NSError *e){ ++callbacks; error=e; result=u; }];
    Check(Wait(^BOOL{ return callbacks==1; },2) && error.code==7 && !result && runtime.manifest,@"soft attempt timeout retains responsive source");
    __block NSUInteger lowerCallbacks=0;
    [runtime resolveMusicURLForSource:@"tx" musicInfo:@{} quality:@"flac" timeout:0.2 invalidateOnTimeout:NO completion:^(NSURL *u,NSError *e){ ++lowerCallbacks; result=u; error=e; }];
    Check(Wait(^BOOL{ return lowerCallbacks==1; },2) && result && !error,@"same runtime resolves lower quality after soft timeout");
    Pump(0.6);
    Check(callbacks==1 && runtime.manifest,@"late high URL discarded; responsive cancellation probe does not invalidate source");

    callbacks=0;
    NSString *identifier=[runtime resolveMusicURLForSource:@"tx" musicInfo:@{} quality:@"128k" timeout:0.3 invalidateOnTimeout:NO completion:^(NSURL *u,NSError *e){ ++callbacks; result=u; error=e; }];
    [runtime cancelRequestWithIdentifier:identifier];
    Check(Wait(^BOOL{ return callbacks==1; },2) && error.code==NSUserCancelledError && !result,@"soft attempt explicit cancellation completes once");
    Pump(0.6); Check(callbacks==1 && runtime.manifest,@"ordinary cancellation keeps responsive runtime available");

    callbacks=0; __block NSString *requested;
    FMQualityResolver *session=[[FMQualityResolver alloc] initWithPlatform:@"tx" supportedQualities:@[@"flac24bit",@"flac"] timeout:0.24 isCurrent:^BOOL{ return runtime.manifest!=nil; } resolve:^dispatch_block_t(NSString *q,NSTimeInterval limit,FMQualityAttemptCompletion done){
        NSString *token=[runtime resolveMusicURLForSource:@"tx" musicInfo:@{} quality:q timeout:limit invalidateOnTimeout:NO completion:done];
        return ^{ [runtime cancelRequestWithIdentifier:token]; };
    }];
    [session nextWithCompletion:^(NSURL *u,NSString *q,NSError *e){ ++callbacks; result=u; requested=q; error=e; }];
    Check(Wait(^BOOL{ return callbacks==1; },2) && result && !error && [requested isEqual:@"flac"],@"production ladder plus JSCore skips slow high attempt and resolves lower");
    Pump(0.6); Check(callbacks==1 && runtime.manifest,@"old high completion cannot replace ladder result");
    [session cancel];

    callbacks=0;
    [runtime resolveMusicURLForSource:@"tx" musicInfo:@{} quality:@"128k" timeout:1 completion:^(NSURL *u,NSError *e){ ++callbacks; result=u; error=e; }];
    Check(Wait(^BOOL{ return callbacks==1; },3) && error.code==7 && !result && !runtime.manifest,@"original API still discards runtime on hard timeout");
    [runtime invalidate];
    fprintf(stdout,"LXQualityRuntime: %s (%lu failures)\n",failures?"FAILED":"PASS",(unsigned long)failures);
    return failures?1:0;
} }
