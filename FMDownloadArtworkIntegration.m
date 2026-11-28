#import "FMDownloadArtworkIntegration.h"
#import "FMDownloadArtwork.h"
#import "FMTrackMetadata.h"
#import <fcntl.h>
#import <sys/stat.h>
#import <errno.h>
#import <stdio.h>
#import <unistd.h>

static BOOL FMDARegular(NSURL *url, struct stat *result) {
    struct stat s;
    if (!url.isFileURL || lstat(url.fileSystemRepresentation, &s) || !S_ISREG(s.st_mode) || s.st_size <= 0) return NO;
    if (result) *result = s;
    return YES;
}
static BOOL FMDASameFile(struct stat a, struct stat b) {
    return a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_size == b.st_size &&
        a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec;
}
static NSString *FMDAIdentifier(id value) {
    if ([value isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)value) != CFBooleanGetTypeID()) value=[value stringValue];
    if (![value isKindOfClass:NSString.class] || ![value length] || [value length] > 220) return nil;
    static NSCharacterSet *invalid;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        invalid=[[NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-."]
                 invertedSet];
    });
    return [value rangeOfCharacterFromSet:invalid].location == NSNotFound ? value : nil;
}
static NSString *FMDASource(id server) {
    if (![server isKindOfClass:NSString.class]) return nil;
    return @{@"wy":@"wy", @"netease":@"wy", @"qq":@"tx", @"tx":@"tx", @"kg":@"kg", @"kugou":@"kg",
             @"kw":@"kw", @"kuwo":@"kw", @"mg":@"mg", @"migu":@"mg", @"qs":@"qishui", @"qishui":@"qishui"}[server];
}
static NSArray *FMDAExtensions(void) {
    return @[@"mp3",@"flac",@"m4a",@"wav",@"ogg",@"opus",@"aac",@"aif",@"aiff",@"aifc",@"caf",@"mp4",@"ape",@"wv",@"mpc",@"tta",@"spx",@"dsf",@"dff"];
}
static NSArray *FMDAReadIndex(NSURL *url) {
    struct stat s;
    if (!FMDARegular(url, &s) || s.st_size > 64 * 1024 * 1024) return nil;
    NSData *data = [NSData dataWithContentsOfURL:url options:NSDataReadingUncached error:nil];
    if (!data.length) return nil;
    id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    return [json isKindOfClass:NSArray.class] ? json : nil;
}

@interface FMDownloadArtworkIntegration ()
@property(nonatomic,strong) NSURL *support,*assets,*downloads,*index;
@property(nonatomic,strong) FMDownloadArtwork *store;
@property(nonatomic,strong) dispatch_queue_t queue;
@property(nonatomic,strong) dispatch_source_t directoryWatch,indexWatch;
@property(nonatomic) ino_t watchedInode;
@property(nonatomic) struct stat snapshotStamp;
@property(nonatomic) BOOL hasSnapshot;
@property(nonatomic,strong) NSMutableDictionary<NSString *,NSDate *> *retryAfter;
@property(nonatomic,strong) NSMutableSet<NSString *> *active;
@property(nonatomic,copy) NSDictionary<NSString *,NSDictionary *> *rows;
@property(nonatomic,strong) NSMutableArray<NSString *> *pending;
@property(nonatomic) BOOL scheduled,started;
@end
@implementation FMDownloadArtworkIntegration
- (instancetype)initWithSupport:(NSURL *)support documents:(NSURL *)documents store:(FMDownloadArtwork *)store {
    if ((self=[super init])) {
        _support=support; _downloads=[documents URLByAppendingPathComponent:@"Downloads" isDirectory:YES];
        _assets=[support URLByAppendingPathComponent:@"DownloadAssets" isDirectory:YES];
        _index=[support URLByAppendingPathComponent:@"downloaded_tracks.json"];
        _store=store; _active=NSMutableSet.set; _retryAfter=NSMutableDictionary.dictionary;
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
    if(_directoryWatch)dispatch_source_cancel(_directoryWatch);
    if(_indexWatch)dispatch_source_cancel(_indexWatch);
}
- (void)refresh { dispatch_async(_queue,^{self.hasSnapshot=NO;[self schedule];}); }
- (void)schedule {
    if(_scheduled)return;
    _scheduled=YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,250*NSEC_PER_MSEC),_queue,^{self.scheduled=NO;[self scan];});
}
- (void)scan {
    if(!_directoryWatch) {
        [NSFileManager.defaultManager createDirectoryAtURL:_support withIntermediateDirectories:YES attributes:nil error:nil];
        _directoryWatch=[self watch:_support];
    }
    struct stat s;
    ino_t inode=FMDARegular(_index,&s)?s.st_ino:0;
    if(_watchedInode!=inode || (inode && !_indexWatch)){
        if(_indexWatch)dispatch_source_cancel(_indexWatch);
        _indexWatch=inode?[self watch:_index]:nil;
        _watchedInode=inode;
    }
    if(inode && _hasSnapshot && FMDASameFile(_snapshotStamp,s))return;
    NSArray *records=FMDAReadIndex(_index);
    if(!inode || !records) { self.rows=@{};self.pending=nil;self.hasSnapshot=NO;return; }
    struct stat after;
    if(!FMDARegular(_index,&after) || !FMDASameFile(s,after)) { [self schedule];return; }
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
    _pending=pending;
    for(NSString *key in _retryAfter.allKeys)if(!rows[key])[_retryAfter removeObjectForKey:key];
    [self pump];
}
- (NSURL *)audioForKey:(NSString *)key {
    for(NSString *ext in FMDAExtensions()){
        NSURL *file=[_downloads URLByAppendingPathComponent:[key stringByAppendingPathExtension:ext]];
        if(FMDARegular(file,NULL))return file;
    }
    return nil;
}
- (NSURL *)sidecar:(NSString *)key {
    return [_assets URLByAppendingPathComponent:[key stringByAppendingString:@"_cover.jpg"]];
}
- (BOOL)indexStillContainsKey:(NSString *)key stamp:(struct stat)stamp {
    struct stat now;
    if(!FMDARegular(_index,&now))return NO;
    if(FMDASameFile(stamp,now))return YES;
    for(id record in FMDAReadIndex(_index)){
        if(![record isKindOfClass:NSDictionary.class])continue;
        NSString *identifier=FMDAIdentifier(record[@"id"]),*server=record[@"server"];
        if(identifier && FMDASource(server) && [[NSString stringWithFormat:@"%@_%@",server,identifier] isEqual:key])return YES;
    }
    return NO;
}
- (BOOL)publish:(NSURL *)jpeg key:(NSString *)key {
    if(![FMDownloadArtwork isUsableJPEGAtURL:jpeg])return NO;
    NSFileManager *files=NSFileManager.defaultManager;
    [files createDirectoryAtURL:_assets withIntermediateDirectories:YES attributes:nil error:nil];
    struct stat folder;
    if(lstat(_assets.fileSystemRepresentation,&folder)||!S_ISDIR(folder.st_mode))return NO;
    NSURL *dest=[self sidecar:key];
    if([FMDownloadArtwork isUsableImageAtURL:dest])return YES;
    NSURL *tmp=[_assets URLByAppendingPathComponent:[@".artwork-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    if(![files copyItemAtURL:jpeg toURL:tmp error:nil])return NO;
    BOOL success=NO;
    @try {
        struct stat original;
        if(lstat(dest.fileSystemRepresentation,&original)){
            if(errno!=ENOENT)return NO;
            // Exclusive creation preserves a native cover which finished during repair.
            success=link(tmp.fileSystemRepresentation,dest.fileSystemRepresentation)==0;
        }else if(S_ISREG(original.st_mode)&&![FMDownloadArtwork isUsableImageAtURL:dest]){
            struct stat check;
            if(!lstat(dest.fileSystemRepresentation,&check)&&FMDASameFile(original,check))
                success=rename(tmp.fileSystemRepresentation,dest.fileSystemRepresentation)==0;
        }
        return success||[FMDownloadArtwork isUsableImageAtURL:dest];
    } @finally {[files removeItemAtURL:tmp error:nil];}
}
- (void)pump {
    while(_pending.count && _active.count<2) {
        NSString *key=_pending.lastObject;[_pending removeLastObject];
        if([_active containsObject:key]||[_retryAfter[key] timeIntervalSinceNow]>0)continue;
        NSURL *sidecar=[self sidecar:key];
        if([FMDownloadArtwork isUsableImageAtURL:sidecar])continue;
        NSDictionary *row=_rows[key];NSString *source=FMDASource(row[@"server"]);
        NSURL *audio=[self audioForKey:key];
        struct stat audioStamp,indexStamp=_snapshotStamp;
        if(!FMDARegular(audio,&audioStamp))continue;
        NSString *identifier=FMDAIdentifier(row[@"id"]);
        NSDictionary *meta=FMTrackMetadataForParameters(row,source);
        NSString *cover=meta[@"img"];
        if(![cover isKindOfClass:NSString.class] || !cover.length)
            cover=[row[@"cover"] isKindOfClass:NSString.class]?row[@"cover"]:nil;
        NSURL *URL=cover.length?[NSURL URLWithString:cover]:nil;
        [_active addObject:key];
        [_store resolvePlatform:source trackID:identifier audioFile:audio coverURL:URL completion:^(NSURL *jpeg){
            dispatch_async(self.queue,^{
                struct stat now;
                BOOL current=FMDARegular(audio,&now)&&FMDASameFile(audioStamp,now)&&[self indexStillContainsKey:key stamp:indexStamp];
                if(current && (!jpeg||![self publish:jpeg key:key]))self.retryAfter[key]=[NSDate dateWithTimeIntervalSinceNow:300];
                [self.active removeObject:key];[self pump];
            });
        }];
    }
}
@end

void FMDownloadArtworkInstall(void) {
    static FMDownloadArtworkIntegration *service;
    static dispatch_once_t once;
    dispatch_once(&once,^{
        NSURL *support=[NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
        NSURL *documents=[NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
        service=[[FMDownloadArtworkIntegration alloc]initWithSupport:support documents:documents store:FMDownloadArtwork.sharedStore];
        [service start];
        // Re-entering the app also retries transient offline failures after their delay.
        [NSNotificationCenter.defaultCenter addObserverForName:@"UIApplicationDidBecomeActiveNotification" object:nil queue:nil
            usingBlock:^(__unused NSNotification *event){[service refresh];}];
    });
}
