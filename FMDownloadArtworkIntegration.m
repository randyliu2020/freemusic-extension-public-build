#import "FMDownloadArtworkIntegration.h"
#import "FMDownloadArtwork.h"
#import "FMDownloadFiles.h"
#import "FMTrackMetadata.h"
#import <fcntl.h>
#import <sys/stat.h>
#import <errno.h>
#import <stdio.h>
#import <unistd.h>

NSNotificationName const FMDownloadArtworkDidRecoverNotification = @"FMDownloadArtworkDidRecoverNotification";
NSNotificationName const FMDownloadArtworkStatusDidChangeNotification = @"FMDownloadArtworkStatusDidChangeNotification";
NSNotificationName const FMDownloadCatalogueDidChangeNotification = @"FMDownloadCatalogueDidChangeNotification";
static FMDownloadArtworkIntegration *FMDAService;
static NSDictionary *FMDAEmptyStatus(void) {
    return @{@"scanned":@NO,@"wyRegistered":@0,@"wyUsable":@0,@"wyMissingAudio":@0,@"wyFailed":@0,@"wyPending":@0};
}
NSDictionary *FMDownloadArtworkStatus(void) {
    @synchronized (FMDownloadArtworkIntegration.class) { return [FMDAService status] ?: FMDAEmptyStatus(); }
}

@interface FMDownloadArtworkIntegration ()
@property(nonatomic,strong) NSURL *support,*assets,*downloads,*index,*legacyIndex,*legacyCache,*selectedIndex;
@property(nonatomic,strong) FMDownloadArtwork *store;
@property(nonatomic,strong) dispatch_queue_t queue;
@property(nonatomic,strong) dispatch_source_t indexWatch,retryTimer;
@property(nonatomic,strong) NSMutableDictionary<NSURL *,id> *directoryWatches;
@property(nonatomic,strong) NSMutableDictionary<NSURL *,NSNumber *> *directoryInodes;
@property(nonatomic) ino_t watchedInode;
@property(nonatomic) struct stat snapshotStamp;
@property(nonatomic) BOOL hasSnapshot;
@property(nonatomic,strong) NSMutableDictionary<NSString *,NSDate *> *retryAfter;
@property(nonatomic,strong) NSMutableSet<NSString *> *active;
@property(nonatomic,copy) NSDictionary<NSString *,NSDictionary *> *rows;
@property(nonatomic,strong) NSMutableArray<NSString *> *pending;
@property(nonatomic,strong) NSMutableDictionary<NSString *,NSString *> *states,*announced;
@property(nonatomic,copy) NSDictionary *publishedStatus, *publishedAudioCatalogue;
@property(nonatomic) BOOL scheduled,started,statusNotificationScheduled;
@end
@implementation FMDownloadArtworkIntegration
- (instancetype)initWithSupport:(NSURL *)support documents:(NSURL *)documents store:(FMDownloadArtwork *)store {
    if ((self=[super init])) {
        _support=support; _downloads=[documents URLByAppendingPathComponent:@"Downloads" isDirectory:YES];
        _assets=[support URLByAppendingPathComponent:@"DownloadAssets" isDirectory:YES];
        _index=[support URLByAppendingPathComponent:@"downloaded_tracks.json"];
        NSURL *caches=[support.URLByDeletingLastPathComponent URLByAppendingPathComponent:@"Caches" isDirectory:YES];
        _legacyIndex=[caches URLByAppendingPathComponent:@"downloaded_tracks.json"];
        _legacyCache=[caches URLByAppendingPathComponent:@"MusicCache" isDirectory:YES];
        _store=store; _active=NSMutableSet.set; _retryAfter=NSMutableDictionary.dictionary;
        _announced=NSMutableDictionary.dictionary;_states=NSMutableDictionary.dictionary;
        _directoryWatches=NSMutableDictionary.dictionary;
        _directoryInodes=NSMutableDictionary.dictionary;
        _publishedStatus=FMDAEmptyStatus();
        _queue=dispatch_queue_create("FreeMusic.download-artwork-index",DISPATCH_QUEUE_SERIAL);
        dispatch_set_target_queue(_queue, dispatch_get_global_queue(QOS_CLASS_UTILITY,0));
    }
    return self;
}
- (dispatch_source_t)watch:(NSURL *)URL {
    int fd=open(URL.fileSystemRepresentation,O_EVTONLY|O_NOFOLLOW);
    if(fd<0) return nil;
    dispatch_source_t watcher=dispatch_source_create(DISPATCH_SOURCE_TYPE_VNODE,fd,
        DISPATCH_VNODE_WRITE|DISPATCH_VNODE_RENAME|DISPATCH_VNODE_DELETE,_queue);
    if(!watcher){close(fd);return nil;}
    __weak typeof(self) weak=self;
    dispatch_source_set_event_handler(watcher, ^{[weak schedule];});
    dispatch_source_set_cancel_handler(watcher, ^{close(fd);});
    dispatch_resume(watcher);
    return watcher;
}
- (void)start {
    dispatch_async(_queue,^{
        if(self.started)return;
        self.started=YES;
        [self scan];
    });
}
- (void)dealloc {
    for(dispatch_source_t source in _directoryWatches.allValues)dispatch_source_cancel(source);
    if(_indexWatch)dispatch_source_cancel(_indexWatch);
    if(_retryTimer)dispatch_source_cancel(_retryTimer);
}
- (NSDictionary *)status { @synchronized(self){return _publishedStatus;} }
- (void)updateStatus {
    NSMutableDictionary *summary=[FMDAEmptyStatus() mutableCopy];
    summary[@"scanned"]=@(_hasSnapshot);
    NSUInteger count=0;
    for(NSString *key in _rows) {
        if(![FMDASource(_rows[key][@"server"]) isEqual:@"wy"])continue;
        count++;
        NSString *state=_states[key] ?: @"wyPending";
        summary[state]=@([summary[state] unsignedIntegerValue]+1);
    }
    summary[@"wyRegistered"]=@(count);
    @synchronized(self) {
        if([summary isEqual:_publishedStatus])return;
        _publishedStatus=summary.copy;
    }
    if(_statusNotificationScheduled)return;
    _statusNotificationScheduled=YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,200*NSEC_PER_MSEC),_queue,^{
        self.statusNotificationScheduled=NO;
        dispatch_async(dispatch_get_main_queue(),^{
            [NSNotificationCenter.defaultCenter postNotificationName:FMDownloadArtworkStatusDidChangeNotification object:nil];
        });
    });
}
- (NSURL *)authoritativeIndex {
    struct stat s;
    // Match the original loader's existence decision: a corrupt or empty
    // current index must never cause entries from an older list to reappear.
    if(!lstat(_index.fileSystemRepresentation,&s) || errno!=ENOENT)return _index;
    return _legacyIndex;
}
- (void)refresh { dispatch_async(_queue,^{self.hasSnapshot=NO;[self schedule];}); }
- (void)schedule {
    if(_scheduled)return;
    _scheduled=YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,250*NSEC_PER_MSEC),_queue,^{self.scheduled=NO;[self scan];});
}
// Directory changes also include JPEG repairs and metadata reordering. Compare
// only real, registered audio identities on the background index queue.
- (void)refreshAudioCatalogue {
    NSMutableDictionary *snapshot = NSMutableDictionary.dictionary;
    NSFileManager *files = NSFileManager.defaultManager;
    for (NSURL *root in @[_downloads, _assets]) {
        if (!FMDADirectory(root)) continue;
        for (NSString *name in [files contentsOfDirectoryAtPath:root.path error:nil]) {
            NSString *ext = name.pathExtension;
            if (![FMDAExtensions() containsObject:ext]) continue;
            NSString *key = name.stringByDeletingPathExtension;
            NSDictionary *row = _rows[key];
            if (!row && [root isEqual:_assets] && [ext isEqual:@"caf"] && [key hasSuffix:@"_playback"]) {
                key = [key substringToIndex:key.length - @"_playback".length];
                row = _rows[key];
            }
            if (!row) continue;
            NSURL *file = [root URLByAppendingPathComponent:name];
            struct stat stamp;
            if (FMDARegular(file, &stamp)) {
                snapshot[file] = @[key, @(stamp.st_dev), @(stamp.st_ino), @(stamp.st_size),
                                   @(stamp.st_mtimespec.tv_sec), @(stamp.st_mtimespec.tv_nsec)];
            }
        }
    }
    BOOL changed = _publishedAudioCatalogue && ![_publishedAudioCatalogue isEqual:snapshot];
    _publishedAudioCatalogue = snapshot.copy;
    if (changed) dispatch_async(dispatch_get_main_queue(), ^{
        [NSNotificationCenter.defaultCenter postNotificationName:FMDownloadCatalogueDidChangeNotification object:nil];
    });
}
- (void)scan {
    NSArray *watchRoots=@[_support.URLByDeletingLastPathComponent,_support,_downloads.URLByDeletingLastPathComponent,_downloads,_assets,
                          _legacyIndex.URLByDeletingLastPathComponent,_legacyCache];
    for(NSURL *root in watchRoots) {
        struct stat dir;
        ino_t inode=(!lstat(root.fileSystemRepresentation,&dir) && S_ISDIR(dir.st_mode))?dir.st_ino:0;
        if(_directoryWatches[root] && [_directoryInodes[root] unsignedLongLongValue]!=inode) {
            dispatch_source_cancel(_directoryWatches[root]);
            [_directoryWatches removeObjectForKey:root];[_directoryInodes removeObjectForKey:root];
        }
        if(!_directoryWatches[root] && inode) {
            dispatch_source_t watcher=[self watch:root];
            if(watcher){_directoryWatches[root]=watcher;_directoryInodes[root]=@(inode);}
        }
    }
    NSURL *index=[self authoritativeIndex];
    struct stat s;
    ino_t inode=FMDARegular(index,&s)?s.st_ino:0;
    BOOL sameIndex=[_selectedIndex isEqual:index];
    if(!sameIndex || _watchedInode!=inode || (inode && !_indexWatch)){
        if(_indexWatch)dispatch_source_cancel(_indexWatch);
        _indexWatch=inode?[self watch:index]:nil;
        _watchedInode=inode;
    }
    if(sameIndex && inode && _hasSnapshot && FMDASameFile(_snapshotStamp,s)){
        // The metadata may arrive first and remain byte-identical while the
        // download completes or iOS atomically moves the audio into place.
        for(NSString *key in _rows)
            if([_states[key] isEqual:@"wyMissingAudio"] && ![_active containsObject:key] &&
               ![_pending containsObject:key] && [self audioForKey:key])[_pending addObject:key];
        [self refreshAudioCatalogue];
        [self pump];return;
    }
    _selectedIndex=index;
    NSArray *records=FMDAReadIndex(index);
    if(!inode || !records) { self.rows=@{};[self refreshAudioCatalogue];self.pending=nil;self.hasSnapshot=NO;[self updateStatus];return; }
    struct stat after;
    if(!FMDARegular(index,&after) || !FMDASameFile(s,after)) { [self schedule];return; }
    _hasSnapshot=YES;
    _snapshotStamp=s;
    NSMutableDictionary *rows=NSMutableDictionary.dictionary;
    NSMutableArray *pending=NSMutableArray.array;
    for(id record in records) {
        if(![record isKindOfClass:NSDictionary.class])continue;
        NSString *identifier=FMDAIdentifier(record[@"id"]),*server=record[@"server"];
        if(!identifier||!FMDASource(server))continue;
        NSString *key=[NSString stringWithFormat:@"%@_%@",server,identifier];
        if(!rows[key])[pending addObject:key];
        rows[key]=record;
    }
    _rows=rows;
    [self refreshAudioCatalogue];
    _pending=pending;
    [_states removeAllObjects];
    for(NSString *key in _announced.allKeys)if(!rows[key])[_announced removeObjectForKey:key];
    for(NSString *key in _retryAfter.allKeys)if(!rows[key])[_retryAfter removeObjectForKey:key];
    [self pump];
}
- (NSURL *)audioForKey:(NSString *)key {
    for(NSURL *root in @[_downloads,_assets,_legacyCache]) {
        if(!FMDADirectory(root))continue;
        for(NSString *ext in FMDAExtensions()){
            NSURL *file=[root URLByAppendingPathComponent:[key stringByAppendingPathExtension:ext]];
            if(FMDARegular(file,NULL))return file;
        }
        if([root isEqual:_assets]){
            NSURL *decoded=[root URLByAppendingPathComponent:[key stringByAppendingString:@"_playback.caf"]];
            if(FMDARegular(decoded,NULL))return decoded;
        }
    }
    return nil;
}
- (NSURL *)sidecar:(NSString *)key {
    return [_assets URLByAppendingPathComponent:[key stringByAppendingString:@"_cover.jpg"]];
}
- (BOOL)indexStillContainsKey:(NSString *)key index:(NSURL *)registeredIndex stamp:(struct stat)stamp row:(NSDictionary *)expected {
    NSURL *current=[self authoritativeIndex];
    struct stat now;
    if(!FMDARegular(current,&now))return NO;
    if([registeredIndex isEqual:current] && FMDASameFile(stamp,now))return YES;
    for(id record in FMDAReadIndex(current)){
        if(![record isKindOfClass:NSDictionary.class])continue;
        NSString *identifier=FMDAIdentifier(record[@"id"]),*server=record[@"server"];
        if(identifier && FMDASource(server) && [[NSString stringWithFormat:@"%@_%@",server,identifier] isEqual:key])
            return [(record[@"cover"] ?: NSNull.null) isEqual:(expected[@"cover"] ?: NSNull.null)];
    }
    return NO;
}
- (BOOL)publishImage:(NSURL *)image at:(NSURL *)dest {
    if(![FMDownloadArtwork isUsableImageAtURL:image])return NO;
    NSFileManager *files=NSFileManager.defaultManager;
    NSURL *directory=dest.URLByDeletingLastPathComponent;
    if([directory.URLByStandardizingPath.path isEqual:_assets.URLByStandardizingPath.path])
        [files createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:nil];
    if(!FMDADirectory(directory))return NO;
    if([FMDownloadArtwork isUsableImageAtURL:dest])return YES;
    NSURL *tmp=[directory URLByAppendingPathComponent:[@".artwork-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    if(![files copyItemAtURL:image toURL:tmp error:nil])return NO;
    BOOL success=NO;
    @try {
        struct stat original;
        if(lstat(dest.fileSystemRepresentation,&original)){
            if(errno!=ENOENT)return NO;
            // Exclusive creation preserves a native cover which finished during repair.
            success=link(tmp.fileSystemRepresentation,dest.fileSystemRepresentation)==0;
        }else if(S_ISREG(original.st_mode) && original.st_size<=8*1024*1024 && ![FMDownloadArtwork isUsableImageAtURL:dest]){
            // A file above our decoder budget may still be a valid original.
            // An inability to inspect it is not evidence that replacement is safe.
            struct stat check;
            if(!lstat(dest.fileSystemRepresentation,&check)&&FMDASameFile(original,check))
                success=rename(tmp.fileSystemRepresentation,dest.fileSystemRepresentation)==0;
        }
        return success||[FMDownloadArtwork isUsableImageAtURL:dest];
    } @finally {[files removeItemAtURL:tmp error:nil];}
}
- (NSArray<NSURL *> *)nativeCovers:(NSString *)key {
    NSString *name=[key stringByAppendingString:@"_cover.jpg"];
    return @[[self.downloads URLByAppendingPathComponent:name],[self sidecar:key],[self.legacyCache URLByAppendingPathComponent:name]];
}
- (NSURL *)firstUsable:(NSArray<NSURL *> *)covers {
    for(NSURL *cover in covers)
        if(FMDADirectory(cover.URLByDeletingLastPathComponent) && [FMDownloadArtwork isUsableImageAtURL:cover])return cover;
    return nil;
}
- (NSURL *)restore:(NSURL *)image covers:(NSArray<NSURL *> *)covers {
    // Native resolution selects the first nonempty regular file, even a broken
    // image. Repair that exact shadow if present, while preserving every good
    // native image and keeping legacy-cache-only artwork in persistent storage.
    NSURL *first=covers[0],*persistent=covers[1];
    if(FMDADirectory(first.URLByDeletingLastPathComponent) && FMDARegular(first,NULL)) {
        if([self publishImage:image at:first])return first;
        return nil;
    }
    if([self publishImage:image at:persistent])return persistent;
    return nil;
}
- (void)announceCover:(NSURL *)url key:(NSString *)key row:(NSDictionary *)row {
    id expected=[row[@"cover"] isKindOfClass:NSString.class]?row[@"cover"]:NSNull.null;
    struct stat s;
    if(!FMDARegular(url,&s))return;
    NSString *version=[NSString stringWithFormat:@"%@|%llu|%lld|%lld|%ld|%@",url.path,
                       (unsigned long long)s.st_ino,(long long)s.st_size,(long long)s.st_mtimespec.tv_sec,s.st_mtimespec.tv_nsec,expected];
    if([_announced[key] isEqual:version])return;
    _announced[key]=version;
    NSDictionary *info=@{@"server":row[@"server"],@"id":FMDAIdentifier(row[@"id"]),@"coverURL":url,@"trackKey":key,@"expectedCover":expected};
    dispatch_async(dispatch_get_main_queue(),^{
        [NSNotificationCenter.defaultCenter postNotificationName:FMDownloadArtworkDidRecoverNotification object:nil userInfo:info];
    });
}
- (void)scheduleRetry {
    if(_retryTimer){dispatch_source_cancel(_retryTimer);_retryTimer=nil;}
    NSDate *date=nil;
    for(NSDate *candidate in _retryAfter.allValues)
        if(!date || [candidate compare:date]==NSOrderedAscending)date=candidate;
    if(!date)return;
    _retryTimer=dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,0,0,_queue);
    int64_t delay=(int64_t)(MAX(0.2,date.timeIntervalSinceNow)*NSEC_PER_SEC);
    dispatch_source_set_timer(_retryTimer,dispatch_time(DISPATCH_TIME_NOW,delay),DISPATCH_TIME_FOREVER,NSEC_PER_SEC);
    __weak typeof(self) weak=self;
    dispatch_source_set_event_handler(_retryTimer,^{
        typeof(self) service=weak;if(!service)return;
        for(NSString *key in service.retryAfter.allKeys) {
            if([service.retryAfter[key] timeIntervalSinceNow]>0)continue;
            [service.retryAfter removeObjectForKey:key];
            if(service.rows[key] && ![service.pending containsObject:key])[service.pending addObject:key];
        }
        [service scheduleRetry];[service pump];
    });
    dispatch_resume(_retryTimer);
}
- (void)pump {
    while(_pending.count && _active.count<2) {
        NSString *key=_pending.lastObject;[_pending removeLastObject];
        if([_active containsObject:key])continue;
        NSDictionary *row=_rows[key];NSString *source=FMDASource(row[@"server"]);
        NSURL *audio=[self audioForKey:key];
        struct stat audioStamp,indexStamp=_snapshotStamp;
        NSURL *registeredIndex=_selectedIndex;
        if(!FMDARegular(audio,&audioStamp)){_states[key]=@"wyMissingAudio";continue;}
        NSArray<NSURL *> *covers=[self nativeCovers:key];
        NSURL *known=[self firstUsable:covers];
        if(known) {
            BOOL registered=[self indexStillContainsKey:key index:registeredIndex stamp:indexStamp row:row];
            NSURL *usable=registered?[self restore:known covers:covers]:nil;
            _states[key]=usable?@"wyUsable":@"wyFailed";
            // This also refreshes a loaded model holding a file URL from a
            // previous container after an update/re-sign. Never trust its path.
            if(usable){
                [_retryAfter removeObjectForKey:key];
                [self announceCover:usable key:key row:row];
            }else if(registered){_retryAfter[key]=[NSDate dateWithTimeIntervalSinceNow:300];}
            continue;
        }
        [_announced removeObjectForKey:key];
        if([_retryAfter[key] timeIntervalSinceNow]>0){_states[key]=@"wyFailed";continue;}
        _states[key]=@"wyPending";
        NSString *identifier=FMDAIdentifier(row[@"id"]);
        NSDictionary *meta=FMTrackMetadataForParameters(row,source);
        NSString *cover=meta[@"img"];
        if(![cover isKindOfClass:NSString.class] || !cover.length)
            cover=[row[@"cover"] isKindOfClass:NSString.class]?row[@"cover"]:nil;
        NSURL *URL=cover.length?[NSURL URLWithString:cover]:nil;
        if(URL.isFileURL)URL=nil; // Only native exact-key locations above are trusted across container changes.
        [_active addObject:key];
        [_store resolveRegisteredPlatform:row[@"server"] trackID:identifier audioFile:audio coverURL:URL completion:^(NSURL *jpeg){
            dispatch_async(self.queue,^{
                struct stat now;
                BOOL current=FMDARegular(audio,&now)&&FMDASameFile(audioStamp,now)&&[self indexStillContainsKey:key index:registeredIndex stamp:indexStamp row:row];
                if(current) {
                    NSURL *available=[self firstUsable:covers] ?: jpeg;
                    NSURL *usable=available?[self restore:available covers:covers]:nil;
                    self.states[key]=usable?@"wyUsable":@"wyFailed";
                    if(usable){[self.retryAfter removeObjectForKey:key];[self announceCover:usable key:key row:row];}
                    else self.retryAfter[key]=[NSDate dateWithTimeIntervalSinceNow:300];
                }else if(self.rows[key]) {
                    // Re-evaluate the authoritative index/audio pair after an
                    // atomic replacement; a stale callback cannot publish.
                    self.hasSnapshot=NO;[self schedule];
                }
                [self.active removeObject:key];[self pump];
            });
        }];
    }
    [self updateStatus];
    [self scheduleRetry];
}
@end

void FMDownloadArtworkInstall(void) {
    static dispatch_once_t once;
    dispatch_once(&once,^{
        NSURL *support=[NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
        NSURL *documents=[NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
        FMDownloadArtworkIntegration *service=[[FMDownloadArtworkIntegration alloc]initWithSupport:support documents:documents store:FMDownloadArtwork.sharedStore];
        @synchronized(FMDownloadArtworkIntegration.class){FMDAService=service;}
        [service start];
        // Re-entering the app also retries transient offline failures after their delay.
        [NSNotificationCenter.defaultCenter addObserverForName:@"UIApplicationDidBecomeActiveNotification" object:nil queue:nil
            usingBlock:^(__unused NSNotification *event){[service refresh];}];
    });
}
