#import "FMQishuiSearch.h"
#import <mach-o/loader.h>

static NSUInteger failures;
static void Check(BOOL condition,NSString *name) { if(!condition) { failures++; fprintf(stderr,"FAIL: %s\n",name.UTF8String); } }
static NSDictionary *Config(void) {
    NSMutableDictionary *query=NSMutableDictionary.dictionary;
    for(NSString *key in FMXQishuiConfigurationKeys())query[key]=@"fixture";
    return @{@"query":query,@"trigger_type":@"fixture"};
}
static void WriteString(NSMutableData *data,NSUInteger offset,NSString *value) {
    NSData *bytes=[value dataUsingEncoding:NSUTF8StringEncoding]; uint64_t pair[2]={0,0};
    if(bytes.length<=15) { memcpy(pair,bytes.bytes,bytes.length); pair[1]|=(0xe0ULL+bytes.length)<<56; }
    else { NSUInteger position=0x540000+offset%0x1000; memcpy((uint8_t *)data.mutableBytes+position,bytes.bytes,bytes.length); pair[0]=0xd000000000000000ULL|bytes.length; pair[1]=0x4008000000000000ULL|(position-32); }
    memcpy((uint8_t *)data.mutableBytes+offset,pair,sizeof(pair));
}
static NSMutableData *Executable(void) {
    NSMutableData *data=[NSMutableData dataWithLength:0x5591b0];
    struct mach_header_64 header={.magic=MH_MAGIC_64,.cputype=CPU_TYPE_ARM64,.filetype=MH_EXECUTE,.ncmds=1,.sizeofcmds=sizeof(struct uuid_command)};
    struct uuid_command uuid={.cmd=LC_UUID,.cmdsize=sizeof(struct uuid_command),.uuid={0x21,0x2e,0x31,0x08,0x9a,0x0c,0x33,0x09,0xbe,0xdc,0x7e,0x99,0x6e,0x81,0x99,0xd1}};
    memcpy(data.mutableBytes,&header,sizeof(header)); memcpy((uint8_t *)data.mutableBytes+sizeof(header),&uuid,sizeof(uuid));
    NSArray *keys=FMXQishuiConfigurationKeys();
    for(NSUInteger i=0;i<keys.count;i++) { WriteString(data,0x558f70+i*32,keys[i]); WriteString(data,0x558f80+i*32,@"fixture"); }
    WriteString(data,0x558f18,@"trigger_type"); WriteString(data,0x558f28,@"fixture"); return data;
}
static NSDictionary *Track(NSUInteger identifier) {
    return @{@"entity":@{@"track":@{@"base_info":@{@"id":@(identifier).stringValue,@"name":@"Fixture title",@"duration_ms":@210250},
        @"related_info":@{@"artist_links":@[@{@"name":@"A"},@{@"name":@"B"}],@"album_link":@{@"name":@"Album"}},
        @"display_info":@{@"cover_url":@{@"urls":@[@"file:///invalid",@"https://example.invalid/cover.jpg"]}}}}};
}
static NSDictionary *Payload(NSUInteger cursor,BOOL more) {
    NSMutableArray *tracks=NSMutableArray.array;
    for(NSUInteger i=cursor;i<cursor+20;i++)[tracks addObject:Track(i)];
    return @{@"err_no":@0,@"data":@{@"result_groups":@[@{@"id":@"tracks",@"data":tracks,@"has_more":@(more),@"next_cursor":@(cursor+20)}]}};
}
static NSMutableArray *recorded;
static NSString *mode;
static dispatch_semaphore_t searchStarted;
static dispatch_semaphore_t overlapRelease;
@interface QSFixtureTransport : NSURLProtocol
@property(atomic) BOOL stopped;
@end
@implementation QSFixtureTransport
+ (BOOL)canInitWithRequest:(NSURLRequest *)request { return YES; } // Deny every accidental real-network destination in this isolated session.
+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request { return request; }
- (void)startLoading {
    NSURL *url=self.request.URL;
    // NSURL.path normalizes away a directory's trailing slash; components.path preserves the HTTP path.
    NSString *path=[NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO].path;
    BOOL token=[url.host isEqual:@"open.qishui.com"] && [path isEqual:@"/api/luna/v1/platform/client/token/get/"];
    BOOL search=[url.host isEqual:@"open.douyin.com"] && [path isEqual:@"/api/luna/v1/platform/search/"];
    if(!token && !search) {
        fprintf(stderr,"QS FIXTURE rejected endpoint host=%s path=%s normalizedPath=%s\n",url.host.UTF8String,path.UTF8String,url.path.UTF8String);
        [self.client URLProtocol:self didFailWithError:[NSError errorWithDomain:@"Fixture" code:1 userInfo:nil]]; return;
    }
    NSData *bodyData=self.request.HTTPBody;
    NSDictionary *body=bodyData?[NSJSONSerialization JSONObjectWithData:bodyData options:0 error:nil]:nil;
    if(self.request.HTTPBodyStream) {
        NSInputStream *stream=self.request.HTTPBodyStream; [stream open]; NSMutableData *data=NSMutableData.data;
        uint8_t buffer[4096]; NSInteger size; while((size=[stream read:buffer maxLength:sizeof(buffer)])>0)[data appendBytes:buffer length:size]; [stream close];
        bodyData=data; body=[NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    }
    NSMutableURLRequest *retained=[self.request mutableCopy]; retained.HTTPBodyStream=nil; retained.HTTPBody=bodyData;
    @synchronized(recorded) { [recorded addObject:retained]; }
    if(search && searchStarted)dispatch_semaphore_signal(searchStarted);
    NSDictionary *result=token?@{@"client_token":@"fixture-token"}:Payload([body[@"cursor"] integerValue],[body[@"cursor"] integerValue]<40);
    if([mode isEqual:@"loop"] && search)result=@{@"data":@{@"result_groups":@[@{@"id":@"tracks",@"data":@[Track(1)],@"has_more":@YES,@"next_cursor":body[@"cursor"]?:@"0"}]}};
    if([mode isEqual:@"malformed"] && search)result=@{@"data":@{}};
    if([mode isEqual:@"rejected"] && search)result=@{@"err_no":@401,@"err_msg":@"SENSITIVE-SERVER-DETAIL"};
    NSTimeInterval delay=([mode isEqual:@"slow"] || ([mode isEqual:@"slowSearch"] && search))?0.5:0.001;
    dispatch_semaphore_t releaseGate;
    if([mode isEqual:@"overlap"] && search && [body[@"q"] isEqual:@"overlap"]) {
        NSUInteger cursor=(NSUInteger)[body[@"cursor"] integerValue]; // Native cursor JSON is a nonnegative decimal NSString.
        if(cursor==40) { result=Payload(40,NO); releaseGate=overlapRelease; }
        else if(cursor==0) {
            NSMutableArray *tracks=NSMutableArray.array;
            for(NSUInteger i=0;i<30;i++)[tracks addObject:Track(1000+i)];
            result=@{@"data":@{@"result_groups":@[@{@"id":@"tracks",@"data":tracks,@"has_more":@YES,@"next_cursor":@100}]}};
        } else result=Payload(cursor,NO);
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(delay*NSEC_PER_SEC)),dispatch_get_global_queue(QOS_CLASS_DEFAULT,0),^{
        if(releaseGate)dispatch_semaphore_wait(releaseGate,dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC));
        if(self.stopped)return;
        NSData *data=[NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
        NSHTTPURLResponse *response=[[NSHTTPURLResponse alloc] initWithURL:url statusCode:200 HTTPVersion:@"HTTP/1.1" headerFields:@{@"Content-Type":@"application/json"}];
        [self.client URLProtocol:self didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageNotAllowed];
        [self.client URLProtocol:self didLoadData:data]; [self.client URLProtocolDidFinishLoading:self];
    });
}
- (void)stopLoading { self.stopped=YES; }
@end
static FMQishuiSearchClient *Client(void) {
    NSURLSessionConfiguration *configuration=NSURLSessionConfiguration.ephemeralSessionConfiguration;
    configuration.protocolClasses=@[QSFixtureTransport.class];
    return [[FMQishuiSearchClient alloc] initWithConfiguration:Config() deviceID:@"1234567890123456789" sessionConfiguration:configuration];
}
static NSDictionary *Search(FMQishuiSearchClient *client,NSString *keyword,NSInteger page,NSTimeInterval timeout,NSError **error) {
    dispatch_semaphore_t done=dispatch_semaphore_create(0); __block NSDictionary *result; __block NSError *failure;
    [client search:keyword page:page timeout:timeout completion:^(NSDictionary *payload,NSError *e) { result=payload; failure=e; dispatch_semaphore_signal(done); }];
    Check(dispatch_semaphore_wait(done,dispatch_time(DISPATCH_TIME_NOW,3*NSEC_PER_SEC))==0,@"search completes within test budget");
    if(failure)fprintf(stderr,"QS FIXTURE result mode=%s page=%ld code=%ld message=%s requests=%lu\n",mode.UTF8String,(long)page,(long)failure.code,failure.localizedDescription.UTF8String,(unsigned long)recorded.count);
    if(error)*error=failure; return result;
}
int main(void) { @autoreleasepool {
    recorded=NSMutableArray.array; mode=@"normal";
    NSMutableData *binary=Executable(); Check(FMXQishuiConfigurationFromExecutable(binary)!=nil,@"verified layout extracts synthetic public configuration");
    NSMutableData *bad=[binary mutableCopy]; ((uint8_t *)bad.mutableBytes)[40]^=1;
    Check(!FMXQishuiConfigurationFromExecutable(bad),@"unknown executable UUID rejected");
    bad=[binary mutableCopy]; WriteString(bad,0x558f70,@"wrong"); Check(!FMXQishuiConfigurationFromExecutable(bad),@"changed key layout rejected");
    Check(!FMXQishuiConfigurationFromExecutable([binary subdataWithRange:NSMakeRange(0,64)]),@"truncated binary rejected");
    NSDictionary *decoded=FMXQishuiDecodeSearch(Payload(0,YES),nil); NSDictionary *track=[decoded[@"tracks"] firstObject];
    Check([track[@"server"] isEqual:@"qs"] && [track[@"id"] isEqual:@"0"] && [track[@"platform"] isEqual:@4],@"native source and ID preserved");
    Check([track[@"singer"] isEqual:@"A / B"] && [track[@"duration"] doubleValue]==210.25 && [track[@"album"] isEqual:@"Album"],@"metadata types mapped without source labels");
    Check([track[@"cover"] hasPrefix:@"https://"],@"invalid cover URL excluded");
    NSDictionary *prefixTrack=@{@"entity":@{@"track":@{@"base_info":@{@"id":@"prefix"},@"display_info":@{@"cover_url":@{@"urls":@[@"https://example.invalid/img/"],@"uri":@"fixture/path",@"template_prefix":@"fixture"}}}}};
    NSDictionary *prefixPayload=@{@"data":@{@"result_groups":@[@{@"id":@"tracks",@"data":@[prefixTrack],@"has_more":@NO}]}};
    Check([FMXQishuiDecodeSearch(prefixPayload,nil)[@"tracks"][0][@"cover"] isEqual:@"https://example.invalid/img/fixture/path~fixture-image.image"],@"native cover prefix is completed with URI and template");
    NSError *error; FMQishuiSearchClient *client=Client();
    NSDictionary *first=Search(client,@"fixture",0,2,&error);
    Check(!error && [first[@"data"] count]==40 && [first[@"total"] integerValue]==41,@"first native page preserves both 20-track batches");
    NSDictionary *second=Search(client,@"fixture",1,2,&error);
    Check(!error && [second[@"data"] count]==20 && [second[@"data"][0][@"id"] isEqual:@"40"] && [second[@"total"] integerValue]==60,@"next page uses cursor 40 without lost tracks");
    NSUInteger calls=recorded.count;
    NSDictionary *empty=Search(client,@"fixture",2,2,&error);
    Check(!error && [empty[@"data"] isKindOfClass:NSArray.class] && [empty[@"data"] count]==0 && recorded.count==calls,@"exhausted cursor produces empty page without another network request");
    Check(!Search(client,@"another keyword",1,2,&error) && error.code==409,@"page without matching keyword cursor is rejected");
    NSUInteger tokens=0,searches=0;
    for(NSURLRequest *request in recorded) {
        BOOL token=[request.URL.host isEqual:@"open.qishui.com"]; tokens+=token; searches+=!token;
        NSMutableDictionary *query=NSMutableDictionary.dictionary;
        for(NSURLQueryItem *item in [NSURLComponents componentsWithURL:request.URL resolvingAgainstBaseURL:NO].queryItems)query[item.name]=item.value;
        Check([query[@"did"] isEqual:query[@"iid"]] && [query[@"device_id"] isEqual:query[@"did"]] && [query[@"vehicle_id"] isEqual:@"qishui-1234567890123456789"],@"native device aliases kept consistent");
        Check(query.count==(token?25:24) && (query[@"trigger_type"]!=nil)==token,@"query contains only native whitelist and dynamic fields");
        Check([request.HTTPMethod isEqual:token?@"GET":@"POST"] && [[request valueForHTTPHeaderField:@"User-Agent"] isEqual:@"LunaOpenSDK/1.0.10"],@"native method and user agent");
        Check(![request valueForHTTPHeaderField:@"Authorization"] && ![request valueForHTTPHeaderField:@"Cookie"],@"aacert/user authentication not copied to catalogue");
        Check(token?![request valueForHTTPHeaderField:@"access-token"]:[[request valueForHTTPHeaderField:@"access-token"] isEqual:@"fixture-token"],@"client token sent only to search endpoint");
        if(!token) {
            NSDictionary *body=[NSJSONSerialization JSONObjectWithData:request.HTTPBody options:0 error:nil];
            Check(body.count==11 && [body[@"q"] isEqual:@"fixture"] && [body[@"search_id"] isEqual:body[@"from_search_id"]] && [body[@"search_id"] length]>0,@"native search body has keyword, paired IDs and exact fields");
            Check([body[@"search_method"] isEqual:@"input"] && [body[@"search_type"] isEqual:@"track"] && [body[@"search_scene"] isEqual:@"normal"] && [body[@"scene_name"] isEqual:@"search"],@"native search context values retained");
            Check([body[@"common_params"] isEqual:@{}] && [body[@"last_viewed_media"] isEqual:@{}] && [body[@"ab_param"] isEqual:@""],@"anonymous catalogue body contains no account state");
        }
    }
    Check(tokens==1 && searches==3,@"client token reused in memory across native pages");
    // An in-flight old page must retain its own starting offset while a same-keyword refresh replaces the cache.
    client=Client(); mode=@"normal";
    Check([Search(client,@"overlap",0,2,&error)[@"data"] count]==40 && !error,@"overlap fixture establishes old cursor and offset");
    mode=@"overlap"; searchStarted=dispatch_semaphore_create(0); overlapRelease=dispatch_semaphore_create(0);
    dispatch_semaphore_t oldDone=dispatch_semaphore_create(0); __block NSDictionary *oldPage; __block NSError *oldError;
    [client search:@"overlap" page:1 timeout:2 completion:^(NSDictionary *response,NSError *e) { oldPage=response; oldError=e; dispatch_semaphore_signal(oldDone); }];
    Check(dispatch_semaphore_wait(searchStarted,dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC))==0,@"old page is in flight before same-keyword refresh");
    NSDictionary *refreshed=Search(client,@"overlap",0,2,&error);
    Check(!error && [refreshed[@"data"] count]==30 && [refreshed[@"total"] integerValue]==31,@"refresh replaces cache with a different cursor generation");
    dispatch_semaphore_signal(overlapRelease);
    Check(dispatch_semaphore_wait(oldDone,dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC))==0 && !oldError && [oldPage[@"total"] integerValue]==60,@"old response total retains its original offset during refresh");
    Check(!Search(client,@"overlap",2,2,&error) && error.code==409,@"old page cannot write its continuation into refreshed cache");
    NSDictionary *newPage=Search(client,@"overlap",1,2,&error);
    Check(!error && [newPage[@"data"][0][@"id"] isEqual:@"100"] && [newPage[@"total"] integerValue]==50,@"refreshed page uses its own cursor and offset after old completion");
    searchStarted=nil; overlapRelease=nil;
    mode=@"loop"; Check(!Search(Client(),@"loop",0,2,&error) && [error.localizedDescription containsString:@"分页"],@"nonadvancing cursor stops instead of looping");
    mode=@"malformed"; Check(!Search(Client(),@"bad",0,2,&error) && error.code==502 && [error.localizedDescription containsString:@"格式"],@"malformed search fails clearly");
    mode=@"rejected"; client=Client(); calls=recorded.count;
    Check(!Search(client,@"bad",0,2,&error) && ![[client.status description] containsString:@"SENSITIVE"],@"server errors are sanitized in local status");
    Check(recorded.count-calls==4,@"401 refresh is normal token acquisition and is bounded to one retry");
    mode=@"slow"; client=Client(); Check(!Search(client,@"timeout",0,0.04,&error) && error.code==NSURLErrorTimedOut && [client.status[@"message"] containsString:@"超时"],@"deadline cancels pending token request and reports timeout");
    dispatch_semaphore_t done=dispatch_semaphore_create(0); __block NSUInteger completions=0; __block NSError *cancelError;
    mode=@"slowSearch"; searchStarted=dispatch_semaphore_create(0);
    client=Client(); FMXQishuiCancellation cancel=[client search:@"cancel" page:0 timeout:2 completion:^(NSDictionary *result,NSError *e) { completions++; cancelError=e; dispatch_semaphore_signal(done); }];
    Check(dispatch_semaphore_wait(searchStarted,dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC))==0,@"search child is in flight before cancellation");
    cancel([NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorCancelled userInfo:nil]);
    Check(dispatch_semaphore_wait(done,dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC))==0 && cancelError.code==NSURLErrorCancelled,@"cancellation completes promptly");
    [NSThread sleepForTimeInterval:0.6]; Check(completions==1,@"cancelled network callback cannot complete twice");
    client=[[FMQishuiSearchClient alloc] initWithConfiguration:nil deviceID:@""];
    Check(!Search(client,@"missing",0,1,&error) && [client.status[@"state"] isEqual:@"unavailable"],@"unsupported executable configuration fails without network");
    fprintf(stdout,"Qishui catalogue tests: %s (%lu failures)\n",failures?"FAILED":"PASSED",(unsigned long)failures);
    return failures?1:0;
} }
