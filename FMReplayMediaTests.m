#import "FMReplayMedia.h"
#import "FMReplayCache.h"
#import "FMDownloadTestFixtures.inc"

typedef void (^FixtureFinish)(NSURL *, NSURLResponse *, NSError *);
extern void FMReplayMediaTestStore(FMReplayCache *store);
extern FixtureFinish FMReplayMediaTestAdopt(NSURL *url,FixtureFinish completion);
extern BOOL FMReplayMediaTestStart(NSString *key);
extern BOOL FMReplayMediaTestIdle(NSString *key);

static NSHTTPURLResponse *Response(NSURL *url,NSInteger code,NSUInteger length,NSDictionary *extras) {
    NSMutableDictionary *headers=[@{@"Content-Type":@"audio/wav", @"Content-Length":@(length).stringValue} mutableCopy];
    [headers addEntriesFromDictionary:extras];
    return [[NSHTTPURLResponse alloc] initWithURL:url statusCode:code HTTPVersion:@"HTTP/1.1" headerFields:headers];
}
static NSURL *Temporary(NSURL *root,NSData *bytes) {
    NSURL *file=[root URLByAppendingPathComponent:NSUUID.UUID.UUIDString];
    [bytes writeToURL:file atomically:YES];return file;
}
static void NativeResult(NSURL *url,NSURL *file,NSHTTPURLResponse *response,NSError *error) {
    __block NSUInteger times=0;
    FixtureFinish original=^(NSURL *value,NSURLResponse *r,NSError *e){
        if([file isEqual:value] && r==response && e==error)times++;
        // Reproduce the native delegate moving away its original temporary file.
        [NSFileManager.defaultManager removeItemAtURL:value error:nil];
    };
    FMReplayMediaTestAdopt(url,original)(file,response,error);
    Check(times==1,@"Native completion keeps the same file, response and error exactly once");
}
int main(int argc,const char **argv) {
    @autoreleasepool {
        if(argc!=2)return 2;
        rows=NSMutableArray.array;
        NSURL *root=[NSFileManager.defaultManager.temporaryDirectory URLByAppendingPathComponent:NSUUID.UUID.UUIDString isDirectory:YES];
        [NSFileManager.defaultManager createDirectoryAtURL:root withIntermediateDirectories:YES attributes:nil error:nil];
        FMReplayCache *store=[[FMReplayCache alloc] initWithDirectory:[root URLByAppendingPathComponent:@"store"] audioByteLimit:4096*1024 entryLimit:32];
        FMReplayMediaTestStore(store);
        FMDownloadHTTPFixture *server=[FMDownloadHTTPFixture new];
        NSString *namespace=[store selectSourceFile:@"A.js" script:@"// fixture A"];
        NSString *(^registerTrack)(NSString *,NSURL *)=^NSString *(NSString *track,NSURL *url) {
            NSString *key=[store keyForNamespace:namespace platform:@"tx" trackID:track quality:@"320k"];
            [store saveAddress:url forKey:key];
            [FMReplayMedia registerRemoteURL:url key:key];return key;
        };
        NSData *audio=server.audio;
        NSURL *url=[server URL:@"native.wav"];
        NSString *key=registerTrack(@"native",url);
        __block NSUInteger nativeSuccess=0;
        FixtureFinish finish=FMReplayMediaTestAdopt(url,^(NSURL *file,NSURLResponse *r,NSError *e){
            if(!e && file)nativeSuccess++;
            [NSFileManager.defaultManager removeItemAtURL:file error:nil];
        });
        NSUInteger nativeBefore=server.requests;
        Check(!FMReplayMediaTestStart(key) && server.requests==nativeBefore,@"An existing native transfer suppresses a second download");
        finish(Temporary(root,audio),Response(url,200,audio.length,@{}),nil);
        Check(nativeSuccess==1,@"Native callback still owns the original temporary file");
        Check(Wait(^BOOL{return FMReplayMediaTestIdle(key);},8),@"Native audio decoder completes");
        NSURL *cached=[store audioForKey:key];
        Check(cached.isFileURL && [cached.pathExtension isEqual:@"wav"] &&
              [[NSData dataWithContentsOfURL:cached] isEqual:audio],@"Native transfer survives original file removal with exact audio bytes");
        NSUInteger requests=server.requests;
        FMReplayMediaTestStart(key);
        Pump(0.05);
        Check(server.requests==requests,@"A complete native copy replays without a new HTTP request");
        if(cached){AVAudioFile *decoded=[[AVAudioFile alloc] initForReading:cached error:nil];Check(decoded.length>0,@"Saved file opens in a real local audio decoder");}

        NSArray *cases=@[
            @[@"partial",@206,@{@"Content-Range":@"bytes 0-127/99999"},audio],
            @[@"nostore",@200,@{@"Cache-Control":@"private, no-store"},audio],
            @[@"badlength",@200,@{},audio],
            @[@"truncated-wave",@200,@{},[audio subdataWithRange:NSMakeRange(0,audio.length/2)]],
            @[@"manifest",@200,@{},[@"#EXTM3U\n#EXT-X-VERSION:3\n#EXTINF:2,\nseg.aac\n" dataUsingEncoding:NSUTF8StringEncoding]],
            @[@"invalid",@200,@{},[@"<!DOCTYPE html><body>fixture login page</body>" dataUsingEncoding:NSUTF8StringEncoding]],
            @[@"interrupted",@200,@{},audio],
        ];
        for(NSArray *row in cases){
            NSString *name=row[0];NSData *body=row[3];NSURL *u=[server URL:name];NSString *k=registerTrack(name,u);
            NSUInteger claimed=body.length+([name isEqual:@"badlength"]?77:0);
            NSError *err=[name isEqual:@"interrupted"]?[NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorNetworkConnectionLost userInfo:nil]:nil;
            NativeResult(u,Temporary(root,body),Response(u,[row[1] integerValue],claimed,row[2]),err);
            Check(Wait(^BOOL{return FMReplayMediaTestIdle(k);},8) && [store audioForKey:k]==nil, name);
        }
        NSURL *supp=[server URL:@"whole"];NSString *suppKey=registerTrack(@"supplemental",supp);
        NSUInteger before=server.requests;FMReplayMediaTestStart(suppKey);FMReplayMediaTestStart(suppKey);
        Check(Wait(^BOOL{return FMReplayMediaTestIdle(suppKey);},8) && [store audioForKey:suppKey].isFileURL && server.requests==before+1,
              @"Supplemental finite audio transfer is downloaded and validated exactly once");
        NSURL *oldURL=[server URL:@"late"];NSString *oldKey=registerTrack(@"late",oldURL);
        __block NSUInteger deliveries=0;
        FixtureFinish oldFinish=FMReplayMediaTestAdopt(oldURL,^(NSURL *f,NSURLResponse *r,NSError *e){deliveries++;});
        [FMReplayMedia sourceDidChange];NSString *other=[store selectSourceFile:@"B.js" script:@"// fixture B"];
        NSString *newKey=[store keyForNamespace:other platform:@"tx" trackID:@"late" quality:@"320k"];
        [store saveAddress:oldURL forKey:newKey];[FMReplayMedia registerRemoteURL:oldURL key:newKey];
        oldFinish(Temporary(root,audio),Response(oldURL,200,audio.length,@{}),nil);
        Check(deliveries==1 && ![store audioForKey:newKey] && ![store audioForKey:oldKey],
              @"Late native completion after source change cannot create an audio hit in either namespace");
        [FMReplayMedia sourceDidChange];[server stop];FMReplayMediaTestStore(nil);
        [NSFileManager.defaultManager removeItemAtURL:root error:nil];
        NSDictionary *report=@{@"passed":@(failures==0),@"assertions":rows,@"requests":@(server.requests),@"physical_device":@NO};
        NSData *json=[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:nil];
        return [json writeToFile:[NSString stringWithUTF8String:argv[1]] atomically:YES] && !failures ? 0 : 1;
    }
}
