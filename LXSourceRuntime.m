#import "LXSourceRuntime.h"
#import <JavaScriptCore/JavaScriptCore.h>
#import <CommonCrypto/CommonCrypto.h>
#import <Security/Security.h>
#import <math.h>
#import <dispatch/dispatch.h>

NSString * const LXSourceRuntimeErrorDomain = @"FreeMusic.LXSourceRuntime";
static const NSUInteger LXMaxResponseBytes = 4 * 1024 * 1024;
static const NSUInteger LXMaxRequestBytes = 1024 * 1024;
static NSError *LXError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:LXSourceRuntimeErrorDomain code:code userInfo:@{NSLocalizedDescriptionKey:message ?: @"Source error"}];
}
static NSString *LXJSON(id value) {
    if (![NSJSONSerialization isValidJSONObject:value]) return nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:value options:0 error:nil];
    return data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
}
static NSDictionary *LXJSONObject(NSString *text) {
    NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding];
    id value = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    return [value isKindOfClass:NSDictionary.class] ? value : nil;
}
static BOOL LXIsHTTPURL(NSURL *URL) {
    NSString *scheme = URL.scheme.lowercaseString;
    return URL.host.length && ([scheme isEqualToString:@"https"] || [scheme isEqualToString:@"http"]) && !URL.user.length && !URL.password.length;
}
static NSData *LXBytes(NSArray *values) {
    if (![values isKindOfClass:NSArray.class] || values.count > LXMaxResponseBytes) return nil;
    NSMutableData *data = [NSMutableData dataWithLength:values.count];
    uint8_t *bytes = data.mutableBytes;
    for (NSUInteger i = 0; i < values.count; i++) {
        if (![values[i] isKindOfClass:NSNumber.class]) return nil;
        bytes[i] = [values[i] unsignedCharValue];
    }
    return data;
}
static NSArray *LXByteArray(NSData *data) {
    NSMutableArray *values = [NSMutableArray arrayWithCapacity:data.length];
    const uint8_t *bytes = data.bytes;
    for (NSUInteger i = 0; i < data.length; i++) [values addObject:@(bytes[i])];
    return values;
}
static NSString *LXHex(NSData *data) {
    const uint8_t *bytes = data.bytes;
    NSMutableString *value = [NSMutableString stringWithCapacity:data.length * 2];
    for (NSUInteger i = 0; i < data.length; i++) [value appendFormat:@"%02x", bytes[i]];
    return value;
}
static NSDictionary *LXCodec(NSString *operation, id value, NSString *encoding) {
    encoding = encoding.lowercaseString;
    if ([encoding isEqualToString:@"utf-8"]) encoding = @"utf8";
    if (![@[@"utf8", @"base64", @"hex"] containsObject:encoding]) return @{ @"error": @"Unsupported buffer encoding" };
    if ([operation isEqualToString:@"decode"]) {
        if (![value isKindOfClass:NSString.class] || [value length] > LXMaxResponseBytes * 2) return @{ @"error": @"Invalid or oversized buffer string" };
        NSData *data;
        if ([encoding isEqualToString:@"utf8"]) data = [value dataUsingEncoding:NSUTF8StringEncoding];
        else if ([encoding isEqualToString:@"base64"]) {
            NSMutableString *s = [[value stringByReplacingOccurrencesOfString:@"-" withString:@"+"] mutableCopy];
            [s replaceOccurrencesOfString:@"_" withString:@"/" options:0 range:NSMakeRange(0,s.length)];
            NSString *clean = [[s componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] componentsJoinedByString:@""];
            s = [clean mutableCopy];
            while (s.length % 4) [s appendString:@"="];
            data = [[NSData alloc] initWithBase64EncodedString:s options:0];
        } else {
            NSString *s = value;
            NSMutableData *out = [NSMutableData dataWithCapacity:s.length / 2];
            for (NSUInteger i = 0; i + 1 < s.length; i += 2) {
                unsigned int n = 0;
                NSString *pair = [s substringWithRange:NSMakeRange(i,2)];
                NSScanner *scanner = [NSScanner scannerWithString:pair];
                if (![scanner scanHexInt:&n] || !scanner.isAtEnd) break; // Buffer.from(hex) truncates invalid suffix.
                uint8_t b = (uint8_t)n; [out appendBytes:&b length:1];
            }
            data = out;
        }
        return data ? @{ @"bytes":LXByteArray(data) } : @{ @"error":@"Invalid buffer data" };
    }
    NSData *data = LXBytes(value);
    if (!data) return @{ @"error":@"Invalid byte array" };
    NSString *result;
    if ([encoding isEqualToString:@"hex"]) result = LXHex(data);
    else if ([encoding isEqualToString:@"base64"]) result = [data base64EncodedStringWithOptions:0];
    else result = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    return result ? @{ @"value":result } : @{ @"error":@"Buffer is not valid UTF-8" };
}
static NSDictionary *LXCrypto(NSString *operation, NSDictionary *args) {
    if ([operation isEqualToString:@"md5"]) {
        NSData *data = [args[@"value"] dataUsingEncoding:NSUTF8StringEncoding];
        if (data.length > LXMaxResponseBytes) return @{ @"error":@"MD5 input too large" };
        unsigned char hash[CC_MD5_DIGEST_LENGTH];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        CC_MD5(data.bytes, (CC_LONG)data.length, hash);
#pragma clang diagnostic pop
        return @{ @"value":LXHex([NSData dataWithBytes:hash length:sizeof(hash)]) };
    }
    if ([operation isEqualToString:@"randomBytes"]) {
        NSInteger count = [args[@"size"] integerValue];
        if (count < 0 || count > 65536) return @{ @"error":@"randomBytes size out of range" };
        NSMutableData *data = [NSMutableData dataWithLength:(NSUInteger)count];
        if (count && SecRandomCopyBytes(kSecRandomDefault, data.length, data.mutableBytes) != errSecSuccess) return @{ @"error":@"Secure random unavailable" };
        return @{ @"bytes":LXByteArray(data) };
    }
    if ([operation isEqualToString:@"aesEncrypt"]) {
        NSData *data = LXBytes(args[@"bytes"]), *key = LXBytes(args[@"key"]), *iv = LXBytes(args[@"iv"]);
        NSString *mode = args[@"mode"];
        BOOL ecb = [mode isEqualToString:@"aes-128-ecb"], cbc = [mode isEqualToString:@"aes-128-cbc"];
        if (!ecb && !cbc) return @{ @"error":@"Unsupported AES mode (supported: aes-128-cbc, aes-128-ecb)" };
        if (!data || key.length != kCCKeySizeAES128 || (cbc && iv.length != kCCBlockSizeAES128)) return @{ @"error":@"Invalid AES key/IV/data" };
        NSMutableData *out = [NSMutableData dataWithLength:data.length + kCCBlockSizeAES128];
        size_t count = 0;
        CCCryptorStatus status = CCCrypt(kCCEncrypt, kCCAlgorithmAES, kCCOptionPKCS7Padding | (ecb ? kCCOptionECBMode : 0), key.bytes, key.length, ecb ? NULL : iv.bytes, data.bytes, data.length, out.mutableBytes, out.length, &count);
        if (status != kCCSuccess) return @{ @"error":@"AES encryption failed" };
        out.length = count;
        return @{ @"bytes":LXByteArray(out) };
    }
    return @{ @"error":@"Unsupported crypto operation" };
}

@class LXSourceRuntime;
@interface LXHTTPState : NSObject
@property(nonatomic,copy) NSString *identifier;
@property(nonatomic,strong) NSURLSessionDataTask *task;
@property(nonatomic,strong) NSMutableData *data;
@property(nonatomic,strong) NSHTTPURLResponse *response;
@property(nonatomic) NSUInteger redirects;
@end
@implementation LXHTTPState @end

@interface LXHTTPDelegate : NSObject <NSURLSessionDataDelegate>
@property(nonatomic,weak) LXSourceRuntime *owner;
@end

@interface LXSourceRuntime ()
@property(atomic,copy,readwrite) NSDictionary *manifest;
- (void)installBridge;
- (void)handleEvent:(NSString *)event json:(NSString *)json;
- (void)startHTTP:(NSString *)identifier URL:(NSString *)URL options:(NSDictionary *)options;
- (void)cancelHTTP:(NSString *)identifier;
- (void)startTimer:(NSString *)identifier milliseconds:(double)milliseconds repeat:(BOOL)repeat;
- (void)cancelTimer:(NSString *)identifier;
- (BOOL)finishLoad:(NSError *)error;
- (BOOL)finishResolve:(NSString *)identifier URL:(NSURL *)URL error:(NSError *)error;
- (void)receiveResponse:(NSHTTPURLResponse *)response task:(NSURLSessionTask *)task completion:(void (^)(NSURLSessionResponseDisposition))completion;
- (void)receiveData:(NSData *)data task:(NSURLSessionTask *)task;
- (void)finishHTTPTask:(NSURLSessionTask *)task error:(NSError *)error;
- (void)redirectTask:(NSURLSessionTask *)task request:(NSURLRequest *)request completion:(void (^)(NSURLRequest *))completion;
@end

@implementation LXHTTPDelegate
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveResponse:(NSURLResponse *)response completionHandler:(void (^)(NSURLSessionResponseDisposition))completionHandler {
    LXSourceRuntime *owner = self.owner;
    if (owner) [owner receiveResponse:(NSHTTPURLResponse *)response task:task completion:completionHandler];
    else completionHandler(NSURLSessionResponseCancel);
}
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveData:(NSData *)data { [self.owner receiveData:data task:task]; }
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error { [self.owner finishHTTPTask:task error:error]; }
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task willPerformHTTPRedirection:(NSHTTPURLResponse *)response newRequest:(NSURLRequest *)request completionHandler:(void (^)(NSURLRequest *))completionHandler {
    LXSourceRuntime *owner = self.owner;
    if (owner) [owner redirectTask:task request:request completion:completionHandler]; else completionHandler(nil);
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didReceiveChallenge:(NSURLAuthenticationChallenge *)challenge completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition, NSURLCredential *))completionHandler {
    // Keep platform TLS verification. Never consult app/shared saved credentials.
    if ([challenge.protectionSpace.authenticationMethod isEqualToString:NSURLAuthenticationMethodServerTrust]) completionHandler(NSURLSessionAuthChallengePerformDefaultHandling,nil);
    else completionHandler(NSURLSessionAuthChallengeCancelAuthenticationChallenge,nil);
}
@end

@implementation LXSourceRuntime {
    NSString *_bootstrap;
    dispatch_queue_t _jsQueue;
    dispatch_queue_t _timerQueue;
    NSLock *_lock;
    JSContext *_context; // Access exclusively on _jsQueue.
    NSURLSession *_session;
    LXHTTPDelegate *_HTTPDelegate;
    NSMutableDictionary<NSNumber *,LXHTTPState *> *_HTTPTasks; // lock protected.
    NSMutableDictionary<NSString *,dispatch_source_t> *_timers; // lock protected.
    NSMutableDictionary<NSString *,LXSourceURLCompletion> *_pending; // lock protected.
    LXSourceLoadCompletion _loadCompletion; // lock protected.
    NSDictionary *_proposedManifest; // JS queue only.
    BOOL _started, _invalidated; // lock protected.
    BOOL _evaluated; // JS queue only.
}
- (instancetype)initWithBootstrapScript:(NSString *)bootstrap {
    if ((self = [super init])) {
        _bootstrap = [bootstrap copy];
        _jsQueue = dispatch_queue_create("app.freemusic.lx.javascript", DISPATCH_QUEUE_SERIAL);
        _timerQueue = dispatch_queue_create("app.freemusic.lx.timers", DISPATCH_QUEUE_SERIAL);
        _lock = [NSLock new];
        _HTTPTasks = [NSMutableDictionary dictionary]; _timers = [NSMutableDictionary dictionary]; _pending = [NSMutableDictionary dictionary];
        NSURLSessionConfiguration *configuration = NSURLSessionConfiguration.ephemeralSessionConfiguration;
        configuration.HTTPCookieStorage = nil; configuration.HTTPCookieAcceptPolicy = NSHTTPCookieAcceptPolicyNever;
        configuration.HTTPShouldSetCookies = NO; configuration.URLCredentialStorage = nil; configuration.URLCache = nil;
        configuration.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
        configuration.timeoutIntervalForRequest = 15; configuration.timeoutIntervalForResource = 30;
        configuration.HTTPMaximumConnectionsPerHost = 4;
        configuration.protocolClasses = @[];
        // The app adapter may prepend its class in a global getter hook, so an
        // internal NSURLProtocol request property below is the recursion guard.
        _HTTPDelegate = [LXHTTPDelegate new]; _HTTPDelegate.owner = self;
        NSOperationQueue *delegateQueue = [NSOperationQueue new]; delegateQueue.maxConcurrentOperationCount = 1;
        delegateQueue.name = @"app.freemusic.lx.network";
        _session = [NSURLSession sessionWithConfiguration:configuration delegate:_HTTPDelegate delegateQueue:delegateQueue];
    }
    return self;
}
- (void)dealloc {
    [_session invalidateAndCancel];
    for (dispatch_source_t timer in _timers.allValues) dispatch_source_cancel(timer);
}
- (BOOL)isInvalidated { [_lock lock]; BOOL value = _invalidated; [_lock unlock]; return value; }
- (BOOL)finishLoad:(NSError *)error {
    [_lock lock]; LXSourceLoadCompletion completion = _loadCompletion; _loadCompletion = nil; [_lock unlock];
    if (!completion) return NO;
    NSDictionary *manifest = error ? nil : self.manifest;
    dispatch_async(dispatch_get_main_queue(), ^{ completion(manifest,error); });
    return YES;
}
- (void)loadSource:(NSString *)script name:(NSString *)name timeout:(NSTimeInterval)timeout completion:(LXSourceLoadCompletion)completion {
    [_lock lock];
    BOOL rejected = _started || _invalidated;
    if (!rejected) { _started = YES; _loadCompletion = [completion copy]; }
    [_lock unlock];
    if (rejected) { dispatch_async(dispatch_get_main_queue(), ^{ completion(nil,LXError(1,@"A runtime can load only one source")); }); return; }
    if ([script lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > 2 * 1024 * 1024 || !_bootstrap.length || !script.length) {
        [self finishLoad:LXError(2,@"Missing or oversized source/bootstrap")]; [self invalidate]; return;
    }
    timeout = isfinite(timeout) ? MAX(1,MIN(30,timeout)) : 15;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(timeout*NSEC_PER_SEC)), dispatch_get_global_queue(QOS_CLASS_UTILITY,0), ^{
        typeof(self) self = weakSelf; if (!self) return;
        [self->_lock lock]; BOOL loading = self->_loadCompletion != nil; [self->_lock unlock];
        if (loading && [self finishLoad:LXError(3,@"Source initialization timed out; discard this runtime")]) [self invalidate];
    });
    dispatch_async(_jsQueue, ^{
        @autoreleasepool {
            if ([self isInvalidated]) return;
            self->_context = [[JSContext alloc] initWithVirtualMachine:[JSVirtualMachine new]];
            [self installBridge];
            NSMutableDictionary *info = [@{@"name":name ?: @"Imported source", @"description":@"", @"version":@"", @"author":@"", @"homepage":@"", @"rawScript":script} mutableCopy];
            NSString *header = [script substringToIndex:MIN(script.length,8192)];
            for (NSString *key in @[@"name",@"description",@"version",@"author",@"homepage"]) {
                NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:[NSString stringWithFormat:@"(?m)^\\s*\\*?\\s*@%@\\s+([^\\r\\n]+)",key] options:0 error:nil];
                NSTextCheckingResult *match = [re firstMatchInString:header options:0 range:NSMakeRange(0,header.length)];
                if (match) info[key] = [[header substringWithRange:[match rangeAtIndex:1]] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
            }
            self->_context[@"__LXScriptInfo"] = info;
            [self->_context evaluateScript:self->_bootstrap withSourceURL:[NSURL URLWithString:@"lx-runtime://bootstrap.js"]];
            if (!self->_context.exception) [self->_context evaluateScript:script withSourceURL:[NSURL URLWithString:@"lx-runtime://imported-source.js"]];
            self->_evaluated = YES;
            if ([self isInvalidated]) return;
            if (self->_context.exception) {
                NSString *message = [self->_context.exception toString] ?: @"Source JavaScript error";
                [self finishLoad:LXError(4,message)]; [self invalidate];
            } else if (self->_proposedManifest) {
                self.manifest = self->_proposedManifest;
                [self finishLoad:nil];
            }
        }
    });
}
- (void)installBridge {
    __weak typeof(self) weakSelf = self;
    JSValue *bridge = [JSValue valueWithNewObjectInContext:_context];
    bridge[@"send"] = ^(NSString *event, NSString *json) { [weakSelf handleEvent:event json:json]; };
    bridge[@"request"] = ^(NSString *identifier, NSString *URL, NSString *json) { [weakSelf startHTTP:identifier URL:URL options:LXJSONObject(json)]; };
    bridge[@"cancelHTTP"] = ^(NSString *identifier) { [weakSelf cancelHTTP:identifier]; };
    bridge[@"timer"] = ^(NSString *identifier, double milliseconds, BOOL repeat) { [weakSelf startTimer:identifier milliseconds:milliseconds repeat:repeat]; };
    bridge[@"cancelTimer"] = ^(NSString *identifier) { [weakSelf cancelTimer:identifier]; };
    bridge[@"resolve"] = ^(NSString *identifier, NSString *URL, NSString *error) {
        NSURL *parsed = URL.length ? [NSURL URLWithString:URL] : nil;
        NSError *failure = error.length ? LXError(5,error) : (LXIsHTTPURL(parsed) ? nil : LXError(5,@"Invalid music URL"));
        [weakSelf finishResolve:identifier URL:failure ? nil : parsed error:failure];
    };
    bridge[@"codec"] = ^NSDictionary *(NSString *operation, JSValue *value, NSString *encoding) { return LXCodec(operation,[value toObject],encoding); };
    bridge[@"crypto"] = ^NSDictionary *(NSString *operation, JSValue *args) { return LXCrypto(operation,[args toDictionary]); };
    _context[@"__LXNative"] = bridge;
    _context.exceptionHandler = ^(JSContext *context, JSValue *exception) {
        context.exception = exception;
        typeof(self) self = weakSelf;
        if (self && self->_evaluated && !self.manifest) { [self finishLoad:LXError(4,[exception toString])]; [self invalidate]; }
    };
}
- (void)handleEvent:(NSString *)event json:(NSString *)json {
    if ([self isInvalidated]) return;
    NSDictionary *value = LXJSONObject(json); if (!value) return;
    if ([event isEqualToString:@"inited"]) {
        _proposedManifest = value;
        if (_evaluated) { self.manifest = value; [self finishLoad:nil]; }
    } else if ([event isEqualToString:@"updateAlert"]) {
        dispatch_async(dispatch_get_main_queue(), ^{ if (![self isInvalidated] && self.updateAlertHandler) self.updateAlertHandler(value); });
    }
}
- (NSString *)resolveMusicURLForSource:(NSString *)source musicInfo:(NSDictionary *)musicInfo quality:(NSString *)quality timeout:(NSTimeInterval)timeout completion:(LXSourceURLCompletion)completion {
    NSString *identifier = NSUUID.UUID.UUIDString;
    NSDictionary *sourceInfo = self.manifest[@"sources"][source];
    NSDictionary *payload = @{@"source":source ?: @"", @"action":@"musicUrl", @"info":@{@"type":quality ?: NSNull.null, @"musicInfo":musicInfo ?: @{}}};
    NSString *json = LXJSON(payload);
    BOOL validQuality = [source isEqualToString:@"local"] ? quality == nil : [sourceInfo[@"qualitys"] containsObject:quality ?: @""];
    [_lock lock];
    BOOL unavailable = _invalidated || !sourceInfo || !validQuality || !json || _pending.count >= 16;
    if (!unavailable) _pending[identifier] = [completion copy];
    [_lock unlock];
    if (unavailable) { dispatch_async(dispatch_get_main_queue(), ^{ completion(nil,LXError(6,@"Source unavailable, unsupported quality, invalid metadata, or too many requests")); }); return identifier; }
    timeout = isfinite(timeout) ? MAX(1,MIN(60,timeout)) : 25;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(timeout*NSEC_PER_SEC)), dispatch_get_global_queue(QOS_CLASS_UTILITY,0), ^{
        typeof(self) self = weakSelf; if (!self) return;
        [self->_lock lock];
        LXSourceURLCompletion timedOut = self->_pending[identifier];
        [self->_pending removeObjectForKey:identifier];
        [self->_lock unlock];
        if (timedOut) {
            // Clear the public manifest before notifying the UI, so callers can
            // reliably recognize the discarded runtime in their error handler.
            [self invalidate];
            dispatch_async(dispatch_get_main_queue(), ^{ timedOut(nil,LXError(7,@"Music URL resolution timed out; runtime discarded")); });
        }
    });
    dispatch_async(_jsQueue, ^{ if (![self isInvalidated]) [self->_context[@"__LXResolve"] callWithArguments:@[identifier,json]]; });
    return identifier;
}
- (BOOL)finishResolve:(NSString *)identifier URL:(NSURL *)URL error:(NSError *)error {
    [_lock lock]; LXSourceURLCompletion completion = _pending[identifier]; [_pending removeObjectForKey:identifier]; [_lock unlock];
    if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(URL,error); });
    return completion != nil;
}
- (void)cancelRequestWithIdentifier:(NSString *)identifier {
    [self finishResolve:identifier URL:nil error:LXError(NSUserCancelledError,@"Request cancelled")];
    dispatch_async(_jsQueue, ^{ [self->_context[@"__LXCancelResolve"] callWithArguments:@[identifier]]; });
}
- (void)startTimer:(NSString *)identifier milliseconds:(double)milliseconds repeat:(BOOL)repeat {
    [_lock lock];
    if (_invalidated || _timers.count >= 128) { [_lock unlock]; _context.exception = [JSValue valueWithNewErrorFromMessage:@"Timer limit reached or runtime invalidated" inContext:_context]; return; }
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,0,0,_timerQueue);
    _timers[identifier] = timer;
    uint64_t interval = (uint64_t)(MAX(1,MIN(milliseconds,2147483647)) * NSEC_PER_MSEC);
    dispatch_source_set_timer(timer,dispatch_time(DISPATCH_TIME_NOW,interval),repeat ? interval : DISPATCH_TIME_FOREVER,NSEC_PER_MSEC);
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(timer, ^{
        typeof(self) self = weakSelf; if (!self) return;
        if (!repeat) [self cancelTimer:identifier];
        dispatch_async(self->_jsQueue, ^{ if (![self isInvalidated]) [self->_context[@"__LXTimerFire"] callWithArguments:@[identifier]]; });
    });
    dispatch_resume(timer);
    [_lock unlock];
}
- (void)cancelTimer:(NSString *)identifier {
    [_lock lock]; dispatch_source_t timer = _timers[identifier]; [_timers removeObjectForKey:identifier]; [_lock unlock];
    if (timer) dispatch_source_cancel(timer);
}
- (void)deliverHTTP:(NSString *)identifier response:(NSDictionary *)response error:(NSString *)error {
    NSString *json = response ? LXJSON(response) : @"";
    dispatch_async(_jsQueue, ^{ if (![self isInvalidated]) [self->_context[@"__LXHTTPDone"] callWithArguments:@[identifier,error ?: @"",json ?: @""]]; });
}
- (void)startHTTP:(NSString *)identifier URL:(NSString *)URLString options:(NSDictionary *)options {
    NSURL *URL = [NSURL URLWithString:URLString];
    if (!LXIsHTTPURL(URL) || URLString.length > 16384 || !options) { [self deliverHTTP:identifier response:nil error:@"Invalid HTTP request"]; return; }
    NSTimeInterval timeout = [options[@"timeout"] doubleValue] / 1000.0;
    timeout = isfinite(timeout) ? MAX(1,MIN(timeout,30)) : 15;
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:URL cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:timeout];
    // Local request metadata, not an HTTP header. Prevent a source requesting
    // the app's backend from recursively invoking the app's source adapter.
    [NSURLProtocol setProperty:@YES forKey:@"FMX.internalRequest" inRequest:request];
    NSString *method = [options[@"method"] uppercaseString] ?: @"GET";
    if (![@[@"GET",@"POST",@"PUT",@"PATCH",@"DELETE",@"HEAD",@"OPTIONS"] containsObject:method]) { [self deliverHTTP:identifier response:nil error:@"Unsupported HTTP method"]; return; }
    request.HTTPMethod = method;
    request.HTTPShouldHandleCookies = NO;
    NSDictionary *headers = options[@"headers"];
    if (![headers isKindOfClass:NSDictionary.class] || headers.count > 64) { [self deliverHTTP:identifier response:nil error:@"Invalid headers"]; return; }
    NSCharacterSet *badHeaderName = [[NSCharacterSet characterSetWithCharactersInString:@"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789!#$%&'*+-.^_`|~"] invertedSet];
    NSUInteger headerBytes = 0;
    for (id key in headers) {
        if (![key isKindOfClass:NSString.class] || ![key length] || [key rangeOfCharacterFromSet:badHeaderName].location != NSNotFound || ![headers[key] isKindOfClass:NSString.class] || [headers[key] rangeOfCharacterFromSet:NSCharacterSet.newlineCharacterSet].location != NSNotFound) { [self deliverHTTP:identifier response:nil error:@"Invalid HTTP header"]; return; }
        headerBytes += [key lengthOfBytesUsingEncoding:NSUTF8StringEncoding] + [headers[key] lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
        if (headerBytes > 32768) { [self deliverHTTP:identifier response:nil error:@"HTTP headers exceed 32 KiB"]; return; }
        [request setValue:headers[key] forHTTPHeaderField:key];
    }
    id body = options[@"body"], form = options[@"form"];
    if (form) {
        if ([form isKindOfClass:NSString.class]) body = form;
        else if ([form isKindOfClass:NSDictionary.class]) {
            NSMutableArray *pairs = [NSMutableArray array];
            NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:@"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"];
            for (NSString *key in form) {
                NSString *value = form[key] == NSNull.null ? @"" : [form[key] description];
                [pairs addObject:[NSString stringWithFormat:@"%@=%@",[key stringByAddingPercentEncodingWithAllowedCharacters:allowed],[value stringByAddingPercentEncodingWithAllowedCharacters:allowed]]];
            }
            body = [pairs componentsJoinedByString:@"&"];
        } else { [self deliverHTTP:identifier response:nil error:@"Unsupported form value"]; return; }
        if (![request valueForHTTPHeaderField:@"Content-Type"]) [request setValue:@"application/x-www-form-urlencoded" forHTTPHeaderField:@"Content-Type"];
    } else if ([options[@"jsonBody"] boolValue] && ![request valueForHTTPHeaderField:@"Content-Type"]) [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    if (body && ![body isKindOfClass:NSString.class]) { [self deliverHTTP:identifier response:nil error:@"HTTP body must be a string"]; return; }
    request.HTTPBody = [body dataUsingEncoding:NSUTF8StringEncoding];
    if (request.HTTPBody.length > LXMaxRequestBytes) { [self deliverHTTP:identifier response:nil error:@"HTTP body exceeds 1 MiB"]; return; }
    [_lock lock];
    if (_invalidated || _HTTPTasks.count >= 16) { [_lock unlock]; [self deliverHTTP:identifier response:nil error:@"HTTP concurrency limit reached"]; return; }
    LXHTTPState *state = [LXHTTPState new]; state.identifier = identifier; state.data = [NSMutableData data];
    state.task = [_session dataTaskWithRequest:request]; _HTTPTasks[@(state.task.taskIdentifier)] = state;
    [state.task resume]; [_lock unlock];
}
- (void)cancelHTTP:(NSString *)identifier {
    [_lock lock];
    LXHTTPState *found;
    for (LXHTTPState *state in _HTTPTasks.allValues) if ([state.identifier isEqualToString:identifier]) { found = state; break; }
    if (found) [_HTTPTasks removeObjectForKey:@(found.task.taskIdentifier)];
    [_lock unlock]; [found.task cancel];
}
- (void)receiveResponse:(NSHTTPURLResponse *)response task:(NSURLSessionTask *)task completion:(void (^)(NSURLSessionResponseDisposition))completion {
    [_lock lock]; LXHTTPState *state = _HTTPTasks[@(task.taskIdentifier)];
    // HEAD Content-Length describes the resource a GET would return, not a body
    // transferred by this request. Sources use HEAD to validate large audio URLs.
    BOOL isHead = [task.currentRequest.HTTPMethod.uppercaseString isEqualToString:@"HEAD"];
    BOOL okay = state && [response isKindOfClass:NSHTTPURLResponse.class] && (isHead || response.expectedContentLength <= (int64_t)LXMaxResponseBytes);
    if (okay) state.response = response;
    [_lock unlock];
    completion(okay ? NSURLSessionResponseAllow : NSURLSessionResponseCancel);
    if (!okay && state) [self finishHTTPTask:task error:LXError(8,@"HTTP response exceeds 4 MiB or has invalid type")];
}
- (void)receiveData:(NSData *)data task:(NSURLSessionTask *)task {
    [_lock lock]; LXHTTPState *state = _HTTPTasks[@(task.taskIdentifier)];
    BOOL tooLarge = state && state.data.length + data.length > LXMaxResponseBytes;
    if (state && !tooLarge) [state.data appendData:data];
    [_lock unlock];
    if (tooLarge) { [task cancel]; [self finishHTTPTask:task error:LXError(8,@"HTTP response exceeds 4 MiB")]; }
}
- (void)finishHTTPTask:(NSURLSessionTask *)task error:(NSError *)error {
    [_lock lock]; LXHTTPState *state = _HTTPTasks[@(task.taskIdentifier)]; [_HTTPTasks removeObjectForKey:@(task.taskIdentifier)]; [_lock unlock];
    if (!state) return;
    if (error) { [self deliverHTTP:state.identifier response:nil error:error.localizedDescription]; return; }
    NSString *text = [[NSString alloc] initWithData:state.data encoding:NSUTF8StringEncoding];
    if (!text) { [self deliverHTTP:state.identifier response:nil error:@"Binary/non-UTF-8 HTTP responses are unsupported"]; return; }
    id body = state.data.length ? [NSJSONSerialization JSONObjectWithData:state.data options:NSJSONReadingFragmentsAllowed error:nil] : nil;
    NSMutableDictionary *headers = [NSMutableDictionary dictionary];
    [state.response.allHeaderFields enumerateKeysAndObjectsUsingBlock:^(id key, id value, BOOL *stop) { headers[[[key description] lowercaseString]] = [value description]; }];
    [self deliverHTTP:state.identifier response:@{@"statusCode":@(state.response.statusCode), @"headers":headers, @"body":body ?: text, @"url":state.response.URL.absoluteString ?: @""} error:nil];
}
- (void)redirectTask:(NSURLSessionTask *)task request:(NSURLRequest *)request completion:(void (^)(NSURLRequest *))completion {
    [_lock lock]; LXHTTPState *state = _HTTPTasks[@(task.taskIdentifier)]; BOOL okay = state && ++state.redirects <= 5 && LXIsHTTPURL(request.URL); [_lock unlock];
    if (!okay) { completion(nil); [task cancel]; [self finishHTTPTask:task error:LXError(9,@"Too many redirects or invalid redirect URL")]; return; }
    NSMutableURLRequest *redirect = [request mutableCopy]; redirect.HTTPShouldHandleCookies = NO;
    [NSURLProtocol setProperty:@YES forKey:@"FMX.internalRequest" inRequest:redirect];
    NSURL *oldURL = task.currentRequest.URL;
    if (![oldURL.host.lowercaseString isEqualToString:request.URL.host.lowercaseString] || ![oldURL.scheme.lowercaseString isEqualToString:request.URL.scheme.lowercaseString] || ![(oldURL.port ?: @0) isEqual:(request.URL.port ?: @0)]) {
        [redirect setValue:nil forHTTPHeaderField:@"Cookie"]; [redirect setValue:nil forHTTPHeaderField:@"Authorization"];
    }
    completion(redirect);
}
- (void)invalidate {
    [_lock lock];
    if (_invalidated) { [_lock unlock]; return; }
    _invalidated = YES;
    NSArray *tasks = _HTTPTasks.allValues; [_HTTPTasks removeAllObjects];
    NSArray *timers = _timers.allValues; [_timers removeAllObjects];
    NSDictionary *pending = [_pending copy]; [_pending removeAllObjects];
    LXSourceLoadCompletion load = _loadCompletion; _loadCompletion = nil;
    [_lock unlock];
    for (LXHTTPState *state in tasks) [state.task cancel];
    for (dispatch_source_t timer in timers) dispatch_source_cancel(timer);
    [_session invalidateAndCancel];
    self.manifest = nil;
    NSError *error = LXError(NSUserCancelledError,@"Source runtime invalidated");
    dispatch_async(dispatch_get_main_queue(), ^{
        if (load) load(nil,error);
        for (LXSourceURLCompletion completion in pending.allValues) completion(nil,error);
    });
    dispatch_async(_jsQueue, ^{
        [self->_context[@"__LXDispose"] callWithArguments:@[]];
        self->_context.exceptionHandler = nil; self->_context = nil; self->_proposedManifest = nil;
    });
}
@end
