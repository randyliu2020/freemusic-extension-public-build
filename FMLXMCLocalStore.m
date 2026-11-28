#import "FMLXMCLocalStore.h"
#import <CoreFoundation/CoreFoundation.h>
#import <fcntl.h>
#import <sys/stat.h>
#import <unistd.h>
#import <errno.h>
#import <CommonCrypto/CommonDigest.h>

NSNotificationName const FMLXMCLocalImportDidFinish=@"FMX.LXMC.LocalImportDidFinish";
static const NSUInteger FMStoreLimit=32*1024*1024;
static const int64_t FMFirstPlaylist=-1000000, FMFirstRecord=-1000000000;
static NSString *const FMMarker=@"FMX-LXMC-LOCAL:";
static NSError *FMLocalError(NSInteger code,NSString *message){return [NSError errorWithDomain:FMLXMCErrorDomain code:code userInfo:@{NSLocalizedDescriptionKey:message}];}
static NSDictionary *FMReply(BOOL ok,id data,NSString *message){return @{@"code":ok?@200:@500,@"data":data?:@(ok),@"msg":message?: (ok?@"成功":@"本机歌单保存失败")};}
static NSNumber *FMInteger(NSString *text){
    if(![text isKindOfClass:NSString.class]||![text length]||text.length>20)return nil;
    NSScanner *scanner=[NSScanner scannerWithString:text];scanner.charactersToBeSkipped=nil;long long value=0;
    return [scanner scanLongLong:&value]&&scanner.isAtEnd&&[[NSString stringWithFormat:@"%lld",value] isEqual:text]?@(value):nil;
}
static NSString *FMText(id object,NSUInteger maximum){return [object isKindOfClass:NSString.class]&&[object length]<=maximum&&[object rangeOfString:@"\0"].location==NSNotFound?object:nil;}
static NSDictionary *FMNativeTrack(id value){
    if(![value isKindOfClass:NSDictionary.class])return nil;
    NSString *source=FMText(value[@"server"],16),*identifier=FMText(value[@"id"],64),*title=FMText(value[@"title"],1024);
    if(![@[@"wy",@"qq",@"kg",@"qs"] containsObject:source?:@""]||!identifier.length||!title.length)return nil;
    NSString *singer=FMText(value[@"singer"],2048)?:@"",*cover=FMText(value[@"cover"],4096)?:@"";
    if(cover.length){NSURLComponents *parts=[NSURLComponents componentsWithString:cover];if(![@[@"http",@"https"] containsObject:parts.scheme.lowercaseString?:@""]||!parts.host.length||parts.user||parts.password)cover=@"";}
    return @{@"id":identifier,@"server":source,@"title":title,@"singer":singer,@"cover":cover};
}
// The native one-song API uses numeric platform/song_id/artist, unlike bulk's
// server/id/singer payload. Preserve its exact identities, including zeroes.
static NSDictionary *FMNativeSingleTrack(NSDictionary *parameters){
    NSString *source=@{@"0":@"wy",@"2":@"kg",@"3":@"qq",@"4":@"qs"}[parameters[@"platform"]?:@""];
    if(!source)return nil;
    return FMNativeTrack(@{@"server":source,@"id":parameters[@"song_id"]?:@"",@"title":parameters[@"title"]?:@"",@"singer":parameters[@"artist"]?:@"",@"cover":parameters[@"cover"]?:@""});
}
static NSString *FMEditDigest(NSArray *parts) {
    NSData *bytes = [NSPropertyListSerialization dataWithPropertyList:parts format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
    if (!bytes || bytes.length > UINT32_MAX) return nil;
    unsigned char hash[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(bytes.bytes, (CC_LONG)bytes.length, hash);
    char hex[65];
    for (NSUInteger i=0; i<sizeof(hash); i++) snprintf(hex+i*2, 3, "%02x", hash[i]);
    return [NSString stringWithUTF8String:hex];
}
static NSString *FMEditListKey(NSDictionary *row) {
    if (![row isKindOfClass:NSDictionary.class]) return nil;
    NSNumber *identifier = FMInteger([row[@"id"] description]);
    if (!identifier || identifier.longLongValue == 0) return nil;
    NSString *owner = [row[@"user_id"] description] ?: @"";
    return FMEditDigest(@[identifier.longLongValue < 0 ? @"local" : @"cloud", owner, identifier.stringValue]);
}
static NSString *FMEditTrackKey(NSDictionary *track) {
    if (![track isKindOfClass:NSDictionary.class]) return nil;
    NSNumber *record = FMInteger([track[@"record_id"] description]);
    if (record && record.longLongValue != 0) return FMEditDigest(@[@"record", record.stringValue]);
    NSString *server = [track[@"server"] description], *identifier = [track[@"id"] description];
    return (server.length && identifier.length) ? FMEditDigest(@[@"track", server, identifier]) : nil;
}
static BOOL FMEditUnique(NSArray *ids, NSUInteger maximum) {
    if (![ids isKindOfClass:NSArray.class] || ids.count > maximum) return NO;
    for (id key in ids) if (![key isKindOfClass:NSString.class] || [key length]!=64) return NO;
    return [NSSet setWithArray:ids].count == ids.count;
}
static BOOL FMEditMetadataValid(id metadata) {
    if (!metadata) return YES;
    if (![metadata isKindOfClass:NSDictionary.class] || !FMEditUnique(metadata[@"order"]?:@[], 1500)) return NO;
    NSDictionary *lists = metadata[@"lists"] ?: @{};
    if (![lists isKindOfClass:NSDictionary.class] || lists.count > 1500) return NO;
    for (id key in lists) {
        NSDictionary *item=lists[key];
        if (![key isKindOfClass:NSString.class] || [key length]!=64 || ![item isKindOfClass:NSDictionary.class]) return NO;
        if (item[@"title"] && !FMText(item[@"title"],256).length) return NO;
        if (!FMEditUnique(item[@"hidden"]?:@[],20000) || !FMEditUnique(item[@"order"]?:@[],20000)) return NO;
    }
    return YES;
}
static NSArray *FMEditOrder(NSArray *rows, NSArray *order, NSSet *hidden, NSString *(^identity)(NSDictionary *)) {
    if (!order.count && !hidden.count) return rows;
    NSMutableDictionary *indexed = [NSMutableDictionary dictionary];
    for (NSDictionary *row in rows) {
        NSString *key=identity(row);
        if (key && indexed[key]) return rows; // Ambiguous data remains in the native order.
        if (key) indexed[key]=row;
    }
    NSMutableArray *out=[NSMutableArray array];
    NSMutableSet *emitted=[NSMutableSet set];
    for (NSString *key in order) if (indexed[key] && ![hidden containsObject:key] && ![emitted containsObject:key]) {
        [out addObject:indexed[key]]; [emitted addObject:key];
    }
    for (NSDictionary *row in rows) {
        NSString *key=identity(row);
        if (!key || (![hidden containsObject:key] && ![emitted containsObject:key])) [out addObject:row];
    }
    return out;
}
static BOOL FMEditFail(NSError **error, NSString *message) {
    if (error) *error=FMLocalError(55,message);
    return NO;
}
@interface FMLXMCLocalStore ()
@property(nonatomic,strong) NSURL *directory;
@property(nonatomic,strong) NSRecursiveLock *lock;
@property(nonatomic,strong) NSDictionary *state;
@property(nonatomic,strong) NSError *loadError;
@property(nonatomic,strong) NSMutableDictionary<NSString *,NSMutableDictionary *> *plans;
@property(nonatomic) int64_t nextReservation;
@property(nonatomic) NSUInteger commits,failedCommits,cancelled,overwrites,copies;
@property(nonatomic,copy) NSArray<NSDictionary *> *editorCloudLists;
@property(nonatomic,strong) NSCache<NSString *, NSArray *> *editorCloudTracks;
@end
@implementation FMLXMCLocalStore
+ (instancetype)sharedStore{
    static FMLXMCLocalStore *store;static dispatch_once_t once;dispatch_once(&once,^{
        NSURL *support=[NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
        store=[[self alloc]initWithDirectory:[support URLByAppendingPathComponent:@"FMXLocalPlaylists-v1" isDirectory:YES]];
    });return store;
}
- (instancetype)initWithDirectory:(NSURL *)directory{
    if(!(self=[super init]))return nil;_directory=directory;_lock=[NSRecursiveLock new];_plans=[NSMutableDictionary dictionary];
    _state=@{@"schema":@1,@"revision":@0,@"nextPlaylist":@(FMFirstPlaylist),@"nextRecord":@(FMFirstRecord),@"playlists":@[]};
    NSError *error=nil;struct stat st;
    if(!directory.isFileURL||(!lstat(directory.fileSystemRepresentation,&st)&&(!S_ISDIR(st.st_mode)||S_ISLNK(st.st_mode))))error=FMLocalError(40,@"本机歌单目录无效，原数据未改动。");
    if(!error&&![NSFileManager.defaultManager createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:&error]){}
    NSURL *file=[directory URLByAppendingPathComponent:@"playlists.json"];
    if(!error&&[NSFileManager.defaultManager fileExistsAtPath:file.path]){
        int fd=open(file.fileSystemRepresentation,O_RDONLY|O_NOFOLLOW|O_CLOEXEC);struct stat info;
        NSMutableData *data=[NSMutableData data];BOOL valid=fd>=0&&!fstat(fd,&info)&&S_ISREG(info.st_mode)&&info.st_size>0&&info.st_size<=FMStoreLimit;
        if(valid){unsigned char buffer[32768];ssize_t size;while((size=read(fd,buffer,sizeof(buffer)))>0){if(data.length+(NSUInteger)size>FMStoreLimit){valid=NO;break;}[data appendBytes:buffer length:(NSUInteger)size];}if(size<0)valid=NO;}
        if(fd>=0)close(fd);
        id decoded=valid?[NSJSONSerialization JSONObjectWithData:data options:0 error:nil]:nil;
        if([self validateState:decoded])_state=decoded;else error=FMLocalError(41,@"本机歌单数据无法读取；为保护原数据，本次不写入。");
    }
    _loadError=error;_nextReservation=[_state[@"nextPlaylist"] longLongValue];
    _editorCloudTracks=[NSCache new];_editorCloudTracks.totalCostLimit=40000;_editorCloudLists=@[];return self;
}
- (BOOL)ownsPlaylistID:(NSString *)identifier{NSNumber *number=FMInteger(identifier);return number&&number.longLongValue<=FMFirstPlaylist&&number.longLongValue>FMFirstRecord;}
- (BOOL)ownsRecordID:(NSString *)identifier{NSNumber *number=FMInteger(identifier);return number&&number.longLongValue<=FMFirstRecord&&number.longLongValue>INT64_MIN/2;}
- (BOOL)validateState:(id)state{
    if (![state isKindOfClass:NSDictionary.class] || !FMEditMetadataValid(state[@"editor"])) return NO;
    if(![state isKindOfClass:NSDictionary.class]||![state[@"schema"] isEqual:@1]||![state[@"playlists"] isKindOfClass:NSArray.class]||[state[@"playlists"] count]>300||![state[@"revision"] isKindOfClass:NSNumber.class]||![self ownsPlaylistID:[state[@"nextPlaylist"] description]]||![self ownsRecordID:[state[@"nextRecord"] description]])return NO;
    NSMutableSet *ids=[NSMutableSet set],*records=[NSMutableSet set];NSUInteger total=0;
    for(id row in state[@"playlists"]){
        if(![row isKindOfClass:NSDictionary.class]||![row[@"id"] isKindOfClass:NSNumber.class]||![self ownsPlaylistID:[row[@"id"] description]]||[ids containsObject:row[@"id"]]||!FMText(row[@"title"],256).length||![row[@"revision"] isKindOfClass:NSNumber.class]||![row[@"tracks"] isKindOfClass:NSArray.class]||[row[@"tracks"] count]>20000)return NO;
        [ids addObject:row[@"id"]];total+=[row[@"tracks"] count];if(total>100000)return NO;
        for(id track in row[@"tracks"]){if(!FMNativeTrack(track)||![track[@"record_id"] isKindOfClass:NSNumber.class]||![self ownsRecordID:[track[@"record_id"] description]]||[records containsObject:track[@"record_id"]])return NO;[records addObject:track[@"record_id"]];}
    }return YES;
}
- (NSArray *)nativePlaylists{
    [self.lock lock];@try{NSMutableArray *lists=[NSMutableArray array];for(NSDictionary *row in self.state[@"playlists"])[lists addObject:@{@"id":row[@"id"],@"title":row[@"title"],@"user_id":@0,@"count":@([row[@"tracks"] count]),@"revision":row[@"revision"]}];return [lists copy];}@finally{[self.lock unlock];}
}
- (NSArray *)matchesForPlaylist:(FMLXMCPlaylist *)playlist{
    [self.lock lock];@try{NSMutableArray *matches=[NSMutableArray array];for(NSDictionary *row in self.state[@"playlists"]){
        BOOL source=playlist.sourceIdentity&&[row[@"sourceIdentity"] isEqual:playlist.sourceIdentity];
        BOOL exact=!playlist.sourceIdentity&&[row[@"contentFingerprint"] isEqual:playlist.contentFingerprint];
        if(source||exact)[matches addObject:@{@"id":row[@"id"],@"title":row[@"title"],@"count":@([row[@"tracks"] count]),@"revision":row[@"revision"],@"matchKind":source?@"source":@"exact"}];
    }return matches;}@finally{[self.lock unlock];}
}
- (void)prune{
    NSTimeInterval now=NSProcessInfo.processInfo.systemUptime;
    for(NSString *key in self.plans.allKeys)if([self.plans[key][@"expires"] doubleValue]<=now){FMLXMCRevokeURL(key);[self.plans removeObjectForKey:key];}
}
- (NSDictionary *)row:(NSNumber *)identifier{for(NSDictionary *row in self.state[@"playlists"])if([row[@"id"] isEqual:identifier])return row;return nil;}
- (NSString *)preparePlaylist:(FMLXMCPlaylist *)playlist replacing:(NSNumber *)identifier error:(NSError **)error{
    if(error)*error=nil;[self.lock lock];@try{
        [self prune];NSError *failure=self.loadError;
        NSDictionary *old=identifier?[self row:identifier]:nil;
        if(identifier&&!old)failure=FMLocalError(42,@"选择的本机歌单已不存在，请重新选择。");
        if(identifier)for(NSDictionary *pending in self.plans.allValues)if([pending[@"id"] isEqual:identifier])failure=FMLocalError(52,@"这个歌单已有待处理的导入，请先完成或取消。");
        if(self.plans.count>=16)failure=FMLocalError(43,@"待处理的歌单过多，请完成或取消之前的导入。");
        if(failure){if(error)*error=failure;return nil;}
        NSString *url=FMLXMCRegisterPlaylist(playlist,error);if(!url)return nil;
        NSNumber *reserved=identifier?:@(self.nextReservation--);
        if(![self ownsPlaylistID:reserved.stringValue]){FMLXMCRevokeURL(url);if(error)*error=FMLocalError(44,@"本机歌单数量超出范围。");return nil;}
        NSString *saveTitle=playlist.title;
        if(!identifier){NSMutableSet *titles=[NSMutableSet set];for(NSDictionary *row in self.state[@"playlists"])[titles addObject:row[@"title"]];for(NSDictionary *pending in self.plans.allValues)if(pending[@"saveTitle"])[titles addObject:pending[@"saveTitle"]];NSUInteger suffix=1;while([titles containsObject:saveTitle]){NSString *base=playlist.title.length>230?[playlist.title substringToIndex:230]:playlist.title;saveTitle=suffix==1?[base stringByAppendingString:@"（副本）"]:[base stringByAppendingFormat:@"（副本 %lu）",(unsigned long)suffix];suffix++;}}
        NSMutableDictionary *plan=[@{@"playlist":playlist,@"saveTitle":saveTitle,@"id":reserved,@"replace":@(identifier!=nil),@"expectedRevision":old?old[@"revision"]:@0,@"phase":@"selected",@"marker":[FMMarker stringByAppendingString:NSUUID.UUID.UUIDString],@"expires":@(NSProcessInfo.processInfo.systemUptime+1800)} mutableCopy];
        self.plans[url]=plan;return url;
    }@finally{[self.lock unlock];}
}
- (void)revokeImportURL:(NSString *)url{
    if(!url.length)return;[self.lock lock];@try{if([self.plans[url][@"phase"] isEqual:@"selected"]){[self.plans removeObjectForKey:url];self.cancelled++;}FMLXMCRevokeURL(url);}@finally{[self.lock unlock];}
}
- (BOOL)persist:(NSDictionary *)state error:(NSError **)error{
    if(self.loadError){if(error)*error=self.loadError;return NO;}
    if(![self validateState:state]){if(error)*error=FMLocalError(45,@"歌单数据不完整或超过本机容量限制，原歌单已保留。");return NO;}
    NSData *data=[NSJSONSerialization dataWithJSONObject:state options:NSJSONWritingSortedKeys error:error];
    if(!data||data.length>FMStoreLimit){if(error&&!*error)*error=FMLocalError(45,@"本机歌单超过容量限制，原歌单已保留。");return NO;}
    NSURL *destination=[self.directory URLByAppendingPathComponent:@"playlists.json"],*temporary=[self.directory URLByAppendingPathComponent:[@".write-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    struct stat st;if(lstat(self.directory.fileSystemRepresentation,&st)||!S_ISDIR(st.st_mode)||S_ISLNK(st.st_mode)||(!lstat(destination.fileSystemRepresentation,&st)&&!S_ISREG(st.st_mode))){if(error)*error=FMLocalError(46,@"本机保存位置不可用，原歌单已保留。");return NO;}
    int fd=open(temporary.fileSystemRepresentation,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0600);BOOL ok=fd>=0;
    const uint8_t *bytes=data.bytes;NSUInteger offset=0;
    while(ok&&offset<data.length){ssize_t size=write(fd,bytes+offset,data.length-offset);if(size<0&&errno==EINTR)continue;if(size<=0){ok=NO;break;}offset+=(NSUInteger)size;}
    if(ok&&fsync(fd))ok=NO;if(fd>=0&&close(fd))ok=NO;
    if(ok&&rename(temporary.fileSystemRepresentation,destination.fileSystemRepresentation))ok=NO;
    if(!ok){unlink(temporary.fileSystemRepresentation);if(error)*error=FMLocalError(47,@"未能保存本机歌单，原歌单已保留，请重试。");return NO;}
    // Rename is the commit point. A directory-sync failure cannot be rolled back
    // safely after it; retain the successfully installed state in memory.
    int dir=open(self.directory.fileSystemRepresentation,O_RDONLY|O_DIRECTORY|O_CLOEXEC);if(dir>=0){fsync(dir);close(dir);}
    self.state=[state copy];self.commits++;return YES;
}
- (NSDictionary *)commitRows:(NSArray *)rows nextRecord:(int64_t)nextRecord error:(NSError **)error{
    NSMutableDictionary *updated=[self.state mutableCopy];updated[@"revision"]=@([self.state[@"revision"] unsignedLongLongValue]+1);updated[@"nextPlaylist"]=@(MIN(self.nextReservation,[self.state[@"nextPlaylist"] longLongValue]));updated[@"nextRecord"]=@(nextRecord);updated[@"playlists"]=rows;
    if(![self persist:updated error:error]){self.failedCommits++;return nil;}return updated;
}
- (void)notifyPlan:(NSDictionary *)plan error:(NSError *)error{
    FMLXMCPlaylist *playlist=plan[@"playlist"];NSString *title=plan[@"saveTitle"]?:playlist.title;NSDictionary *info=@{@"success":@(!error),@"replaced":plan[@"replace"]?:@NO,@"count":@(playlist.tracks.count),@"title":title?:@"",@"message":error.localizedDescription?:[NSString stringWithFormat:@"“%@”已保存 %lu 首歌曲，可在资料库中查看。仅保存在这部手机。",title,(unsigned long)playlist.tracks.count]};
    dispatch_async(dispatch_get_main_queue(),^{[NSNotificationCenter.defaultCenter postNotificationName:FMLXMCLocalImportDidFinish object:self userInfo:info];});
}
- (NSDictionary *)importBulk:(NSArray *)incoming plan:(NSMutableDictionary *)plan key:(NSString *)key{
    FMLXMCPlaylist *playlist=plan[@"playlist"];NSError *error=nil;NSDictionary *old=[self row:plan[@"id"]];
    if(![plan[@"phase"] isEqual:@"created"]||incoming.count!=playlist.tracks.count)error=FMLocalError(48,@"导入内容未完整传递，原歌单已保留。");
    if(!error){for(NSUInteger index=0;index<incoming.count;index++)if(![FMNativeTrack(incoming[index]) isEqual:FMNativeTrack(playlist.tracks[index])]){error=FMLocalError(48,@"导入内容发生变化，原歌单已保留。");break;}}
    if(!error&&[plan[@"replace"] boolValue]&&(!old||![old[@"revision"] isEqual:plan[@"expectedRevision"]]))error=FMLocalError(49,@"歌单在导入期间已修改，请重新选择；当前内容已保留。");
    int64_t record=[self.state[@"nextRecord"] longLongValue];NSMutableArray *tracks=[NSMutableArray array];
    if(!error){for(NSDictionary *track in playlist.tracks){NSMutableDictionary *copy=[track mutableCopy];copy[@"record_id"]=@(record--);[tracks addObject:copy];}
        NSMutableDictionary *row=[@{@"id":plan[@"id"],@"title":plan[@"saveTitle"],@"tracks":tracks,@"revision":@([old[@"revision"] unsignedLongLongValue]+1),@"contentFingerprint":playlist.contentFingerprint} mutableCopy];
        if(playlist.sourceIdentity)row[@"sourceIdentity"]=playlist.sourceIdentity;
        NSMutableArray *rows=[self.state[@"playlists"] mutableCopy];if(old)[rows replaceObjectAtIndex:[rows indexOfObjectIdenticalTo:old] withObject:row];else[rows addObject:row];
        [self commitRows:rows nextRecord:record error:&error];
    }
    if(error&&[error code]!=47)self.failedCommits++;
    if(!error){if(old)self.overwrites++;else self.copies++;}
    [self.plans removeObjectForKey:key];[self notifyPlan:plan error:error];
    return FMReply(!error,!error?@YES:@NO,error.localizedDescription);
}
- (NSDictionary *)responseForAction:(NSString *)action parameters:(NSDictionary *)parameters importRequest:(NSURLRequest *)request{
    [self.lock lock];@try{
        [self prune];
        if([action isEqual:@"import_playlist"]){NSString *url=parameters[@"url"];NSMutableDictionary *plan=self.plans[url];if(!plan)return nil;
            NSError *error=nil;NSData *data=FMLXMCResponseForRequest(request,&error);if(!data){[self.plans removeObjectForKey:url];return FMReply(NO,nil,error.localizedDescription);}
            plan[@"phase"]=@"parsed";FMLXMCPlaylist *playlist=plan[@"playlist"];
            return FMReply(YES,@{@"title":plan[@"marker"],@"tracks":playlist.tracks},nil);
        }
        if([action isEqual:@"playlist_create"]&&[parameters[@"title"] hasPrefix:FMMarker]){
            for(NSMutableDictionary *plan in self.plans.allValues)if([plan[@"marker"] isEqual:parameters[@"title"]]&&[plan[@"phase"] isEqual:@"parsed"]){plan[@"phase"]=@"created";return FMReply(YES,@{@"id":plan[@"id"]},nil);}
            return FMReply(NO,nil,@"这次本机歌单导入已失效，请重新选择。");
        }
        NSNumber *identifier=FMInteger([action isEqual:@"playlist_delete"]?parameters[@"id"]:parameters[@"playlist_id"]);
        if([action isEqual:@"playlist_add_tracks_bulk"]&&[self ownsPlaylistID:identifier.stringValue]){
            NSData *data=[parameters[@"tracks"] dataUsingEncoding:NSUTF8StringEncoding];id incoming=data.length&&data.length<=FMLXMCMaximumExpandedBytes?[NSJSONSerialization JSONObjectWithData:data options:0 error:nil]:nil;
            for(NSString *key in self.plans.allKeys){NSMutableDictionary *plan=self.plans[key];if([plan[@"id"] isEqual:identifier]&&[plan[@"phase"] isEqual:@"created"]){return [self importBulk:[incoming isKindOfClass:NSArray.class]?incoming:@[] plan:plan key:key];}}
        }
        if([action isEqual:@"playlist_reorder"]){
            NSArray *ids=[parameters[@"ids"] componentsSeparatedByString:@","];NSMutableArray *local=[NSMutableArray array];NSUInteger cloudCount=0;
            for(NSString *text in ids){if([self ownsPlaylistID:text])[local addObject:FMInteger(text)];else cloudCount++;}
            if(!local.count)return nil;
            if(local.count!=[self.state[@"playlists"] count]||[NSSet setWithArray:local].count!=local.count)return FMReply(NO,nil,@"本机歌单列表已变化，请刷新后重试。");
            NSMutableArray *rows=[NSMutableArray array];for(NSNumber *number in local){NSDictionary *row=[self row:number];if(!row)return FMReply(NO,nil,@"本机歌单排序无效。");[rows addObject:row];}
            NSError *error=nil;[self commitRows:rows nextRecord:[self.state[@"nextRecord"] longLongValue] error:&error];
            if(error)return FMReply(NO,nil,error.localizedDescription);return cloudCount?nil:FMReply(YES,@YES,nil);
        }
        if([action isEqual:@"playlist_del_track"]){NSNumber *record=FMInteger(parameters[@"record_id"]?:parameters[@"id"]);if(![self ownsRecordID:record.stringValue])return nil;
            for(NSDictionary *row in self.state[@"playlists"])for(NSDictionary *track in row[@"tracks"])if([track[@"record_id"] isEqual:record]){
                NSMutableArray *tracks=[row[@"tracks"] mutableCopy];[tracks removeObjectIdenticalTo:track];return [self updateRow:row tracks:tracks nextRecord:[self.state[@"nextRecord"] longLongValue]];
            }return FMReply(NO,nil,@"本机歌曲记录已不存在。");
        }
        if(![self ownsPlaylistID:identifier.stringValue])return nil;
        NSDictionary *row=[self row:identifier];if(!row)return FMReply(NO,nil,@"本机歌单不存在或尚未保存。");
        if([action isEqual:@"playlist_get_tracks"])return FMReply(YES,row[@"tracks"],nil);
        if([action isEqual:@"playlist_delete"]){NSMutableArray *rows=[self.state[@"playlists"] mutableCopy];[rows removeObjectIdenticalTo:row];NSError *error=nil;[self commitRows:rows nextRecord:[self.state[@"nextRecord"] longLongValue] error:&error];return FMReply(!error,nil,error.localizedDescription);}
        if([action isEqual:@"playlist_add_track"]||[action isEqual:@"playlist_add_tracks_bulk"]){
            NSDictionary *single=[action isEqual:@"playlist_add_track"]?FMNativeSingleTrack(parameters):nil;
            id incoming=[action isEqual:@"playlist_add_track"]?(single?@[single]:nil):[NSJSONSerialization JSONObjectWithData:[parameters[@"tracks"] dataUsingEncoding:NSUTF8StringEncoding]?:NSData.data options:0 error:nil];
            if(![incoming isKindOfClass:NSArray.class]||[incoming count]>20000)return FMReply(NO,nil,@"歌曲数据无效。");
            NSMutableArray *tracks=[row[@"tracks"] mutableCopy];NSMutableSet *keys=[NSMutableSet set];for(NSDictionary *track in tracks)[keys addObject:[NSString stringWithFormat:@"%@:%@",track[@"server"],track[@"id"]]];int64_t next=[self.state[@"nextRecord"] longLongValue];
            for(id raw in incoming){NSDictionary *track=FMNativeTrack(raw);if(!track)return FMReply(NO,nil,@"歌曲数据不完整，原歌单已保留。");NSString *key=[NSString stringWithFormat:@"%@:%@",track[@"server"],track[@"id"]];if([keys containsObject:key])continue;NSMutableDictionary *copy=[track mutableCopy];copy[@"record_id"]=@(next--);[tracks addObject:copy];[keys addObject:key];}
            return [self updateRow:row tracks:tracks nextRecord:next];
        }
        if([action isEqual:@"playlist_tracks_reorder"]){NSArray *ids=[parameters[@"record_ids"] componentsSeparatedByString:@","];NSMutableDictionary *byID=[NSMutableDictionary dictionary];for(NSDictionary *track in row[@"tracks"])byID[[track[@"record_id"] description]]=track;
            if(ids.count!=byID.count||[NSSet setWithArray:ids].count!=ids.count)return FMReply(NO,nil,@"歌曲排序已变化，请刷新后重试。");NSMutableArray *tracks=[NSMutableArray array];for(NSString *key in ids){if(!byID[key])return FMReply(NO,nil,@"歌曲排序无效。");[tracks addObject:byID[key]];}return [self updateRow:row tracks:tracks nextRecord:[self.state[@"nextRecord"] longLongValue]];
        }
        return FMReply(NO,nil,@"此操作暂不支持本机歌单，原内容未改动。");
    }@finally{[self.lock unlock];}
}
- (NSDictionary *)updateRow:(NSDictionary *)row tracks:(NSArray *)tracks nextRecord:(int64_t)nextRecord{
    NSMutableDictionary *replacement=[row mutableCopy];replacement[@"tracks"]=tracks;replacement[@"revision"]=@([row[@"revision"] unsignedLongLongValue]+1);[replacement removeObjectForKey:@"contentFingerprint"];
    NSMutableArray *rows=[self.state[@"playlists"] mutableCopy];[rows replaceObjectAtIndex:[rows indexOfObjectIdenticalTo:row] withObject:replacement];NSError *error=nil;[self commitRows:rows nextRecord:nextRecord error:&error];return FMReply(!error,nil,error.localizedDescription);
}
- (NSArray *)orderedLibrary:(NSArray *)nativeRows {
    NSDictionary *meta = self.state[@"editor"] ?: @{};
    NSMutableArray *rows=[NSMutableArray arrayWithCapacity:nativeRows.count];
    for (id raw in nativeRows) {
        NSString *key=FMEditListKey(raw);
        if (!key) { [rows addObject:raw]; continue; }
        NSDictionary *prefs=meta[@"lists"][key];
        if (!prefs) { [rows addObject:raw]; continue; }
        NSMutableDictionary *row=[raw mutableCopy];
        if (prefs[@"title"]) row[@"title"]=prefs[@"title"];
        NSArray *observed=[self.editorCloudTracks objectForKey:key];
        if (observed && prefs[@"hidden"]) {
            NSSet *hidden=[NSSet setWithArray:prefs[@"hidden"]];
            NSUInteger excluded=0;
            for (NSDictionary *track in observed) if ([hidden containsObject:track[@"key"]]) excluded++;
            row[@"count"]=@(observed.count-excluded);
        }
        [rows addObject:row];
    }
    return FMEditOrder(rows,meta[@"order"],nil,^NSString *(NSDictionary *row){ return FMEditListKey(row); });
}
- (NSDictionary *)mergePlaylistList:(NSDictionary *)response {
    [self.lock lock];
    @try {
        NSArray *cloud=[response[@"code"] integerValue]==200&&[response[@"data"] isKindOfClass:NSArray.class]?response[@"data"]:@[];
        NSMutableArray *safe=[NSMutableArray array];
        for (id row in cloud) {
            if (!FMEditListKey(row)) continue;
            NSNumber *identifier=FMInteger([row[@"id"] description]);
            NSString *title=FMText(row[@"title"],256);
            if (identifier.longLongValue<=0 || !title.length) continue;
            [safe addObject:@{@"id":identifier,@"title":title,@"user_id":[row[@"user_id"] description]?:@"",@"count":@([row[@"count"] integerValue])}];
        }
        self.editorCloudLists=safe;
        NSArray *native=[cloud arrayByAddingObjectsFromArray:self.nativePlaylists];
        NSMutableDictionary *result=[response isKindOfClass:NSDictionary.class]?[response mutableCopy]:[NSMutableDictionary dictionary];
        result[@"code"]=@200; result[@"data"]=[self orderedLibrary:native];
        return result;
    } @finally { [self.lock unlock]; }
}
- (NSArray *)editorPlaylists {
    [self.lock lock];
    @try {
        NSArray *sorted=[self orderedLibrary:[self.editorCloudLists arrayByAddingObjectsFromArray:self.nativePlaylists]];
        NSMutableArray *out=[NSMutableArray array];
        for (NSDictionary *row in sorted) {
            NSString *key=FMEditListKey(row);
            if (key) [out addObject:@{@"key":key,@"id":row[@"id"],@"title":row[@"title"],@"count":row[@"count"]?:@0}];
        }
        return out;
    } @finally { [self.lock unlock]; }
}
- (NSDictionary *)editorList:(NSString *)key {
    for (NSDictionary *row in self.editorPlaylists) if ([row[@"key"] isEqual:key]) return row;
    return nil;
}
- (NSArray *)editorTrackRows:(NSArray *)native {
    if (![native isKindOfClass:NSArray.class] || native.count>20000) return nil;
    NSMutableSet *keys=[NSMutableSet set]; NSMutableArray *out=[NSMutableArray arrayWithCapacity:native.count];
    for (id row in native) {
        NSString *key=FMEditTrackKey(row);
        if (!key || [keys containsObject:key]) return nil;
        [keys addObject:key];
        [out addObject:@{@"key":key,@"title":FMText(row[@"title"],1024)?:@"未知歌曲",
            @"singer":FMText(row[@"singer"],2048)?:FMText(row[@"artist"],2048)?:@""}];
    }
    return out;
}
- (NSArray *)editorTracks:(NSString *)key {
    [self.lock lock];
    @try {
        NSDictionary *row=[self editorList:key];
        if (!row) return nil;
        if ([row[@"id"] longLongValue]<0) return [self editorTrackRows:[self row:row[@"id"]][@"tracks"]];
        NSArray *raw=[self.editorCloudTracks objectForKey:key];
        if (!raw) return nil;
        NSDictionary *prefs=self.state[@"editor"][@"lists"][key];
        return FMEditOrder(raw,prefs[@"order"],[NSSet setWithArray:prefs[@"hidden"]?:@[]],^NSString *(NSDictionary *entry){ return entry[@"key"]; });
    } @finally { [self.lock unlock]; }
}
- (NSDictionary *)mergeTracks:(NSDictionary *)response playlistID:(NSString *)identifier {
    if (![response isKindOfClass:NSDictionary.class] || [response[@"code"] integerValue]!=200 ||
        ![response[@"data"] isKindOfClass:NSArray.class]) return response;
    [self.lock lock];
    @try {
        for (NSDictionary *row in self.editorCloudLists) {
            if (![[row[@"id"] description] isEqual:identifier]) continue;
            NSString *key=FMEditListKey(row);
            NSArray *raw=[self editorTrackRows:response[@"data"]];
            if (!raw) { [self.editorCloudTracks removeObjectForKey:key]; return response; }
            [self.editorCloudTracks setObject:raw forKey:key cost:MAX(1,raw.count)];
            NSDictionary *prefs=self.state[@"editor"][@"lists"][key];
            if (!prefs[@"hidden"] && !prefs[@"order"]) return response;
            NSMutableDictionary *result=[response mutableCopy];
            result[@"data"]=FMEditOrder(response[@"data"],prefs[@"order"],[NSSet setWithArray:prefs[@"hidden"]?:@[]],^NSString *(NSDictionary *entry){return FMEditTrackKey(entry);});
            return result;
        }
        return response;
    } @finally { [self.lock unlock]; }
}
- (BOOL)saveEdit:(NSDictionary *)prefs key:(NSString *)key order:(NSArray *)order error:(NSError **)error {
    NSMutableDictionary *meta=[self.state[@"editor"] mutableCopy]?:[NSMutableDictionary dictionary];
    if (key) {
        NSMutableDictionary *lists=[meta[@"lists"] mutableCopy]?:[NSMutableDictionary dictionary];
        lists[key]=prefs; meta[@"lists"]=lists;
    }
    if (order) meta[@"order"]=order;
    NSMutableDictionary *next=[self.state mutableCopy];
    next[@"editor"]=meta;
    next[@"revision"]=@([self.state[@"revision"] unsignedLongLongValue]+1);
    return [self persist:next error:error];
}
- (BOOL)renameEditorPlaylist:(NSString *)key title:(NSString *)title error:(NSError **)error {
    [self.lock lock];
    @try {
        NSString *clean=[title stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (!FMText(clean,256).length) return FMEditFail(error,@"歌单名需为 1 至 256 个字符。");
        NSDictionary *summary=[self editorList:key];
        if (!summary) return FMEditFail(error,@"歌单已变化，请返回列表后重试。");
        if ([summary[@"id"] longLongValue]<0) {
            NSDictionary *row=[self row:summary[@"id"]];
            NSMutableDictionary *copy=[row mutableCopy]; copy[@"title"]=clean;
            copy[@"revision"]=@([row[@"revision"] unsignedLongLongValue]+1);
            NSMutableArray *rows=[self.state[@"playlists"] mutableCopy];
            rows[[rows indexOfObjectIdenticalTo:row]]=copy;
            return [self commitRows:rows nextRecord:[self.state[@"nextRecord"] longLongValue] error:error]!=nil;
        }
        NSMutableDictionary *prefs=[self.state[@"editor"][@"lists"][key] mutableCopy]?:[NSMutableDictionary dictionary];
        prefs[@"title"]=clean;
        return [self saveEdit:prefs key:key order:nil error:error];
    } @finally { [self.lock unlock]; }
}
- (BOOL)saveEditorListOrder:(NSArray *)keys error:(NSError **)error {
    [self.lock lock];
    @try {
        NSArray *existing=[self.editorPlaylists valueForKey:@"key"];
        if(!FMEditUnique(keys,1500) || keys.count!=existing.count ||
           ![[NSSet setWithArray:keys] isEqualToSet:[NSSet setWithArray:existing]]) return FMEditFail(error,@"歌单列表已变化，请刷新后重试。");
        // A cloud outage or a different account can temporarily hide lists.
        // Reorder the visible slots, retaining the stored positions of others.
        NSSet *visible=[NSSet setWithArray:keys];
        NSMutableArray *merged=[NSMutableArray array];NSUInteger position=0;
        for(NSString *previous in self.state[@"editor"][@"order"]) {
            if ([visible containsObject:previous]) [merged addObject:keys[position++]];
            else [merged addObject:previous];
        }
        while(position<keys.count) [merged addObject:keys[position++]];
        return [self saveEdit:nil key:nil order:merged error:error];
    } @finally { [self.lock unlock]; }
}
- (BOOL)saveEditorTracks:(NSArray *)desired replacing:(NSArray *)observed playlist:(NSString *)key error:(NSError **)error {
    [self.lock lock];
    @try {
        NSDictionary *summary=[self editorList:key]; NSArray *current=[self editorTracks:key];
        if (!summary || !current || ![[current valueForKey:@"key"] isEqual:observed] || !FMEditUnique(desired,20000))
            return FMEditFail(error,@"歌单已变化，请重新打开后编辑。");
        NSSet *remaining=[NSSet setWithArray:desired];
        if (![remaining isSubsetOfSet:[NSSet setWithArray:observed]]) return FMEditFail(error,@"歌曲列表无效。");
        if ([summary[@"id"] longLongValue]<0) {
            NSDictionary *row=[self row:summary[@"id"]];
            NSMutableDictionary *byKey=[NSMutableDictionary dictionary];
            for(NSDictionary *track in row[@"tracks"]) byKey[FMEditTrackKey(track)]=track;
            NSMutableArray *tracks=[NSMutableArray arrayWithCapacity:desired.count];
            for(NSString *identifier in desired) [tracks addObject:byKey[identifier]];
            NSDictionary *reply=[self updateRow:row tracks:tracks nextRecord:[self.state[@"nextRecord"] longLongValue]];
            return [reply[@"code"] integerValue]==200 || FMEditFail(error,reply[@"msg"]?:@"歌单保存失败。");
        }
        NSMutableDictionary *prefs=[self.state[@"editor"][@"lists"][key] mutableCopy]?:[NSMutableDictionary dictionary];
        NSMutableSet *hidden=[NSMutableSet setWithArray:prefs[@"hidden"]?:@[]];
        for(NSString *record in observed) if(![remaining containsObject:record]) [hidden addObject:record];
        prefs[@"hidden"]=[hidden.allObjects sortedArrayUsingSelector:@selector(compare:)]; prefs[@"order"]=desired;
        return [self saveEdit:prefs key:key order:nil error:error];
    } @finally { [self.lock unlock]; }
}
- (NSDictionary *)diagnostics{[self.lock lock];@try{return @{@"schema":@1,@"localPlaylists":@([self.state[@"playlists"] count]),@"pending":@(self.plans.count),@"commits":@(self.commits),@"failedCommits":@(self.failedCommits),@"overwrites":@(self.overwrites),@"copies":@(self.copies),@"cancelled":@(self.cancelled),@"loadFailed":@(self.loadError!=nil)};}@finally{[self.lock unlock];}}
@end
