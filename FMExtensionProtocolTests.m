#import "FMExtensionProtocol.h"
#import "FMLXMC.h"
#import "FMTrackMetadata.h"
#import "FMQishuiSearch.h"
#import <objc/runtime.h>
#import <sys/socket.h>
#import <netinet/in.h>
#import <unistd.h>
#import <stdatomic.h>

static NSUInteger failures;
static NSMutableArray<NSDictionary *> *checkRows;
static NSString *checkScope = @"legacy";
static NSUInteger rankingLoopbackRequests, rankingQishuiCalls, rankingSessionCallbacks;
static void SetCheckScope(NSString *scope) { @synchronized(checkRows) { checkScope = scope; } }
static void Check(BOOL condition, NSString *name) {
    @synchronized(checkRows) {
        [checkRows addObject:@{@"ordinal":@(checkRows.count + 1), @"name":name, @"scope":checkScope, @"passed":@(condition)}];
        if (!condition) { failures++; fprintf(stderr, "FAIL: %s\n", name.UTF8String); }
    }
}

static NSDictionary *SearchTrack(NSString *source, NSString *identifier, NSString *title, NSString *singer) {
    return @{@"server":source, @"id":identifier, @"title":title, @"singer":singer};
}
static NSDictionary *SearchResponse(NSArray *tracks, NSInteger total) {
    return @{@"code":@200, @"data":tracks, @"total":@(total)};
}
static NSArray *SearchPairs(NSDictionary *response) {
    NSMutableArray *pairs = NSMutableArray.array;
    for (NSDictionary *track in response[@"data"]) [pairs addObject:@[track[@"server"], track[@"id"]]];
    return pairs;
}

static void RunSearchRankingTests(void) {
    SetCheckScope(@"ranking.semantic");
    NSDictionary *wrongArtist = SearchTrack(@"kg", @"other", @"知足", @"另一位歌手");
    NSDictionary *duet = SearchTrack(@"qq", @"duet", @"知足", @"于文文 / 胡彦斌");
    NSDictionary *live = SearchTrack(@"wy", @"live", @"知足（Live版）", @"于文文 / 胡彦斌");
    NSDictionary *unrelated = SearchTrack(@"wy", @"unrelated", @"远方", @"其他歌手");
    NSArray *sources = @[SearchResponse(@[wrongArtist, unrelated], 20), SearchResponse(@[live, duet], 30)];
    NSDictionary *result = FMXMergeSearchResponsesForKeyword(sources, 0, @"知足 于文文 胡彦斌");
    Check([result[@"data"][0] isEqual:duet] && [result[@"data"][1] isEqual:live],
          @"rank exact title with both named singers before the same-title other singer, retaining the live version");
    Check([FMXMergeSearchResponsesForKeyword(sources, 0, @"于文文 胡彦斌 知足")[@"data"][0] isEqual:duet],
          @"rank artist-before-title query as the same exact combination");
    NSDictionary *tokens = FMXMergeSearchResponsesForKeyword(sources, 0, @"胡彦斌 知足 于文文");
    Check([tokens[@"data"][0] isEqual:duet] && [tokens[@"data"][1] isEqual:live],
          @"unordered title and singer tokens prefer the plain title slightly without removing its live version");
    Check([FMXMergeSearchResponsesForKeyword(sources, 0, @"胡彦斌 知足 Live")[@"data"][0] isEqual:live],
          @"explicit live token still takes precedence over the plain-title token bonus");

    NSDictionary *artistOnly = @{@"server":@"qq", @"id":@"artist", @"title":@"另一首", @"singer":NSNull.null, @"artist":@"胡彦斌"};
    NSDictionary *nameMention = SearchTrack(@"kg", @"mention", @"致胡彦斌", @"其他歌手");
    Check([FMXMergeSearchResponsesForKeyword(@[SearchResponse(@[nameMention, artistOnly], 2)], 0, @"胡彦斌")[@"data"][0] isEqual:artistOnly],
          @"exact artist fallback field outranks a title merely mentioning the artist and tolerates null singer");

    NSDictionary *cafe = SearchTrack(@"qq", @"cafe", @"Café!", @"A Singer");
    NSDictionary *cafeRemix = SearchTrack(@"wy", @"cafe-remix", @"Cafe (Remix)", @"A Singer");
    NSDictionary *normalized = FMXMergeSearchResponsesForKeyword(@[SearchResponse(@[cafeRemix, cafe], 2)], 0, @" ＣＡＦＥ ");
    Check([normalized[@"data"][0] isEqual:cafe], @"ranking folds case, fullwidth letters, diacritics and punctuation without rewriting the original title");
    Check([normalized[@"data"][0][@"title"] isEqual:@"Café!"], @"normalized rank never changes the displayed title");

    NSDictionary *studio = SearchTrack(@"kg", @"studio", @"知足", @"另一位歌手");
    NSDictionary *cover = SearchTrack(@"qq", @"cover", @"知足（翻唱版）", @"翻唱歌手");
    NSDictionary *subtitle = SearchTrack(@"qq", @"subtitle", @"知足（电影主题曲）", @"另一位歌手");
    NSArray *versions = @[SearchResponse(@[subtitle, live, cover, studio], 4)];
    NSDictionary *titleResult = FMXMergeSearchResponsesForKeyword(versions, 0, @"知足");
    Check([SearchPairs(titleResult) isEqual:@[@[@"kg",@"studio"],@[@"wy",@"live"],@[@"qq",@"cover"],@[@"qq",@"subtitle"]]],
          @"exact song title precedes recognized version suffixes; arbitrary subtitles are not stripped");
    Check([titleResult[@"data"] containsObject:live] && [titleResult[@"data"] containsObject:cover],
          @"live and cover recordings remain selectable with their own identifiers and metadata");
    Check([FMXMergeSearchResponsesForKeyword(versions, 0, @"知足 Live版")[@"data"][0] isEqual:live],
          @"explicit live-version query promotes that version over the studio recording");

    NSDictionary *sameQQ = SearchTrack(@"qq", @"shared", @"知足", @"甲");
    NSDictionary *sameWY = SearchTrack(@"wy", @"shared", @"知足", @"甲");
    NSDictionary *secondQQ = SearchTrack(@"qq", @"different-id", @"知足", @"甲");
    NSDictionary *repeatQQ = SearchTrack(@"qq", @"shared", @"知足（Live）", @"changed duplicate");
    NSArray *identitySources = @[SearchResponse(@[sameQQ, secondQQ, repeatQQ], 30), SearchResponse(@[sameWY], 40)];
    NSDictionary *identityResult = FMXMergeSearchResponsesForKeyword(identitySources, 2, @"知足");
    NSArray *expectedPairs = @[@[@"qq",@"shared"],@[@"wy",@"shared"],@[@"qq",@"different-id"]];
    Check([SearchPairs(identityResult) isEqual:expectedPairs], @"deduplicate only repeated source and ID, never merge cross-platform or distinct-ID same-name songs");
    Check(identityResult[@"data"][0] == sameQQ, @"dedup retains first original native track dictionary");
    Check([identityResult[@"page"] isEqual:@2] && [identityResult[@"count"] isEqual:@3] && [identityResult[@"total"] isEqual:@70],
          @"ranking retains current page, source total and unique result count");
    for (NSUInteger i=0; i<3; i++) {
        Check([SearchPairs(FMXMergeSearchResponsesForKeyword(identitySources, 2, @"知足")) isEqual:expectedPairs],
              @"equal relevance deterministically preserves source round-robin then within-source order");
    }
    for (id keyword in @[NSNull.null, @"", @"  —— ! /  "]) {
        NSDictionary *withoutQuery = FMXMergeSearchResponsesForKeyword(sources, 3, keyword == NSNull.null ? nil : keyword);
        Check([withoutQuery isEqual:FMXMergeSearchResponses(sources, 3)], @"blank or punctuation-only query preserves legacy merge behavior");
    }
    NSArray *before = [NSJSONSerialization JSONObjectWithData:[NSJSONSerialization dataWithJSONObject:sources options:0 error:NULL] options:0 error:NULL];
    NSDictionary *nextPage = FMXMergeSearchResponsesForKeyword(@[SearchResponse(@[unrelated], 50)], 1, @"远方");
    Check([nextPage[@"data"] isEqual:@[unrelated]] && [nextPage[@"page"] isEqual:@1], @"next-page ranking never leaks candidates from an earlier page or query");
    Check([sources isEqual:before], @"ranking leaves source response arrays and track metadata untouched");

    NSArray *partlyFailed = @[NSNull.null, @{@"code":@503, @"data":@[duet]},
        SearchResponse(@[NSNull.null, @{@"id":@"bad", @"server":@"qq", @"title":@99}, wrongArtist, duet], 4),
        @{@"code":@200, @"data":@"malformed"}];
    NSDictionary *survivors = FMXMergeSearchResponsesForKeyword(partlyFailed, 0, @"知足 于文文 胡彦斌");
    Check([survivors[@"data"] isEqual:@[duet, wrongArtist]], @"failed and malformed sources cannot suppress or inject into valid ranked results");
    Check([FMXMergeSearchResponsesForKeyword(@[NSNull.null, @{@"code":@500}], 0, @"知足")[@"data"] count] == 0,
          @"merge never invents tracks when every source is unavailable");
    NSDictionary *near = SearchTrack(@"qq", @"near", @"Faded", @"Unknown");
    NSDictionary *far = SearchTrack(@"wy", @"far", @"Elsewhere", @"Other");
    Check([FMXMergeSearchResponsesForKeyword(@[SearchResponse(@[far, near], 2)], 0, @"Fadex")[@"data"][0] isEqual:near],
          @"bounded edit-distance fallback improves misspelled queries below exact relevance tiers");
    NSString *longText = [@"x" stringByPaddingToLength:2048 withString:@"x" startingAtIndex:0];
    NSDictionary *longTrack = SearchTrack(@"qq", @"long", longText, longText);
    Check([FMXMergeSearchResponsesForKeyword(@[SearchResponse(@[longTrack, near], 2)], 0, longText)[@"data"] count] == 2,
          @"large query and metadata remain safe and do not discard valid candidates");
    SetCheckScope(@"legacy");
}

// Only authored data is used by the aggregate integration fixture. The Qishui
// subclass never reads native configuration and never creates a network task.
@interface FMXSearchFixtureQishui : FMQishuiSearchClient
@property(nonatomic, copy) NSString *lastKeyword;
@property(nonatomic) NSInteger lastPage;
@property(nonatomic) NSUInteger calls;
@property(nonatomic) BOOL forceFailure;
@end
@implementation FMXSearchFixtureQishui
- (FMXQishuiCancellation)search:(NSString *)keyword page:(NSInteger)page timeout:(NSTimeInterval)timeout completion:(FMXQishuiCompletion)completion {
    self.calls++;
    self.lastKeyword = keyword;
    self.lastPage = page;
    if (self.forceFailure) completion(nil, [NSError errorWithDomain:@"SearchFixture" code:503 userInfo:nil]);
    else completion(SearchResponse(@[SearchTrack(@"qs", [NSString stringWithFormat:@"p%ld-live",(long)page], @"知足（Live）", @"于文文 / 胡彦斌")], 10), nil);
    return ^(NSError *reason) {};
}
@end

static NSDictionary *SearchLoopbackResponse(NSString *path, NSInteger *status) {
    NSURLComponents *components = [NSURLComponents componentsWithString:[@"http://127.0.0.1" stringByAppendingString:path]];
    NSMutableDictionary *query = NSMutableDictionary.dictionary;
    for (NSURLQueryItem *item in components.queryItems) if (item.value) query[item.name] = item.value;
    NSInteger platform = [query[@"platform"] integerValue], page = [query[@"page"] integerValue];
    if (platform == 0 || [query[@"fixture_failure"] isEqual:@"1"]) {
        *status = 503;
        return @{@"code":@503, @"msg":@"authored source unavailable"};
    }
    NSString *identifier = [NSString stringWithFormat:@"p%ld-%@", (long)page, platform == 2 ? @"other" : @"duet"];
    return SearchResponse(@[SearchTrack(platform == 2 ? @"qq" : @"kg", identifier, @"知足", platform == 2 ? @"另一位歌手" : @"于文文 / 胡彦斌")], 10);
}

@interface FMXTestClient : NSObject <NSURLProtocolClient>
@property(nonatomic, strong) NSMutableData *data;
@property(nonatomic, strong) NSError *error;
@property(nonatomic, strong) dispatch_semaphore_t done;
@property(nonatomic) NSUInteger completions;
@end

// Test-only transport: actual NSURLSession requests still target the production-shaped URL;
// only requests with this fixture header can be routed to a local TCP server.
static NSUInteger loopbackPort;
static atomic_uint originRequests;
static IMP originalDefaultConfiguration;
static IMP originalEphemeralConfiguration;

@interface FMXLoopbackTransport : NSURLProtocol
@property(nonatomic, strong) NSURLSession *session;
@property(nonatomic, strong) NSURLSessionTask *task;
@end
@implementation FMXLoopbackTransport
+ (BOOL)canInitWithRequest:(NSURLRequest *)request {
    return [@[@"aacert.com", @"m.kugou.com"] containsObject:request.URL.host] &&
        [[request valueForHTTPHeaderField:@"X-FMX-Test"] isEqualToString:@"local-contract"];
}
+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request { return request; }
- (void)startLoading {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
        NSMutableURLRequest *request = [self.request mutableCopy];
        if (request.HTTPBodyStream) {
            NSInputStream *stream = request.HTTPBodyStream;
            [stream open];
            NSMutableData *data = NSMutableData.data;
            uint8_t buffer[4096];
            NSInteger count;
            while ((count = [stream read:buffer maxLength:sizeof(buffer)]) > 0) [data appendBytes:buffer length:(NSUInteger)count];
            [stream close];
            if (count < 0) { [self.client URLProtocol:self didFailWithError:stream.streamError]; return; }
            request.HTTPBodyStream = nil;
            request.HTTPBody = data;
        }
        // This test-only hop has an in-memory body; make the local echo framing deterministic.
        [request setValue:nil forHTTPHeaderField:@"Transfer-Encoding"];
        if (request.HTTPBody) [request setValue:@(request.HTTPBody.length).stringValue forHTTPHeaderField:@"Content-Length"];
        NSURLComponents *url = [NSURLComponents componentsWithURL:request.URL resolvingAgainstBaseURL:NO];
        url.scheme = @"http";
        url.host = @"127.0.0.1";
        url.port = @(loopbackPort);
        request.URL = url.URL;
        self.session = [NSURLSession sessionWithConfiguration:NSURLSessionConfiguration.ephemeralSessionConfiguration];
        self.task = [self.session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            if (error) { [self.client URLProtocol:self didFailWithError:error]; }
            else {
                NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
                NSHTTPURLResponse *restored = [[NSHTTPURLResponse alloc] initWithURL:self.request.URL statusCode:http.statusCode HTTPVersion:@"HTTP/1.1" headerFields:http.allHeaderFields];
                [self.client URLProtocol:self didReceiveResponse:restored cacheStoragePolicy:NSURLCacheStorageNotAllowed];
                if (data) [self.client URLProtocol:self didLoadData:data];
                [self.client URLProtocolDidFinishLoading:self];
            }
            [self.session finishTasksAndInvalidate];
        }];
        [self.task resume];
    });
}
- (void)stopLoading { [self.task cancel]; [self.session invalidateAndCancel]; }
@end

static NSURLSessionConfiguration *TestConfiguration(id self, SEL selector, IMP original) {
    NSURLSessionConfiguration *configuration = ((id (*)(id, SEL))original)(self, selector);
    NSMutableArray *classes = [configuration.protocolClasses mutableCopy] ?: NSMutableArray.array;
    [classes removeObject:FMXLoopbackTransport.class];
    NSUInteger interceptorIndex = [classes indexOfObject:FMExtensionProtocol.class];
    NSUInteger transportIndex = interceptorIndex == NSNotFound ? 0 : interceptorIndex+1;
    // The test transport must precede built-in HTTP protocols but follow the subject under test.
    [classes insertObject:FMXLoopbackTransport.class atIndex:transportIndex];
    configuration.protocolClasses = classes;
    return configuration;
}

static NSURLSessionConfiguration *TestDefaultConfiguration(id self, SEL selector) {
    return TestConfiguration(self, selector, originalDefaultConfiguration);
}

static NSURLSessionConfiguration *TestEphemeralConfiguration(id self, SEL selector) {
    return TestConfiguration(self, selector, originalEphemeralConfiguration);
}

static int StartLoopbackServer(void) {
    int listener = socket(AF_INET, SOCK_STREAM, 0);
    if (listener < 0) return -1;
    struct sockaddr_in address = {0};
    address.sin_len = sizeof(address);
    address.sin_family = AF_INET;
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (bind(listener, (struct sockaddr *)&address, sizeof(address)) || listen(listener, 8)) { close(listener); return -1; }
    socklen_t addressSize = sizeof(address);
    if (getsockname(listener, (struct sockaddr *)&address, &addressSize)) { close(listener); return -1; }
    loopbackPort = ntohs(address.sin_port);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
        while (YES) {
            int client = accept(listener, NULL, NULL);
            if (client < 0) break;
            @autoreleasepool {
                struct timeval timeout = {3, 0};
                setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
                int noSigPipe = 1;
                setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, sizeof(noSigPipe));
                NSMutableData *received = NSMutableData.data;
                NSData *separator = [@"\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding];
                NSRange headerEnd = NSMakeRange(NSNotFound, 0);
                uint8_t buffer[4096];
                while (received.length < 128*1024 && headerEnd.location == NSNotFound) {
                    ssize_t count = recv(client, buffer, sizeof(buffer), 0);
                    if (count <= 0) break;
                    [received appendBytes:buffer length:(NSUInteger)count];
                    headerEnd = [received rangeOfData:separator options:0 range:NSMakeRange(0, received.length)];
                }
                if (headerEnd.location != NSNotFound) {
                    NSString *head = [[NSString alloc] initWithData:[received subdataWithRange:NSMakeRange(0, headerEnd.location)] encoding:NSUTF8StringEncoding];
                    NSArray *lines = [head componentsSeparatedByString:@"\r\n"];
                    NSArray *first = [lines.firstObject componentsSeparatedByString:@" "];
                    NSMutableDictionary *headers = NSMutableDictionary.dictionary;
                    for (NSUInteger i=1; i<lines.count; i++) {
                        NSRange colon = [lines[i] rangeOfString:@":"];
                        if (colon.location == NSNotFound) continue;
                        NSString *name = [[lines[i] substringToIndex:colon.location] lowercaseString];
                        headers[name] = [[lines[i] substringFromIndex:colon.location+1] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
                    }
                    NSUInteger start = NSMaxRange(headerEnd);
                    NSUInteger length = [headers[@"content-length"] integerValue];
                    while (received.length < start+length && received.length < 128*1024) {
                        ssize_t count = recv(client, buffer, sizeof(buffer), 0);
                        if (count <= 0) break;
                        [received appendBytes:buffer length:(NSUInteger)count];
                    }
                    NSData *bodyData = [received subdataWithRange:NSMakeRange(start, MIN(length, received.length-start))];
                    NSString *body = [[NSString alloc] initWithData:bodyData encoding:NSUTF8StringEncoding] ?: @"";
                    NSString *path = first.count > 1 ? first[1] : @"";
                    NSDictionary *echo = @{@"method":first.firstObject ?: @"", @"path":path, @"body":body, @"headers":headers};
                    NSInteger status = [path containsString:@"echo_status=207"] ? 207 : 200;
                    if ([headers[@"x-fmx-search-fixture"] isEqual:@"ranking"]) echo = SearchLoopbackResponse(path, &status);
                    NSData *output = [NSJSONSerialization dataWithJSONObject:echo options:NSJSONWritingSortedKeys error:NULL];
                    NSString *responseHead = [NSString stringWithFormat:@"HTTP/1.1 %ld Test\r\nContent-Type: application/json\r\nX-FMX-Origin: preserved\r\nContent-Length: %lu\r\nConnection: close\r\n\r\n",(long)status,(unsigned long)output.length];
                    NSMutableData *response = [[responseHead dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
                    [response appendData:output];
                    atomic_fetch_add(&originRequests, 1);
                    NSUInteger sent = 0;
                    while (sent < response.length) {
                        ssize_t count = send(client, (const uint8_t *)response.bytes+sent, response.length-sent, 0);
                        if (count <= 0) break;
                        sent += (NSUInteger)count;
                    }
                }
                close(client);
            }
        }
    });
    return listener;
}

static NSMutableURLRequest *StreamRequest(NSString *query, NSString *body) {
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:[@"https://aacert.com/ms/api.php?" stringByAppendingString:query]]];
    request.HTTPMethod = @"POST";
    request.HTTPBodyStream = [NSInputStream inputStreamWithData:[body dataUsingEncoding:NSUTF8StringEncoding]];
    request.timeoutInterval = 3;
    [request setValue:@"application/x-www-form-urlencoded" forHTTPHeaderField:@"Content-Type"];
    [request setValue:@"local-contract" forHTTPHeaderField:@"X-FMX-Test"];
    [request setValue:@"fixture_cookie=local_only" forHTTPHeaderField:@"Cookie"];
    [request setValue:@"Bearer fixture-local-only" forHTTPHeaderField:@"Authorization"];
    return request;
}

static NSDictionary *FetchWithConfigurationAndWait(NSURLRequest *request, NSURLSessionConfiguration *configuration, NSTimeInterval wait) {
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    NSTimeInterval began=NSProcessInfo.processInfo.systemUptime;
    __block NSDictionary *result;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:configuration];
    NSURLSessionDataTask *task = [session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        id json = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
        NSHTTPURLResponse *http = [response isKindOfClass:NSHTTPURLResponse.class] ? (id)response : nil;
        result = @{@"json":json ?: NSNull.null, @"error":error ?: NSNull.null, @"status":@(http.statusCode), @"headers":http.allHeaderFields ?: @{}, @"raw":data ?: NSData.data};
        dispatch_semaphore_signal(done);
    }];
    [task resume];
    BOOL completed = dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(wait*NSEC_PER_SEC))) == 0;
    [session invalidateAndCancel];
    NSError *fetchError=[result[@"error"] isKindOfClass:NSError.class]?result[@"error"]:nil;
    if(!completed||fetchError)fprintf(stderr,"FETCH diagnostic: completed=%d elapsed=%.3f wait=%.3f request_timeout=%.3f status=%ld error_domain=%s error_code=%ld\n",completed,NSProcessInfo.processInfo.systemUptime-began,wait,request.timeoutInterval,(long)[result[@"status"] integerValue],fetchError.domain.UTF8String?:"none",(long)fetchError.code);
    Check(completed, @"NSURLSession loopback completes without external network");
    return result ?: @{};
}

static NSDictionary *FetchWithConfiguration(NSURLRequest *request, NSURLSessionConfiguration *configuration) {
    return FetchWithConfigurationAndWait(request, configuration, 5);
}

static NSDictionary *Fetch(NSURLRequest *request) {
    return FetchWithConfiguration(request, NSURLSessionConfiguration.defaultSessionConfiguration);
}

static NSMutableURLRequest *SearchFixtureRequest(NSString *keyword, NSInteger page, BOOL fail) {
    NSURLComponents *url = [NSURLComponents componentsWithString:@"https://aacert.com/ms/api.php"];
    url.queryItems = @[[NSURLQueryItem queryItemWithName:@"action" value:@"search"],
        [NSURLQueryItem queryItemWithName:@"keyword" value:keyword],
        [NSURLQueryItem queryItemWithName:@"platform" value:@"2"],
        [NSURLQueryItem queryItemWithName:@"page" value:@(page).stringValue],
        [NSURLQueryItem queryItemWithName:@"fixture_failure" value:fail ? @"1" : @"0"]];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url.URL];
    request.timeoutInterval = 3;
    [request setValue:@"local-contract" forHTTPHeaderField:@"X-FMX-Test"];
    [request setValue:@"ranking" forHTTPHeaderField:@"X-FMX-Search-Fixture"];
    return request;
}

static void RunSearchRankingIntegrationTests(void) {
    SetCheckScope(@"ranking.integration");
    id previousAggregate = [NSUserDefaults.standardUserDefaults objectForKey:@"FMX.aggregateSearch"];
    [NSUserDefaults.standardUserDefaults setBool:YES forKey:@"FMX.aggregateSearch"];
    FMXSearchFixtureQishui *qishui = [[FMXSearchFixtureQishui alloc] initWithConfiguration:nil deviceID:@"authored-local-fixture"];
    [FMExtensionProtocol setQishuiSearchClient:qishui];
    unsigned before = atomic_load(&originRequests);
    NSDictionary *first = Fetch(SearchFixtureRequest(@"知足 于文文 胡彦斌", 4, NO));
    if (first[@"error"]) rankingSessionCallbacks++;
    NSDictionary *firstJSON = [first[@"json"] isKindOfClass:NSDictionary.class] ? first[@"json"] : @{};
    Check([SearchPairs(firstJSON) isEqual:@[@[@"kg",@"p4-duet"],@[@"qs",@"p4-live"],@[@"qq",@"p4-other"]]],
          @"actual aggregate NSURLSession applies the request keyword after one source fails and retains Qishui versions");
    Check([firstJSON[@"page"] isEqual:@4] && [firstJSON[@"count"] isEqual:@3] && [qishui.lastKeyword isEqual:@"知足 于文文 胡彦斌"] && qishui.lastPage == 4,
          @"aggregate forwards the same keyword and native page to each source and preserves page metadata");
    Check(atomic_load(&originRequests) == before+3 && qishui.calls == 1, @"aggregate keeps three independent native requests and one isolated Qishui request");
    NSDictionary *second = Fetch(SearchFixtureRequest(@"另一位歌手", 1, NO));
    if (second[@"error"]) rankingSessionCallbacks++;
    NSDictionary *secondJSON = [second[@"json"] isKindOfClass:NSDictionary.class] ? second[@"json"] : @{};
    Check([SearchPairs(secondJSON) firstObject] && [[SearchPairs(secondJSON) firstObject] isEqual:@[@"qq",@"p1-other"]] && [secondJSON[@"page"] isEqual:@1],
          @"next aggregate request uses its own singer query and page instead of stale ranking context");
    qishui.forceFailure = YES;
    NSDictionary *failed = Fetch(SearchFixtureRequest(@"知足", 0, YES));
    if (failed[@"error"]) rankingSessionCallbacks++;
    NSDictionary *failedJSON = [failed[@"json"] isKindOfClass:NSDictionary.class] ? failed[@"json"] : nil;
    Check([failed[@"error"] isKindOfClass:NSError.class] || (failedJSON && [failedJSON[@"code"] integerValue] != 200),
          @"all-source failure remains an explicit failure rather than an empty successful ranking");
    rankingLoopbackRequests = atomic_load(&originRequests) - before;
    rankingQishuiCalls = qishui.calls;
    Check(rankingLoopbackRequests == 9 && rankingQishuiCalls == 3 && rankingSessionCallbacks == 3,
          @"ranking integration executes all three aggregate sessions, nine loopback HTTP requests and three isolated Qishui calls");
    [FMExtensionProtocol setQishuiSearchClient:nil];
    if (previousAggregate) [NSUserDefaults.standardUserDefaults setObject:previousAggregate forKey:@"FMX.aggregateSearch"];
    else [NSUserDefaults.standardUserDefaults removeObjectForKey:@"FMX.aggregateSearch"];
    SetCheckScope(@"legacy");
}

// Native import integration, through actual NSURLSession body streams. The token
// and songs are authored here; no user file or remotely usable credential exists.
static void RunLXMCImportTests(void) {
    id previousAggregate = [NSUserDefaults.standardUserDefaults objectForKey:@"FMX.aggregateSearch"];
    [NSUserDefaults.standardUserDefaults setBool:NO forKey:@"FMX.aggregateSearch"];
    [FMExtensionProtocol setParseHandler:nil canHandle:nil];
    FMTrackMetadataReset();
    __block NSUInteger observedTracks=0;
    [FMExtensionProtocol setTrackMetadataObserver:^(id response){
        if([response isKindOfClass:NSDictionary.class]&&response[@"source"])observedTracks++;
        FMTrackMetadataObserveResponse(response);
    }];
    NSDictionary *fixture = @{@"type":@"playListPart_v2", @"data":@{@"id":@"fixture-only", @"name":@"Protocol Import Fixture", @"list":@[
        @{@"source":@"wy", @"name":@"Authored One", @"singer":@"Fixture Artist", @"interval":@"01:23", @"meta":@{@"songId":@12345}},
        @{@"source":@"tx", @"name":@"Authored Two", @"singer":@"Fixture Artist", @"interval":@"02:34", @"cookie":@"fixture-private-only", @"meta":@{@"songId":@"Ab0123456789Cd",@"id":@8765,@"albumMid":@"fixture-album-mid",@"strMediaMid":@"fixture-media-mid",@"_qualitys":@{@"flac":@{@"size":@123456,@"ext":@"flac",@"auth":@"fixture-private-quality"}}}}
    ]}};
    NSError *error = nil;
    NSData *fixtureData = [NSJSONSerialization dataWithJSONObject:fixture options:0 error:&error];
    FMLXMCImportDocument *document = fixtureData ? FMLXMCParseData(fixtureData, &error) : nil;
    NSString *token = document.playlists.count ? FMLXMCRegisterPlaylist(document.playlists.firstObject, &error) : nil;
    Check(token.length > 0 && !error && document.importedTrackCount == 2, @"LX import authored fixture registers two mapped tracks");
    Check(observedTracks==2,@"LX import observes accepted raw tracks only after successful document validation");
    if (token.length) {
        NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~"];
        NSString *body = [@"url=" stringByAppendingString:[token stringByAddingPercentEncodingWithAllowedCharacters:allowed]];
        NSMutableURLRequest *request = StreamRequest(@"action=import_playlist&_t=fixture-local", body);
        Check(request.HTTPBody == nil && request.HTTPBodyStream.streamStatus == NSStreamStatusNotOpen,
              @"LX import begins with a genuine unopened HTTPBodyStream");
        Check([FMExtensionProtocol canInitWithRequest:request] && request.HTTPBodyStream.streamStatus == NSStreamStatusNotOpen,
              @"LX import selection claims the streamed native route without consuming the stream or needing aggregation/JS");
        unsigned beforeOrigin = atomic_load(&originRequests);
        NSDictionary *first = Fetch(request);
        NSDictionary *firstJSON = [first[@"json"] isKindOfClass:NSDictionary.class] ? first[@"json"] : @{};
        NSDictionary *expected = @{@"code":@200, @"data":@{@"title":@"Protocol Import Fixture", @"tracks":document.playlists.firstObject.tracks}};
        Check(first[@"error"] == NSNull.null && [first[@"status"] integerValue] == 200 && [firstJSON isEqual:expected],
              @"NSURLSession streamed LX token returns the exact native import title and tracks envelope");
        Check(atomic_load(&originRequests) == beforeOrigin, @"Single-use LX token never reaches the local origin transport or network");
        NSDictionary *metadata=FMTrackMetadataForParameters(@{@"id":@"Ab0123456789Cd"},@"tx");
        Check([metadata[@"albumMid"] isEqual:@"fixture-album-mid"]&&[metadata[@"strMediaMid"] isEqual:@"fixture-media-mid"]&&[metadata[@"songId"] isEqual:@"8765"]&&[metadata[@"_types"][@"flac"][@"size"] isEqual:@123456],@"LXMC through native protocol retains script-required media and quality metadata");
        NSString *safeMetadata=[[NSString alloc]initWithData:[NSJSONSerialization dataWithJSONObject:metadata options:0 error:nil] encoding:NSUTF8StringEncoding];
        Check(![safeMetadata containsString:@"fixture-private"]&&![[[NSString alloc]initWithData:first[@"raw"] encoding:NSUTF8StringEncoding] containsString:@"fixture-media-mid"],@"LX extras stay internal and imported credentials never reach JS metadata");

        // A fresh stream, including a different session configuration, must not
        // resurrect a consumed token or fall back to forwarding its secret value.
        NSDictionary *used = FetchWithConfiguration(StreamRequest(@"action=import_playlist&_t=fixture-used", body), NSURLSessionConfiguration.ephemeralSessionConfiguration);
        NSError *usedError = [used[@"error"] isKindOfClass:NSError.class] ? used[@"error"] : nil;
        Check([usedError.domain isEqualToString:FMLXMCErrorDomain] && usedError.code == 17 && [used[@"raw"] length] == 0,
              @"Repeated LX token fails locally with the parser's explicit single-use error");
        Check(atomic_load(&originRequests) == beforeOrigin, @"Used LX token does not escape through ephemeral-session fallback");
        FMLXMCRevokeURL(token);
    }

    // This is a native external-link import, not a fetch of the embedded link.
    // The fixture transport routes the sole API request to our loopback server.
    NSString *ordinaryBody = @"url=https%3A%2F%2Fmusic.163.com%2F%23%2Fplaylist%3Fid%3D12345&title=A%2BB+Song&source=fixture%26only";
    NSMutableURLRequest *ordinary = StreamRequest(@"action=import_playlist&_t=fixture-remote&echo_status=207", ordinaryBody);
    [ordinary setValue:@"kept-verbatim" forHTTPHeaderField:@"X-FMX-Import-Fixture"];
    unsigned beforeForward = atomic_load(&originRequests);
    NSDictionary *forwarded = Fetch(ordinary);
    NSDictionary *echo = [forwarded[@"json"] isKindOfClass:NSDictionary.class] ? forwarded[@"json"] : @{};
    Check(forwarded[@"error"] == NSNull.null && [forwarded[@"status"] integerValue] == 207,
          @"Ordinary streamed import preserves the origin HTTP response status");
    Check([echo[@"body"] isEqual:ordinaryBody] && [echo[@"method"] isEqual:@"POST"] &&
          [echo[@"path"] isEqual:@"/ms/api.php?action=import_playlist&_t=fixture-remote&echo_status=207"],
          @"Ordinary streamed import preserves every encoded body byte, HTTP method and query");
    Check([echo[@"headers"][@"cookie"] isEqual:@"fixture_cookie=local_only"] &&
          [echo[@"headers"][@"authorization"] isEqual:@"Bearer fixture-local-only"] &&
          [echo[@"headers"][@"content-type"] isEqual:@"application/x-www-form-urlencoded"] &&
          [echo[@"headers"][@"x-fmx-import-fixture"] isEqual:@"kept-verbatim"],
          @"Ordinary streamed import preserves original Cookie, Authorization and content/custom headers");
    NSMutableDictionary *responseHeaders = NSMutableDictionary.dictionary;
    for (NSString *key in forwarded[@"headers"]) responseHeaders[key.lowercaseString] = forwarded[@"headers"][key];
    NSData *expectedResponse = [NSJSONSerialization dataWithJSONObject:echo options:NSJSONWritingSortedKeys error:NULL];
    Check([responseHeaders[@"x-fmx-origin"] isEqual:@"preserved"] &&
          [responseHeaders[@"content-type"] isEqual:@"application/json"] && [forwarded[@"raw"] isEqual:expectedResponse],
          @"Ordinary streamed import preserves origin response headers and exact JSON response bytes");
    Check(atomic_load(&originRequests) == beforeForward + 1, @"Ordinary remote-link import forwards exactly once without interceptor recursion");
    NSUInteger beforeInvalid=observedTracks;
    NSDictionary *invalidDocument=@{@"type":@"playList_v2",@"data":@[fixture[@"data"],@{@"name":@"Invalid trailing list",@"list":@"not an array"}]};
    Check(FMLXMCParseData([NSJSONSerialization dataWithJSONObject:invalidDocument options:0 error:nil],&error)==nil&&observedTracks==beforeInvalid,@"partly parsed invalid LX document does not populate track metadata");
    NSDictionary *acceptedSong=fixture[@"data"][@"list"][0];
    NSDictionary *mixedDocument=@{@"type":@"playListPart_v2",@"data":@{@"name":@"Filtered observer fixture",@"list":@[acceptedSong,acceptedSong,@{@"source":@"kw",@"name":@"Unsupported",@"meta":@{@"songId":@123}},@{@"source":@"wy",@"name":@"Invalid identifier",@"meta":@{@"songId":@"bad-id"}}]}};
    FMLXMCImportDocument *mixed=FMLXMCParseData([NSJSONSerialization dataWithJSONObject:mixedDocument options:0 error:nil],&error);
    Check(mixed.importedTrackCount==1&&mixed.playlists.firstObject.duplicateCount==1&&observedTracks==beforeInvalid+1,@"LX observer excludes duplicate, unsupported and invalid tracks");
    NSUInteger beforeRemoved=observedTracks;
    [FMExtensionProtocol setTrackMetadataObserver:nil];
    FMLXMCParseData(fixtureData,&error);
    Check(observedTracks==beforeRemoved,@"clearing the protocol observer also removes local LX observation");
    FMTrackMetadataReset();
    if (previousAggregate) [NSUserDefaults.standardUserDefaults setObject:previousAggregate forKey:@"FMX.aggregateSearch"];
    else [NSUserDefaults.standardUserDefaults removeObjectForKey:@"FMX.aggregateSearch"];
}

@implementation FMXTestClient
- (instancetype)init { if ((self = [super init])) { _data = NSMutableData.data; _done = dispatch_semaphore_create(0); } return self; }
- (void)URLProtocol:(NSURLProtocol *)protocol wasRedirectedToRequest:(NSURLRequest *)request redirectResponse:(NSURLResponse *)response {}
- (void)URLProtocol:(NSURLProtocol *)protocol cachedResponseIsValid:(NSCachedURLResponse *)cachedResponse {}
- (void)URLProtocol:(NSURLProtocol *)protocol didReceiveResponse:(NSURLResponse *)response cacheStoragePolicy:(NSURLCacheStoragePolicy)policy {}
- (void)URLProtocol:(NSURLProtocol *)protocol didLoadData:(NSData *)data { [self.data appendData:data]; }
- (void)URLProtocolDidFinishLoading:(NSURLProtocol *)protocol { self.completions++; dispatch_semaphore_signal(self.done); }
- (void)URLProtocol:(NSURLProtocol *)protocol didFailWithError:(NSError *)error { self.error = error; self.completions++; dispatch_semaphore_signal(self.done); }
- (void)URLProtocol:(NSURLProtocol *)protocol didReceiveAuthenticationChallenge:(NSURLAuthenticationChallenge *)challenge {}
- (void)URLProtocol:(NSURLProtocol *)protocol didCancelAuthenticationChallenge:(NSURLAuthenticationChallenge *)challenge {}
@end

@interface FMXWaitingStream : NSInputStream
@property(atomic) NSStreamStatus testStatus;
@property(nonatomic, strong) dispatch_semaphore_t closed;
@end
@implementation FMXWaitingStream
- (instancetype)init { if ((self = [super init])) { _testStatus = NSStreamStatusNotOpen; _closed = dispatch_semaphore_create(0); } return self; }
- (void)open { self.testStatus = NSStreamStatusOpen; }
- (void)close { self.testStatus = NSStreamStatusClosed; dispatch_semaphore_signal(self.closed); }
- (NSStreamStatus)streamStatus { return self.testStatus; }
- (BOOL)hasBytesAvailable { return NO; }
- (NSInteger)read:(uint8_t *)buffer maxLength:(NSUInteger)length { return 0; }
- (NSError *)streamError { return nil; }
@end

static void RunParseBudgetTests(void) {
    __block NSUInteger calls = 0;
    __block NSUInteger cleanups=0;
    __block NSTimeInterval handlerStarted=0,delayedCallbackAt=0,cleanedAt=0;
    __block NSError *cleanupReason;
    __block FMXProtocolCompletion heldCompletion;
    dispatch_semaphore_t started = dispatch_semaphore_create(0);
    dispatch_semaphore_t cleaned = dispatch_semaphore_create(0);
    [FMExtensionProtocol setParseHandler:^FMXParseCancellation(NSURLRequest *request, NSDictionary *parameters, FMXProtocolCompletion complete) {
        calls++;
        Check(request.HTTPBodyStream == nil && [parameters[@"server"] isEqual:@"qq"], @"QQ budget fixture reaches handler with retained native request");
        if ([parameters[@"id"] isEqual:@"fixture-long"]) {
            handlerStarted=NSProcessInfo.processInfo.systemUptime;
            Check(request.timeoutInterval == 40, @"Extension does not extend the original 40-second fixture request timeout");
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 28*NSEC_PER_SEC), dispatch_get_global_queue(QOS_CLASS_DEFAULT,0), ^{
                delayedCallbackAt=NSProcessInfo.processInfo.systemUptime;
                complete(@{@"code":@200,@"data":@{@"url":@"https://example.invalid/fixture.mp3",@"quality":@"128k"}}, nil);
            });
        } else heldCompletion = complete;
        dispatch_semaphore_signal(started);
        return ^(NSError *reason) { cleanups++;cleanedAt=NSProcessInfo.processInfo.systemUptime;cleanupReason=reason; dispatch_semaphore_signal(cleaned); };
    } canHandle:^BOOL(NSURLRequest *request, NSDictionary *parameters) {
        return [parameters[@"server"] isEqual:@"qq"] && ![parameters[@"qmc"] isEqual:@"1"];
    }];

    unsigned beforeOrigin = atomic_load(&originRequests);
    NSMutableURLRequest *longRequest = StreamRequest(@"action=parse", @"server=qq&id=fixture-long&level=qq_standard");
    // Keep the real 28-second response so the old 20-second cap still fails.
    // Give loaded CI workers scheduling headroom; production timeouts are unchanged.
    longRequest.timeoutInterval = 40;
    NSTimeInterval begin = NSProcessInfo.processInfo.systemUptime;
    NSDictionary *result = FetchWithConfigurationAndWait(longRequest, NSURLSessionConfiguration.defaultSessionConfiguration, 50);
    NSTimeInterval elapsed=NSProcessInfo.processInfo.systemUptime-begin;
    NSError *longError=[result[@"error"] isKindOfClass:NSError.class]?result[@"error"]:nil;
    fprintf(stderr,"LONG PARSE diagnostic: elapsed=%.3f handler_start=%.3f callback=%.3f cleanup=%.3f calls=%lu cleanups=%lu status=%ld error_domain=%s error_code=%ld cleanup_domain=%s cleanup_code=%ld\n",elapsed,handlerStarted?handlerStarted-begin:-1,delayedCallbackAt?delayedCallbackAt-begin:-1,cleanedAt?cleanedAt-begin:-1,(unsigned long)calls,(unsigned long)cleanups,(long)[result[@"status"] integerValue],longError.domain.UTF8String?:"none",(long)longError.code,cleanupReason.domain.UTF8String?:"none",(long)cleanupReason.code);
    Check([result[@"status"] integerValue] == 200 && [result[@"json"][@"code"] integerValue] == 200 && result[@"json"][@"data"][@"url"] != nil,
          @"Actual NSURLSession accepts a 28-second anonymous resolution beyond the old 20-second cap");
    Check(elapsed >= 27.5 && delayedCallbackAt-handlerStarted >= 27.5 && calls == 1 && cleanups == 1 && cleanupReason == nil,
          @"Delayed resolution completes once with successful cleanup");
    Check(atomic_load(&originRequests) == beforeOrigin, @"Delayed supported QQ request never reaches the native backend");
    while (dispatch_semaphore_wait(started, DISPATCH_TIME_NOW) == 0) {}
    while (dispatch_semaphore_wait(cleaned, DISPATCH_TIME_NOW) == 0) {}

    // A larger parser cap cannot override an explicitly short native request.
    NSMutableURLRequest *shortRequest = StreamRequest(@"action=parse", @"server=qq&id=fixture-short&level=qq_standard");
    shortRequest.timeoutInterval = 0.2;
    FMXTestClient *shortClient = FMXTestClient.new;
    FMExtensionProtocol *shortProtocol = [[FMExtensionProtocol alloc] initWithRequest:shortRequest cachedResponse:nil client:shortClient];
    [shortProtocol startLoading];
    Check(dispatch_semaphore_wait(shortClient.done,dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC))==0 && shortClient.error.code==NSURLErrorTimedOut,
          @"Explicit short QQ request deadline still expires promptly");
    Check(cleanupReason.code==NSURLErrorTimedOut && shortClient.completions==1,@"Short parse deadline reaches cleanup exactly once as timeout");
    if(heldCompletion)heldCompletion(@{@"code":@200,@"data":@{@"url":@"https://example.invalid/late.mp3"}},nil);
    Check(dispatch_semaphore_wait(shortClient.done,dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC/20))!=0 && shortClient.completions==1,
          @"Timed-out parse ignores late URL completion");
    heldCompletion=nil;
    while (dispatch_semaphore_wait(started, DISPATCH_TIME_NOW) == 0) {}
    while (dispatch_semaphore_wait(cleaned, DISPATCH_TIME_NOW) == 0) {}

    NSMutableURLRequest *cancelRequest = StreamRequest(@"action=parse", @"server=qq&id=fixture-cancel&level=qq_standard");
    cancelRequest.timeoutInterval=30;
    FMXTestClient *cancelClient=FMXTestClient.new;
    FMExtensionProtocol *cancelProtocol=[[FMExtensionProtocol alloc] initWithRequest:cancelRequest cachedResponse:nil client:cancelClient];
    [cancelProtocol startLoading];
    Check(dispatch_semaphore_wait(started,dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC))==0,@"QQ parse starts before cancellation");
    [cancelProtocol stopLoading];
    Check(dispatch_semaphore_wait(cleaned,dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC))==0 && cleanupReason.code==NSURLErrorCancelled,
          @"Client cancellation remains immediate and distinct from timeout");
    if(heldCompletion)heldCompletion(@{@"code":@200,@"data":@{@"url":@"https://example.invalid/late.mp3"}},nil);
    Check(dispatch_semaphore_wait(cancelClient.done,dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC/20))!=0 && cancelClient.completions==0,
          @"Cancelled QQ request cannot publish a late playback URL");
    heldCompletion=nil;

    NSString *encryptedBody=@"server=qq&id=fixture-qmc&level=lossless&qmc=1";
    NSUInteger beforeCalls=calls;
    NSDictionary *forwarded=Fetch(StreamRequest(@"action=parse&echo_status=207",encryptedBody));
    NSDictionary *echo=[forwarded[@"json"] isKindOfClass:NSDictionary.class]?forwarded[@"json"]:@{};
    Check([forwarded[@"status"] integerValue]==207 && [echo[@"body"] isEqual:encryptedBody] &&
          [echo[@"headers"][@"cookie"] isEqual:@"fixture_cookie=local_only"] &&
          [echo[@"headers"][@"authorization"] isEqual:@"Bearer fixture-local-only"] && calls==beforeCalls,
          @"Predicate-rejected QMC request keeps its exact original body/auth and bypasses JS without quality rewriting");
    [FMExtensionProtocol setParseHandler:nil canHandle:nil];
}

static void RunKugouTests(NSDictionary *fixtures, BOOL hasLoopback) {
    __block BOOL supported = YES;
    __block BOOL delayed = NO;
    __block NSError *injectedError;
    __block NSUInteger handlerCalls = 0;
    __block FMXProtocolCompletion heldCompletion;
    dispatch_semaphore_t handlerStarted = dispatch_semaphore_create(0);
    dispatch_semaphore_t handlerCancelled = dispatch_semaphore_create(0);
    __block NSError *cleanupReason;
    FMXParseHandler handler = ^FMXParseCancellation(NSURLRequest *request, NSDictionary *parameters, FMXProtocolCompletion complete) {
        handlerCalls++;
        Check([request.URL.host isEqualToString:@"m.kugou.com"] && [request.HTTPMethod isEqualToString:@"GET"], @"kg handler gets original native GET request");
        Check([parameters isEqual:@{@"server":@"kg", @"id":@"EFEC0563692CAF94C184248B1D83227F", @"level":@"standard"}], @"kg receives only standard-quality synthetic parameters");
        if (delayed) { heldCompletion = complete; dispatch_semaphore_signal(handlerStarted); }
        else complete(injectedError ? nil : @{@"url":@"https://example.invalid/kg.mp3", @"bitRate":@128}, injectedError);
        return ^(NSError *reason) { cleanupReason = reason; dispatch_semaphore_signal(handlerCancelled); };
    };
    FMXParsePredicate predicate = ^BOOL(NSURLRequest *request, NSDictionary *parameters) {
        return supported && [parameters[@"server"] isEqualToString:@"kg"] && [parameters[@"level"] isEqualToString:@"standard"];
    };
    [FMExtensionProtocol setParseHandler:handler canHandle:predicate];
    for (NSDictionary *test in fixtures[@"kg_request_cases"]) {
        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:test[@"url"]]];
        request.HTTPMethod = test[@"method"] ?: @"GET";
        if (test[@"body"]) request.HTTPBody = [test[@"body"] dataUsingEncoding:NSUTF8StringEncoding];
        if ([test[@"stream"] boolValue]) request.HTTPBodyStream = [NSInputStream inputStreamWithData:NSData.data];
        Check([FMExtensionProtocol canInitWithRequest:request] == [test[@"intercept"] boolValue], test[@"name"]);
        [NSURLProtocol setProperty:@YES forKey:@"FMX.internalRequest" inRequest:request];
        Check(![FMExtensionProtocol canInitWithRequest:request], [test[@"name"] stringByAppendingString:@" no recursion"]);
    }
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"https://m.kugou.com/app/i/getSongInfo.php?cmd=playInfo&hash=efec0563692caf94c184248b1d83227f"]];
    request.timeoutInterval = 2;
    [request setValue:@"local-contract" forHTTPHeaderField:@"X-FMX-Test"];
    [request setValue:@"fixture_kg=local_only" forHTTPHeaderField:@"Cookie"];
    [request setValue:@"Bearer kg-local-only" forHTTPHeaderField:@"Authorization"];
    Check([FMExtensionProtocol canInitWithRequest:request], @"kg supported source selected");
    supported = NO;
    Check(![FMExtensionProtocol canInitWithRequest:request], @"kg unsupported source stays native");
    [FMExtensionProtocol setParseHandler:handler canHandle:nil];
    Check(![FMExtensionProtocol canInitWithRequest:request], @"kg missing predicate stays native");
    [FMExtensionProtocol setParseHandler:nil canHandle:predicate];
    Check(![FMExtensionProtocol canInitWithRequest:request], @"kg missing handler stays native");
    [FMExtensionProtocol setParseHandler:handler canHandle:^BOOL(NSURLRequest *r, NSDictionary *p) {
        @throw [NSException exceptionWithName:@"FixturePredicate" reason:@"test" userInfo:nil];
    }];
    Check(![FMExtensionProtocol canInitWithRequest:request], @"kg predicate exception stays native");
    [FMExtensionProtocol setParseHandler:handler canHandle:predicate];
    supported = YES;
    if (hasLoopback) {
        unsigned beforeOrigin = atomic_load(&originRequests);
        NSDictionary *success = FetchWithConfiguration(request, NSURLSessionConfiguration.ephemeralSessionConfiguration);
        Check([success[@"status"] integerValue] == 200 && [success[@"json"] isEqual:@{@"url":@"https://example.invalid/kg.mp3", @"bitRate":@128}], @"kg ephemeral session returns native top-level dictionary without API envelope");
        Check(handlerCalls == 1 && atomic_load(&originRequests) == beforeOrigin, @"kg supported JS request never reaches origin");
        Check(cleanupReason == nil, @"successful handler cleanup has no cancellation reason");
        injectedError = [NSError errorWithDomain:@"Fixture" code:1 userInfo:nil];
        NSDictionary *failed = FetchWithConfiguration(request, NSURLSessionConfiguration.ephemeralSessionConfiguration);
        Check([failed[@"status"] integerValue] == 200 && [failed[@"json"] isEqual:@{@"url":@""}], @"kg JS error returns empty URL for native fallback");
        injectedError = nil;

        // Selection and loading are separate; switching scripts between them must preserve the native request.
        Check([FMExtensionProtocol canInitWithRequest:request], @"kg selected before source switches");
        supported = NO;
        FMXTestClient *client = FMXTestClient.new;
        FMExtensionProtocol *protocol = [[FMExtensionProtocol alloc] initWithRequest:request cachedResponse:nil client:client];
        [protocol startLoading];
        Check(dispatch_semaphore_wait(client.done, dispatch_time(DISPATCH_TIME_NOW, 3*NSEC_PER_SEC)) == 0 && !client.error, @"kg source switch forwards through native ephemeral flow");
        NSDictionary *echo = client.data.length ? [NSJSONSerialization JSONObjectWithData:client.data options:0 error:NULL] : nil;
        Check([echo[@"method"] isEqual:@"GET"] && [echo[@"path"] isEqual:@"/app/i/getSongInfo.php?cmd=playInfo&hash=efec0563692caf94c184248b1d83227f"] &&
              [echo[@"headers"][@"cookie"] isEqual:@"fixture_kg=local_only"] && [echo[@"headers"][@"authorization"] isEqual:@"Bearer kg-local-only"], @"kg fallback preserves query method Cookie and Authorization");
        Check(handlerCalls == 2 && atomic_load(&originRequests) == beforeOrigin+1, @"kg source switch does not invoke stale handler");
    }
    supported = YES;
    delayed = YES;
    // Earlier synchronous handler completions also cancel work during cleanup; use fresh signals here.
    while (dispatch_semaphore_wait(handlerCancelled, DISPATCH_TIME_NOW) == 0) {}
    FMXTestClient *cancelClient = FMXTestClient.new;
    FMExtensionProtocol *cancelProtocol = [[FMExtensionProtocol alloc] initWithRequest:request cachedResponse:nil client:cancelClient];
    [cancelProtocol startLoading];
    Check(dispatch_semaphore_wait(handlerStarted, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)) == 0, @"kg delayed handler starts");
    [cancelProtocol stopLoading];
    Check(dispatch_semaphore_wait(handlerCancelled, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)) == 0, @"kg cancellation reaches JS cancel block");
    Check(cleanupReason.code == NSURLErrorCancelled, @"client cancellation is distinguished from deadline timeout");
    if (heldCompletion) heldCompletion(@{@"url":@"https://example.invalid/late.mp3"}, nil);
    Check(dispatch_semaphore_wait(cancelClient.done, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC/20)) != 0 && cancelClient.completions == 0, @"kg cancelled request ignores late completion");
    heldCompletion = nil;

    NSMutableURLRequest *timeoutRequest = [request mutableCopy];
    timeoutRequest.timeoutInterval = 0.05;
    FMXTestClient *timeoutClient = FMXTestClient.new;
    FMExtensionProtocol *timeoutProtocol = [[FMExtensionProtocol alloc] initWithRequest:timeoutRequest cachedResponse:nil client:timeoutClient];
    [timeoutProtocol startLoading];
    Check(dispatch_semaphore_wait(timeoutClient.done, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)) == 0 && !timeoutClient.error, @"kg timeout produces native fallback completion");
    NSDictionary *timeoutJSON = timeoutClient.data.length ? [NSJSONSerialization JSONObjectWithData:timeoutClient.data options:0 error:NULL] : nil;
    Check([timeoutJSON isEqual:@{@"url":@""}] && timeoutClient.completions == 1, @"kg timeout returns one empty URL dictionary");
    Check(cleanupReason.code == NSURLErrorTimedOut, @"short protocol deadline reaches handler as timeout, not ordinary cancellation");
    heldCompletion = nil;
    [FMExtensionProtocol setParseHandler:nil canHandle:nil];
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        checkRows = NSMutableArray.array;
        if (argc != 2 && argc != 3) { fprintf(stderr, "usage: protocol-tests intercept-contract-fixtures.json [report.json]\n"); return 2; }
        NSData *data = [NSData dataWithContentsOfFile:[NSString stringWithUTF8String:argv[1]]];
        NSDictionary *fixtures = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
        if (!fixtures) { fprintf(stderr, "fixture read failed\n"); return 2; }
        __block NSUInteger handlerCalls = 0;
        [FMExtensionProtocol setParseHandler:^FMXParseCancellation(NSURLRequest *request, NSDictionary *parameters, FMXProtocolCompletion complete) {
            handlerCalls++;
            Check(request.HTTPBodyStream == nil && request.HTTPBody.length > 0, @"handler receives retained HTTPBody");
            complete(@{@"code":@200,@"data":@{@"url":@"https://example.invalid/audio.mp3",@"quality":@"standard"}}, nil);
            return nil;
        } canHandle:^BOOL(NSURLRequest *request, NSDictionary *parameters) {
            return [parameters[@"server"] isEqualToString:@"wy"];
        }];
        id priorAggregate = [NSUserDefaults.standardUserDefaults objectForKey:@"FMX.aggregateSearch"];
        for (NSDictionary *test in fixtures[@"request_cases"]) {
            [NSUserDefaults.standardUserDefaults setBool:[test[@"aggregate"] boolValue] forKey:@"FMX.aggregateSearch"];
            NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:test[@"url"]]];
            request.HTTPMethod = test[@"method"];
            if (test[@"body"]) {
                NSData *body = [test[@"body"] dataUsingEncoding:NSUTF8StringEncoding];
                if ([test[@"stream"] boolValue]) request.HTTPBodyStream = [NSInputStream inputStreamWithData:body];
                else request.HTTPBody = body;
                [request setValue:@"application/x-www-form-urlencoded; charset=utf-8" forHTTPHeaderField:@"Content-Type"];
            }
            Check([FMExtensionProtocol canInitWithRequest:request] == [test[@"intercept"] boolValue], test[@"name"]);
            NSDictionary *parameters = FMXRequestParameters(request);
            for (NSString *key in test[@"expected_parameters"]) {
                Check([parameters[key] isEqual:test[@"expected_parameters"][key]], [test[@"name"] stringByAppendingFormat:@" parameter %@", key]);
            }
            [NSURLProtocol setProperty:@YES forKey:@"FMX.internalRequest" inRequest:request];
            Check(![FMExtensionProtocol canInitWithRequest:request], [test[@"name"] stringByAppendingString:@" no recursion"]);
        }
        for (NSDictionary *test in fixtures[@"merge_cases"]) {
            NSDictionary *result = FMXMergeSearchResponses(test[@"responses"], [test[@"page"] integerValue]);
            NSMutableArray *pairs = NSMutableArray.array;
            for (NSDictionary *track in result[@"data"]) [pairs addObject:@[track[@"server"],track[@"id"]]];
            Check([pairs isEqual:test[@"expected_pairs"]], test[@"name"]);
            Check([result[@"count"] unsignedIntegerValue] == pairs.count, [test[@"name"] stringByAppendingString:@" count"]);
        }
        RunSearchRankingTests();
        int listener = StartLoopbackServer();
        Check(listener >= 0, @"local TCP test server starts");
        Method defaultFactory = class_getClassMethod(NSURLSessionConfiguration.class, @selector(defaultSessionConfiguration));
        originalDefaultConfiguration = method_getImplementation(defaultFactory);
        method_setImplementation(defaultFactory, (IMP)TestDefaultConfiguration);
        Method ephemeralFactory = class_getClassMethod(NSURLSessionConfiguration.class, @selector(ephemeralSessionConfiguration));
        originalEphemeralConfiguration = method_getImplementation(ephemeralFactory);
        method_setImplementation(ephemeralFactory, (IMP)TestEphemeralConfiguration);
        NSArray *originalClasses = [NSURLSessionConfiguration.defaultSessionConfiguration.protocolClasses copy];
        [FMExtensionProtocol install];
        [FMExtensionProtocol install];
        NSArray *newClasses = NSURLSessionConfiguration.defaultSessionConfiguration.protocolClasses;
        Check([newClasses containsObject:FMExtensionProtocol.class], @"configuration getter installs interceptor");
        Check([NSURLSessionConfiguration.ephemeralSessionConfiguration.protocolClasses containsObject:FMExtensionProtocol.class], @"ephemeral configuration getter installs interceptor");
        for (Class cls in originalClasses) Check([newClasses containsObject:cls], @"configuration getter preserves protocols");
        Check([NSCountedSet.alloc initWithArray:newClasses].count == newClasses.count, @"configuration getter does not duplicate entries");
        NSMutableURLRequest *parseRequest = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"https://aacert.com/ms/api.php?action=parse"]];
        parseRequest.HTTPMethod = @"POST";
        parseRequest.HTTPBody = [@"server=wy&id=346083&level=standard" dataUsingEncoding:NSUTF8StringEncoding];
        [parseRequest setValue:@"application/x-www-form-urlencoded" forHTTPHeaderField:@"Content-Type"];
        FMXTestClient *client = FMXTestClient.new;
        FMExtensionProtocol *protocol = [[FMExtensionProtocol alloc] initWithRequest:parseRequest cachedResponse:nil client:client];
        [protocol startLoading];
        Check(dispatch_semaphore_wait(client.done, dispatch_time(DISPATCH_TIME_NOW, 3*NSEC_PER_SEC)) == 0, @"parse completion arrives");
        NSDictionary *parsed = client.data.length ? [NSJSONSerialization JSONObjectWithData:client.data options:0 error:NULL] : nil;
        Check(!client.error && [parsed[@"code"] integerValue] == 200 && client.completions == 1, @"parse delegate produces native API envelope");
        [protocol stopLoading];

        if (listener >= 0) {
            NSUInteger beforeHandler = handlerCalls;
            unsigned beforeOrigin = atomic_load(&originRequests);
            NSDictionary *supported = Fetch(StreamRequest(@"action=parse&_t=123", @"server=wy&id=346083&level=standard&title=A%2BB+Song&singer=Beyond"));
            Check([supported[@"status"] integerValue] == 200 && [supported[@"json"] isKindOfClass:NSDictionary.class] && [supported[@"json"][@"code"] integerValue] == 200,
                  @"NSURLSession streamed parse reaches JS handler envelope");
            Check(handlerCalls == beforeHandler+1 && atomic_load(&originRequests) == beforeOrigin, @"supported streamed parse does not contact origin");

            NSString *originalBody = @"server=qq&id=0019uVBT0LJCDw&level=qq_standard&title=A%2BB+Song&singer=Beyond";
            NSDictionary *unsupported = Fetch(StreamRequest(@"action=parse&_t=456&echo_status=207", originalBody));
            NSDictionary *echo = [unsupported[@"json"] isKindOfClass:NSDictionary.class] ? unsupported[@"json"] : @{};
            Check([unsupported[@"status"] integerValue] == 207, @"unsupported parse preserves original HTTP status");
            Check([echo[@"body"] isEqual:originalBody] && [echo[@"method"] isEqual:@"POST"], @"unsupported parse preserves complete stream and method");
            Check([echo[@"path"] isEqual:@"/ms/api.php?action=parse&_t=456&echo_status=207"], @"unsupported parse preserves query");
            Check([echo[@"headers"][@"cookie"] isEqual:@"fixture_cookie=local_only"] &&
                  [echo[@"headers"][@"authorization"] isEqual:@"Bearer fixture-local-only"], @"unsupported parse preserves Cookie and Authorization");
            Check(handlerCalls == beforeHandler+1, @"unsupported parse does not call JS handler");

            NSDictionary *login = Fetch(StreamRequest(@"action=login&_t=789", @"name=fixture&action_detail=unchanged"));
            Check([login[@"json"] isKindOfClass:NSDictionary.class] && [login[@"json"][@"body"] isEqual:@"name=fixture&action_detail=unchanged"], @"login flow passes through unchanged");
            NSDictionary *noAction = Fetch(StreamRequest(@"_t=790", @"no_action=unchanged"));
            Check([noAction[@"json"] isKindOfClass:NSDictionary.class] && [noAction[@"json"][@"body"] isEqual:@"no_action=unchanged"], @"NoAction flow passes through unchanged");

            unsigned failureOrigin = atomic_load(&originRequests);
            NSString *large = [@"server=wy&id=1&title=" stringByPaddingToLength:65537 withString:@"x" startingAtIndex:0];
            NSDictionary *oversize = Fetch(StreamRequest(@"action=parse", large));
            Check([oversize[@"error"] isKindOfClass:NSError.class], @"oversize streamed body fails explicitly");
            NSDictionary *invalid = Fetch(StreamRequest(@"action=parse", @"server=wy&id=%ZZ"));
            Check([invalid[@"error"] isKindOfClass:NSError.class], @"malformed stream fails explicitly");
            Check(atomic_load(&originRequests) == failureOrigin, @"failed body reads never forward partial requests");

            [FMExtensionProtocol setParseHandler:nil canHandle:nil];
            NSDictionary *disabled = Fetch(StreamRequest(@"action=parse&_t=791", @"server=wy&id=346083"));
            Check([disabled[@"json"] isKindOfClass:NSDictionary.class] && [disabled[@"json"][@"body"] isEqual:@"server=wy&id=346083"], @"no handler preserves original parse flow");
        }

        RunKugouTests(fixtures, listener >= 0);
        if (listener >= 0) RunParseBudgetTests();
        if (listener >= 0) RunLXMCImportTests();
        if (listener >= 0) RunSearchRankingIntegrationTests();

        if (listener >= 0) {
            [NSUserDefaults.standardUserDefaults setBool:NO forKey:@"FMX.aggregateSearch"];
            __block NSUInteger observed=0;
            __block NSDictionary *observedResponse=nil;
            [FMExtensionProtocol setTrackMetadataObserver:^(id response){observed++;observedResponse=response;}];
            NSMutableURLRequest *search=[NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"https://aacert.com/ms/api.php?action=search&keyword=authored&platform=2&page=0"]];
            [search setValue:@"local-contract" forHTTPHeaderField:@"X-FMX-Test"];
            unsigned before=atomic_load(&originRequests);
            Check([FMExtensionProtocol canInitWithRequest:search],@"metadata observer accepts native search without enabling aggregation");
            NSDictionary *result=Fetch(search);
            Check(observed==1&&[result[@"json"] isEqual:observedResponse],@"native search response reaches observer and caller unchanged");
            Check(atomic_load(&originRequests)==before+1,@"metadata observation makes exactly one original request");
            [FMExtensionProtocol setTrackMetadataObserver:nil];
            Check(![FMExtensionProtocol canInitWithRequest:search],@"removing observer restores ordinary nonaggregate selection");
        }

        // Direct lifecycle checks keep custom waiting streams outside Foundation's own upload reader.
        FMXWaitingStream *waiting = FMXWaitingStream.new;
        NSMutableURLRequest *timeoutRequest = StreamRequest(@"action=parse", @"unused");
        timeoutRequest.HTTPBodyStream = waiting;
        timeoutRequest.timeoutInterval = 0.1;
        FMXTestClient *timeoutClient = FMXTestClient.new;
        FMExtensionProtocol *timeoutProtocol = [[FMExtensionProtocol alloc] initWithRequest:timeoutRequest cachedResponse:nil client:timeoutClient];
        [timeoutProtocol startLoading];
        Check(dispatch_semaphore_wait(timeoutClient.done, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)) == 0 && timeoutClient.error.code == NSURLErrorTimedOut,
              @"waiting stream cannot block timeout");
        Check(dispatch_semaphore_wait(waiting.closed, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)) == 0, @"timed-out stream closes");

        FMXWaitingStream *cancelledStream = FMXWaitingStream.new;
        NSMutableURLRequest *cancelRequest = StreamRequest(@"action=parse", @"unused");
        cancelRequest.HTTPBodyStream = cancelledStream;
        FMXTestClient *cancelClient = FMXTestClient.new;
        FMExtensionProtocol *cancelProtocol = [[FMExtensionProtocol alloc] initWithRequest:cancelRequest cachedResponse:nil client:cancelClient];
        [cancelProtocol startLoading];
        [NSThread sleepForTimeInterval:0.03];
        [cancelProtocol stopLoading];
        Check(dispatch_semaphore_wait(cancelledStream.closed, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)) == 0 && cancelClient.completions == 0,
              @"cancel closes stream without late client completion");
        [FMExtensionProtocol setParseHandler:nil canHandle:nil];
        method_setImplementation(defaultFactory, originalDefaultConfiguration);
        method_setImplementation(ephemeralFactory, originalEphemeralConfiguration);
        if (listener >= 0) { shutdown(listener, SHUT_RDWR); close(listener); }
        if (priorAggregate) [NSUserDefaults.standardUserDefaults setObject:priorAggregate forKey:@"FMX.aggregateSearch"];
        else [NSUserDefaults.standardUserDefaults removeObjectForKey:@"FMX.aggregateSearch"];
        if (argc == 3) {
            NSUInteger semanticChecks = 0, integrationChecks = 0;
            for (NSDictionary *row in checkRows) {
                if ([row[@"scope"] isEqual:@"ranking.semantic"]) semanticChecks++;
                if ([row[@"scope"] isEqual:@"ranking.integration"]) integrationChecks++;
            }
            NSDictionary *report = @{@"passed":@(failures == 0), @"failures":@(failures), @"assertions":@(checkRows.count), @"cases":[checkRows copy],
                @"evidence":@{@"external_network_used":@NO, @"original_app_runtime_verified":@NO,
                    @"ranking_semantic_assertions":@(semanticChecks), @"ranking_integration_assertions":@(integrationChecks),
                    @"ranking_actual_loopback_requests":@(rankingLoopbackRequests), @"ranking_actual_qishui_stub_calls":@(rankingQishuiCalls),
                    @"ranking_actual_session_callbacks":@(rankingSessionCallbacks), @"ranking_integration_ran":@(rankingSessionCallbacks > 0)}};
            NSError *reportError = nil;
            NSData *reportData = [NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:&reportError];
            if (!reportData || ![reportData writeToFile:[NSString stringWithUTF8String:argv[2]] options:NSDataWritingAtomic error:&reportError]) {
                failures++;
                fprintf(stderr, "FAIL: protocol JSON report could not be saved (%s)\n", reportError.domain.UTF8String ?: "unknown");
            }
        }
        printf("%s: protocol contract tests, %lu assertions, %lu failures\n", failures ? "FAILED" : "DONE", (unsigned long)checkRows.count, (unsigned long)failures);
        return failures ? 1 : 0;
    }
}
