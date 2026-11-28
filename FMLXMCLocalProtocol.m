#import "FMLXMCLocalProtocol.h"
#import "FMLXMCLocalStore.h"
#import "FMTrackMetadata.h"
static NSString *const FMLocalHandled=@"FMX.LXMC.LocalProtocolHandled";
static NSURLRequest *FMEditorListRequest;
static NSDictionary *FMParameters(NSString *string){
    NSMutableDictionary *values=[NSMutableDictionary dictionary];
    for(NSString *part in [string componentsSeparatedByString:@"&"]){NSRange equals=[part rangeOfString:@"="];if(equals.location==NSNotFound)continue;
        NSString *key=[[[part substringToIndex:equals.location] stringByReplacingOccurrencesOfString:@"+" withString:@" "] stringByRemovingPercentEncoding];
        NSString *value=[[[part substringFromIndex:equals.location+1] stringByReplacingOccurrencesOfString:@"+" withString:@" "] stringByRemovingPercentEncoding];
        if(!key||!value||values[key])return nil;values[key]=value;
    }return values;
}
@interface FMLXMCLocalProtocol ()<NSURLSessionDataDelegate>
@property(nonatomic,strong) NSURLSession *session;
@property(nonatomic,strong) NSURLSessionDataTask *task;
@property(nonatomic,strong) NSMutableData *received;
@property(nonatomic,strong) NSURLResponse *response;
@property(nonatomic,strong) NSMutableURLRequest *effective;
@property(nonatomic,copy) NSString *action;
@property(nonatomic,copy) NSString *playlistID;
@property(nonatomic,copy) NSString *editorPlaylistKey;
@property(nonatomic) BOOL directStream;
@property(nonatomic,strong) dispatch_queue_t queue;
@property(atomic) BOOL stopped;
@property(atomic) BOOL finished;
@property(atomic,strong) NSInputStream *bodyStream;
@end
@implementation FMLXMCLocalProtocol
+ (NSURLSessionDataTask *)loadEditorTracksForKey:(NSString *)key completion:(void (^)(NSError *))completion {
    NSURLRequest *template;
    @synchronized(FMLXMCLocalProtocol.class) { template=FMEditorListRequest; }
    NSNumber *identifier=nil;
    for(NSDictionary *row in FMLXMCLocalStore.sharedStore.editorPlaylists) if ([row[@"key"] isEqual:key]) { identifier=row[@"id"]; break; }
    if(!template || identifier.longLongValue<=0) {
        dispatch_async(dispatch_get_main_queue(),^{completion([NSError errorWithDomain:FMLXMCErrorDomain code:56 userInfo:@{NSLocalizedDescriptionKey:@"请先刷新资料库以载入当前账号的歌单。"}]);});
        return nil;
    }
    NSURLComponents *url=[NSURLComponents componentsWithURL:template.URL resolvingAgainstBaseURL:NO];
    NSMutableArray *query=[NSMutableArray array];
    for(NSURLQueryItem *q in url.queryItems) if (![q.name isEqual:@"action"] && ![q.name isEqual:@"playlist_id"]) [query addObject:q];
    [query addObject:[NSURLQueryItem queryItemWithName:@"action" value:@"playlist_get_tracks"]];
    [query addObject:[NSURLQueryItem queryItemWithName:@"playlist_id" value:identifier.stringValue]];
    url.queryItems=query;
    NSMutableURLRequest *request=[template mutableCopy]; request.URL=url.URL; request.timeoutInterval=15;
    request.cachePolicy=NSURLRequestReloadIgnoringLocalCacheData;
    [NSURLProtocol removePropertyForKey:FMLocalHandled inRequest:request];
    NSURLSession *session=[NSURLSession sessionWithConfiguration:NSURLSessionConfiguration.defaultSessionConfiguration];
    NSURLSessionDataTask *task=[session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        [session finishTasksAndInvalidate];
        id result = data.length && data.length <= 32*1024*1024 ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        BOOL ok = [result isKindOfClass:NSDictionary.class] && [result[@"code"] integerValue]==200 && [result[@"data"] isKindOfClass:NSArray.class];
        dispatch_async(dispatch_get_main_queue(),^{
            NSError *problem=error;
            if(!problem && (!ok || ![FMLXMCLocalStore.sharedStore editorTracks:key]))
                problem=[NSError errorWithDomain:FMLXMCErrorDomain code:57 userInfo:@{NSLocalizedDescriptionKey:@"暂时无法读取这张歌单，请在资料库刷新后重试。"}];
            completion(problem);
        });
    }];
    [task resume]; return task;
}
+ (BOOL)canInitWithRequest:(NSURLRequest *)request{
    NSURL *url=request.URL;if([NSURLProtocol propertyForKey:FMLocalHandled inRequest:request]||![url.scheme.lowercaseString isEqual:@"https"]||![url.host.lowercaseString isEqual:@"aacert.com"]||![url.path isEqual:@"/ms/api.php"]||url.user.length||url.password.length||(url.port&&url.port.integerValue!=443))return NO;
    NSString *action=FMParameters(url.query?:@"")[@"action"],*method=request.HTTPMethod.uppercaseString?:@"GET";
    if([action isEqual:@"playlist_list"]||[action isEqual:@"playlist_get_tracks"])return [method isEqual:@"GET"];
    return [method isEqual:@"POST"]&&[@[@"import_playlist",@"playlist_create",@"playlist_add_tracks_bulk",@"playlist_add_track",@"playlist_del_track",@"playlist_delete",@"playlist_tracks_reorder",@"playlist_reorder"] containsObject:action?:@""];
}
+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request{return request;}
- (void)startLoading{
    self.queue=dispatch_queue_create("FMX.LXMC.NativeRequest",DISPATCH_QUEUE_SERIAL);
    NSTimeInterval budget=MIN(20,self.request.timeoutInterval>0?self.request.timeoutInterval:20);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(budget*NSEC_PER_SEC)),self.queue,^{
        if(self.stopped||self.finished)return;[self.bodyStream close];[self.task cancel];[self.session invalidateAndCancel];
        [self fail:[NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorTimedOut userInfo:@{NSLocalizedDescriptionKey:@"歌单请求超时，未完成的导入不会覆盖原歌单。"}]];
    });
    // A body stream may temporarily return zero or block in read. Keep it off the
    // serialized state/delegate queue so cancellation/deadlines can close it.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{@autoreleasepool{
        if(self.stopped)return;NSMutableURLRequest *request=[self.request mutableCopy];
        NSData *body=request.HTTPBody;NSError *readError=nil;
        if(!body&&request.HTTPBodyStream){NSInputStream *stream=request.HTTPBodyStream;self.bodyStream=stream;
            if(self.stopped||self.finished){[stream close];return;}[stream open];NSMutableData *bytes=[NSMutableData data];unsigned char chunk[32768];BOOL complete=NO;
            while(!self.stopped&&!self.finished){NSInteger count=[stream read:chunk maxLength:sizeof(chunk)];
                if(count>0){if(bytes.length+(NSUInteger)count>FMLXMCMaximumExpandedBytes){readError=[NSError errorWithDomain:FMLXMCErrorDomain code:50 userInfo:nil];break;}[bytes appendBytes:chunk length:(NSUInteger)count];}
                else if(count<0||stream.streamStatus==NSStreamStatusError){readError=stream.streamError?:[NSError errorWithDomain:FMLXMCErrorDomain code:50 userInfo:nil];break;}
                else if(stream.streamStatus==NSStreamStatusAtEnd){complete=YES;break;}
                else if(stream.streamStatus==NSStreamStatusClosed){break;}
                else [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.005]];
            }[stream close];self.bodyStream=nil;
            if(self.stopped||self.finished)return;if(!complete&&!readError)readError=[NSError errorWithDomain:FMLXMCErrorDomain code:50 userInfo:nil];body=bytes;request.HTTPBodyStream=nil;request.HTTPBody=body;
        }
        dispatch_async(self.queue,^{if(self.stopped||self.finished)return;if(readError){[self fail:readError];return;}[self beginRequest:request body:body];});
    }});
}
- (void)beginRequest:(NSMutableURLRequest *)request body:(NSData *)body{
        if(body.length>FMLXMCMaximumExpandedBytes){[self fail:[NSError errorWithDomain:FMLXMCErrorDomain code:50 userInfo:@{NSLocalizedDescriptionKey:@"歌单请求过大，原歌单未改动。"}]];return;}
        NSDictionary *bodyParameters=FMParameters([[NSString alloc]initWithData:body?:NSData.data encoding:NSUTF8StringEncoding]?:@"");
        if(!bodyParameters){[self fail:[NSError errorWithDomain:FMLXMCErrorDomain code:50 userInfo:@{NSLocalizedDescriptionKey:@"歌单请求含重复或无效字段，未转发。"}]];return;}
        self.effective=request;NSMutableDictionary *parameters=[FMParameters(request.URL.query?:@"") mutableCopy];self.action=parameters[@"action"]?:@"";[parameters addEntriesFromDictionary:bodyParameters];parameters[@"action"]=self.action;
        self.playlistID=parameters[@"playlist_id"];
        if ([self.action isEqual:@"playlist_get_tracks"]) {
            for (NSDictionary *row in FMLXMCLocalStore.sharedStore.editorPlaylists) {
                if ([[row[@"id"] description] isEqual:self.playlistID]) { self.editorPlaylistKey=row[@"key"]; break; }
            }
        }
        if(self.stopped)return;
        NSDictionary *result=[FMLXMCLocalStore.sharedStore responseForAction:self.action parameters:parameters importRequest:request];
        if(result){
            if([result[@"code"] integerValue]==200&&[@[@"playlist_get_tracks",@"import_playlist"] containsObject:self.action])FMTrackMetadataObserveResponse(result);
            [self deliver:result];return;
        }
        // Local IDs never go to the remote account, including mixed reorder IDs.
        // The order of local entries is managed by the original library display;
        // cloud order is sent with only its original, positive identities.
        if([self.action isEqual:@"playlist_reorder"]){NSArray *ids=[parameters[@"ids"] componentsSeparatedByString:@","];NSMutableArray *cloud=[NSMutableArray array];BOOL local=NO;
            for(NSString *identifier in ids){if([FMLXMCLocalStore.sharedStore ownsPlaylistID:identifier])local=YES;else[cloud addObject:identifier];}
            if(local){if(!cloud.count){[self deliver:@{@"code":@200,@"data":@YES}];return;}parameters[@"ids"]=[cloud componentsJoinedByString:@","];[parameters removeObjectForKey:@"action"];NSMutableArray *parts=[NSMutableArray array];NSCharacterSet *allowed=[NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~"];
                for(NSString *key in parameters)[parts addObject:[NSString stringWithFormat:@"%@=%@",[key stringByAddingPercentEncodingWithAllowedCharacters:allowed],[parameters[key] stringByAddingPercentEncodingWithAllowedCharacters:allowed]]];request.HTTPBody=[[parts componentsJoinedByString:@"&"]dataUsingEncoding:NSUTF8StringEncoding];[request setValue:nil forHTTPHeaderField:@"Content-Length"];
            }
        }
        [NSURLProtocol setProperty:@YES forKey:FMLocalHandled inRequest:request];
        NSURLSessionConfiguration *configuration=NSURLSessionConfiguration.defaultSessionConfiguration;
        configuration.requestCachePolicy=NSURLRequestReloadIgnoringLocalCacheData;self.received=[NSMutableData data];
        NSOperationQueue *delegates=[NSOperationQueue new];delegates.maxConcurrentOperationCount=1;delegates.underlyingQueue=self.queue;
        self.session=[NSURLSession sessionWithConfiguration:configuration delegate:self delegateQueue:delegates];self.task=[self.session dataTaskWithRequest:request];
        if(self.stopped){[self.session invalidateAndCancel];return;}[self.task resume];
        if([self.action isEqual:@"playlist_list"]&&FMLXMCLocalStore.sharedStore.nativePlaylists.count){
            // Local library availability must not depend on an unreachable cloud.
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,4*NSEC_PER_SEC),self.queue,^{if(self.stopped||self.finished)return;[self deliver:[FMLXMCLocalStore.sharedStore mergePlaylistList:nil]];[self.task cancel];[self.session invalidateAndCancel];});
        }
}
- (void)deliver:(NSDictionary *)result{
    if(self.stopped||self.finished)return;NSError *error=nil;NSData *data=[NSJSONSerialization dataWithJSONObject:result options:0 error:&error];if(!data){[self fail:error];return;}self.finished=YES;
    NSHTTPURLResponse *response=[[NSHTTPURLResponse alloc]initWithURL:self.request.URL statusCode:200 HTTPVersion:@"HTTP/1.1" headerFields:@{@"Content-Type":@"application/json; charset=utf-8",@"Cache-Control":@"no-store"}];
    [self.client URLProtocol:self didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageNotAllowed];if(self.stopped)return;[self.client URLProtocol:self didLoadData:data];if(!self.stopped)[self.client URLProtocolDidFinishLoading:self];
}
- (void)fail:(NSError *)error{if(!self.stopped&&!self.finished){self.finished=YES;[self.client URLProtocol:self didFailWithError:error?:[NSError errorWithDomain:FMLXMCErrorDomain code:51 userInfo:nil]];}}
- (void)stopLoading{self.stopped=YES;[self.bodyStream close];[self.task cancel];[self.session invalidateAndCancel];}
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didReceiveResponse:(NSURLResponse *)response completionHandler:(void (^)(NSURLSessionResponseDisposition))completionHandler{
    if(self.stopped||self.finished){completionHandler(NSURLSessionResponseCancel);return;}
    self.response=response;
    if(![self.action isEqual:@"playlist_list"]&&![self.action isEqual:@"playlist_get_tracks"]&&!self.stopped)[self.client URLProtocol:self didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    completionHandler(self.stopped?NSURLSessionResponseCancel:NSURLSessionResponseAllow);
}
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveData:(NSData *)data{
    if(self.stopped||self.finished)return;
    if([self.action isEqual:@"playlist_get_tracks"] && !self.directStream){
        if(self.received.length+data.length<=32*1024*1024){[self.received appendData:data];return;}
        self.directStream=YES;
        [self.client URLProtocol:self didReceiveResponse:self.response cacheStoragePolicy:NSURLCacheStorageNotAllowed];
        [self.client URLProtocol:self didLoadData:self.received];[self.received setLength:0];
        [self.client URLProtocol:self didLoadData:data];
    }
    else if([self.action isEqual:@"playlist_list"]){if(self.received.length+data.length>8*1024*1024){[self.task cancel];return;}[self.received appendData:data];}
    else[self.client URLProtocol:self didLoadData:data];
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error{
    if(!self.stopped&&!self.finished){
        if([self.action isEqual:@"playlist_list"]){id response=!error?[NSJSONSerialization JSONObjectWithData:self.received options:0 error:nil]:nil;
            BOOL good=[response isKindOfClass:NSDictionary.class]&&[response[@"code"] integerValue]==200&&[response[@"data"] isKindOfClass:NSArray.class];
            @synchronized(FMLXMCLocalProtocol.class){ FMEditorListRequest=good?[self.request copy]:nil; }
            if(good || FMLXMCLocalStore.sharedStore.nativePlaylists.count)[self deliver:[FMLXMCLocalStore.sharedStore mergePlaylistList:good?response:nil]];
            else { [FMLXMCLocalStore.sharedStore mergePlaylistList:nil]; if(error)[self fail:error];else{self.finished=YES;[self.client URLProtocol:self didReceiveResponse:self.response cacheStoragePolicy:NSURLCacheStorageNotAllowed];[self.client URLProtocol:self didLoadData:self.received];[self.client URLProtocolDidFinishLoading:self];} }
        }else if([self.action isEqual:@"playlist_get_tracks"] && !self.directStream && !error){
            id body=[NSJSONSerialization JSONObjectWithData:self.received options:0 error:nil];
            if([body isKindOfClass:NSDictionary.class]&&[body[@"code"] integerValue]==200&&[body[@"data"] isKindOfClass:NSArray.class]) {
                BOOL sameOwner=NO;
                for(NSDictionary *row in FMLXMCLocalStore.sharedStore.editorPlaylists) if([row[@"key"] isEqual:self.editorPlaylistKey] &&
                    [[row[@"id"] description] isEqual:self.playlistID]) { sameOwner=YES; break; }
                NSDictionary *merged=sameOwner ? [FMLXMCLocalStore.sharedStore mergeTracks:body playlistID:self.playlistID] : body;
                FMTrackMetadataObserveResponse(merged); [self deliver:merged];
            } else {
                self.finished=YES; [self.client URLProtocol:self didReceiveResponse:self.response cacheStoragePolicy:NSURLCacheStorageNotAllowed];
                [self.client URLProtocol:self didLoadData:self.received];[self.client URLProtocolDidFinishLoading:self];
            }
        }else if(error)[self fail:error];else{self.finished=YES;[self.client URLProtocolDidFinishLoading:self];}
    }[session finishTasksAndInvalidate];self.session=nil;
}
@end
