// Authored native-contract integration: production URL protocols, real loopback
// HTTP and real atomic local files. No original executable or external requests.
#import "FMLXMCLocalStore.h"
#import "FMLXMCLocalProtocol.h"
#import "FMExtensionProtocol.h"
#import "FMTrackMetadata.h"
#import <objc/runtime.h>
#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <unistd.h>
#import <stdatomic.h>
#import <string.h>

static NSUInteger failures,requests;
static NSMutableArray *cases;
static FMLXMCLocalStore *fixtureStore;
static IMP defaultIMP,ephemeralIMP,storeIMP;
static uint16_t port;
static atomic_uint httpRequests,leakedPrivateRequests,remoteReorders,invalidRemoteReorders;
static atomic_int listMode;
static NSData *JSON(id value){return [NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingSortedKeys error:nil];}
static void Check(BOOL ok,NSString *name){[cases addObject:@{@"name":name,@"passed":@(ok)}];if(!ok)failures++;printf("%s %s\n",ok?"PASS":"FAIL",name.UTF8String);}
static void Pump(double seconds){NSDate *until=[NSDate dateWithTimeIntervalSinceNow:seconds];while([until timeIntervalSinceNow]>0)[NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.002]];}
static id Shared(id receiver,SEL selector){return fixtureStore;}
static NSString *Form(NSDictionary *parameters){NSMutableArray *parts=[NSMutableArray array];NSCharacterSet *allowed=[NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~"];for(NSString *key in parameters)[parts addObject:[NSString stringWithFormat:@"%@=%@",[key stringByAddingPercentEncodingWithAllowedCharacters:allowed],[[parameters[key] description] stringByAddingPercentEncodingWithAllowedCharacters:allowed]]];return [parts componentsJoinedByString:@"&"];}
static NSURLRequest *Request(NSString *action,NSDictionary *parameters,BOOL stream){BOOL get=[@[@"playlist_list",@"playlist_get_tracks"] containsObject:action];NSString *form=Form(parameters);NSMutableURLRequest *request=[NSMutableURLRequest requestWithURL:[NSURL URLWithString:[NSString stringWithFormat:@"https://aacert.com/ms/api.php?action=%@%@",action,get?[@"&" stringByAppendingString:form]:@""]] cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:10];request.HTTPMethod=get?@"GET":@"POST";
    if(!get){NSData *body=[form dataUsingEncoding:NSUTF8StringEncoding];if(stream)request.HTTPBodyStream=[NSInputStream inputStreamWithData:body];else request.HTTPBody=body;[request setValue:@"application/x-www-form-urlencoded" forHTTPHeaderField:@"Content-Type"];}return request;
}
static NSDictionary *FetchRequest(NSURLRequest *request){requests++;NSURLSession *session=[NSURLSession sessionWithConfiguration:NSURLSessionConfiguration.defaultSessionConfiguration];dispatch_semaphore_t done=dispatch_semaphore_create(0);__block NSData *data;__block NSError *error;[[session dataTaskWithRequest:request completionHandler:^(NSData *body,NSURLResponse *response,NSError *failure){data=body;error=failure;dispatch_semaphore_signal(done);}]resume];BOOL finished=dispatch_semaphore_wait(done,dispatch_time(DISPATCH_TIME_NOW,12*NSEC_PER_SEC))==0;[session invalidateAndCancel];if(!finished)return @{@"code":@599};if(error)return @{@"code":@598,@"error":@(error.code)};id json=data?[NSJSONSerialization JSONObjectWithData:data options:0 error:nil]:nil;return [json isKindOfClass:NSDictionary.class]?json:@{@"code":@597};}
static NSDictionary *Fetch(NSString *action,NSDictionary *parameters){return FetchRequest(Request(action,parameters,NO));}
static NSDictionary *Song(NSString *identifier){return @{@"source":@"wy",@"name":[@"Song " stringByAppendingString:identifier],@"singer":@"Authored Artist",@"interval":@"03:00",@"meta":@{@"songId":identifier,@"albumName":@"Authored Album"}};}
static FMLXMCPlaylist *Playlist(NSString *origin,NSString *title,NSArray *identifiers){NSMutableArray *songs=[NSMutableArray array];for(NSString *identifier in identifiers)[songs addObject:Song(identifier)];NSMutableDictionary *list=[@{@"name":title,@"list":songs} mutableCopy];if(origin)list[@"id"]=origin;return FMLXMCParseData(JSON(@{@"type":@"playListPart_v2",@"data":list}),nil).playlists.firstObject;}
static NSArray *Bulk(NSArray *tracks){NSMutableArray *result=[NSMutableArray array];for(NSDictionary *track in tracks)[result addObject:@{@"id":track[@"id"],@"title":track[@"title"],@"singer":track[@"singer"]?:@"Unknown Artist",@"server":track[@"server"],@"cover":track[@"cover"]?:@""}];return result;}
static NSDictionary *StartImport(NSString *url){NSDictionary *parsed=Fetch(@"import_playlist",@{@"url":url?:@""});if([parsed[@"code"] integerValue]!=200)return parsed;NSDictionary *create=Fetch(@"playlist_create",@{@"title":parsed[@"data"][@"title"],@"token":@"authored-token"});return @{@"parsed":parsed,@"created":create};}
static NSDictionary *FinishImport(NSDictionary *started){NSNumber *identifier=started[@"created"][@"data"][@"id"];if(!identifier)return @{@"code":@599};NSString *tracks=[[NSString alloc]initWithData:JSON(Bulk(started[@"parsed"][@"data"][@"tracks"])) encoding:NSUTF8StringEncoding];return FetchRequest(Request(@"playlist_add_tracks_bulk",@{@"token":@"authored-token",@"playlist_id":identifier.stringValue,@"tracks":tracks},YES));}
static NSDictionary *Import(FMLXMCPlaylist *playlist,NSNumber *replace){NSError *error=nil;NSString *url=[fixtureStore preparePlaylist:playlist replacing:replace error:&error];if(!url)return @{@"code":@596,@"error":@(error.code)};NSDictionary *started=StartImport(url);NSDictionary *finished=FinishImport(started);return @{@"code":finished[@"code"]?:@0,@"id":started[@"created"][@"data"][@"id"]?:@0};}
static NSArray *Tracks(NSNumber *identifier){return Fetch(@"playlist_get_tracks",@{@"playlist_id":identifier.stringValue})[@"data"];}

@interface LXReadStream:NSInputStream
@property(nonatomic,strong) NSData *bytes;
@property(nonatomic,strong) NSCondition *condition;
@property(nonatomic,strong) dispatch_semaphore_t reading,closed;
@property(nonatomic) BOOL blockReads,wasClosed;
@property(nonatomic) NSUInteger offset,zeroReads;
@end
@implementation LXReadStream
- (instancetype)init{if((self=[super init])){_condition=[NSCondition new];_reading=dispatch_semaphore_create(0);_closed=dispatch_semaphore_create(0);}return self;}
- (void)open{}
- (void)close{[self.condition lock];self.wasClosed=YES;[self.condition broadcast];[self.condition unlock];dispatch_semaphore_signal(self.closed);}
- (NSStreamStatus)streamStatus{if(self.wasClosed)return NSStreamStatusClosed;return self.offset==self.bytes.length&&!self.blockReads&&!self.zeroReads?NSStreamStatusAtEnd:NSStreamStatusOpen;}
- (NSError *)streamError{return nil;}
- (BOOL)hasBytesAvailable{return !self.wasClosed;}
- (NSInteger)read:(uint8_t *)buffer maxLength:(NSUInteger)length{dispatch_semaphore_signal(self.reading);[self.condition lock];while(self.blockReads&&!self.wasClosed)[self.condition wait];if(self.wasClosed){[self.condition unlock];return 0;}if(self.zeroReads){self.zeroReads--;[self.condition unlock];return 0;}NSUInteger count=MIN(length,self.bytes.length-self.offset);if(count)memcpy(buffer,(const uint8_t *)self.bytes.bytes+self.offset,count);self.offset+=count;[self.condition unlock];return (NSInteger)count;}
- (BOOL)getBuffer:(uint8_t **)buffer length:(NSUInteger *)length{return NO;}
@end
@interface LXProtocolClient:NSObject<NSURLProtocolClient>
@property(nonatomic,strong) NSMutableData *body;
@property(nonatomic,strong) NSError *error;
@property(nonatomic,strong) dispatch_semaphore_t done;
@property(atomic) NSUInteger completions;
@property(atomic) NSUInteger responses;
@end
@implementation LXProtocolClient
- (instancetype)init{if((self=[super init])){_body=[NSMutableData data];_done=dispatch_semaphore_create(0);}return self;}
- (void)URLProtocol:(NSURLProtocol *)protocol didReceiveResponse:(NSURLResponse *)response cacheStoragePolicy:(NSURLCacheStoragePolicy)policy{self.responses++;}
- (void)URLProtocol:(NSURLProtocol *)protocol didLoadData:(NSData *)data{[self.body appendData:data];}
- (void)URLProtocolDidFinishLoading:(NSURLProtocol *)protocol{self.completions++;dispatch_semaphore_signal(self.done);}
- (void)URLProtocol:(NSURLProtocol *)protocol didFailWithError:(NSError *)error{self.error=error;self.completions++;dispatch_semaphore_signal(self.done);}
- (void)URLProtocol:(NSURLProtocol *)protocol wasRedirectedToRequest:(NSURLRequest *)request redirectResponse:(NSURLResponse *)response{}
- (void)URLProtocol:(NSURLProtocol *)protocol cachedResponseIsValid:(NSCachedURLResponse *)response{}
- (void)URLProtocol:(NSURLProtocol *)protocol didReceiveAuthenticationChallenge:(NSURLAuthenticationChallenge *)challenge{}
- (void)URLProtocol:(NSURLProtocol *)protocol didCancelAuthenticationChallenge:(NSURLAuthenticationChallenge *)challenge{}
@end

@interface LXLoopbackTransport:NSURLProtocol<NSURLSessionDataDelegate>
@property(nonatomic,strong) NSURLSession *session;
@property(nonatomic,strong) NSURLSessionDataTask *task;
@property(atomic) BOOL stopped;
@end
@implementation LXLoopbackTransport
+ (BOOL)canInitWithRequest:(NSURLRequest *)request{return [request.URL.host isEqual:@"aacert.com"];}
+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request{return request;}
- (void)startLoading{
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{
    NSMutableURLRequest *request=[self.request mutableCopy];NSURLComponents *parts=[NSURLComponents componentsWithURL:request.URL resolvingAgainstBaseURL:NO];parts.scheme=@"http";parts.host=@"127.0.0.1";parts.port=@(port);request.URL=parts.URL;
    // NSURLSession can hand a custom protocol an in-memory POST as a stream.
    // Materialize only this test transport hop, with explicit HTTP framing.
    if(request.HTTPBodyStream){NSInputStream *stream=request.HTTPBodyStream;[stream open];NSMutableData *data=[NSMutableData data];uint8_t bytes[4096];NSInteger count=0;
        while(!self.stopped&&(count=[stream read:bytes maxLength:sizeof(bytes)])>0){[data appendBytes:bytes length:(NSUInteger)count];if(data.length>65536)break;}[stream close];
        if(self.stopped)return;if(count<0||data.length>65536){[self.client URLProtocol:self didFailWithError:stream.streamError?:[NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorCannotDecodeContentData userInfo:nil]];return;}request.HTTPBodyStream=nil;request.HTTPBody=data;
    }
    [request setValue:nil forHTTPHeaderField:@"Transfer-Encoding"];if(request.HTTPBody)[request setValue:@(request.HTTPBody.length).stringValue forHTTPHeaderField:@"Content-Length"];
    if(self.stopped)return;
    self.session=[NSURLSession sessionWithConfiguration:NSURLSessionConfiguration.ephemeralSessionConfiguration delegate:self delegateQueue:nil];self.task=[self.session dataTaskWithRequest:request];[self.task resume];
    });
}
- (void)stopLoading{self.stopped=YES;[self.task cancel];[self.session invalidateAndCancel];}
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveResponse:(NSURLResponse *)response completionHandler:(void(^)(NSURLSessionResponseDisposition))completionHandler{[self.client URLProtocol:self didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageNotAllowed];completionHandler(NSURLSessionResponseAllow);}
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveData:(NSData *)data{[self.client URLProtocol:self didLoadData:data];}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error{if(error)[self.client URLProtocol:self didFailWithError:error];else[self.client URLProtocolDidFinishLoading:self];[session finishTasksAndInvalidate];}
@end
static NSURLSessionConfiguration *Configuration(id receiver,SEL selector,IMP original){NSURLSessionConfiguration *configuration=((id(*)(id,SEL))original)(receiver,selector);NSMutableArray *classes=[configuration.protocolClasses mutableCopy];[classes removeObject:LXLoopbackTransport.class];NSUInteger index=[classes indexOfObject:FMExtensionProtocol.class];[classes insertObject:LXLoopbackTransport.class atIndex:index==NSNotFound?0:index+1];configuration.protocolClasses=classes;return configuration;}
static id Default(id receiver,SEL selector){return Configuration(receiver,selector,defaultIMP);}
static id Ephemeral(id receiver,SEL selector){return Configuration(receiver,selector,ephemeralIMP);}
static BOOL SendAll(int client,NSData *data){NSUInteger offset=0;while(offset<data.length){ssize_t size=send(client,(const uint8_t *)data.bytes+offset,data.length-offset,0);if(size<=0)return NO;offset+=(NSUInteger)size;}return YES;}
static int StartServer(void){int listener=socket(AF_INET,SOCK_STREAM,0);struct sockaddr_in address={0};address.sin_len=sizeof(address);address.sin_family=AF_INET;address.sin_addr.s_addr=htonl(INADDR_LOOPBACK);if(listener<0||bind(listener,(struct sockaddr *)&address,sizeof(address))||listen(listener,16))return -1;socklen_t size=sizeof(address);getsockname(listener,(struct sockaddr *)&address,&size);port=ntohs(address.sin_port);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{while(YES){int client=accept(listener,NULL,NULL);if(client<0)return;dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{@autoreleasepool{
        int one=1;setsockopt(client,SOL_SOCKET,SO_NOSIGPIPE,&one,sizeof(one));struct timeval timeout={2,0};setsockopt(client,SOL_SOCKET,SO_RCVTIMEO,&timeout,sizeof(timeout));NSMutableData *received=[NSMutableData data];NSData *separator=[@"\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding];uint8_t bytes[4096];NSRange range;
        do{ssize_t count=recv(client,bytes,sizeof(bytes),0);if(count<=0){close(client);return;}[received appendBytes:bytes length:(NSUInteger)count];range=[received rangeOfData:separator options:0 range:NSMakeRange(0,received.length)];}while(range.location==NSNotFound&&received.length<65536);
        if(range.location==NSNotFound){close(client);return;}
        NSString *head=[[NSString alloc]initWithData:[received subdataWithRange:NSMakeRange(0,range.location)] encoding:NSUTF8StringEncoding];NSUInteger length=0;
        for(NSString *line in [head componentsSeparatedByString:@"\r\n"])if([line.lowercaseString hasPrefix:@"content-length:"])length=(NSUInteger)[[line substringFromIndex:15] integerValue];
        NSUInteger start=NSMaxRange(range);if(length>65536){close(client);return;}
        // Closing with an unread POST body can reset the connection and make a
        // valid production reorder fail intermittently. Consume the whole body.
        while(received.length<start+length){ssize_t count=recv(client,bytes,MIN(sizeof(bytes),start+length-received.length),0);if(count<=0){close(client);return;}[received appendBytes:bytes length:(NSUInteger)count];}
        NSString *raw=[[NSString alloc]initWithData:received encoding:NSUTF8StringEncoding];if(!raw){close(client);return;}atomic_fetch_add(&httpRequests,1);if([raw containsString:@"fmx-lxmc"]||[raw containsString:@"FMX-LXMC-LOCAL"])atomic_fetch_add(&leakedPrivateRequests,1);
        if([head containsString:@"action=playlist_reorder"]){NSString *bodyText=[[NSString alloc]initWithData:[received subdataWithRange:NSMakeRange(start,length)] encoding:NSUTF8StringEncoding];atomic_fetch_add(&remoteReorders,1);if(![bodyText isEqual:@"ids=77"])atomic_fetch_add(&invalidRemoteReorders,1);}
        BOOL list=[raw containsString:@"action=playlist_list"],cloudImport=[raw containsString:@"action=import_playlist"];int mode=atomic_load(&listMode);
        if(list&&mode==2){close(client);return;}
        NSDictionary *payload=list?@{@"code":@200,@"data":@[@{@"id":@77,@"title":@"Existing cloud playlist",@"user_id":@42,@"count":@3}]}:cloudImport?@{@"code":@200,@"data":@{@"title":@"Original platform import",@"tracks":@[]}}:@{@"code":@200,@"data":@YES};
        NSData *body=JSON(payload);NSString *header=[NSString stringWithFormat:@"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: %lu\r\nConnection: close\r\n\r\n",(unsigned long)body.length];SendAll(client,[header dataUsingEncoding:NSUTF8StringEncoding]);if(list&&mode==1)usleep(6000000);SendAll(client,body);close(client);
    }});}});return listener;
}
int main(int argc,const char *argv[]){@autoreleasepool{
    cases=[NSMutableArray array];NSURL *root=[[NSURL fileURLWithPath:NSTemporaryDirectory()]URLByAppendingPathComponent:[@"FMXLocalTest-" stringByAppendingString:NSUUID.UUID.UUIDString] isDirectory:YES];fixtureStore=[[FMLXMCLocalStore alloc]initWithDirectory:root];
    int listener=StartServer();Check(listener>=0,@"loopback_server_starts_without_external_network");
    Method shared=class_getClassMethod(FMLXMCLocalStore.class,@selector(sharedStore));storeIMP=method_setImplementation(shared,(IMP)Shared);
    Method defaultMethod=class_getClassMethod(NSURLSessionConfiguration.class,@selector(defaultSessionConfiguration)),ephemeralMethod=class_getClassMethod(NSURLSessionConfiguration.class,@selector(ephemeralSessionConfiguration));defaultIMP=method_setImplementation(defaultMethod,(IMP)Default);ephemeralIMP=method_setImplementation(ephemeralMethod,(IMP)Ephemeral);[FMExtensionProtocol install];
    NSArray *classes=NSURLSessionConfiguration.defaultSessionConfiguration.protocolClasses;
    Check([classes indexOfObject:FMLXMCLocalProtocol.class]<[classes indexOfObject:FMExtensionProtocol.class]&&[NSCountedSet.alloc initWithArray:classes].count==classes.count,@"production_configuration_installs_local_protocol_first_once");
    __block NSUInteger resultNotifications=0;__block NSDictionary *lastResult;id observer=[NSNotificationCenter.defaultCenter addObserverForName:FMLXMCLocalImportDidFinish object:fixtureStore queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note){resultNotifications++;lastResult=note.userInfo;}];
    FMLXMCPlaylist *initial=Playlist(@"origin-001",@"Authored favorites",@[@"101",@"102"]);NSError *error=nil;
    NSString *url=[fixtureStore preparePlaylist:initial replacing:nil error:&error];NSDictionary *staged=StartImport(url);NSNumber *identifier=staged[@"created"][@"data"][@"id"];
    Check(identifier.longLongValue<0&&fixtureStore.nativePlaylists.count==0&&![[NSFileManager defaultManager]fileExistsAtPath:[[root URLByAppendingPathComponent:@"playlists.json"]path]],@"native_create_reserves_identity_without_exposing_empty_playlist");
    NSDictionary *saved=FinishImport(staged);NSArray *tracks=Tracks(identifier);Pump(0.03);
    Check([saved[@"code"] integerValue]==200&&tracks.count==2&&[tracks[0][@"record_id"] longLongValue]<0&&[tracks[0][@"duration"] integerValue]==180,@"real_session_native_import_create_bulk_get_commits_complete_tracks");
    Check(resultNotifications==1&&[lastResult[@"success"] boolValue],@"successful_commit_posts_one_explicit_result");
    NSDictionary *list=Fetch(@"playlist_list",@{});Check([list[@"data"] count]==2&&[list[@"data"][0][@"id"] isEqual:@77]&&[list[@"data"][1][@"id"] isEqual:identifier],@"native_library_merges_local_playlist_without_hiding_cloud_entry");
    FMLXMCLocalStore *reloaded=[[FMLXMCLocalStore alloc]initWithDirectory:root];Check(reloaded.nativePlaylists.count==1&&[reloaded.nativePlaylists.firstObject[@"id"] isEqual:identifier],@"committed_playlist_survives_real_store_reload");
    FMTrackMetadataReset();FMLXMCLocalStore *priorStore=fixtureStore;fixtureStore=reloaded;Tracks(identifier);NSDictionary *restoredMetadata=FMTrackMetadataForParameters(@{@"id":@"101"},@"wy");fixtureStore=priorStore;
    Check([restoredMetadata[@"name"] isEqual:@"Song 101"]&&[restoredMetadata[@"singer"] isEqual:@"Authored Artist"]&&[restoredMetadata[@"albumName"] isEqual:@"Authored Album"]&&[restoredMetadata[@"interval"] isEqual:@"03:00"],@"cold_store_get_tracks_restores_base_metadata_for_js_playback");
    Check([fixtureStore matchesForPlaylist:Playlist(@"origin-001",@"Renamed",@[@"103"])].count==1&&[fixtureStore matchesForPlaylist:Playlist(@"origin-other",initial.title,@[@"101",@"102"])].count==0,@"source_provenance_finds_updates_without_using_title_as_identity");
    FMLXMCPlaylist *updated=Playlist(@"origin-001",@"Renamed",@[@"103"]);NSDictionary *replacement=Import(updated,identifier);
    Check([replacement[@"code"] integerValue]==200&&[replacement[@"id"] isEqual:identifier]&&fixtureStore.nativePlaylists.count==1&&[Tracks(identifier).firstObject[@"id"] isEqual:@"103"],@"explicit_overwrite_keeps_native_id_and_atomically_replaces_content");
    NSDictionary *copy=Import(updated,nil);NSNumber *copyID=copy[@"id"];
    Check([copy[@"code"] integerValue]==200&&![copyID isEqual:identifier]&&fixtureStore.nativePlaylists.count==2&&[fixtureStore matchesForPlaylist:updated].count==2,@"explicit_save_copy_creates_visible_separate_playlist");
    NSUInteger before=fixtureStore.nativePlaylists.count;NSString *cancelled=[fixtureStore preparePlaylist:initial replacing:identifier error:&error];[fixtureStore revokeImportURL:cancelled];NSDictionary *cancelResponse=Fetch(@"import_playlist",@{@"url":cancelled});
    Check([cancelResponse[@"code"] integerValue]!=200&&fixtureStore.nativePlaylists.count==before&&[Tracks(identifier).firstObject[@"id"] isEqual:@"103"],@"cancelled_selection_does_not_create_or_overwrite_any_playlist");
    NSString *first=[fixtureStore preparePlaylist:initial replacing:identifier error:&error];NSString *second=[fixtureStore preparePlaylist:updated replacing:identifier error:&error];
    Check(first&&!second&&error.code==52,@"concurrent_overwrite_of_same_target_is_rejected_before_native_create");[fixtureStore revokeImportURL:first];
    NSString *conflict=[fixtureStore preparePlaylist:initial replacing:identifier error:&error];NSDictionary *conflictStart=StartImport(conflict);Fetch(@"playlist_add_track",@{@"token":@"authored-token",@"playlist_id":identifier.stringValue,@"song_id":@"104",@"title":@"Native added",@"platform":@"0",@"artist":@"Artist",@"cover":@""});NSDictionary *conflicted=FinishImport(conflictStart);
    Check([conflicted[@"code"] integerValue]!=200&&Tracks(identifier).count==2&&[Tracks(identifier).lastObject[@"id"] isEqual:@"104"],@"revision_conflict_preserves_intervening_native_library_edit");
    BOOL singlesOK=YES;NSDictionary *platforms=@{@"0":@"wy",@"2":@"kg",@"3":@"qq",@"4":@"qs"};
    for(NSString *platform in platforms){NSDictionary *added=Fetch(@"playlist_add_track",@{@"token":@"authored-token",@"playlist_id":copyID.stringValue,@"platform":platform,@"song_id":@"00123",@"title":@"Original single contract",@"artist":@"Native artist",@"cover":@""});NSDictionary *last=Tracks(copyID).lastObject;singlesOK=singlesOK&&[added[@"code"] integerValue]==200&&[added[@"data"] isEqual:@YES]&&[last[@"server"] isEqual:platforms[platform]]&&[last[@"id"] isEqual:@"00123"]&&[last[@"singer"] isEqual:@"Native artist"];}
    NSUInteger countBeforeUnknown=Tracks(copyID).count;NSDictionary *unknownPlatform=Fetch(@"playlist_add_track",@{@"playlist_id":copyID.stringValue,@"platform":@"999",@"song_id":@"123",@"title":@"Unknown platform",@"artist":@"Artist"});
    Check(singlesOK&&[unknownPlatform[@"code"] integerValue]!=200&&Tracks(copyID).count==countBeforeUnknown,@"original_seven_field_single_track_contract_preserves_four_platforms_and_rejects_unknown");
    NSArray *oldTracks=Tracks(identifier);NSData *oldFile=[NSData dataWithContentsOfURL:[root URLByAppendingPathComponent:@"playlists.json"]];NSString *failing=[fixtureStore preparePlaylist:initial replacing:identifier error:&error];NSDictionary *failureStart=StartImport(failing);
    NSURL *backup=[NSURL fileURLWithPath:[root.path stringByAppendingString:@"-retained"]];BOOL moved=[NSFileManager.defaultManager moveItemAtURL:root toURL:backup error:nil];[@"blocked-directory" writeToURL:root atomically:YES encoding:NSUTF8StringEncoding error:nil];NSDictionary *failed=FinishImport(failureStart);[NSFileManager.defaultManager removeItemAtURL:root error:nil];BOOL restored=[NSFileManager.defaultManager moveItemAtURL:backup toURL:root error:nil];Pump(0.03);
    Check(moved&&restored&&[failed[@"code"] integerValue]!=200&&[Tracks(identifier) isEqual:oldTracks]&&[[NSData dataWithContentsOfURL:[root URLByAppendingPathComponent:@"playlists.json"]] isEqual:oldFile]&&fixtureStore.nativePlaylists.count==before,@"real_filesystem_commit_failure_preserves_old_disk_and_library_without_duplicate");
    Check(![lastResult[@"success"] boolValue]&&[lastResult[@"message"] containsString:@"保留"],@"failed_commit_reports_failure_and_retained_original");
    NSString *truncated=[fixtureStore preparePlaylist:initial replacing:identifier error:&error];NSDictionary *truncatedStart=StartImport(truncated);NSDictionary *badBulk=Fetch(@"playlist_add_tracks_bulk",@{@"playlist_id":identifier.stringValue,@"tracks":@"[]"});
    Check([truncatedStart[@"created"][@"code"] integerValue]==200&&[badBulk[@"code"] integerValue]!=200&&[Tracks(identifier) isEqual:oldTracks],@"incomplete_native_bulk_never_partially_overwrites_old_playlist");
    NSDictionary *ordinary=Fetch(@"import_playlist",@{@"url":@"https://music.163.com/playlist?id=123"});Check([ordinary[@"data"][@"title"] isEqual:@"Original platform import"],@"ordinary_native_platform_import_stays_on_original_remote_path");
    NSMutableURLRequest *streamRequest=[Request(@"import_playlist",@{@"url":@"https://music.163.com/playlist?id=123"},NO) mutableCopy];
    LXReadStream *zeroStream=[LXReadStream new];zeroStream.bytes=streamRequest.HTTPBody;zeroStream.zeroReads=2;streamRequest.HTTPBody=nil;streamRequest.HTTPBodyStream=zeroStream;
    LXProtocolClient *streamClient=[LXProtocolClient new];FMLXMCLocalProtocol *streamProtocol=[[FMLXMCLocalProtocol alloc]initWithRequest:streamRequest cachedResponse:nil client:streamClient];[streamProtocol startLoading];
    BOOL streamDone=dispatch_semaphore_wait(streamClient.done,dispatch_time(DISPATCH_TIME_NOW,3*NSEC_PER_SEC))==0;NSDictionary *streamJSON=[NSJSONSerialization JSONObjectWithData:streamClient.body options:0 error:nil];
    Check(streamDone&&!streamClient.error&&[streamJSON[@"data"][@"title"] isEqual:@"Original platform import"],@"temporary_zero_byte_stream_read_is_not_mistaken_for_end_of_body");[streamProtocol stopLoading];
    LXReadStream *blocked=[LXReadStream new];blocked.bytes=zeroStream.bytes;blocked.blockReads=YES;streamRequest.HTTPBodyStream=blocked;LXProtocolClient *cancelClient=[LXProtocolClient new];FMLXMCLocalProtocol *cancelProtocol=[[FMLXMCLocalProtocol alloc]initWithRequest:streamRequest cachedResponse:nil client:cancelClient];[cancelProtocol startLoading];BOOL reading=dispatch_semaphore_wait(blocked.reading,dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC))==0;[cancelProtocol stopLoading];BOOL closed=dispatch_semaphore_wait(blocked.closed,dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC))==0;Pump(0.03);
    Check(reading&&closed&&cancelClient.completions==0,@"cancel_closes_blocked_body_stream_without_late_completion");
    LXReadStream *deadlineStream=[LXReadStream new];deadlineStream.bytes=zeroStream.bytes;deadlineStream.blockReads=YES;streamRequest.HTTPBodyStream=deadlineStream;streamRequest.timeoutInterval=0.08;LXProtocolClient *deadlineClient=[LXProtocolClient new];FMLXMCLocalProtocol *deadlineProtocol=[[FMLXMCLocalProtocol alloc]initWithRequest:streamRequest cachedResponse:nil client:deadlineClient];[deadlineProtocol startLoading];BOOL timed=dispatch_semaphore_wait(deadlineClient.done,dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC))==0;
    Check(timed&&deadlineClient.error.code==NSURLErrorTimedOut&&deadlineStream.wasClosed&&deadlineClient.completions==1,@"short_request_deadline_closes_blocked_stream_and_fails_once");
    __block NSURLSessionResponseDisposition lateDisposition=NSURLSessionResponseAllow;[(id<NSURLSessionDataDelegate>)deadlineProtocol URLSession:nil dataTask:nil didReceiveResponse:[[NSHTTPURLResponse alloc]initWithURL:streamRequest.URL statusCode:200 HTTPVersion:@"HTTP/1.1" headerFields:@{}] completionHandler:^(NSURLSessionResponseDisposition disposition){lateDisposition=disposition;}];
    Check(lateDisposition==NSURLSessionResponseCancel&&deadlineClient.responses==0&&deadlineClient.completions==1,@"queued_transport_response_after_real_timeout_cannot_violate_terminal_order");[deadlineProtocol stopLoading];
    atomic_store(&listMode,1);NSTimeInterval start=NSProcessInfo.processInfo.systemUptime;NSDictionary *delayed=Fetch(@"playlist_list",@{});NSTimeInterval elapsed=NSProcessInfo.processInfo.systemUptime-start;
    Check([delayed[@"code"] integerValue]==200&&[delayed[@"data"] count]==fixtureStore.nativePlaylists.count&&elapsed<5.5&&elapsed>=3.5,@"real_stalled_http_list_falls_back_to_local_library_within_four_seconds");
    atomic_store(&listMode,2);NSDictionary *offline=Fetch(@"playlist_list",@{});Check([offline[@"code"] integerValue]==200&&[offline[@"data"] count]==fixtureStore.nativePlaylists.count,@"real_broken_http_list_keeps_local_library_available");atomic_store(&listMode,0);
    NSArray *beforeReorder=Tracks(identifier);NSString *recordIDs=[NSString stringWithFormat:@"%@,%@",beforeReorder[1][@"record_id"],beforeReorder[0][@"record_id"]];NSDictionary *reordered=Fetch(@"playlist_tracks_reorder",@{@"playlist_id":identifier.stringValue,@"record_ids":recordIDs});
    Check([reordered[@"data"] isEqual:@YES]&&[Tracks(identifier).firstObject[@"id"] isEqual:beforeReorder.lastObject[@"id"]],@"original_track_reorder_route_persists_local_order");
    NSDictionary *deletedTrack=Fetch(@"playlist_del_track",@{@"record_id":[Tracks(identifier).firstObject[@"record_id"] description]});Check([deletedTrack[@"data"] isEqual:@YES]&&Tracks(identifier).count==1,@"original_track_delete_route_updates_local_playlist");
    BOOL reordersPassed=YES;for(NSUInteger attempt=0;attempt<8;attempt++){NSNumber *firstID=attempt%2?copyID:identifier,*lastID=attempt%2?identifier:copyID;NSDictionary *orderedLists=Fetch(@"playlist_reorder",@{@"ids":[NSString stringWithFormat:@"%@,%@,77",firstID,lastID]});BOOL correct=[orderedLists[@"data"] isEqual:@YES]&&[fixtureStore.nativePlaylists.firstObject[@"id"] isEqual:firstID];reordersPassed&=correct;if(!correct)NSLog(@"Reorder attempt %lu response %@ expected %@ actual %@",(unsigned long)attempt,orderedLists,firstID,fixtureStore.nativePlaylists.firstObject[@"id"]);}
    Check(reordersPassed&&atomic_load(&remoteReorders)==8&&atomic_load(&invalidRemoteReorders)==0,@"mixed_playlist_reorder_keeps_local_order_and_remote_ids_separate");
    NSDictionary *deletedList=Fetch(@"playlist_delete",@{@"id":copyID.stringValue});Check([deletedList[@"data"] isEqual:@YES]&&fixtureStore.nativePlaylists.count==1&&[Tracks(copyID) isKindOfClass:NSArray.class]==NO,@"original_playlist_delete_route_removes_only_selected_local_playlist");
    unsigned transportBefore=atomic_load(&httpRequests);NSDictionary *unknown=Fetch(@"playlist_get_tracks",@{@"playlist_id":@"-1999999"});Check([unknown[@"code"] integerValue]!=200&&atomic_load(&httpRequests)==transportBefore,@"stale_local_identity_fails_locally_instead_of_reaching_cloud");
    NSURL *corrupt=[NSURL fileURLWithPath:[root.path stringByAppendingString:@"-corrupt"]];[NSFileManager.defaultManager createDirectoryAtURL:corrupt withIntermediateDirectories:YES attributes:nil error:nil];NSData *garbage=[@"authored-corrupt-data" dataUsingEncoding:NSUTF8StringEncoding];[garbage writeToURL:[corrupt URLByAppendingPathComponent:@"playlists.json"] atomically:YES];FMLXMCLocalStore *damaged=[[FMLXMCLocalStore alloc]initWithDirectory:corrupt];
    Check(![damaged preparePlaylist:initial replacing:nil error:&error]&&[[NSData dataWithContentsOfURL:[corrupt URLByAppendingPathComponent:@"playlists.json"]] isEqual:garbage],@"corrupt_persistent_store_fails_closed_without_replacing_original_bytes");
    Check(atomic_load(&leakedPrivateRequests)==0,@"synthetic_import_tokens_and_private_create_markers_never_reach_http");
    NSData *persisted=[NSData dataWithContentsOfURL:[root URLByAppendingPathComponent:@"playlists.json"]];NSString *text=[[NSString alloc]initWithData:persisted encoding:NSUTF8StringEncoding];Check(![text containsString:@"authored-token"]&&![text containsString:@"origin-001"]&&![text containsString:@"FMX-LXMC-LOCAL"]&&![text containsString:@"fmx-lxmc.invalid"],@"persistent_store_excludes_account_tokens_raw_source_ids_and_bridge_secrets");
    NSArray<NSURL *> *files=[NSFileManager.defaultManager contentsOfDirectoryAtURL:root includingPropertiesForKeys:nil options:0 error:nil];Check(files.count==1&&[files.firstObject.lastPathComponent isEqual:@"playlists.json"],@"commits_and_failures_leave_no_partial_files_or_hidden_playlists");
    NSDictionary *report=@{@"passed":@(failures==0),@"failures":@(failures),@"cases":cases,@"evidence":@{@"real_http_requests":@(atomic_load(&httpRequests)),@"native_urlsession_requests":@(requests),@"atomic_disk_writes_verified":@YES,@"replacement_rollback_verified":@YES,@"cloud_playlists_preserved":@YES,@"source_identity_used":@YES,@"external_network_used":@NO,@"original_app_runtime_verified":@NO,@"stalled_http_fallback_seconds":@(elapsed),@"result_notifications":@(resultNotifications)}};
    NSString *reportPath=argc>1?[NSString stringWithUTF8String:argv[1]]:@"local-playlist-tests.json";BOOL wrote=[JSON(report) writeToFile:reportPath atomically:YES];
    [NSNotificationCenter.defaultCenter removeObserver:observer];method_setImplementation(shared,storeIMP);method_setImplementation(defaultMethod,defaultIMP);method_setImplementation(ephemeralMethod,ephemeralIMP);shutdown(listener,SHUT_RDWR);close(listener);[NSFileManager.defaultManager removeItemAtURL:root error:nil];[NSFileManager.defaultManager removeItemAtURL:corrupt error:nil];
    printf("%s local playlists: %lu cases, %lu failures; %s\n",failures||!wrote?"FAILED":"DONE",(unsigned long)cases.count,(unsigned long)failures,reportPath.UTF8String);return failures||!wrote?1:0;
}}
