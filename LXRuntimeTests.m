// Standalone macOS executable. Uses self-authored fixtures only.
#import <Foundation/Foundation.h>
#import "LXSourceRuntime.h"
#import <sys/socket.h>
#import <netinet/in.h>
#import <unistd.h>

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
                    requestText=[[NSString alloc] initWithData:request encoding:NSUTF8StringEncoding] ?: @"";
                    NSRange boundary=[requestText rangeOfString:@"\r\n\r\n"];
                    if (boundary.location != NSNotFound) {
                        headerEnd=NSMaxRange(boundary);
                        for (NSString *line in [[requestText substringToIndex:boundary.location] componentsSeparatedByString:@"\r\n"]) {
                            if ([line.lowercaseString hasPrefix:@"content-length:"]) contentLength=[[[line componentsSeparatedByString:@":"] lastObject] integerValue];
                        }
                        if (request.length >= headerEnd+contentLength) break;
                    }
                }
                NSString *body=headerEnd != NSNotFound ? [requestText substringFromIndex:headerEnd] : @"";
                BOOL cookie=[requestText.lowercaseString containsString:@"\r\ncookie:"];
                BOOL internalHeader=[requestText.lowercaseString containsString:@"\r\nfmx.internalrequest:"];
                NSDictionary *response=@{@"echo":body,@"cookie":@(cookie),@"internalHeader":@(internalHeader)};
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
                BOOL head = [requestText hasPrefix:@"HEAD "];
                NSString *header=[NSString stringWithFormat:@"HTTP/1.1 200 OK\r\nContent-Type: %@\r\nSet-Cookie: fixture=must-not-persist\r\nContent-Length: %lu\r\nConnection: close\r\n\r\n",head ? @"audio/mpeg" : @"application/json",(unsigned long)(head ? 10*1024*1024 : json.length)];
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
        "check(lx.utils.buffer.bufToString(lx.utils.crypto.aesEncrypt('hello','aes-128-ecb','0123456789abcdef',''),'hex')==='674c7ef38e78cabd9cec9c125823a639','native AES ECB');"
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
        "case 'timer':await new Promise(r=>setTimeout(r,20));return 'https://fixture.invalid/timer.mp3';"
        "case 'invalid':return 'file:///unexpected';"
        "case 'reject':throw Error('fixture rejection');"
        "case 'pending':return new Promise(()=>{});"
        "default:throw Error('unknown fixture');}});"
        "check(typeof lx.send('inited',{sources:{wy:{type:'music',actions:['musicUrl'],qualitys:['128k']},qs:{type:'music',actions:['musicUrl'],qualitys:['128k']}}}).then==='function','send Promise');",port];
        LXSourceRuntime *runtime=[[LXSourceRuntime alloc] initWithBootstrapScript:bootstrap];
        Load(runtime,script,YES);
        Require(runtime.manifest[@"sources"][@"qs"]==nil && runtime.manifest[@"sources"][@"wy"]!=nil,@"Unknown platform filtering");
        for(NSString *song in @[@"normal",@"text-body",@"json-body",@"cookies",@"head",@"timer"]) Resolve(runtime,song,YES,nil);
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
        shutdown(server,SHUT_RDWR); close(server);
        printf("PASS: native JavaScriptCore, crypto, HTTP loopback, cookie isolation, callbacks, cancellation, timeout fixtures\n");
    }
    return 0;
}
