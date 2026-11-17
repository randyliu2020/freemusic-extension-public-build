// Standalone macOS executable. Uses self-authored fixtures only.
#import <Foundation/Foundation.h>
#import "LXSourceRuntime.h"
#import <sys/socket.h>
#import <netinet/in.h>
#import <unistd.h>
#import <stdatomic.h>
#import <errno.h>

static void Require(BOOL value, NSString *message) {
    if (!value) { fprintf(stderr,"FAIL: %s\n",message.UTF8String); exit(1); }
}
static void Wait(BOOL (^done)(void), NSTimeInterval timeout) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    while (!done() && deadline.timeIntervalSinceNow > 0) [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    Require(done(),@"Test callback timed out");
}
static int StartFixtureServer(uint16_t *port) {
    int server = socket(AF_INET,SOCK_STREAM,0); Require(server >= 0,@"Create fixture socket");
    int yes = 1; setsockopt(server,SOL_SOCKET,SO_REUSEADDR,&yes,sizeof(yes));
    struct sockaddr_in address = {0}; address.sin_len=sizeof(address); address.sin_family=AF_INET; address.sin_addr.s_addr=htonl(INADDR_LOOPBACK); address.sin_port=0;
    Require(bind(server,(struct sockaddr *)&address,sizeof(address)) == 0,@"Bind loopback fixture");
    socklen_t length=sizeof(address); getsockname(server,(struct sockaddr *)&address,&length); *port=ntohs(address.sin_port);
    Require(listen(server,4) == 0,@"Listen fixture");
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0), ^{
        @autoreleasepool {
            for (;;) {
                int client=accept(server,NULL,NULL); if (client < 0) return;
                int noPipe=1; setsockopt(client,SOL_SOCKET,SO_NOSIGPIPE,&noPipe,sizeof(noPipe));
                struct timeval socketTimeout={3,0}; setsockopt(client,SOL_SOCKET,SO_RCVTIMEO,&socketTimeout,sizeof(socketTimeout));
                NSMutableData *request=[NSMutableData data]; char buffer[4096];
                NSString *requestText=@""; NSUInteger headerEnd=NSNotFound, contentLength=0;
                while (request.length < 65536) {
                    ssize_t count=recv(client,buffer,sizeof(buffer),0); if (count<=0) break;
                    [request appendBytes:buffer length:(NSUInteger)count];
                    NSRange boundary=[request rangeOfData:[@"\r\n\r\n" dataUsingEncoding:NSASCIIStringEncoding] options:0 range:NSMakeRange(0,request.length)];
                    if (boundary.location != NSNotFound) {
                        headerEnd=NSMaxRange(boundary);
                        requestText=[[NSString alloc] initWithData:[request subdataWithRange:NSMakeRange(0,headerEnd)] encoding:NSUTF8StringEncoding] ?: @"";
                        for (NSString *line in [requestText componentsSeparatedByString:@"\r\n"]) {
                            if ([line.lowercaseString hasPrefix:@"content-length:"]) contentLength=[[[line componentsSeparatedByString:@":"] lastObject] integerValue];
                        }
                        if (request.length >= headerEnd+contentLength) break;
                    }
                }
                NSData *rawBody=headerEnd != NSNotFound && headerEnd<=request.length ? [request subdataWithRange:NSMakeRange(headerEnd,request.length-headerEnd)] : NSData.data;
                NSString *body=[[NSString alloc] initWithData:rawBody encoding:NSUTF8StringEncoding] ?: @"";
                BOOL cookie=[requestText.lowercaseString containsString:@"\r\ncookie:"];
                BOOL internalHeader=[requestText.lowercaseString containsString:@"\r\nfmx.internalrequest:"];
                NSDictionary *response=@{@"echo":body,@"cookie":@(cookie),@"internalHeader":@(internalHeader),@"bodyBase64":[rawBody base64EncodedStringWithOptions:0],@"requestHeaders":requestText};
                if ([requestText hasPrefix:@"GET /session "])
                    response=@{@"code":@0,@"data":@{@"session":@"anonymous-fixture-session"}};
                else if ([requestText hasPrefix:@"GET /parse?"]) {
                    BOOL authenticated=[requestText.lowercaseString containsString:@"\r\nx-fixture-session: anonymous-fixture-session\r\n"];
                    BOOL validMID=[requestText hasPrefix:@"GET /parse?mid=anonymous_mid&quality=128k "];
                    response=authenticated && validMID
                        ? @{@"code":@200,@"url":@"https://fixture.invalid/full.mp3?duration=240"}
                        : @{@"code":@403,@"message":@"fixture verification required"};
                }
                NSData *json=[NSJSONSerialization dataWithJSONObject:response options:0 error:nil];
                BOOL binary=[requestText hasPrefix:@"GET /binary "];
                if(binary){const unsigned char bytes[]={0,255,128,65,0};json=[NSData dataWithBytes:bytes length:sizeof(bytes)];}
                if([requestText hasPrefix:@"GET /slow "])usleep(200000);
                BOOL oversized=[requestText hasPrefix:@"GET /oversized "];
                BOOL head = [requestText hasPrefix:@"HEAD "];
                NSString *header=[NSString stringWithFormat:@"HTTP/1.1 200 OK\r\nContent-Type: %@\r\nSet-Cookie: fixture=must-not-persist\r\nContent-Length: %lu\r\nConnection: close\r\n\r\n",head ? @"audio/mpeg" : binary ? @"application/octet-stream" : @"application/json",(unsigned long)(head ? 10*1024*1024 : oversized ? 4*1024*1024+1 : json.length)];
                NSMutableData *reply=[[header dataUsingEncoding:NSUTF8StringEncoding] mutableCopy]; if (!head) [reply appendData:json];
                NSUInteger sent=0; while (sent<reply.length) { ssize_t n=send(client,(const char *)reply.bytes+sent,reply.length-sent,0); if(n<=0) break; sent+=(NSUInteger)n; }
                close(client);
            }
        }
    });
    return server;
}
static void Load(LXSourceRuntime *runtime, NSString *script, BOOL expectedSuccess) {
    __block BOOL complete=NO;
    [runtime loadSource:script name:@"fixture" timeout:2 completion:^(NSDictionary *manifest,NSError *error) {
        Require(NSThread.isMainThread,@"Load completion is on main thread");
        Require(expectedSuccess ? manifest!=nil && error==nil : error!=nil,@"Unexpected fixture load result");
        complete=YES;
    }];
    Wait(^BOOL{return complete;},4);
}
static void Resolve(LXSourceRuntime *runtime, NSString *song, BOOL success, NSString *expectedError) {
    __block BOOL complete=NO;
    [runtime resolveMusicURLForSource:@"wy" musicInfo:@{@"songmid":song,@"name":@"fixture"} quality:@"128k" timeout:1 completion:^(NSURL *URL,NSError *error) {
        Require(NSThread.isMainThread,@"Resolve completion is on main thread");
        Require(success ? URL!=nil && error==nil : error!=nil,@"Unexpected resolve outcome");
        if(expectedError) Require([error.localizedDescription containsString:expectedError],error.localizedDescription);
        complete=YES;
    }];
    Wait(^BOOL{return complete;},4);
}
static void AuthenticatedQQ(LXSourceRuntime *runtime, uint16_t port) {
    // Self-authored flow on loopback: pending initialization request, callback
    // JSON, script-provided header, QQ songmid, and HTTP-200 business errors.
    NSString *script=[NSString stringWithFormat:
        @"const base='http://127.0.0.1:%hu';"
        "function call(path,headers={}){return new Promise((resolve,reject)=>lx.request(base+path,{headers,timeout:6000},(error,response)=>error?reject(error):resolve(response.body)))}"
        "const session=call('/session').then(body=>body.data.session);"
        "lx.on('request',async({source,action,info})=>{"
        "if(source!=='tx'||action!=='musicUrl')throw Error('fixture event');"
        "const key=await session;"
        "const body=await call('/parse?mid='+encodeURIComponent(info.musicInfo.songmid)+'&quality='+info.type,{'X-Fixture-Session':key});"
        "if(body.code!==200)throw Error(body.message);return body.url;});"
        "lx.send('inited',{sources:{tx:{type:'music',actions:['musicUrl','lyric','pic'],qualitys:['128k','320k','flac','hires']}}});",port];
    Load(runtime,script,YES);
    __block NSUInteger finished=0;
    for (NSString *mid in @[@"anonymous_mid",@"rejected_mid"]) {
        [runtime resolveMusicURLForSource:@"tx" musicInfo:@{@"songmid":mid} quality:@"128k" timeout:3 completion:^(NSURL *URL,NSError *error) {
            Require(NSThread.isMainThread,@"Authenticated fixture completion thread");
            if ([mid isEqualToString:@"anonymous_mid"])
                Require(!error && [URL.absoluteString isEqualToString:@"https://fixture.invalid/full.mp3?duration=240"],@"QQ returned URL is preserved without preview substitution");
            else Require(!URL && [error.localizedDescription isEqualToString:@"fixture verification required"],@"HTTP 200 business refusal is preserved as source error");
            finished++;
        }];
    }
    Wait(^BOOL{return finished==2;},5);
    Require(runtime.manifest[@"sources"][@"tx"]!=nil,@"Business refusal does not disable initialized source");
    [runtime invalidate];
}
static void CompatibilityCrypto(NSString *bootstrap) {
    // Generated solely for this public test. The expected raw-RSA ciphertext
    // was computed independently with Node/OpenSSL RSA_NO_PADDING. No private
    // key, real source, service credential, or external endpoint is included.
    NSString *spki=@"MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQCVSng5pQU3K5uc/BhOVIJaQCwWo4wAFYuGnSKtBC940NyvpvwXdyoWCVYjvoA694YjeT89VjBw4Ytt78l0PLbqsughA4uGmDzSQdiYFld614S+vlVwM+CZMPIYoCiEN+xi2saoN5Rd4zMJyNbg0ArZk74YlrgVOaVQonToT+crxwIDAQAB";
    NSString *pkcs1=@"MIGJAoGBAJVKeDmlBTcrm5z8GE5UglpALBajjAAVi4adIq0EL3jQ3K+m/Bd3KhYJViO+gDr3hiN5Pz1WMHDhi23vyXQ8tuqy6CEDi4aYPNJB2JgWV3rXhL6+VXAz4Jkw8higKIQ37GLaxqg3lF3jMwnI1uDQCtmTvhiWuBU5pVCidOhP5yvHAgMBAAE=";
    NSArray *keys=@[[NSString stringWithFormat:@"-----BEGIN PUBLIC KEY-----\n%@\n-----END PUBLIC KEY-----",spki],spki,[NSString stringWithFormat:@"-----BEGIN RSA PUBLIC KEY-----\n%@\n-----END RSA PUBLIC KEY-----",pkcs1]];
    NSData *encoded=[NSJSONSerialization dataWithJSONObject:keys options:0 error:nil];
    NSString *json=[[NSString alloc] initWithData:encoded encoding:NSUTF8StringEncoding];
    NSString *script=[NSString stringWithFormat:
        @"function check(v,m){if(!v)throw Error(m)};const keys=%@;"
        "const hex=b=>lx.utils.buffer.bufToString(b,'hex');"
        "for(const key of keys)check(hex(lx.utils.crypto.rsaEncrypt('LX RSA fixture',key))==='5e5519516031099dfe498ea0bcddf9dd9bda08341df240d2c88881dc9e280a1a5c34f28250d424036e5a21cbc37a40b9e7a8cedd157630544268858b3731490805412ffa1b52a8b7f159dc89a97a18e75504264f285e9e57d29a28ffd043efc6521cfa45275090786b71425a0a0d2fe92f9ca4448405d9875ae017bac1bc03ff','RSA format or NoPadding mismatch');"
        "check(hex(lx.utils.crypto.rsaEncrypt(new Uint8Array([0]),keys[0]))==='00'.repeat(128),'RSA integer zero');"
        "for(const [value,key] of [[new Uint8Array(129),keys[0]],[new Uint8Array(128).fill(255),keys[0]],['a','not-a-key'],['a','-----BEGIN PRIVATE KEY-----AAAA-----END PRIVATE KEY-----']]){let fail=false;try{lx.utils.crypto.rsaEncrypt(value,key)}catch(e){fail=true}check(fail,'malformed or oversized RSA accepted')}"
        "check(hex(lx.utils.crypto.aesEncrypt(lx.utils.buffer.from('00112233445566778899aabbccddeeff','hex'),'aes-128-ecb',lx.utils.buffer.from('000102030405060708090a0b0c0d0e0f','hex'),''))==='69c4e0d86a7b0430d8cdb78070b4c55a','NIST AES ECB known vector');"
        "check(hex(lx.utils.buffer.from('abc','hex'))==='ab0c','LX odd hex');"
        "check(hex(lx.utils.buffer.from('gg','hex'))==='00','LX invalid hex');"
        "const view=new DataView(new Uint8Array([1,2,3,4]).buffer,1,2);check(hex(view)==='0203','view offsets');"
        "console.group('fixture');console.groupEnd();console.time('x');console.timeEnd('x');"
        "lx.on('request',()=>Promise.resolve('https://fixture.invalid/crypto.mp3'));lx.send('inited',{sources:{wy:{type:'music',actions:['musicUrl'],qualitys:['128k']}}});",json];
    LXSourceRuntime *runtime=[[LXSourceRuntime alloc] initWithBootstrapScript:bootstrap];
    Load(runtime,script,YES);Resolve(runtime,@"crypto",YES,nil);[runtime invalidate];
    printf("PASS: v7 RSA SPKI/PKCS1 raw known vectors, ECB NoPadding NIST vector, byte views and mobile buffer contract\n");
}
// Read native resource counts under the runtime's own lock. No test API, source
// text, media URLs or credential state is exposed by the production interface.
static NSDictionary *Resources(LXSourceRuntime *runtime) {
    // KVC finds isInvalidated, which takes this lock itself. Read it first.
    NSNumber *invalidated=[runtime valueForKey:@"invalidated"];
    NSLock *lock=[runtime valueForKey:@"lock"];[lock lock];
    NSDictionary *result=@{@"http":@([[runtime valueForKey:@"HTTPTasks"] count]),@"timers":@([[runtime valueForKey:@"timers"] count]),@"pending":@([[runtime valueForKey:@"pending"] count]),@"workers":@([[runtime valueForKey:@"isolatedResolutions"] count]),@"invalidated":invalidated};
    [lock unlock];return result;
}
static LXSourceRuntime *Worker(LXSourceRuntime *runtime,NSString *identifier) {
    NSLock *lock=[runtime valueForKey:@"lock"];[lock lock];
    LXSourceRuntime *worker=[[[runtime valueForKey:@"isolatedResolutions"] objectForKey:identifier] valueForKey:@"worker"];
    [lock unlock];return worker;
}
static void Pump(NSTimeInterval seconds) {
    NSDate *until=[NSDate dateWithTimeIntervalSinceNow:seconds];
    while(until.timeIntervalSinceNow>0)[[NSRunLoop mainRunLoop]runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
}
static atomic_uint holdStarted,holdClosed,lateRequests,pingRequests,cancelledCallbacks;
static int StartIsolationServer(uint16_t *port) {
    int server=socket(AF_INET,SOCK_STREAM,0);Require(server>=0,@"Create isolation fixture socket");
    struct sockaddr_in address={0};address.sin_len=sizeof(address);address.sin_family=AF_INET;address.sin_addr.s_addr=htonl(INADDR_LOOPBACK);
    Require(bind(server,(struct sockaddr *)&address,sizeof(address))==0&&listen(server,32)==0,@"Listen isolation fixture");
    socklen_t length=sizeof(address);getsockname(server,(struct sockaddr *)&address,&length);*port=ntohs(address.sin_port);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{
        for(;;){int client=accept(server,NULL,NULL);if(client<0)return;
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{@autoreleasepool{
                int noPipe=1;setsockopt(client,SOL_SOCKET,SO_NOSIGPIPE,&noPipe,sizeof(noPipe));
                struct timeval timeout={3,0};setsockopt(client,SOL_SOCKET,SO_RCVTIMEO,&timeout,sizeof(timeout));
                NSMutableData *data=NSMutableData.data;char bytes[2048];NSString *text=@"";
                while(data.length<16384){ssize_t count=recv(client,bytes,sizeof(bytes),0);if(count<=0)break;[data appendBytes:bytes length:(NSUInteger)count];text=[[NSString alloc]initWithData:data encoding:NSUTF8StringEncoding]?:@"";if([text containsString:@"\r\n\r\n"])break;}
                if([text hasPrefix:@"GET /hold "]){
                    atomic_fetch_add(&holdStarted,1);
                    // No response: only cancellation closes this real socket.
                    ssize_t count=recv(client,bytes,sizeof(bytes),0);
                    if(count==0||(count<0&&errno==ECONNRESET))atomic_fetch_add(&holdClosed,1);
                }else{
                    if([text hasPrefix:@"GET /late "])atomic_fetch_add(&lateRequests,1);
                    if([text hasPrefix:@"GET /ping "])atomic_fetch_add(&pingRequests,1);
                    if([text hasPrefix:@"GET /callback "])atomic_fetch_add(&cancelledCallbacks,1);
                    const char reply[]="HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}";
                    send(client,reply,sizeof(reply)-1,0);
                }
                close(client);
            }});
        }
    });return server;
}
static void RequireDrained(LXSourceRuntime *worker) {
    NSDictionary *counts=Resources(worker);
    Require([counts[@"invalidated"] boolValue]&&[counts[@"http"] unsignedIntegerValue]==0&&[counts[@"timers"] unsignedIntegerValue]==0&&[counts[@"pending"] unsignedIntegerValue]==0,@"Completed isolated worker has zero HTTP tasks, timers and pending resolutions");
}
static void IsolatedResolutions(NSString *bootstrap) {
    uint16_t port=0;int server=StartIsolationServer(&port);
    NSString *script=[NSString stringWithFormat:
        @"const base='http://127.0.0.1:%hu';const touch=path=>lx.request(base+path,{timeout:5000},()=>{});"
        "lx.on('request',p=>new Promise(resolve=>{"
        "lx.request(base+'/hold',{timeout:5000},()=>touch('/callback'));"
        "setInterval(()=>touch('/ping'),30);setTimeout(()=>touch('/late'),2500);"
        "setTimeout(()=>resolve('https://fixture.invalid/'+p.info.musicInfo.songmid+'.mp3'),p.info.musicInfo.wait);"
        "}));lx.send('inited',{sources:{wy:{type:'music',actions:['musicUrl'],qualitys:['128k']}}});",port];
    LXSourceRuntime *parent=[[LXSourceRuntime alloc]initWithBootstrapScript:bootstrap];Load(parent,script,YES);
    __block NSUInteger callbacks=0;
    unsigned initialStarted=atomic_load(&holdStarted),initialClosed=atomic_load(&holdClosed);
    NSString *cancelled=[parent resolveIsolatedMusicURLForSource:@"wy" musicInfo:@{@"songmid":@"cancel",@"wait":@2000} quality:@"128k" timeout:3 completion:^(NSURL *URL,NSError *error){Require(NSThread.isMainThread&&!URL&&error.code==NSUserCancelledError,@"Isolated cancellation is exactly one native main callback");callbacks++;}];
    LXSourceRuntime *cancelledWorker=Worker(parent,cancelled);Require(cancelledWorker!=nil,@"A separate worker exists before resolution starts");
    Wait(^BOOL{return atomic_load(&holdStarted)>initialStarted&&[Resources(cancelledWorker)[@"timers"] unsignedIntegerValue]>=2&&atomic_load(&pingRequests)>0;},2);
    [parent cancelRequestWithIdentifier:cancelled];[parent cancelRequestWithIdentifier:cancelled];Wait(^BOOL{return callbacks==1;},2);
    RequireDrained(cancelledWorker);Wait(^BOOL{return atomic_load(&holdClosed)>initialClosed;},2);
    Pump(0.15);unsigned quietPings=atomic_load(&pingRequests);Pump(2.6);
    Require(atomic_load(&pingRequests)==quietPings&&atomic_load(&lateRequests)==0&&atomic_load(&cancelledCallbacks)==0&&callbacks==1,@"Cancelling an attempt stops actual timer traffic, held HTTP and late callbacks");
    Require(parent.manifest!=nil&&[Resources(parent)[@"workers"] unsignedIntegerValue]==0,@"Cancelling one worker leaves its selected parent available");

    callbacks=0;__block NSUInteger successes=0,cancellations=0;
    initialStarted=atomic_load(&holdStarted);initialClosed=atomic_load(&holdClosed);
    LXSourceURLCompletion outcome=^(NSURL *URL,NSError *error){Require(NSThread.isMainThread,@"Concurrent isolated callback thread");if(URL&&!error)successes++;else if(error.code==NSUserCancelledError)cancellations++;else Require(NO,@"Unexpected concurrent worker result");callbacks++;};
    NSString *first=[parent resolveIsolatedMusicURLForSource:@"wy" musicInfo:@{@"songmid":@"first",@"wait":@2000} quality:@"128k" timeout:3 completion:outcome];
    NSString *second=[parent resolveIsolatedMusicURLForSource:@"wy" musicInfo:@{@"songmid":@"second",@"wait":@1500} quality:@"128k" timeout:3 completion:outcome];
    LXSourceRuntime *workerA=Worker(parent,first),*workerB=Worker(parent,second);
    Require(workerA&&workerB&&workerA!=workerB,@"Simultaneous playback/download resolutions have distinct runtimes");
    Wait(^BOOL{return atomic_load(&holdStarted)>=initialStarted+2;},2);[parent cancelRequestWithIdentifier:first];
    Wait(^BOOL{return callbacks==2;},3);Require(successes==1&&cancellations==1&&parent.manifest!=nil,@"Cancelling one attempt does not cancel the other worker or parent");
    RequireDrained(workerA);RequireDrained(workerB);Wait(^BOOL{return atomic_load(&holdClosed)>=initialClosed+2;},2);

    callbacks=0;initialStarted=atomic_load(&holdStarted);initialClosed=atomic_load(&holdClosed);
    first=[parent resolveIsolatedMusicURLForSource:@"wy" musicInfo:@{@"songmid":@"parent-a",@"wait":@2000} quality:@"128k" timeout:3 completion:^(NSURL *URL,NSError *error){Require(!URL&&error.code==NSUserCancelledError,@"Parent invalidation cancels worker A");callbacks++;}];
    second=[parent resolveIsolatedMusicURLForSource:@"wy" musicInfo:@{@"songmid":@"parent-b",@"wait":@2000} quality:@"128k" timeout:3 completion:^(NSURL *URL,NSError *error){Require(!URL&&error.code==NSUserCancelledError,@"Parent invalidation cancels worker B");callbacks++;}];
    workerA=Worker(parent,first);workerB=Worker(parent,second);Wait(^BOOL{return atomic_load(&holdStarted)>=initialStarted+2;},2);
    [parent invalidate];Wait(^BOOL{return callbacks==2;},2);RequireDrained(workerA);RequireDrained(workerB);
    Wait(^BOOL{return atomic_load(&holdClosed)>=initialClosed+2;},2);Pump(1.0);
    Require(callbacks==2&&atomic_load(&lateRequests)==0&&atomic_load(&cancelledCallbacks)==0,@"Parent invalidation drains every worker and suppresses late native effects");
    shutdown(server,SHUT_RDWR);close(server);

    NSString *delayed=@"lx.on('request',()=>new Promise(r=>setTimeout(()=>r('https://fixture.invalid/delayed.mp3'),180)));setTimeout(()=>lx.send('inited',{sources:{wy:{type:'music',actions:['musicUrl'],qualitys:['128k']}}}),180);";
    parent=[[LXSourceRuntime alloc]initWithBootstrapScript:bootstrap];Load(parent,delayed,YES);
    __block BOOL finished=NO;NSTimeInterval began=NSProcessInfo.processInfo.systemUptime;
    NSString *timed=[parent resolveIsolatedMusicURLForSource:@"wy" musicInfo:@{@"songmid":@"deadline"} quality:@"128k" timeout:0.28 completion:^(NSURL *URL,NSError *error){Require(!URL&&error.code==7,@"Initialization plus resolution shares one absolute deadline");finished=YES;}];
    LXSourceRuntime *timedWorker=Worker(parent,timed);Wait(^BOOL{return finished;},2);
    Require(NSProcessInfo.processInfo.systemUptime-began<1.2&&parent.manifest!=nil,@"Worker deadline does not add another timeout after initialization or disable parent");RequireDrained(timedWorker);[parent invalidate];

    NSMutableString *large=[NSMutableString stringWithString:@"/*"];[large appendString:[@"x" stringByPaddingToLength:1024*1024 withString:@"x" startingAtIndex:0]];
    [large appendString:@"*/lx.on('request',()=>{if(lx.currentScriptInfo.name!=='fixture'||lx.currentScriptInfo.rawScript.length<1048576)throw Error('snapshot');return Promise.resolve('https://fixture.invalid/large.mp3')});lx.send('inited',{sources:{wy:{type:'music',actions:['musicUrl'],qualitys:['128k']}}});"];
    parent=[[LXSourceRuntime alloc]initWithBootstrapScript:bootstrap];Load(parent,large,YES);[large appendString:@"throw Error('caller mutated source')"];
    finished=NO;[parent resolveIsolatedMusicURLForSource:@"wy" musicInfo:@{@"songmid":@"large"} quality:@"128k" timeout:5 completion:^(NSURL *URL,NSError *error){Require(URL&&!error,@"An authored one-MiB source uses immutable source/name snapshots");finished=YES;}];Wait(^BOOL{return finished;},6);[parent invalidate];

    parent=[[LXSourceRuntime alloc]initWithBootstrapScript:bootstrap];Load(parent,@"lx.on('request',()=>new Promise(()=>{}));lx.send('inited',{sources:{wy:{type:'music',actions:['musicUrl'],qualitys:['128k']}}});",YES);
    callbacks=0;__block NSUInteger refused=0;
    outcome=^(NSURL *URL,NSError *error){Require(!URL&&error,@"Pending capacity test never invents a URL");if(error.code==6)refused++;callbacks++;};
    [parent resolveMusicURLForSource:@"wy" musicInfo:@{} quality:@"128k" timeout:5 completion:outcome];
    for(NSUInteger index=0;index<16;index++)[parent resolveIsolatedMusicURLForSource:@"wy" musicInfo:@{} quality:@"128k" timeout:5 completion:outcome];
    Require([Resources(parent)[@"workers"] unsignedIntegerValue]==15&&[Resources(parent)[@"pending"] unsignedIntegerValue]==1,@"Legacy and isolated calls share the existing 16-request cap");
    [parent invalidate];Wait(^BOOL{return callbacks==17;},3);Require(refused==1,@"Excess isolated request is rejected once while admitted workers all cancel once");
    printf("PASS: isolated JSCore workers drain real loopback sockets/timers, independent cancellation, parent invalidation, total initialization deadline, one-MiB snapshot and combined pending limit\n");
}
int main(int argc,const char *argv[]) {
    @autoreleasepool {
        Require(argc==2,@"Usage: LXRuntimeTests /absolute/path/LXBootstrap.js");
        NSString *bootstrap=[NSString stringWithContentsOfFile:@(argv[1]) encoding:NSUTF8StringEncoding error:nil]; Require(bootstrap.length>0,@"Read bootstrap");
        uint16_t port=0; int server=StartFixtureServer(&port);
        NSString *setup=@"function check(v,m){if(!v)throw Error(m)};"
        "check(typeof require==='undefined'&&typeof fetch==='undefined','unexpected host API');"
        "check(lx.utils.crypto.md5('abc')==='900150983cd24fb0d6963f7d28e17f72','native MD5');"
        "check(lx.utils.buffer.bufToString(lx.utils.buffer.from('中文😀'),'hex')==='e4b8ade69687f09f9880','native UTF-8');"
        "check(lx.utils.buffer.bufToString(lx.utils.buffer.from('5Lit5paH','base64'))==='中文','native base64');"
        "check(lx.utils.buffer.bufToString(lx.utils.crypto.aesEncrypt('0123456789abcdef','aes-128-ecb','0123456789abcdef',''),'hex')==='72727e881edcfd0100a718687909b565','native AES ECB NoPadding');"
        "{let rejected=false;try{lx.utils.crypto.aesEncrypt('hello','aes-128-ecb','0123456789abcdef','')}catch(e){rejected=true}check(rejected,'ECB rejects unaligned data')}"
        "check(lx.utils.buffer.bufToString(lx.utils.crypto.aesEncrypt('hello','aes-128-cbc','0123456789abcdef','abcdef0123456789'),'hex')==='ffcb80bec2437fc2e30b0ef0a8ec5b64','native AES CBC');"
        "check(lx.utils.crypto.randomBytes(16).length===16,'native randomBytes');";
        NSString *script=[setup stringByAppendingFormat:
        @"const endpoint='http://127.0.0.1:%hu/fixture';"
        "function http(body){return new Promise((resolve,reject)=>lx.request(endpoint,{method:'POST',body},(e,r,b)=>e?reject(e):resolve(b)))};"
        "lx.on('request',async({source,action,info})=>{"
        "check(source==='wy'&&action==='musicUrl'&&info.type==='128k','event shape');"
        "switch(info.musicInfo.songmid){"
        "case 'normal':return 'https://fixture.invalid/track.mp3';"
        "case 'text-body':{const data=await http('literal=abc&x=%%20');check(data.echo==='literal=abc&x=%%20','string body altered');return 'https://fixture.invalid/text.mp3'}"
        "case 'json-body':{const data=await http({hello:'world'});check(JSON.parse(data.echo).hello==='world','JSON body');return 'https://fixture.invalid/json.mp3'}"
        "case 'cookies':{await http('first');const data=await http('second');check(data.cookie===false,'cookies persisted');check(data.internalHeader===false,'internal property leaked as header');return 'https://fixture.invalid/cookie.mp3'}"
        "case 'head':{const r=await new Promise((resolve,reject)=>lx.request(endpoint,{method:'HEAD'},(e,r)=>e?reject(e):resolve(r)));check(Number(r.headers['content-length'])===10485760,'HEAD content length');check(r.body==='','HEAD must have no body');return 'https://fixture.invalid/head.mp3'}"
        "case 'binary-response':{const r=await new Promise((resolve,reject)=>lx.request(endpoint.replace('/fixture','/binary'),{binary:true},(e,r)=>e?reject(e):resolve(r)));check(r.body.type==='Buffer','mobile binary Buffer JSON contract');check(lx.utils.buffer.bufToString(lx.utils.buffer.from(r.body),'hex')==='00ff804100','native binary bytes');check(r.statusMessage==='OK','status message');return 'https://fixture.invalid/binary.mp3'}"
        "case 'binary-body':{const d=await http(new Uint8Array([0,255,128,65,0]));check(d.bodyBase64==='AP+AQQA=','binary request altered');check(d.requestHeaders.toLowerCase().includes('content-type: application/octet-stream'),'binary content type');return 'https://fixture.invalid/binary-body.mp3'}"
        "case 'multipart':{const d=await new Promise((resolve,reject)=>lx.request(endpoint,{method:'POST',formData:{text:'中文',file:{value:new Uint8Array([0,255,128]),options:{filename:'fixture.bin',contentType:'application/octet-stream'}}}},(e,r,b)=>e?reject(e):resolve(b)));const raw=lx.utils.buffer.bufToString(lx.utils.buffer.from(d.bodyBase64,'base64'),'hex');check(raw.includes('e4b8ade69687')&&raw.includes('00ff80'),'multipart preserves text/binary');check(raw.includes(lx.utils.buffer.bufToString(lx.utils.buffer.from('filename=\"fixture.bin\"'),'hex')),'multipart filename');check(d.requestHeaders.toLowerCase().includes('multipart/form-data; boundary=lx-'),'multipart boundary header');return 'https://fixture.invalid/multipart.mp3'}"
        "case 'form':{const d=await new Promise((resolve,reject)=>lx.request(endpoint,{method:'POST',form:{hello:'中 文',plus:'a+b'}},(e,r,b)=>e?reject(e):resolve(b)));check(d.echo.includes('hello=%%E4%%B8%%AD%%20%%E6%%96%%87')&&d.echo.includes('plus=a%%2Bb'),'form percent encoding');return 'https://fixture.invalid/form.mp3'}"
        "case 'nonbinary-reject':await new Promise((resolve,reject)=>lx.request(endpoint.replace('/fixture','/binary'),{},(e,r)=>e?reject(e):resolve(r)));return 'https://fixture.invalid/unexpected';"
        "case 'network-cancel':{let called=false;const cancel=lx.request(endpoint.replace('/fixture','/slow'),{binary:true},()=>{called=true});setTimeout(()=>{cancel();cancel()},20);await new Promise(r=>setTimeout(r,300));check(!called,'cancelled HTTP callback delivered');return 'https://fixture.invalid/cancel.mp3'}"
        "case 'oversized-response':await new Promise((resolve,reject)=>lx.request(endpoint.replace('/fixture','/oversized'),{binary:true},(e,r)=>e?reject(e):resolve(r)));return 'https://fixture.invalid/unexpected';"
        "case 'timer':await new Promise(r=>setTimeout(r,20));return 'https://fixture.invalid/timer.mp3';"
        "case 'invalid':return 'file:///unexpected';"
        "case 'reject':throw Error('fixture rejection');"
        "case 'pending':return new Promise(()=>{});"
        "default:throw Error('unknown fixture');}});"
        "check(typeof lx.send('inited',{sources:{wy:{type:'music',actions:['musicUrl'],qualitys:['128k']},qs:{type:'music',actions:['musicUrl'],qualitys:['128k']}}}).then==='function','send Promise');",port];
        LXSourceRuntime *runtime=[[LXSourceRuntime alloc] initWithBootstrapScript:bootstrap];
        Load(runtime,script,YES);
        Require(runtime.manifest[@"sources"][@"qs"]==nil && runtime.manifest[@"sources"][@"wy"]!=nil,@"Unknown platform filtering");
        for(NSString *song in @[@"normal",@"text-body",@"json-body",@"cookies",@"head",@"timer",@"binary-response",@"binary-body",@"multipart",@"form",@"network-cancel"]) Resolve(runtime,song,YES,nil);
        Resolve(runtime,@"nonbinary-reject",NO,@"binary:true");
        Resolve(runtime,@"oversized-response",NO,@"4 MiB");
        Resolve(runtime,@"invalid",NO,@"invalid music URL"); Resolve(runtime,@"reject",NO,@"fixture rejection");
        __block BOOL cancelled=NO;
        NSString *identifier=[runtime resolveMusicURLForSource:@"wy" musicInfo:@{@"songmid":@"pending"} quality:@"128k" timeout:2 completion:^(NSURL *URL,NSError *error){Require(error!=nil&&NSThread.isMainThread,@"Cancellation completion");cancelled=YES;}];
        [runtime cancelRequestWithIdentifier:identifier]; Wait(^BOOL{return cancelled;},3);
        Resolve(runtime,@"pending",NO,@"timed out"); Require(runtime.manifest==nil,@"Timed-out runtime is discarded");
        [runtime invalidate];
        LXSourceRuntime *invalid=[[LXSourceRuntime alloc] initWithBootstrapScript:bootstrap];
        Load(invalid,@"lx.on('request',()=>Promise.resolve('https://fixture.invalid'));lx.send('inited',{sources:{wy:{type:'music',actions:['musicUrl'],qualitys:['128k']}}});throw Error('after init');",NO);
        LXSourceRuntime *delayed=[[LXSourceRuntime alloc] initWithBootstrapScript:bootstrap];
        Load(delayed,@"lx.on('request',()=>Promise.resolve('https://fixture.invalid'));setTimeout(()=>lx.send('inited',{sources:{wy:{type:'music',actions:['musicUrl'],qualitys:['128k']}}}),20);",YES);
        [delayed invalidate];
        LXSourceRuntime *missing=[[LXSourceRuntime alloc] initWithBootstrapScript:bootstrap]; Load(missing,@"const fixture=1;",NO);
        AuthenticatedQQ([[LXSourceRuntime alloc] initWithBootstrapScript:bootstrap],port);
        CompatibilityCrypto(bootstrap);
        IsolatedResolutions(bootstrap);
        shutdown(server,SHUT_RDWR); close(server);
        printf("PASS: native JavaScriptCore, crypto, HTTP loopback, binary and multipart wire bytes, cookie isolation, callbacks, cancellation, timeout fixtures\n");
    }
    return 0;
}
