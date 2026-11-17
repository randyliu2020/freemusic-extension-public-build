#import "LXSourceRuntime.h"
#import <JavaScriptCore/JavaScriptCore.h>
#import <CommonCrypto/CommonCrypto.h>
#import <Security/Security.h>
#import <math.h>
#import <dispatch/dispatch.h>
#import <string.h>

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
static NSString *LXHTTPStatusMessage(NSInteger status) {
    // NSURLSession does not expose a custom HTTP/1 reason phrase. Supply the
    // standard phrase used by LX callbacks for common API responses.
    NSDictionary *phrases=@{@200:@"OK",@201:@"Created",@202:@"Accepted",@204:@"No Content",@206:@"Partial Content",
        @301:@"Moved Permanently",@302:@"Found",@303:@"See Other",@304:@"Not Modified",@307:@"Temporary Redirect",@308:@"Permanent Redirect",
        @400:@"Bad Request",@401:@"Unauthorized",@403:@"Forbidden",@404:@"Not Found",@405:@"Method Not Allowed",@408:@"Request Timeout",
        @409:@"Conflict",@410:@"Gone",@413:@"Payload Too Large",@416:@"Range Not Satisfiable",@422:@"Unprocessable Entity",@429:@"Too Many Requests",
        @500:@"Internal Server Error",@502:@"Bad Gateway",@503:@"Service Unavailable",@504:@"Gateway Timeout"};
    return phrases[@(status)] ?: [NSHTTPURLResponse localizedStringForStatusCode:status] ?: @"";
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
// Security imports RSA public keys as PKCS#1. LX sources commonly supply
// X.509/SPKI PUBLIC KEY PEM, so unwrap only the exact RSA algorithm structure.
static BOOL LXDERItem(NSData *data, NSUInteger *offset, uint8_t tag, NSRange *payload) {
    const uint8_t *p=data.bytes; NSUInteger limit=data.length, cursor=*offset;
    if(cursor+2>limit || p[cursor++]!=tag)return NO;
    NSUInteger size=p[cursor++];
    if(size&0x80){
        NSUInteger count=size&0x7f;size=0;
        if(count==0||count>4||cursor+count>limit||p[cursor]==0)return NO;
        for(NSUInteger i=0;i<count;i++)size=(size<<8)|p[cursor++];
        if(size<128)return NO;
    }
    if(size>limit-cursor)return NO;
    *payload=NSMakeRange(cursor,size);*offset=cursor+size;return YES;
}
static NSData *LXRSAPublicKeyData(NSString *text) {
    if(![text isKindOfClass:NSString.class]||text.length>16384||[text containsString:@"PRIVATE KEY"])return nil;
    NSString *base64=text;
    for(NSString *marker in @[@"-----BEGIN PUBLIC KEY-----",@"-----END PUBLIC KEY-----",@"-----BEGIN RSA PUBLIC KEY-----",@"-----END RSA PUBLIC KEY-----"])
        base64=[base64 stringByReplacingOccurrencesOfString:marker withString:@""];
    base64=[[base64 componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] componentsJoinedByString:@""];
    NSData *der=[[NSData alloc] initWithBase64EncodedString:base64 options:0];
    if(!der.length||der.length>8192)return nil;
    NSUInteger outer=0;NSRange sequence;
    if(!LXDERItem(der,&outer,0x30,&sequence)||outer!=der.length)return nil;
    NSData *contents=[der subdataWithRange:sequence];const uint8_t *p=contents.bytes;
    if(!contents.length)return nil;
    if(p[0]==0x02){
        NSUInteger pos=0;NSRange modulus,exponent;
        if(!LXDERItem(contents,&pos,0x02,&modulus)||!modulus.length||!LXDERItem(contents,&pos,0x02,&exponent)||!exponent.length||pos!=contents.length)return nil;
        return der;
    }
    NSUInteger pos=0;NSRange algorithm,bits;
    if(!LXDERItem(contents,&pos,0x30,&algorithm)||!LXDERItem(contents,&pos,0x03,&bits)||pos!=contents.length||bits.length<2||p[bits.location]!=0)return nil;
    static const uint8_t rsaOID[]={0x06,0x09,0x2a,0x86,0x48,0x86,0xf7,0x0d,0x01,0x01,0x01};
    NSData *alg=[contents subdataWithRange:algorithm];
    if(!((alg.length==sizeof(rsaOID)||alg.length==sizeof(rsaOID)+2)&&memcmp(alg.bytes,rsaOID,sizeof(rsaOID))==0))return nil;
    if(alg.length>sizeof(rsaOID)){const uint8_t *a=alg.bytes;if(a[sizeof(rsaOID)]!=0x05||a[sizeof(rsaOID)+1]!=0)return nil;}
    NSData *pkcs1=[contents subdataWithRange:NSMakeRange(bits.location+1,bits.length-1)];
    NSUInteger check=0;NSRange pkcs1Sequence;
    if(!LXDERItem(pkcs1,&check,0x30,&pkcs1Sequence)||check!=pkcs1.length||!pkcs1Sequence.length||((const uint8_t *)pkcs1.bytes)[pkcs1Sequence.location]!=0x02)return nil;
    return LXRSAPublicKeyData([pkcs1 base64EncodedStringWithOptions:0]);
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
        // Official LX mobile uses CBC/PKCS7 but ECB/NoPadding.
        if(ecb && data.length % kCCBlockSizeAES128)return @{ @"error":@"AES ECB NoPadding input must be a multiple of 16 bytes" };
        CCCryptorStatus status = CCCrypt(kCCEncrypt, kCCAlgorithmAES, ecb ? kCCOptionECBMode : kCCOptionPKCS7Padding, key.bytes, key.length, ecb ? NULL : iv.bytes, data.bytes, data.length, out.mutableBytes, out.length, &count);
        if (status != kCCSuccess) return @{ @"error":@"AES encryption failed" };
        out.length = count;
        return @{ @"bytes":LXByteArray(out) };
    }
    if ([operation isEqualToString:@"rsaEncrypt"]) {
        NSData *data=LXBytes(args[@"bytes"]), *der=LXRSAPublicKeyData(args[@"key"]);
        if(!data||!der)return @{@"error":@"Invalid RSA public key or data"};
        CFErrorRef error=NULL;
        SecKeyRef key=SecKeyCreateWithData((__bridge CFDataRef)der,(__bridge CFDictionaryRef)@{(__bridge id)kSecAttrKeyType:(__bridge id)kSecAttrKeyTypeRSA,(__bridge id)kSecAttrKeyClass:(__bridge id)kSecAttrKeyClassPublic},&error);
        if(error)CFRelease(error);
        if(!key)return @{@"error":@"Invalid RSA public key"};
        size_t length=SecKeyGetBlockSize(key);
        if(length<64||length>1024||data.length>length||!SecKeyIsAlgorithmSupported(key,kSecKeyOperationTypeEncrypt,kSecKeyAlgorithmRSAEncryptionRaw)){
            CFRelease(key);return @{@"error":@"RSA NoPadding input/key size unsupported"};
        }
        // Java RSA/ECB/NoPadding left-pads a short positive integer to the
        // modulus size. Apple raw RSA requires that complete sized block.
        NSMutableData *block=[NSMutableData dataWithLength:length];
        if(data.length)memcpy((uint8_t *)block.mutableBytes+length-data.length,data.bytes,data.length);
        error=NULL;
        NSData *encrypted=CFBridgingRelease(SecKeyCreateEncryptedData(key,kSecKeyAlgorithmRSAEncryptionRaw,(__bridge CFDataRef)block,&error));
        CFRelease(key);if(error)CFRelease(error);
        if(!encrypted||encrypted.length!=length)return @{@"error":@"RSA NoPadding encryption failed"};
        return @{@"bytes":LXByteArray(encrypted)};
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
@property(nonatomic) BOOL binary;
@end
@implementation LXHTTPState @end

@interface LXIsolatedResolution : NSObject
@property(nonatomic,strong) LXSourceRuntime *worker;
@property(nonatomic,copy) LXSourceURLCompletion completion;
@property(nonatomic,strong) dispatch_source_t deadlineTimer;
@property(nonatomic) NSTimeInterval deadline;
@end
@implementation LXIsolatedResolution @end

@interface LXHTTPDelegate : NSObject <NSURLSessionDataDelegate>
@property(nonatomic,weak) LXSourceRuntime *owner;
@end

@interface LXSourceRuntime ()
@property(atomic,copy,readwrite) NSDictionary *manifest;
- (void)installBridge;
- (void)handleEvent:(NSString *)event json:(NSString *)json;
- (void)startHTTP:(NSString *)identifier URL:(NSString *)URL options:(NSDictionary *)options;
- (void)cancelHTTP:(NSString *)identifier;
- (void)cancelSoftResolutionOnJSQueue:(NSString *)identifier;
- (void)startTimer:(NSString *)identifier milliseconds:(double)milliseconds repeat:(BOOL)repeat;
- (void)cancelTimer:(NSString *)identifier;
- (BOOL)finishLoad:(NSError *)error;
- (BOOL)finishResolve:(NSString *)identifier URL:(NSURL *)URL error:(NSError *)error;
- (BOOL)finishIsolatedResolution:(NSString *)identifier URL:(NSURL *)URL error:(NSError *)error;
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
    NSString *_sourceSnapshot, *_sourceName;
    dispatch_queue_t _jsQueue;
    dispatch_queue_t _timerQueue;
    NSLock *_lock;
    JSContext *_context; // Access exclusively on _jsQueue.
    NSURLSession *_session;
    LXHTTPDelegate *_HTTPDelegate;
    NSMutableDictionary<NSNumber *,LXHTTPState *> *_HTTPTasks; // lock protected.
    NSMutableDictionary<NSString *,dispatch_source_t> *_timers; // lock protected.
    NSMutableDictionary<NSString *,LXSourceURLCompletion> *_pending; // lock protected.
    NSMutableSet<NSString *> *_softResolutions; // lock protected; opt-in quality attempts only.
    NSMutableDictionary<NSString *,LXIsolatedResolution *> *_isolatedResolutions; // lock protected.
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
        _HTTPTasks = [NSMutableDictionary dictionary]; _timers = [NSMutableDictionary dictionary]; _pending = [NSMutableDictionary dictionary]; _softResolutions = NSMutableSet.set;
        _isolatedResolutions=NSMutableDictionary.dictionary;
        NSURLSessionConfiguration *configuration = NSURLSessionConfiguration.ephemeralSessionConfiguration;
        configuration.HTTPCookieStorage = nil; configuration.HTTPCookieAcceptPolicy = NSHTTPCookieAcceptPolicyNever;
        configuration.HTTPShouldSetCookies = NO; configuration.URLCredentialStorage = nil; configuration.URLCache = nil;
        configuration.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
        configuration.timeoutIntervalForRequest = 13; configuration.timeoutIntervalForResource = 60;
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
    for(LXIsolatedResolution *attempt in _isolatedResolutions.allValues){
        if(attempt.deadlineTimer)dispatch_source_cancel(attempt.deadlineTimer);
        [attempt.worker invalidate];
        LXSourceURLCompletion completion=attempt.completion;
        if(completion)dispatch_async(dispatch_get_main_queue(),^{completion(nil,LXError(NSUserCancelledError,@"Source owner released"));});
    }
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
    script=[script copy];name=[name copy]?:@"Imported source";
    [_lock lock];
    if(!_invalidated){_sourceSnapshot=script;_sourceName=name;}
    [_lock unlock];
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
    return [self resolveMusicURLForSource:source musicInfo:musicInfo quality:quality timeout:timeout invalidateOnTimeout:YES completion:completion];
}
- (NSString *)resolveMusicURLForSource:(NSString *)source musicInfo:(NSDictionary *)musicInfo quality:(NSString *)quality timeout:(NSTimeInterval)timeout invalidateOnTimeout:(BOOL)invalidateOnTimeout completion:(LXSourceURLCompletion)completion {
    NSString *identifier = NSUUID.UUID.UUIDString;
    NSDictionary *sourceInfo = self.manifest[@"sources"][source];
    NSDictionary *payload = @{@"source":source ?: @"", @"action":@"musicUrl", @"info":@{@"type":quality ?: NSNull.null, @"musicInfo":musicInfo ?: @{}}};
    NSString *json = LXJSON(payload);
    BOOL validQuality = [source isEqualToString:@"local"] ? quality == nil : [sourceInfo[@"qualitys"] containsObject:quality ?: @""];
    [_lock lock];
    BOOL unavailable = _invalidated || !sourceInfo || !validQuality || !json || _pending.count+_isolatedResolutions.count >= 16;
    if (!unavailable) {
        _pending[identifier] = [completion copy];
        if (!invalidateOnTimeout) [_softResolutions addObject:identifier];
    }
    [_lock unlock];
    if (unavailable) { dispatch_async(dispatch_get_main_queue(), ^{ completion(nil,LXError(6,@"Source unavailable, unsupported quality, invalid metadata, or too many requests")); }); return identifier; }
    timeout = isfinite(timeout) ? MAX(invalidateOnTimeout ? 1 : 0.01,MIN(60,timeout)) : 25;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(timeout*NSEC_PER_SEC)), dispatch_get_global_queue(QOS_CLASS_UTILITY,0), ^{
        typeof(self) self = weakSelf; if (!self) return;
        [self->_lock lock];
        LXSourceURLCompletion timedOut = self->_pending[identifier];
        [self->_pending removeObjectForKey:identifier];
        [self->_softResolutions removeObject:identifier];
        [self->_lock unlock];
        if (timedOut) {
            if (invalidateOnTimeout) {
                // Preserve the original hard-timeout contract.
                [self invalidate];
            } else [self cancelSoftResolutionOnJSQueue:identifier];
            dispatch_async(dispatch_get_main_queue(), ^{ timedOut(nil,LXError(7,invalidateOnTimeout ? @"Music URL resolution timed out; runtime discarded" : @"Quality attempt timed out")); });
        }
    });
    dispatch_async(_jsQueue, ^{ if (![self isInvalidated]) [self->_context[@"__LXResolve"] callWithArguments:@[identifier,json]]; });
    return identifier;
}
- (NSString *)resolveIsolatedMusicURLForSource:(NSString *)source musicInfo:(NSDictionary *)musicInfo quality:(NSString *)quality timeout:(NSTimeInterval)timeout completion:(LXSourceURLCompletion)completion {
    NSTimeInterval began=NSProcessInfo.processInfo.systemUptime;
    timeout=isfinite(timeout)?MAX(0.01,MIN(20,timeout)):20;
    NSString *identifier=NSUUID.UUID.UUIDString;
    // Freeze caller-owned mutable metadata as well as the source text. The copy
    // does not add app credentials or expose either snapshot through diagnostics.
    NSString *json=LXJSON(@{@"source":source?:@"",@"info":@{@"type":quality?:NSNull.null,@"musicInfo":musicInfo?:@{}}});
    NSDictionary *payload=json?LXJSONObject(json):nil;
    NSString *platform=payload[@"source"];
    NSString *type=payload[@"info"][@"type"]==NSNull.null?nil:payload[@"info"][@"type"];
    NSDictionary *metadata=payload[@"info"][@"musicInfo"];
    NSDictionary *sourceInfo=self.manifest[@"sources"][platform?:@""];
    BOOL validQuality=[platform isEqual:@"local"]?type==nil:[sourceInfo[@"qualitys"] containsObject:type?:@""];
    LXIsolatedResolution *attempt=LXIsolatedResolution.new;
    attempt.completion=[completion copy];attempt.deadline=began+timeout;
    NSString *script,*name,*bootstrap;
    __weak typeof(self) weakSelf=self;
    [_lock lock];
    BOOL unavailable=_invalidated||!sourceInfo||!validQuality||!payload||!_sourceSnapshot.length||_pending.count+_isolatedResolutions.count>=16;
    if(!unavailable){
        script=_sourceSnapshot;name=_sourceName;bootstrap=_bootstrap;
        _isolatedResolutions[identifier]=attempt;
        attempt.deadlineTimer=dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,0,0,_timerQueue);
        NSTimeInterval remaining=MAX(0,attempt.deadline-NSProcessInfo.processInfo.systemUptime);
        dispatch_source_set_timer(attempt.deadlineTimer,dispatch_time(DISPATCH_TIME_NOW,(int64_t)(remaining*NSEC_PER_SEC)),DISPATCH_TIME_FOREVER,0);
        dispatch_source_set_event_handler(attempt.deadlineTimer,^{
            [weakSelf finishIsolatedResolution:identifier URL:nil error:LXError(7,@"Isolated music URL resolution timed out")];
        });
        dispatch_resume(attempt.deadlineTimer);
    }
    [_lock unlock];
    if(unavailable){dispatch_async(dispatch_get_main_queue(),^{completion(nil,LXError(6,@"Source unavailable, unsupported quality, invalid metadata, or too many requests"));});return identifier;}
    LXSourceRuntime *worker=[[LXSourceRuntime alloc]initWithBootstrapScript:bootstrap];
    [_lock lock];
    BOOL current=_isolatedResolutions[identifier]==attempt&&!_invalidated;
    if(current)attempt.worker=worker;
    [_lock unlock];
    if(!current){[worker invalidate];return identifier;}
    __weak LXSourceRuntime *weakWorker=worker;
    [worker loadSource:script name:name timeout:MAX(0.01,attempt.deadline-NSProcessInfo.processInfo.systemUptime) completion:^(NSDictionary *manifest,NSError *error){
        LXSourceRuntime *parent=weakSelf,*activeWorker=weakWorker;
        if(!parent||!activeWorker){[activeWorker invalidate];return;}
        [parent->_lock lock];
        BOOL active=parent->_isolatedResolutions[identifier]==attempt&&!parent->_invalidated;
        NSTimeInterval remaining=attempt.deadline-NSProcessInfo.processInfo.systemUptime;
        [parent->_lock unlock];
        if(!active){[activeWorker invalidate];return;}
        if(error||!manifest){[parent finishIsolatedResolution:identifier URL:nil error:error?:LXError(4,@"Worker source initialization failed")];return;}
        if(remaining<=0){[parent finishIsolatedResolution:identifier URL:nil error:LXError(7,@"Isolated music URL resolution timed out")];return;}
        // A hard timeout is safe here: only this invocation owns the worker.
        [activeWorker resolveMusicURLForSource:platform musicInfo:metadata quality:type timeout:remaining completion:^(NSURL *URL,NSError *failure){
            [weakSelf finishIsolatedResolution:identifier URL:URL error:failure];
        }];
    }];
    return identifier;
}
- (BOOL)finishIsolatedResolution:(NSString *)identifier URL:(NSURL *)URL error:(NSError *)error {
    [_lock lock];
    LXIsolatedResolution *attempt=_isolatedResolutions[identifier];
    if(attempt)[_isolatedResolutions removeObjectForKey:identifier];
    [_lock unlock];
    if(!attempt)return NO;
    if(attempt.deadlineTimer)dispatch_source_cancel(attempt.deadlineTimer);
    [attempt.worker invalidate];
    if(!error&&NSProcessInfo.processInfo.systemUptime>=attempt.deadline)error=LXError(7,@"Isolated music URL resolution timed out");
    LXSourceURLCompletion completion=attempt.completion;
    dispatch_async(dispatch_get_main_queue(),^{completion(error?nil:URL,error);});
    return YES;
}
- (BOOL)finishResolve:(NSString *)identifier URL:(NSURL *)URL error:(NSError *)error {
    [_lock lock]; LXSourceURLCompletion completion = _pending[identifier]; [_pending removeObjectForKey:identifier]; [_softResolutions removeObject:identifier]; [_lock unlock];
    if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(URL,error); });
    return completion != nil;
}
- (void)cancelSoftResolutionOnJSQueue:(NSString *)identifier {
    // Native completion is independent of JavaScript. A cooperative script loses
    // its late result; an unresponsive context is discarded, never force-stopped.
    __block BOOL acknowledged = NO;
    dispatch_async(_jsQueue, ^{
        [self->_context[@"__LXCancelResolve"] callWithArguments:@[identifier]];
        [self->_lock lock]; acknowledged = YES; [self->_lock unlock];
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_global_queue(QOS_CLASS_UTILITY,0), ^{
        [self->_lock lock]; BOOL responsive = acknowledged || self->_invalidated; [self->_lock unlock];
        if (!responsive) [self invalidate];
    });
}
- (void)cancelRequestWithIdentifier:(NSString *)identifier {
    if([self finishIsolatedResolution:identifier URL:nil error:LXError(NSUserCancelledError,@"Request cancelled")])return;
    [_lock lock]; BOOL soft = [_softResolutions containsObject:identifier]; [_lock unlock];
    [self finishResolve:identifier URL:nil error:LXError(NSUserCancelledError,@"Request cancelled")];
    if (soft) [self cancelSoftResolutionOnJSQueue:identifier];
    else dispatch_async(_jsQueue, ^{ [self->_context[@"__LXCancelResolve"] callWithArguments:@[identifier]]; });
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
    timeout = isfinite(timeout) && timeout>0 ? MAX(0.001,MIN(timeout,60)) : 13;
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:URL cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:timeout];
    // Local request metadata, not an HTTP header. Prevent a source requesting
    // the app's backend from recursively invoking the app's source adapter.
    [NSURLProtocol setProperty:@YES forKey:@"FMX.internalRequest" inRequest:request];
    NSString *method = [options[@"method"] uppercaseString] ?: @"GET";
    if (![@[@"GET",@"POST",@"PUT",@"PATCH",@"DELETE",@"HEAD",@"OPTIONS"] containsObject:method]) { [self deliverHTTP:identifier response:nil error:@"Unsupported HTTP method"]; return; }
    request.HTTPMethod = method;
    request.HTTPShouldHandleCookies = NO;
    [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    [request setValue:@"Mozilla/5.0 (Windows NT 10.0; WOW64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/69.0.3497.100 Safari/537.36" forHTTPHeaderField:@"User-Agent"];
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
    id body = options[@"body"], form = options[@"form"], multipart=options[@"multipart"], encodedBody=options[@"bodyBase64"];
    if((NSUInteger)(body!=nil||encodedBody!=nil)+(NSUInteger)(form!=nil)+(NSUInteger)(multipart!=nil)>1){[self deliverHTTP:identifier response:nil error:@"Conflicting HTTP bodies"];return;}
    NSData *requestData=nil;
    if(multipart){
        if(![multipart isKindOfClass:NSArray.class]||[multipart count]>128){[self deliverHTTP:identifier response:nil error:@"Invalid multipart fields"];return;}
        NSString *boundary=[@"LX-" stringByAppendingString:NSUUID.UUID.UUIDString];
        NSMutableData *out=NSMutableData.data;
        NSCharacterSet *bad=NSCharacterSet.controlCharacterSet;
        for(id item in multipart){
            if(![item isKindOfClass:NSDictionary.class]){[self deliverHTTP:identifier response:nil error:@"Invalid multipart part"];return;}
            NSString *name=item[@"name"],*filename=item[@"filename"],*contentType=item[@"contentType"],*encoded=item[@"data"];
            BOOL valid=[name isKindOfClass:NSString.class]&&name.length<=256&&[name rangeOfCharacterFromSet:bad].location==NSNotFound;
            for(id optional in @[filename ?: @"",contentType ?: @""])valid=valid&&[optional isKindOfClass:NSString.class]&&[optional length]<=512&&[optional rangeOfCharacterFromSet:bad].location==NSNotFound;
            if(!valid||![encoded isKindOfClass:NSString.class]||encoded.length>LXMaxRequestBytes*2){[self deliverHTTP:identifier response:nil error:@"Invalid multipart header or data"];return;}
            NSData *part=[[NSData alloc] initWithBase64EncodedString:encoded options:0];
            if(!part){[self deliverHTTP:identifier response:nil error:@"Invalid multipart bytes"];return;}
            NSString *(^quote)(NSString *)=^NSString *(NSString *s){return [[s stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"] stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""];};
            NSMutableString *header=[NSMutableString stringWithFormat:@"--%@\r\nContent-Disposition: form-data; name=\"%@\"",boundary,quote(name)];
            if(filename)[header appendFormat:@"; filename=\"%@\"",quote(filename)];
            [header appendString:@"\r\n"];
            if(contentType.length)[header appendFormat:@"Content-Type: %@\r\n",contentType];
            [header appendString:@"\r\n"];
            [out appendData:[header dataUsingEncoding:NSUTF8StringEncoding]];[out appendData:part];[out appendData:[@"\r\n" dataUsingEncoding:NSUTF8StringEncoding]];
            if(out.length>LXMaxRequestBytes){[self deliverHTTP:identifier response:nil error:@"HTTP body exceeds 1 MiB"];return;}
        }
        [out appendData:[[NSString stringWithFormat:@"--%@--\r\n",boundary] dataUsingEncoding:NSUTF8StringEncoding]];
        [request setValue:[NSString stringWithFormat:@"multipart/form-data; boundary=%@",boundary] forHTTPHeaderField:@"Content-Type"];
        requestData=out;
    } else if(encodedBody){
        if(![encodedBody isKindOfClass:NSString.class]||[encodedBody length]>LXMaxRequestBytes*2){[self deliverHTTP:identifier response:nil error:@"Invalid binary body"];return;}
        requestData=[[NSData alloc] initWithBase64EncodedString:encodedBody options:0];
        if(!requestData){[self deliverHTTP:identifier response:nil error:@"Invalid binary body"];return;}
        if(![request valueForHTTPHeaderField:@"Content-Type"])[request setValue:@"application/octet-stream" forHTTPHeaderField:@"Content-Type"];
    }
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
    request.HTTPBody = requestData ?: [body dataUsingEncoding:NSUTF8StringEncoding];
    if (request.HTTPBody.length > LXMaxRequestBytes) { [self deliverHTTP:identifier response:nil error:@"HTTP body exceeds 1 MiB"]; return; }
    [_lock lock];
    if (_invalidated || _HTTPTasks.count >= 16) { [_lock unlock]; [self deliverHTTP:identifier response:nil error:@"HTTP concurrency limit reached"]; return; }
    LXHTTPState *state = [LXHTTPState new]; state.identifier = identifier; state.data = [NSMutableData data];state.binary=[options[@"binary"] boolValue];
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
    NSString *text = state.binary ? nil : [[NSString alloc] initWithData:state.data encoding:NSUTF8StringEncoding];
    if (!state.binary && !text) { [self deliverHTTP:state.identifier response:nil error:@"Non-UTF-8 response requires binary:true"]; return; }
    id body = !state.binary && state.data.length ? [NSJSONSerialization JSONObjectWithData:state.data options:NSJSONReadingFragmentsAllowed error:nil] : nil;
    NSMutableDictionary *headers = [NSMutableDictionary dictionary];
    [state.response.allHeaderFields enumerateKeysAndObjectsUsingBlock:^(id key, id value, BOOL *stop) { headers[[[key description] lowercaseString]] = [value description]; }];
    NSMutableDictionary *response=[@{@"statusCode":@(state.response.statusCode),@"statusMessage":LXHTTPStatusMessage(state.response.statusCode), @"headers":headers, @"url":state.response.URL.absoluteString ?: @""} mutableCopy];
    if(state.binary)response[@"bodyBase64"]=[state.data base64EncodedStringWithOptions:0];else response[@"body"]=body ?: text;
    [self deliverHTTP:state.identifier response:response error:nil];
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
    NSDictionary *pending = [_pending copy]; [_pending removeAllObjects]; [_softResolutions removeAllObjects];
    NSArray<LXIsolatedResolution *> *isolated=_isolatedResolutions.allValues;[_isolatedResolutions removeAllObjects];
    _sourceSnapshot=nil;_sourceName=nil;
    LXSourceLoadCompletion load = _loadCompletion; _loadCompletion = nil;
    [_lock unlock];
    for (LXHTTPState *state in tasks) [state.task cancel];
    for (dispatch_source_t timer in timers) dispatch_source_cancel(timer);
    for(LXIsolatedResolution *attempt in isolated){if(attempt.deadlineTimer)dispatch_source_cancel(attempt.deadlineTimer);[attempt.worker invalidate];}
    [_session invalidateAndCancel];
    self.manifest = nil;
    NSError *error = LXError(NSUserCancelledError,@"Source runtime invalidated");
    dispatch_async(dispatch_get_main_queue(), ^{
        if (load) load(nil,error);
        for (LXSourceURLCompletion completion in pending.allValues) completion(nil,error);
        for (LXIsolatedResolution *attempt in isolated) attempt.completion(nil,error);
    });
    dispatch_async(_jsQueue, ^{
        [self->_context[@"__LXDispose"] callWithArguments:@[]];
        self->_context.exceptionHandler = nil; self->_context = nil; self->_proposedManifest = nil;
    });
}
@end
