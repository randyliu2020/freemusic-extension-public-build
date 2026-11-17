// Self-authored loopback HTTP fixtures. No original app, private scripts, songs,
// credentials or external network endpoints are involved.
#import "FMJSDownloadCoordinator.h"
#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <unistd.h>
#import <math.h>

static NSUInteger failures;
static NSMutableArray *rows;
static void Check(BOOL condition,NSString *name) {
    [rows addObject:@{@"name":name,@"passed":@(condition)}];
    if(!condition){++failures;fprintf(stderr,"FAIL %s\n",name.UTF8String);}else printf("PASS %s\n",name.UTF8String);
}
static BOOL Wait(BOOL (^predicate)(void),NSTimeInterval timeout) {
    NSTimeInterval deadline=NSProcessInfo.processInfo.systemUptime+timeout;
    while(!predicate() && NSProcessInfo.processInfo.systemUptime<deadline)
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.002]];
    return predicate();
}
static void Pump(NSTimeInterval timeout) { NSTimeInterval end=NSProcessInfo.processInfo.systemUptime+timeout;Wait(^BOOL{return NSProcessInfo.processInfo.systemUptime>=end;},timeout+0.1); }
static void U16(NSMutableData *data,uint16_t value){uint8_t bytes[]={value&255,value>>8};[data appendBytes:bytes length:2];}
static void U32(NSMutableData *data,uint32_t value){uint8_t bytes[]={value&255,(value>>8)&255,(value>>16)&255,value>>24};[data appendBytes:bytes length:4];}
static NSData *Wave(void) {
    uint32_t rate=22050,count=rate*2;NSMutableData *data=NSMutableData.data;
    [data appendBytes:"RIFF" length:4];U32(data,36+count*2);[data appendBytes:"WAVEfmt " length:8];
    U32(data,16);U16(data,1);U16(data,1);U32(data,rate);U32(data,rate*2);U16(data,2);U16(data,16);
    [data appendBytes:"data" length:4];U32(data,count*2);
    for(uint32_t n=0;n<count;n++)U16(data,(uint16_t)(int16_t)(600*sin(2*M_PI*330*n/rate)));
    return data;
}
@interface FMDownloadHTTPFixture : NSObject
@property(nonatomic,readonly) NSData *audio;
@property(nonatomic,readonly) NSUInteger requests;
- (NSURL *)URL:(NSString *)name;
- (void)setBody:(NSData *)body MIME:(NSString *)mime forName:(NSString *)name;
- (void)stop;
@end
@implementation FMDownloadHTTPFixture {
    NSLock *_lock;
    int _fd;
    uint16_t _port;
    NSUInteger _requests;
    BOOL _stopped;
    NSMutableDictionary *_bodies,*_MIMEs;
}
- (instancetype)init {
    if((self=[super init])){
        _audio=Wave();_lock=NSLock.new;_bodies=NSMutableDictionary.dictionary;_MIMEs=NSMutableDictionary.dictionary;_fd=socket(AF_INET,SOCK_STREAM,0);
        NSAssert(_fd>=0,@"Loopback socket creation");
        struct sockaddr_in addr={0};addr.sin_len=sizeof(addr);addr.sin_family=AF_INET;addr.sin_addr.s_addr=inet_addr("127.0.0.1");
        NSAssert(bind(_fd,(struct sockaddr *)&addr,sizeof(addr))==0 && listen(_fd,32)==0,@"Loopback bind/listen");
        socklen_t length=sizeof(addr);NSAssert(getsockname(_fd,(struct sockaddr *)&addr,&length)==0,@"Loopback port");_port=ntohs(addr.sin_port);
        int listener=_fd;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{
            while(YES){
                int client=accept(listener,NULL,NULL);if(client<0)return;
                dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{[self serve:client];close(client);});
            }
        });
    }return self;
}
- (NSUInteger)requests { [_lock lock];NSUInteger value=_requests;[_lock unlock];return value; }
- (NSURL *)URL:(NSString *)name { return [NSURL URLWithString:[NSString stringWithFormat:@"http://127.0.0.1:%u/%@",_port,name]]; }
- (void)setBody:(NSData *)body MIME:(NSString *)mime forName:(NSString *)name {
    NSString *path=[@"/" stringByAppendingString:name];[_lock lock];_bodies[path]=body;_MIMEs[path]=mime;[_lock unlock];
}
- (void)stop { [_lock lock];BOOL stopped=_stopped;_stopped=YES;int fd=_fd;_fd=-1;[_lock unlock];if(!stopped&&fd>=0){shutdown(fd,SHUT_RDWR);close(fd);} }
- (BOOL)send:(NSData *)data client:(int)client {
    const uint8_t *p=data.bytes;NSUInteger done=0;
    while(done<data.length){ssize_t count=send(client,p+done,data.length-done,0);if(count<=0)return NO;done+=(NSUInteger)count;}return YES;
}
- (void)serve:(int)client {
    int yes=1;setsockopt(client,SOL_SOCKET,SO_NOSIGPIPE,&yes,sizeof(yes));
    struct timeval timeout={3,0};setsockopt(client,SOL_SOCKET,SO_RCVTIMEO,&timeout,sizeof(timeout));
    NSMutableData *request=NSMutableData.data;uint8_t buffer[2048];NSData *end=[@"\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding];
    while(request.length<16384 && [request rangeOfData:end options:0 range:NSMakeRange(0,request.length)].location==NSNotFound){
        ssize_t n=recv(client,buffer,sizeof(buffer),0);if(n<=0)return;[request appendBytes:buffer length:(NSUInteger)n];
    }
    NSString *raw=[[NSString alloc] initWithData:request encoding:NSUTF8StringEncoding];NSArray *parts=[raw componentsSeparatedByString:@" "];
    if(parts.count<2)return;NSString *path=parts[1];
    [_lock lock];++_requests;NSData *customBody=_bodies[path];NSString *customMIME=_MIMEs[path];[_lock unlock];
    BOOL interrupted=[path hasPrefix:@"/interrupt"],shortFile=[path hasPrefix:@"/short"],slow=[path hasPrefix:@"/slow"];
    BOOL html=[path hasPrefix:@"/html"],bad=[path hasPrefix:@"/bad"],missing=[path hasPrefix:@"/missing"];
    NSData *body=customBody ?: ((html||bad||missing)?[@"<html>authored server error, not an audio file</html>" dataUsingEncoding:NSUTF8StringEncoding]:_audio);
    NSUInteger declared=body.length;
    if(interrupted || shortFile)body=[body subdataWithRange:NSMakeRange(0,body.length/2)];
    if(!interrupted)declared=body.length;
    NSString *header=[NSString stringWithFormat:@"HTTP/1.1 %@\r\nContent-Type: %@\r\nContent-Length: %lu\r\nCache-Control: public, max-age=3600\r\nConnection: close\r\n\r\n",missing?@"404 Not Found":@"200 OK",customMIME ?: (html?@"text/html":@"audio/wav"),(unsigned long)declared];
    if(![self send:[header dataUsingEncoding:NSUTF8StringEncoding] client:client])return;
    if(slow){
        for(NSUInteger offset=0;offset<body.length;offset+=4096){
            if(![self send:[body subdataWithRange:NSMakeRange(offset,MIN((NSUInteger)4096,body.length-offset))] client:client])return;
            usleep(30000);
        }
    }else [self send:body client:client];
}
@end

static FMQualityResolver *Resolver(FMDownloadHTTPFixture *server,NSArray<NSString *> *qualities,NSDictionary *routes,NSMutableArray *attempts,BOOL (^current)(void)) {
    return [[FMQualityResolver alloc] initWithPlatform:@"tx" supportedQualities:qualities timeout:20 isCurrent:current resolve:^dispatch_block_t(NSString *q,NSTimeInterval timeout,FMQualityAttemptCompletion completion){
        [attempts addObject:q];NSString *path=routes[q];
        completion(path?[server URL:path]:nil,path?nil:[NSError errorWithDomain:@"AuthoredResolver" code:404 userInfo:nil]);return nil;
    }];
}
static FMJSDownloadCoordinator *Download(FMQualityResolver *resolver,NSURL *root,BOOL (^current)(void)) {
    NSURLSessionConfiguration *configuration=NSURLSessionConfiguration.ephemeralSessionConfiguration;
    configuration.timeoutIntervalForRequest=2;configuration.timeoutIntervalForResource=8;
    return [[FMJSDownloadCoordinator alloc] initWithResolver:resolver configuration:configuration temporaryDirectory:root isCurrent:current];
}
static BOOL Empty(NSURL *directory){return [NSFileManager.defaultManager contentsOfDirectoryAtURL:directory includingPropertiesForKeys:nil options:0 error:nil].count==0;}
