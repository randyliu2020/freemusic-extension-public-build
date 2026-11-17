#import "FMExtensionProtocol.h"
#import "FMLXMC.h"
#import "FMQishuiSearch.h"
#import <objc/runtime.h>

static NSString * const FMXHandledKey = @"FMX.internalRequest";
static NSString * const FMXAggregateKey = @"FMX.aggregateSearch";
static NSString * const FMXErrorDomain = @"FMExtensionProtocol";
static const NSUInteger FMXMaximumBodySize = 64 * 1024;
static FMXParseHandler FMXHandler;
static FMXParsePredicate FMXPredicate;
static void (^FMXMetadataObserver)(id);
static FMQishuiSearchClient *FMXQishuiClient;
static NSDictionary<NSString *, NSValue *> *FMXGetterIMPs;
static _Thread_local const void *FMXActiveGetterObject;
static _Thread_local const void *FMXActiveGetterClass;

static FMQishuiSearchClient *FMXGetQishuiClient(void) {
    @synchronized (FMExtensionProtocol.class) {
        if (!FMXQishuiClient) FMXQishuiClient = FMQishuiSearchClient.nativeClient;
        return FMXQishuiClient;
    }
}
NSDictionary<NSString *, NSString *> *FMXQishuiSearchStatus(void) { return [FMXGetQishuiClient() status]; }

static NSError *FMXError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:FMXErrorDomain code:code userInfo:@{NSLocalizedDescriptionKey:message}];
}

static BOOL FMXAddForm(NSString *form, NSMutableDictionary *result) {
    if (form.length == 0) return YES;
    for (NSString *part in [form componentsSeparatedByString:@"&"]) {
        if (part.length == 0) continue;
        NSRange separator = [part rangeOfString:@"="];
        NSString *key = separator.location == NSNotFound ? part : [part substringToIndex:separator.location];
        NSString *value = separator.location == NSNotFound ? @"" : [part substringFromIndex:separator.location + 1];
        key = [[key stringByReplacingOccurrencesOfString:@"+" withString:@" "] stringByRemovingPercentEncoding];
        value = [[value stringByReplacingOccurrencesOfString:@"+" withString:@" "] stringByRemovingPercentEncoding];
        if (!key.length || !value || result[key] != nil) return NO;
        result[key] = value;
    }
    return YES;
}

NSDictionary<NSString *, NSString *> *FMXRequestParameters(NSURLRequest *request) {
    if (request.HTTPBodyStream) return nil;
    NSMutableDictionary *parameters = [NSMutableDictionary dictionary];
    NSURLComponents *components = [NSURLComponents componentsWithURL:request.URL resolvingAgainstBaseURL:NO];
    if (!components || !FMXAddForm(components.percentEncodedQuery ?: @"", parameters)) return nil;
    if (request.HTTPBody.length) {
        NSString *contentType = [[request valueForHTTPHeaderField:@"Content-Type"] lowercaseString];
        NSString *mediaType = [[contentType componentsSeparatedByString:@";"][0]
                              stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (![mediaType isEqualToString:@"application/x-www-form-urlencoded"]) return nil;
        NSString *body = [[NSString alloc] initWithData:request.HTTPBody encoding:NSUTF8StringEncoding];
        if (!body || !FMXAddForm(body, parameters)) return nil;
    }
    return parameters;
}

static NSDictionary *FMXQueryParameters(NSURLRequest *request) {
    NSMutableDictionary *parameters = [NSMutableDictionary dictionary];
    NSURLComponents *components = [NSURLComponents componentsWithURL:request.URL resolvingAgainstBaseURL:NO];
    return components && FMXAddForm(components.percentEncodedQuery ?: @"", parameters) ? parameters : nil;
}

static BOOL FMXIsTarget(NSURLRequest *request) {
    NSURL *url = request.URL;
    return ![NSURLProtocol propertyForKey:FMXHandledKey inRequest:request]
        && [url.scheme.lowercaseString isEqualToString:@"https"]
        && [url.host.lowercaseString isEqualToString:@"aacert.com"]
        && [url.path isEqualToString:@"/ms/api.php"]
        && !url.user.length && !url.password.length
        && (!url.port || url.port.integerValue == 443);
}

static NSDictionary<NSString *, NSString *> *FMXKugouParameters(NSURLRequest *request) {
    NSURL *url = request.URL;
    if ([NSURLProtocol propertyForKey:FMXHandledKey inRequest:request] ||
        ![url.scheme.lowercaseString isEqualToString:@"https"] ||
        ![url.host.lowercaseString isEqualToString:@"m.kugou.com"] ||
        ![url.path isEqualToString:@"/app/i/getSongInfo.php"] ||
        url.user != nil || url.password != nil || url.fragment != nil ||
        (url.port && url.port.integerValue != 443) ||
        ![(request.HTTPMethod.uppercaseString ?: @"GET") isEqualToString:@"GET"] ||
        request.HTTPBody.length || request.HTTPBodyStream) return nil;
    NSDictionary *query = FMXQueryParameters(request);
    NSString *hash = query[@"hash"];
    // The native route has exactly these two fields; other operations and quality variants stay native.
    NSCharacterSet *nonHex = [[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdefABCDEF"] invertedSet];
    if (query.count != 2 || ![query[@"cmd"] isEqualToString:@"playInfo"] || hash.length != 32 ||
        [hash rangeOfCharacterFromSet:nonHex].location != NSNotFound) return nil;
    return @{@"server":@"kg", @"id":hash.uppercaseString, @"level":@"standard"};
}

static BOOL FMXIsValidTrack(id value) {
    if (![value isKindOfClass:NSDictionary.class]) return NO;
    NSDictionary *track = value;
    return [track[@"id"] isKindOfClass:NSString.class] && [track[@"id"] length] > 0
        && [track[@"server"] isKindOfClass:NSString.class] && [track[@"server"] length] > 0
        && [track[@"title"] isKindOfClass:NSString.class];
}

NSDictionary *FMXMergeSearchResponses(NSArray *responses, NSInteger page) {
    NSMutableArray<NSArray *> *lists = [NSMutableArray array];
    NSUInteger longest = 0;
    NSInteger total = 0;
    for (id response in responses) {
        NSArray *list = [response isKindOfClass:NSDictionary.class] &&
            [response[@"code"] isKindOfClass:NSNumber.class] && [response[@"code"] integerValue] == 200 &&
            [response[@"data"] isKindOfClass:NSArray.class] ? response[@"data"] : @[];
        [lists addObject:list];
        longest = MAX(longest, list.count);
        NSNumber *sourceTotal = [response isKindOfClass:NSDictionary.class] ? response[@"total"] : nil;
        total += [sourceTotal isKindOfClass:NSNumber.class] ? MAX(0, sourceTotal.integerValue) : (NSInteger)list.count;
    }
    NSMutableSet<NSArray<NSString *> *> *seen = [NSMutableSet set];
    NSMutableArray *tracks = [NSMutableArray array];
    for (NSUInteger index = 0; index < longest; index++) {
        for (NSArray *list in lists) {
            if (index >= list.count || !FMXIsValidTrack(list[index])) continue;
            NSDictionary *track = list[index];
            NSArray *key = @[track[@"server"], track[@"id"]];
            if ([seen containsObject:key]) continue;
            [seen addObject:key];
            [tracks addObject:track];
        }
    }
    return @{@"code":@200, @"msg":@"成功", @"data":tracks,
             @"page":@(MAX(0, page)), @"count":@(tracks.count), @"total":@(MAX(total, (NSInteger)tracks.count))};
}

// Copying the returned array and preserving the original getter handles private class-cluster instances.
// A small thread-local stack position avoids recursion if an original override calls its superclass.
static NSArray *FMXProtocolClasses(id self, SEL selector) {
    const void *savedObject = FMXActiveGetterObject;
    const void *savedClass = FMXActiveGetterClass;
    Class cls = savedObject == (__bridge const void *)self && savedClass
        ? class_getSuperclass((__bridge Class)savedClass) : object_getClass(self);
    IMP original = NULL;
    while (cls && !original) {
        original = (IMP)[FMXGetterIMPs[NSStringFromClass(cls)] pointerValue];
        if (!original) cls = class_getSuperclass(cls);
    }
    NSArray *classes = @[];
    if (original) {
        FMXActiveGetterObject = (__bridge const void *)self;
        FMXActiveGetterClass = (__bridge const void *)cls;
        @try { classes = ((NSArray *(*)(id, SEL))original)(self, selector) ?: @[]; }
        @finally { FMXActiveGetterObject = savedObject; FMXActiveGetterClass = savedClass; }
    }
    if ([classes containsObject:FMExtensionProtocol.class]) return classes;
    NSMutableArray *result = [classes mutableCopy];
    [result insertObject:FMExtensionProtocol.class atIndex:0];
    return result;
}

@interface FMExtensionProtocol ()
@property(nonatomic, strong) dispatch_queue_t stateQueue;
@property(nonatomic, strong) dispatch_queue_t bodyQueue;
@property(nonatomic, strong) NSURLRequest *effectiveRequest;
@property(atomic) BOOL bodyReadCancelled;
@property(nonatomic, strong) dispatch_source_t deadline;
@property(nonatomic, strong) NSURLSession *childSession;
@property(nonatomic, strong) NSMutableArray<NSURLSessionTask *> *childTasks;
@property(nonatomic, strong) NSMutableArray *responses;
@property(nonatomic, strong) NSMutableArray<NSError *> *errors;
@property(nonatomic) NSUInteger pending;
@property(nonatomic) NSInteger requestedPage;
@property(nonatomic) BOOL finished;
@property(nonatomic, copy) FMXParseCancellation cancelParse;
@property(nonatomic, copy) FMXQishuiCancellation cancelQishui;
@end

@implementation FMExtensionProtocol

+ (void)setQishuiSearchClient:(FMQishuiSearchClient *)client {
    @synchronized (self) { FMXQishuiClient = client; }
}

+ (void)install {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSArray *configurations = @[NSURLSessionConfiguration.defaultSessionConfiguration,
                                    NSURLSessionConfiguration.ephemeralSessionConfiguration];
        NSMutableDictionary *originals = [NSMutableDictionary dictionary];
        NSMutableArray *classes = [NSMutableArray array];
        for (id configuration in configurations) {
            Class cls = object_getClass(configuration);
            NSString *key = NSStringFromClass(cls);
            if (originals[key]) continue;
            Method method = class_getInstanceMethod(cls, @selector(protocolClasses));
            if (!method) continue;
            originals[key] = [NSValue valueWithPointer:(const void *)method_getImplementation(method)];
            [classes addObject:cls];
        }
        FMXGetterIMPs = [originals copy];
        for (Class cls in classes) {
            Method method = class_getInstanceMethod(cls, @selector(protocolClasses));
            const char *types = method_getTypeEncoding(method);
            // Never mutate an inherited Method on an unrelated superclass.
            if (!class_addMethod(cls, @selector(protocolClasses), (IMP)FMXProtocolClasses, types)) {
                method_setImplementation(class_getInstanceMethod(cls, @selector(protocolClasses)), (IMP)FMXProtocolClasses);
            }
        }
        [NSURLProtocol registerClass:self];
    });
}

+ (void)setParseHandler:(FMXParseHandler)handler canHandle:(FMXParsePredicate)predicate {
    @synchronized (self) {
        FMXHandler = [handler copy];
        FMXPredicate = [predicate copy];
    }
}

+ (void)setTrackMetadataObserver:(void (^)(id))observer {
    @synchronized(self) {
        FMXMetadataObserver=[observer copy];
        FMLXMCTrackObserver trackObserver=nil;
        if(observer)trackObserver=^(NSDictionary *track){observer(track);};
        FMLXMCSetTrackObserver(trackObserver);
    }
}

+ (BOOL)canInitWithRequest:(NSURLRequest *)request {
    NSDictionary *kugou = FMXKugouParameters(request);
    if (kugou) {
        FMXParseHandler handler;
        FMXParsePredicate predicate;
        @synchronized (self) { handler = FMXHandler; predicate = FMXPredicate; }
        if (!handler || !predicate) return NO;
        @try { return predicate(request, kugou); }
        @catch (NSException *exception) { return NO; }
    }
    if (!FMXIsTarget(request)) return NO;
    // Do not open or consume a body stream during NSURLProtocol selection.
    NSDictionary *parameters = FMXQueryParameters(request);
    NSString *action = parameters[@"action"];
    NSString *method = request.HTTPMethod.uppercaseString ?: @"GET";
    // Retain streamed bodies before deciding whether an import is a local LX
    // bridge. Ordinary external-link imports are forwarded unchanged afterwards.
    if ([action isEqualToString:@"import_playlist"] && [method isEqualToString:@"POST"]) return YES;
    if ([action isEqualToString:@"search"] && [method isEqualToString:@"GET"]) {
        BOOL observe; @synchronized(self) { observe=FMXMetadataObserver!=nil; }
        return (observe || [NSUserDefaults.standardUserDefaults boolForKey:FMXAggregateKey])
            && [parameters[@"keyword"] length] > 0
            && [@[@"0", @"2", @"3"] containsObject:parameters[@"platform"]];
    }
    if (![action isEqualToString:@"parse"] || ![method isEqualToString:@"POST"]) return NO;
    FMXParseHandler handler;
    @synchronized (self) { handler = FMXHandler; }
    // Unsupported sources are forwarded only after their complete body has been retained.
    return handler != nil;
}

+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request { return request; }

- (instancetype)initWithRequest:(NSURLRequest *)request cachedResponse:(NSCachedURLResponse *)cachedResponse client:(id<NSURLProtocolClient>)client {
    self = [super initWithRequest:request cachedResponse:cachedResponse client:client];
    if (self) {
        _stateQueue = dispatch_queue_create("FMX.protocol.state", DISPATCH_QUEUE_SERIAL);
        _bodyQueue = dispatch_queue_create("FMX.protocol.body", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (void)startLoading {
    dispatch_async(self.stateQueue, ^{
        if (self.finished) return;
        NSDictionary *parameters = FMXQueryParameters(self.request);
        NSDictionary *kugou = FMXKugouParameters(self.request);
        self.effectiveRequest = self.request;
        self.deadline = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, self.stateQueue);
        // LX sources may obtain a token and try a backup before resolving a URL.
        // Give only playback parsing that room; do not extend native deadlines,
        // search/import work, or a caller's cancellation window.
        BOOL parsing = kugou != nil || (FMXIsTarget(self.request) &&
            [parameters[@"action"] isEqualToString:@"parse"] &&
            [self.request.HTTPMethod.uppercaseString isEqualToString:@"POST"]);
        NSTimeInterval limit = parsing ? 45 : 20;
        NSTimeInterval budget = MIN(self.request.timeoutInterval > 0 ? self.request.timeoutInterval : limit, limit);
        // Finish before NSURLSession's own timer can turn a deadline into an indistinguishable stopLoading.
        NSTimeInterval timeout = budget - MIN(0.25, budget * 0.2);
        uint64_t leeway = (uint64_t)(MIN(0.01, timeout * 0.02) * NSEC_PER_SEC);
        dispatch_source_set_timer(self.deadline, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC)), DISPATCH_TIME_FOREVER, leeway);
        __weak typeof(self) weakSelf = self;
        dispatch_source_set_event_handler(self.deadline, ^{
            typeof(self) strongSelf = weakSelf;
            if (!strongSelf || strongSelf.finished) return;
            if (strongSelf.responses) {
                FMXQishuiCancellation cancel = strongSelf.cancelQishui;
                strongSelf.cancelQishui = nil;
                if (cancel) cancel(FMXError(NSURLErrorTimedOut, @"汽水搜索超时"));
                [strongSelf finishSearch];
            }
            else [strongSelf finishPayload:nil error:FMXError(NSURLErrorTimedOut, @"音源解析超时")];
        });
        dispatch_resume(self.deadline);
        if (kugou) [self beginParse:kugou];
        else if ([parameters[@"action"] isEqualToString:@"search"]) {
            if([NSUserDefaults.standardUserDefaults boolForKey:FMXAggregateKey])[self beginSearch:parameters];
            else [self forwardPreparedRequest];
        }
        else [self prepareParseBody];
    });
}

- (void)prepareParseBody {
    NSInputStream *stream = self.request.HTTPBodyStream;
    if (!stream) {
        if (self.request.HTTPBody.length > FMXMaximumBodySize) {
            [self finishPayload:nil error:FMXError(NSURLErrorDataLengthExceedsMaximum, @"解析请求超过64KB限制")];
        } else {
            [self beginPreparedParse];
        }
        return;
    }
    // Separate queue: body availability cannot block timeout, stopLoading, or result delivery.
    dispatch_async(self.bodyQueue, ^{
        NSMutableData *body = [NSMutableData data];
        NSError *readError;
        BOOL reachedEnd = NO;
        @try {
            [stream open];
            uint8_t buffer[4096];
            while (!self.bodyReadCancelled) {
                NSStreamStatus status = stream.streamStatus;
                if (status == NSStreamStatusError) { readError = stream.streamError ?: FMXError(NSURLErrorCannotDecodeRawData, @"无法读取解析请求"); break; }
                if (status == NSStreamStatusAtEnd) { reachedEnd = YES; break; }
                if (status == NSStreamStatusClosed) { readError = FMXError(NSURLErrorCannotDecodeRawData, @"解析请求流提前关闭"); break; }
                if (!stream.hasBytesAvailable) {
                    [NSThread sleepForTimeInterval:0.005];
                    continue;
                }
                NSInteger count = [stream read:buffer maxLength:sizeof(buffer)];
                if (count < 0) { readError = stream.streamError ?: FMXError(NSURLErrorCannotDecodeRawData, @"无法读取解析请求"); break; }
                if (count == 0) { reachedEnd = YES; break; }
                if (body.length + (NSUInteger)count > FMXMaximumBodySize) {
                    readError = FMXError(NSURLErrorDataLengthExceedsMaximum, @"解析请求超过64KB限制");
                    break;
                }
                [body appendBytes:buffer length:(NSUInteger)count];
            }
        } @catch (NSException *exception) {
            readError = FMXError(NSURLErrorCannotDecodeRawData, @"解析请求流读取失败");
        } @finally {
            [stream close];
        }
        dispatch_async(self.stateQueue, ^{
            if (self.finished) return;
            if (readError || !reachedEnd) {
                [self finishPayload:nil error:readError ?: FMXError(NSURLErrorCancelled, @"解析请求已取消")];
                return;
            }
            NSMutableURLRequest *request = [self.request mutableCopy];
            request.HTTPBodyStream = nil;
            request.HTTPBody = body;
            self.effectiveRequest = request;
            [self beginPreparedParse];
        });
    });
}

- (void)beginPreparedParse {
    NSString *lengthHeader = [self.effectiveRequest valueForHTTPHeaderField:@"Content-Length"];
    if (lengthHeader.length) {
        unsigned long long expectedLength = 0;
        NSScanner *scanner = [NSScanner scannerWithString:lengthHeader];
        if (![scanner scanUnsignedLongLong:&expectedLength] || !scanner.isAtEnd || expectedLength != self.effectiveRequest.HTTPBody.length) {
            [self finishPayload:nil error:FMXError(NSURLErrorCannotDecodeRawData, @"解析请求正文长度不完整，未转发")];
            return;
        }
    }
    if ([FMXQueryParameters(self.effectiveRequest)[@"action"] isEqualToString:@"import_playlist"]) {
        if (FMLXMCRequestMatches(self.effectiveRequest)) {
            NSError *error = nil;
            NSData *data = FMLXMCResponseForRequest(self.effectiveRequest, &error);
            NSHTTPURLResponse *response = data ? [[NSHTTPURLResponse alloc] initWithURL:self.effectiveRequest.URL
                statusCode:200 HTTPVersion:@"HTTP/1.1" headerFields:@{@"Content-Type":@"application/json; charset=utf-8"}] : nil;
            [self finishData:data response:response error:error];
        } else [self forwardPreparedRequest];
        return;
    }
    NSDictionary *parameters = FMXRequestParameters(self.effectiveRequest);
    if (!parameters || ![parameters[@"action"] isEqualToString:@"parse"] ||
        ![parameters[@"id"] length] || ![parameters[@"server"] length]) {
        [self finishPayload:nil error:FMXError(NSURLErrorCannotParseResponse, @"解析请求格式无效，未转发不完整请求")];
        return;
    }
    [self beginParse:parameters];
}

- (void)beginSearch:(NSDictionary *)parameters {
    self.requestedPage = MAX(0, [parameters[@"page"] integerValue]);
    self.responses = [NSMutableArray arrayWithArray:@[NSNull.null, NSNull.null, NSNull.null, NSNull.null]];
    self.errors = [NSMutableArray array];
    self.childTasks = [NSMutableArray array];
    self.pending = 4;
    // FreeMusic's metadata session uses the default configuration and shared cookie storage.
    // Preserve explicit authentication headers and normal cookie handling on each copied request.
    NSURLSessionConfiguration *configuration = NSURLSessionConfiguration.defaultSessionConfiguration;
    self.childSession = [NSURLSession sessionWithConfiguration:configuration];
    NSArray<NSNumber *> *platforms = @[@0, @2, @3];
    __weak typeof(self) qishuiSelf = self;
    self.cancelQishui = [FMXGetQishuiClient() search:parameters[@"keyword"] page:self.requestedPage
        timeout:MIN(self.request.timeoutInterval > 0 ? self.request.timeoutInterval : 15, 15)
        completion:^(NSDictionary *response, NSError *error) {
            typeof(self) strongSelf = qishuiSelf;
            if (!strongSelf) return;
            dispatch_async(strongSelf.stateQueue, ^{
                if (strongSelf.finished) return;
                if (response) strongSelf.responses[3] = response;
                else if (error) [strongSelf.errors addObject:error];
                if (--strongSelf.pending == 0) [strongSelf finishSearch];
            });
        }];
    for (NSUInteger index = 0; index < platforms.count; index++) {
        NSMutableURLRequest *request = [self.request mutableCopy];
        NSURLComponents *components = [NSURLComponents componentsWithURL:request.URL resolvingAgainstBaseURL:NO];
        NSMutableArray<NSURLQueryItem *> *items = [NSMutableArray array];
        for (NSURLQueryItem *item in components.queryItems ?: @[]) {
            if (![item.name isEqualToString:@"platform"]) [items addObject:item];
        }
        [items addObject:[NSURLQueryItem queryItemWithName:@"platform" value:platforms[index].stringValue]];
        components.queryItems = items;
        request.URL = components.URL;
        request.timeoutInterval = MIN(request.timeoutInterval > 0 ? request.timeoutInterval : 15, 15);
        [NSURLProtocol setProperty:@YES forKey:FMXHandledKey inRequest:request];
        __weak typeof(self) weakSelf = self;
        NSURLSessionDataTask *task = [self.childSession dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            typeof(self) strongSelf = weakSelf;
            if (!strongSelf) return;
            dispatch_async(strongSelf.stateQueue, ^{
                if (strongSelf.finished) return;
                NSError *jsonError;
                id json = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError] : nil;
                NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)response).statusCode : 0;
                if (!error && status >= 200 && status < 300 && [json isKindOfClass:NSDictionary.class]) {
                    strongSelf.responses[index] = json;
                } else {
                    [strongSelf.errors addObject:error ?: jsonError ?: FMXError(status ?: 502, @"搜索响应不可用")];
                }
                if (--strongSelf.pending == 0) [strongSelf finishSearch];
            });
        }];
        [self.childTasks addObject:task];
        [task resume];
    }
}

- (void)finishSearch {
    BOOL anySuccess = NO;
    NSDictionary *firstFailure;
    for (id response in self.responses) {
        if (![response isKindOfClass:NSDictionary.class]) continue;
        if ([response[@"code"] isKindOfClass:NSNumber.class] && [response[@"code"] integerValue] == 200 &&
            [response[@"data"] isKindOfClass:NSArray.class]) anySuccess = YES;
        else if (!firstFailure && [response[@"code"] isKindOfClass:NSNumber.class] && [response[@"code"] integerValue] != 200) firstFailure = response;
    }
    if (anySuccess) [self finishPayload:FMXMergeSearchResponses(self.responses, self.requestedPage) error:nil];
    else if (firstFailure) [self finishPayload:firstFailure error:nil];
    else [self finishPayload:nil error:self.errors.firstObject ?: FMXError(NSURLErrorTimedOut, @"聚合搜索暂不可用")];
}

- (void)beginParse:(NSDictionary *)parameters {
    FMXParseHandler handler;
    FMXParsePredicate predicate;
    @synchronized (FMExtensionProtocol.class) { handler = FMXHandler; predicate = FMXPredicate; }
    // The source may have changed after selection; the retained body is safe to forward.
    if (!handler || !predicate) {
        [self forwardPreparedRequest];
        return;
    }
    __weak typeof(self) weakSelf = self;
    @try {
        if (!predicate(self.effectiveRequest, parameters)) {
            [self forwardPreparedRequest];
            return;
        }
        self.cancelParse = handler(self.effectiveRequest, parameters, ^(NSDictionary *payload, NSError *error) {
            typeof(self) strongSelf = weakSelf;
            if (!strongSelf) return;
            dispatch_async(strongSelf.stateQueue, ^{ [strongSelf finishPayload:payload error:error]; });
        });
    } @catch (NSException *exception) {
        [self finishPayload:nil error:FMXError(500, @"音源处理失败")];
    }
}

- (void)forwardPreparedRequest {
    NSMutableURLRequest *request = [self.effectiveRequest mutableCopy];
    [NSURLProtocol setProperty:@YES forKey:FMXHandledKey inRequest:request];
    NSURLSessionConfiguration *configuration = FMXKugouParameters(self.effectiveRequest)
        ? NSURLSessionConfiguration.ephemeralSessionConfiguration : NSURLSessionConfiguration.defaultSessionConfiguration;
    self.childSession = [NSURLSession sessionWithConfiguration:configuration];
    __weak typeof(self) weakSelf = self;
    NSURLSessionDataTask *task = [self.childSession dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        dispatch_async(strongSelf.stateQueue, ^{
            [strongSelf finishData:data response:response error:error];
        });
    }];
    self.childTasks = [NSMutableArray arrayWithObject:task];
    [task resume];
}

- (void)endWorkWithReason:(NSError *)reason {
    self.bodyReadCancelled = YES;
    if (self.deadline) { dispatch_source_cancel(self.deadline); self.deadline = nil; }
    [self.childSession invalidateAndCancel];
    self.childSession = nil;
    [self.childTasks removeAllObjects];
    FMXParseCancellation cancel = self.cancelParse;
    self.cancelParse = nil;
    if (cancel) cancel(reason);
    FMXQishuiCancellation cancelQishui = self.cancelQishui;
    self.cancelQishui = nil;
    if (cancelQishui) cancelQishui(reason);
}

- (void)finishData:(NSData *)data response:(NSURLResponse *)response error:(NSError *)error {
    if (self.finished) return;
    self.finished = YES;
    if (!error && !response) error = FMXError(NSURLErrorBadServerResponse, @"原接口未返回响应");
    [self endWorkWithReason:error];
    if (error) { [self.client URLProtocol:self didFailWithError:error]; return; }
    NSString *action=FMXQueryParameters(self.request)[@"action"];
    NSInteger status=[response isKindOfClass:NSHTTPURLResponse.class]?((NSHTTPURLResponse *)response).statusCode:0;
    if(data.length<=4*1024*1024&&status>=200&&status<300&&[@[@"search",@"import_playlist"] containsObject:action?:@""]){
        void (^observer)(id);@synchronized(FMExtensionProtocol.class){observer=FMXMetadataObserver;}
        if(observer&&data.length){id payload=[NSJSONSerialization JSONObjectWithData:data options:0 error:nil];if(payload)observer(payload);}
    }
    // Preserve original HTTP status, headers, response body and non-JSON error responses.
    [self.client URLProtocol:self didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    if (data.length) [self.client URLProtocol:self didLoadData:data];
    [self.client URLProtocolDidFinishLoading:self];
}

- (void)finishPayload:(NSDictionary *)payload error:(NSError *)error {
    if (self.finished) return;
    self.finished = YES;
    if (!error && (!payload || ![NSJSONSerialization isValidJSONObject:payload])) error = FMXError(502, @"音源返回格式无效");
    [self endWorkWithReason:error];
    // The native Kugou parser treats an empty URL as failure and invokes its original backend fallback.
    if (error && FMXKugouParameters(self.request)) { payload = @{@"url":@""}; error = nil; }
    NSData *data = error ? nil : [NSJSONSerialization dataWithJSONObject:payload options:0 error:&error];
    if (error) { [self.client URLProtocol:self didFailWithError:error]; return; }
    NSString *action=FMXQueryParameters(self.request)[@"action"];
    if([@[@"search",@"import_playlist"] containsObject:action?:@""]){void (^observer)(id);@synchronized(FMExtensionProtocol.class){observer=FMXMetadataObserver;}if(observer)observer(payload);}
    NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:self.request.URL statusCode:200 HTTPVersion:@"HTTP/1.1"
        headerFields:@{@"Content-Type":@"application/json; charset=utf-8", @"Cache-Control":@"no-store"}];
    [self.client URLProtocol:self didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    [self.client URLProtocol:self didLoadData:data];
    [self.client URLProtocolDidFinishLoading:self];
}

- (void)stopLoading {
    dispatch_async(self.stateQueue, ^{
        if (self.finished) return;
        self.finished = YES;
        [self endWorkWithReason:FMXError(NSURLErrorCancelled, @"播放请求已取消")];
    });
}

@end
