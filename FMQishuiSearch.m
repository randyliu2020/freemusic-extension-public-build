#import "FMQishuiSearch.h"
#import <mach-o/loader.h>
#import <math.h>

NSString * const FMXQishuiSearchStatusDidChangeNotification = @"FMXQishuiSearchStatusDidChange";
static NSError *QSError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:@"FMQishuiSearch" code:code userInfo:@{NSLocalizedDescriptionKey:message}];
}
NSArray<NSString *> *FMXQishuiConfigurationKeys(void) {
    return @[@"aid",@"app_id",@"app_name",@"version_code",@"version_name",@"channel",@"sdk_aid",@"caller_name",
             @"sdk_version_code",@"sdk_version_name",@"sdk_channel",@"vehicle_type",@"device_brand",@"device_type",
             @"device_platform",@"resolution",@"os_version",@"ac"];
}
static NSString *QSString(NSData *data, NSUInteger offset) {
    if (offset > data.length || data.length-offset < 16) return nil;
    uint64_t a, c;
    memcpy(&a, (const uint8_t *)data.bytes+offset, 8);
    memcpy(&c, (const uint8_t *)data.bytes+offset+8, 8);
    NSUInteger count;
    if ((c >> 60) == 0xe) count = (c >> 56) & 15;
    else { count = a & 0xffffffffffffULL; offset = (c & 0x7ffffffffULL) + 32; }
    if (!count || count > 256 || offset > data.length || count > data.length-offset) return nil;
    NSString *value = [[NSString alloc] initWithBytes:(const uint8_t *)data.bytes+offset length:count encoding:NSUTF8StringEncoding];
    return [value rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location == NSNotFound ? value : nil;
}
NSDictionary *FMXQishuiConfigurationFromExecutable(NSData *data) {
    if (data.length < 0x559100 || data.length > 16*1024*1024) return nil;
    struct mach_header_64 header; memcpy(&header, data.bytes, sizeof(header));
    if (header.magic != MH_MAGIC_64 || header.cputype != CPU_TYPE_ARM64 || header.filetype != MH_EXECUTE ||
        header.ncmds > 1024 || header.sizeofcmds > data.length-sizeof(header)) return nil;
    static const uint8_t uuid[16] = {0x48,0xc7,0x7a,0x33,0x63,0xbc,0x3e,0x8f,0x8f,0xc7,0x5e,0xd6,0x13,0x29,0x24,0xc4};
    NSUInteger offset = sizeof(header), end = offset+header.sizeofcmds; BOOL match = NO;
    for (uint32_t i=0; i<header.ncmds; i++) {
        struct load_command command;
        if (offset > end || end-offset < sizeof(command)) return nil;
        memcpy(&command, (const uint8_t *)data.bytes+offset, sizeof(command));
        if (command.cmdsize < sizeof(command) || command.cmdsize > end-offset) return nil;
        if (command.cmd == LC_UUID && command.cmdsize == sizeof(struct uuid_command))
            match = !memcmp((const uint8_t *)data.bytes+offset+8, uuid, sizeof(uuid));
        offset += command.cmdsize;
    }
    if (!match) return nil;
    NSArray *keys = FMXQishuiConfigurationKeys(); NSMutableDictionary *query = NSMutableDictionary.dictionary;
    for (NSUInteger i=0; i<keys.count; i++) {
        NSUInteger pair = 0x558e18+i*32;
        NSString *key = QSString(data,pair), *value = QSString(data,pair+16);
        if (![key isEqualToString:keys[i]] || !value.length) return nil;
        query[key] = value;
    }
    if (![QSString(data,0x558dc0) isEqualToString:@"trigger_type"]) return nil;
    NSString *trigger = QSString(data,0x558dd0); if (!trigger.length) return nil;
    return @{@"query":query,@"trigger_type":trigger};
}
static NSDictionary *QSDictionary(id value) { return [value isKindOfClass:NSDictionary.class] ? value : @{}; }
static NSString *QSText(id value) { return [value isKindOfClass:NSString.class] ? value : @""; }
static NSString *QSCover(NSDictionary *cover) {
    id urls=cover[@"urls"];
    if (![urls isKindOfClass:NSArray.class]) return @"";
    for(id candidate in urls) {
        NSURL *url=[NSURL URLWithString:QSText(candidate)];
        if (!url.host.length || ![@[@"https",@"http"] containsObject:url.scheme.lowercaseString]) continue;
        NSString *result=candidate, *uri=QSText(cover[@"uri"]), *prefix=QSText(cover[@"template_prefix"]);
        // Native helper 0x1faa84 completes CDN prefixes with uri and the native image template.
        if ([result hasSuffix:@"/"] && uri.length) {
            result=[result stringByAppendingString:uri];
            if(prefix.length)result=[result stringByAppendingFormat:@"~%@-image.image",prefix];
        }
        return result;
    }
    return @"";
}
static BOOL QSHasError(NSDictionary *value) {
    id code = value[@"err_no"] ?: QSDictionary(value[@"data"])[@"error_code"];
    return [code isKindOfClass:NSNumber.class] && [code integerValue] != 0;
}
NSDictionary *FMXQishuiDecodeSearch(NSDictionary *response, NSError **error) {
    if (![response isKindOfClass:NSDictionary.class] || QSHasError(response)) {
        if (error) *error=QSError(502,@"汽水搜索服务返回错误"); return nil;
    }
    id groups = QSDictionary(response[@"data"])[@"result_groups"];
    if (![groups isKindOfClass:NSArray.class]) { if(error)*error=QSError(502,@"汽水搜索返回格式变化"); return nil; }
    NSDictionary *group;
    for (id item in groups) if ([QSDictionary(item)[@"id"] isEqual:@"tracks"]) { group=item; break; }
    // Native empty result_groups is a successful empty search, but a malformed tracks group is not.
    if (!group && [groups count]==0) return @{@"tracks":@[],@"has_more":@NO,@"cursor":@"0"};
    if (!group || ![group[@"data"] isKindOfClass:NSArray.class]) { if(error)*error=QSError(502,@"汽水歌曲列表格式变化"); return nil; }
    NSMutableArray *tracks=NSMutableArray.array;
    for (id item in group[@"data"]) {
        NSDictionary *track=QSDictionary(QSDictionary(QSDictionary(item)[@"entity"])[@"track"]);
        NSDictionary *base=QSDictionary(track[@"base_info"]), *related=QSDictionary(track[@"related_info"]);
        NSString *identifier=QSText(base[@"id"]); if(!identifier.length)identifier=QSText(track[@"id"]);
        if (!identifier.length) continue;
        NSMutableArray *artists=NSMutableArray.array;
        if ([related[@"artist_links"] isKindOfClass:NSArray.class]) for(id artist in related[@"artist_links"]) {
            NSString *name=QSText(QSDictionary(artist)[@"name"]); if(name.length)[artists addObject:name];
        }
        NSString *cover=QSCover(QSDictionary(QSDictionary(track[@"display_info"])[@"cover_url"]));
        NSMutableDictionary *mapped=[@{@"id":identifier,@"title":QSText(base[@"name"]),@"server":@"qs",@"platform":@4,
            @"singer":[artists componentsJoinedByString:@" / "],@"album":QSText(QSDictionary(related[@"album_link"])[@"name"]),@"cover":cover} mutableCopy];
        id duration=base[@"duration_ms"];
        if ([duration isKindOfClass:NSNumber.class] && isfinite([duration doubleValue]) && [duration doubleValue]>=0)
            mapped[@"duration"]=@([duration doubleValue]/1000.0);
        [tracks addObject:mapped];
    }
    BOOL more=[group[@"has_more"] isKindOfClass:NSNumber.class] && [group[@"has_more"] boolValue];
    id cursor=group[@"next_cursor"]; NSString *cursorText=[cursor isKindOfClass:NSNumber.class] ? [cursor stringValue] : QSText(cursor);
    NSScanner *scanner=[NSScanner scannerWithString:cursorText]; long long number;
    BOOL valid=[scanner scanLongLong:&number] && scanner.isAtEnd && number>=0;
    if (more && !valid) { if(error)*error=QSError(502,@"汽水分页信息无效"); return nil; }
    return @{@"tracks":tracks,@"has_more":@(more),@"cursor":valid?[@(number) stringValue]:@"0"};
}

@interface FMQSOperation : NSObject
@property(nonatomic,copy) NSString *identifier, *keyword, *cursor, *searchID, *epoch;
@property(nonatomic) NSInteger page;
@property(nonatomic) NSInteger offset;
@property(nonatomic) NSUInteger rounds;
@property(nonatomic) BOOL finished;
@property(nonatomic) BOOL retriedAuthentication;
@property(nonatomic) NSTimeInterval endTime;
@property(nonatomic,strong) NSMutableArray *tracks;
@property(nonatomic,strong) NSMutableSet *seen;
@property(nonatomic,strong) NSURLSessionTask *task;
@property(nonatomic,strong) dispatch_source_t timer;
@property(nonatomic,copy) FMXQishuiCompletion completion;
@end
@implementation FMQSOperation @end

@interface FMQSRedirectPolicy : NSObject <NSURLSessionTaskDelegate> @end
@implementation FMQSRedirectPolicy
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task willPerformHTTPRedirection:(NSHTTPURLResponse *)response newRequest:(NSURLRequest *)request completionHandler:(void (^)(NSURLRequest *))completionHandler {
    completionHandler(nil); // Client token remains confined to the fixed native search destination.
}
@end

@interface FMQishuiSearchClient ()
@property(nonatomic,copy) NSDictionary *configuration;
@property(nonatomic,copy) NSString *deviceID, *token;
@property(nonatomic) NSTimeInterval tokenTime;
@property(nonatomic,strong) dispatch_queue_t queue;
@property(nonatomic,strong) NSURLSession *session;
@property(nonatomic,strong) NSMutableDictionary<NSString *,FMQSOperation *> *operations;
@property(nonatomic,strong) NSMutableDictionary<NSString *,NSMutableDictionary *> *pages;
@property(nonatomic,copy) NSDictionary *searchStatus;
@end
@implementation FMQishuiSearchClient
- (instancetype)initWithConfiguration:(NSDictionary *)configuration deviceID:(NSString *)deviceID {
    return [self initWithConfiguration:configuration deviceID:deviceID sessionConfiguration:NSURLSessionConfiguration.ephemeralSessionConfiguration];
}
- (instancetype)initWithConfiguration:(NSDictionary *)configuration deviceID:(NSString *)deviceID sessionConfiguration:(NSURLSessionConfiguration *)sessionConfiguration {
    if ((self=[super init])) {
        NSMutableDictionary *query=NSMutableDictionary.dictionary; NSDictionary *supplied=QSDictionary(configuration[@"query"]);
        for(NSString *key in FMXQishuiConfigurationKeys()) {
            NSString *value=QSText(supplied[key]); if(!value.length || value.length>256) { [query removeAllObjects]; break; }
            query[key]=value;
        }
        NSString *trigger=QSText(configuration[@"trigger_type"]);
        if(query.count==18 && trigger.length && trigger.length<=256) _configuration=@{@"query":query,@"trigger_type":trigger};
        _deviceID=[deviceID copy]; _queue=dispatch_queue_create("FMX.qishui.catalogue",DISPATCH_QUEUE_SERIAL);
        _operations=NSMutableDictionary.dictionary; _pages=NSMutableDictionary.dictionary;
        _searchStatus=@{@"state":@"idle",@"message":@"尚未搜索"};
        sessionConfiguration=[sessionConfiguration copy];
        sessionConfiguration.HTTPCookieStorage=nil; sessionConfiguration.HTTPShouldSetCookies=NO;
        sessionConfiguration.URLCredentialStorage=nil;
        sessionConfiguration.HTTPAdditionalHeaders=@{};
        _session=[NSURLSession sessionWithConfiguration:sessionConfiguration delegate:FMQSRedirectPolicy.new delegateQueue:nil];
    } return self;
}
+ (instancetype)nativeClient {
    NSData *data=[NSData dataWithContentsOfFile:NSBundle.mainBundle.executablePath options:NSDataReadingMappedIfSafe error:nil];
    NSDictionary *configuration=data?FMXQishuiConfigurationFromExecutable(data):nil;
    NSString *device;
    @synchronized (self) {
        device=[NSUserDefaults.standardUserDefaults stringForKey:@"fm_qishui_device"];
        if(!device.length && configuration) {
            uint64_t random, bound=9000000000000000000ULL, threshold=(uint64_t)(-bound)%bound;
            do { arc4random_buf(&random,sizeof(random)); } while(random<threshold);
            device=[NSString stringWithFormat:@"%llu",(unsigned long long)(1000000000000000000ULL+random%bound)];
            [NSUserDefaults.standardUserDefaults setObject:device forKey:@"fm_qishui_device"];
        }
    }
    return [[self alloc] initWithConfiguration:configuration deviceID:device?:@""];
}
- (NSDictionary *)status { @synchronized(self) { return self.searchStatus; } }
- (void)setState:(NSString *)state message:(NSString *)message {
    @synchronized(self) { self.searchStatus=@{@"state":state,@"message":message}; }
    dispatch_async(dispatch_get_main_queue(),^{ [NSNotificationCenter.defaultCenter postNotificationName:FMXQishuiSearchStatusDidChangeNotification object:self]; });
}
- (NSMutableURLRequest *)requestForToken:(BOOL)token operation:(FMQSOperation *)operation {
    NSURLComponents *components=[NSURLComponents componentsWithString:token?@"https://open.qishui.com/api/luna/v1/platform/client/token/get/":@"https://open.douyin.com/api/luna/v1/platform/search/"];
    NSMutableDictionary *query=[self.configuration[@"query"] mutableCopy];
    for(NSString *key in @[@"device_id",@"did",@"iid"])query[key]=self.deviceID;
    query[@"vehicle_id"]=[@"qishui-" stringByAppendingString:self.deviceID];
    query[@"_timestamp"]=@((long long)NSDate.date.timeIntervalSince1970).stringValue;
    query[@"_nonce"]=@(arc4random_uniform(65536)).stringValue;
    if(token)query[@"trigger_type"]=self.configuration[@"trigger_type"];
    NSMutableArray *items=NSMutableArray.array;
    for(NSString *key in [[query allKeys] sortedArrayUsingSelector:@selector(compare:)]) [items addObject:[NSURLQueryItem queryItemWithName:key value:query[key]]];
    components.queryItems=items;
    NSMutableURLRequest *request=[NSMutableURLRequest requestWithURL:components.URL];
    request.timeoutInterval=MAX(0.05,MIN(15,operation.endTime-NSProcessInfo.processInfo.systemUptime));
    [request setValue:@"LunaOpenSDK/1.0.10" forHTTPHeaderField:@"User-Agent"];
    if(!token) {
        request.HTTPMethod=@"POST";
        [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
        [request setValue:self.token forHTTPHeaderField:@"access-token"];
        request.HTTPBody=[NSJSONSerialization dataWithJSONObject:@{@"q":operation.keyword,@"cursor":operation.cursor,
            @"search_id":operation.searchID,@"from_search_id":operation.searchID,@"search_method":@"input",
            @"search_type":@"track",@"search_scene":@"normal",@"scene_name":@"search",@"ab_param":@"",
            @"last_viewed_media":@{},@"common_params":@{}} options:0 error:nil];
    }
    return request;
}
- (void)finish:(FMQSOperation *)operation response:(NSDictionary *)response error:(NSError *)error {
    if(operation.finished)return; operation.finished=YES;
    [operation.task cancel]; operation.task=nil;
    if(operation.timer) { dispatch_source_cancel(operation.timer); operation.timer=nil; }
    [self.operations removeObjectForKey:operation.identifier];
    if(!error) [self setState:@"available" message:@"可用"];
    else if(error.code!=NSURLErrorCancelled) [self setState:@"unavailable" message:error.localizedDescription];
    else if(self.operations.count==0 && [[self status][@"state"] isEqual:@"searching"]) [self setState:@"idle" message:@"尚未搜索"];
    FMXQishuiCompletion completion=operation.completion; operation.completion=nil;
    if(completion)completion(response,error);
}
- (void)send:(FMQSOperation *)operation token:(BOOL)token {
    if(operation.finished)return;
    if(!token && !self.token.length) { [self send:operation token:YES]; return; }
    NSMutableURLRequest *request=[self requestForToken:token operation:operation];
    __weak typeof(self) weakSelf=self;
    operation.task=[self.session dataTaskWithRequest:request completionHandler:^(NSData *data,NSURLResponse *response,NSError *error) {
        typeof(self) self=weakSelf; if(!self)return;
        dispatch_async(self.queue,^{
            if(operation.finished)return;
            NSInteger status=[response isKindOfClass:NSHTTPURLResponse.class]?((NSHTTPURLResponse *)response).statusCode:0;
            NSDictionary *json=data.length<=4*1024*1024 ? [NSJSONSerialization JSONObjectWithData:data?:NSData.data options:0 error:nil] : nil;
            id serviceCode=QSDictionary(json)[@"err_no"]?:QSDictionary(QSDictionary(json)[@"data"])[@"error_code"];
            BOOL unauthorized=status==401 || ([serviceCode isKindOfClass:NSNumber.class] && [serviceCode integerValue]==401);
            if(!token && !error && unauthorized && !operation.retriedAuthentication) {
                operation.retriedAuthentication=YES; self.token=nil; [self send:operation token:YES]; return;
            }
            if(error || status<200 || status>=300 || ![json isKindOfClass:NSDictionary.class] || QSHasError(json)) {
                if(!token)self.token=nil; // Future searches obtain a fresh normal client token; no auth bypass or unbounded retry.
                NSString *message=error.code==NSURLErrorTimedOut?@"汽水搜索超时":(token?@"汽水连接暂不可用":@"汽水搜索暂不可用");
                [self finish:operation response:nil error:QSError(error.code?:502,message)]; return;
            }
            if(token) {
                NSString *value=QSText(json[@"client_token"]);
                if(!value.length || value.length>8192) { [self finish:operation response:nil error:QSError(502,@"汽水连接返回格式变化")]; return; }
                self.token=value; self.tokenTime=NSProcessInfo.processInfo.systemUptime; [self send:operation token:NO]; return;
            }
            NSError *decodeError; NSDictionary *decoded=FMXQishuiDecodeSearch(json,&decodeError);
            if(!decoded) { [self finish:operation response:nil error:decodeError]; return; }
            for(NSDictionary *track in decoded[@"tracks"]) if(![operation.seen containsObject:track[@"id"]]) {
                [operation.seen addObject:track[@"id"]]; [operation.tracks addObject:track];
            }
            BOOL more=[decoded[@"has_more"] boolValue]; NSString *cursor=decoded[@"cursor"];
            if(more && [cursor longLongValue]<=[operation.cursor longLongValue]) {
                [self finish:operation response:nil error:QSError(502,@"汽水分页未前进")]; return;
            }
            operation.cursor=cursor; operation.rounds++;
            if(more && operation.tracks.count<30) {
                if(operation.rounds>=8) { [self finish:operation response:nil error:QSError(502,@"汽水分页响应过慢")]; return; }
                [self send:operation token:NO]; return;
            }
            NSMutableDictionary *entry=self.pages[operation.keyword];
            NSInteger observed=operation.offset+(NSInteger)operation.tracks.count;
            if([entry[@"epoch"] isEqual:operation.epoch]) {
                entry[@(operation.page+1).stringValue]=more?cursor:NSNull.null;
                entry[[@"offset:" stringByAppendingString:@(operation.page+1).stringValue]]=@(observed);
            }
            NSDictionary *result=@{@"code":@200,@"msg":@"成功",@"data":operation.tracks,@"page":@(operation.page),
                @"count":@(operation.tracks.count),@"total":@(observed+(more?1:0))};
            [self finish:operation response:result error:nil];
        });
    }];
    [operation.task resume];
}
- (FMXQishuiCancellation)search:(NSString *)keyword page:(NSInteger)page timeout:(NSTimeInterval)timeout completion:(FMXQishuiCompletion)completion {
    FMQSOperation *operation=FMQSOperation.new;
    operation.identifier=NSUUID.UUID.UUIDString; operation.keyword=keyword; operation.page=MAX(0,page);
    operation.searchID=NSUUID.UUID.UUIDString; operation.tracks=NSMutableArray.array; operation.seen=NSMutableSet.set;
    operation.completion=completion; operation.endTime=NSProcessInfo.processInfo.systemUptime+MAX(0.05,MIN(15,timeout));
    dispatch_async(self.queue,^{
        if(!self.configuration || !self.deviceID.length) { [self finish:operation response:nil error:QSError(500,@"当前安装包不支持汽水配置读取")]; return; }
        if(!keyword.length || page<0 || page>10000) { [self finish:operation response:nil error:QSError(400,@"汽水搜索参数无效")]; return; }
        NSMutableDictionary *entry=self.pages[keyword];
        if(page==0) {
            if(self.pages.count>=8) [self.pages removeAllObjects];
            entry=[@{@"epoch":NSUUID.UUID.UUIDString,@"0":@"0",@"offset:0":@0,@"time":@(NSProcessInfo.processInfo.systemUptime)} mutableCopy]; self.pages[keyword]=entry;
        }
        id cursor=entry[@(page).stringValue]; operation.epoch=entry[@"epoch"];
        operation.offset=[entry[[@"offset:" stringByAppendingString:@(page).stringValue]] integerValue];
        if(!cursor || NSProcessInfo.processInfo.systemUptime-[entry[@"time"] doubleValue]>900) {
            [self finish:operation response:nil error:QSError(409,@"请重新搜索后继续汽水分页")]; return;
        }
        if(cursor==NSNull.null) {
            NSNumber *total=entry[[@"offset:" stringByAppendingString:@(page).stringValue]]?:@0;
            entry[@(page+1).stringValue]=NSNull.null; entry[[@"offset:" stringByAppendingString:@(page+1).stringValue]]=total;
            [self finish:operation response:@{@"code":@200,@"data":@[],@"page":@(page),@"count":@0,@"total":total} error:nil]; return;
        }
        operation.cursor=cursor; self.operations[operation.identifier]=operation;
        [self setState:@"searching" message:@"搜索中"];
        operation.timer=dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,0,0,self.queue);
        dispatch_source_set_timer(operation.timer,dispatch_time(DISPATCH_TIME_NOW,(int64_t)(MAX(0.01,operation.endTime-NSProcessInfo.processInfo.systemUptime)*NSEC_PER_SEC)),DISPATCH_TIME_FOREVER,NSEC_PER_MSEC);
        __weak typeof(self) weakSelf=self;
        dispatch_source_set_event_handler(operation.timer,^{ [weakSelf finish:operation response:nil error:QSError(NSURLErrorTimedOut,@"汽水搜索超时")]; });
        dispatch_resume(operation.timer);
        // Remote expiry fields are not reliably relative seconds; use a conservative local upper bound.
        if(NSProcessInfo.processInfo.systemUptime-self.tokenTime>=600)self.token=nil;
        [self send:operation token:self.token.length==0];
    });
    return ^(NSError *reason) {
        dispatch_async(self.queue,^{
            if(operation.finished)return;
            NSError *error=reason?:QSError(NSURLErrorCancelled,@"汽水搜索已取消");
            if(error.code==NSURLErrorTimedOut)error=QSError(NSURLErrorTimedOut,@"汽水搜索超时");
            [self finish:operation response:nil error:error];
        });
    };
}
- (void)dealloc { [self.session invalidateAndCancel]; }
@end
