#import "FMNativeDownloadCoverDisplay.h"
#import "FMDownloadArtworkIntegration.h"
#import <CommonCrypto/CommonDigest.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <objc/runtime.h>
#import <sys/stat.h>
#import <stdio.h>
#import <string.h>

extern NSInteger FMNativeDownloadCoverApply(const void *owner,const void *retainedKeyPath,const void *changes);
typedef void *(*FMDCGetKeyPath)(const void *,const void *);
static NSMutableDictionary<NSString *,NSMutableDictionary *> *FMDCChanges;
static BOOL FMDCScheduled;
static const uint8_t *FMDCImage;
static FMDCGetKeyPath FMDCMakeKeyPath;

static BOOL FMDCMatch(const uint8_t *bytes,size_t length,const char *expected) {
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];CC_SHA256(bytes,(CC_LONG)length,digest);
    char result[2*CC_SHA256_DIGEST_LENGTH+1];
    for(NSUInteger i=0;i<sizeof(digest);i++)snprintf(result+2*i,3,"%02x",digest[i]);
    return strcmp(result,expected)==0;
}
static void FMDCIdentify(void) {
    if(![[NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleVersion"] isEqual:@"4381"] ||
       ![[NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] isEqual:@"4.2.9"] ||
       ![NSBundle.mainBundle.executablePath.lastPathComponent isEqual:@"FreeMusic"])return;
    const struct mach_header_64 *header=(const void *)_dyld_get_image_header(0);
    if(!header || header->magic!=MH_MAGIC_64 || header->cputype!=CPU_TYPE_ARM64 || header->filetype!=MH_EXECUTE ||
       header->ncmds>1024 || header->sizeofcmds>65536)return;
    const uint8_t uuid[]={0x21,0x2e,0x31,0x08,0x9a,0x0c,0x33,0x09,0xbe,0xdc,0x7e,0x99,0x6e,0x81,0x99,0xd1};
    const uint8_t *cursor=(const uint8_t *)(header+1),*end=cursor+header->sizeofcmds;
    BOOL sameUUID=NO,textRange=NO,dataRange=NO;
    for(uint32_t i=0;i<header->ncmds;i++){
        if((size_t)(end-cursor)<sizeof(struct load_command))return;
        const struct load_command *cmd=(const void *)cursor;
        if(cmd->cmdsize<sizeof(*cmd)||(size_t)(end-cursor)<cmd->cmdsize)return;
        if(cmd->cmd==LC_UUID && cmd->cmdsize==sizeof(struct uuid_command))
            sameUUID=!memcmp(((const struct uuid_command *)cmd)->uuid,uuid,sizeof(uuid));
        if(cmd->cmd==LC_SEGMENT_64 && cmd->cmdsize>=sizeof(struct segment_command_64)){
            const struct segment_command_64 *seg=(const void *)cmd;
            if(!strncmp(seg->segname,"__TEXT",16))textRange=seg->vmaddr==0x100000000ULL && seg->fileoff==0 && seg->vmsize>=0x4b9200;
            if(!strncmp(seg->segname,"__DATA",16))dataRange=seg->vmaddr==0x10053c000ULL && seg->vmsize>=0x5ecf0;
        }
        cursor+=cmd->cmdsize;
    }
    if(!sameUUID||!textRange||!dataRange||cursor!=end)return;
    const uint8_t *b=(const void *)header;
    if(!FMDCMatch(b+0x418888,0x50,"3b5f35f043c5a675c46c90dab574b78dd5cfc94fa5e066057c10be7a5237e449") ||
       !FMDCMatch(b+0x7d518,0x50,"c1dec576cc72e508d2d396b4c2ce646e4130fb9f9d047fc0b48eab00a074bb94") ||
       !FMDCMatch(b+0x8b580,0x28,"5981defa70556eb69abd65e1f73c53d7c0ef9e7f9449db0b822d3e530a3e6f56") ||
       !FMDCMatch(b+0x7f7ec,0x70,"b2929de462ca3f57f8288b29fab95e21f6519be802eb795f08814c0eb814fce8") ||
       !FMDCMatch(b+0x4b9134,0xac,"fee8a30e3fd95b36ab3c2dc1c8ff3a9104761cf8f91cb3714b769619eb8cdb2a") ||
       !FMDCMatch(b+0x4b25c,0x28,"be163f67161614d77119715ac5fb3d41a527a85fab2ed25d8254bcbfaabaa7ba")) return;
    FMDCMakeKeyPath=(FMDCGetKeyPath)dlsym(RTLD_DEFAULT,"swift_getKeyPath");
    if(FMDCMakeKeyPath)FMDCImage=b;
}
static NSDictionary *FMDCStamp(NSURL *file) {
    struct stat s;
    if(!file.isFileURL || lstat(file.fileSystemRepresentation,&s) || !S_ISREG(s.st_mode) || s.st_size<=0)return nil;
    return @{@"device":@(s.st_dev),@"inode":@(s.st_ino),@"bytes":@(s.st_size),
             @"seconds":@(s.st_mtimespec.tv_sec),@"nanoseconds":@(s.st_mtimespec.tv_nsec)};
}
static void FMDCFlush(void) {
    NSDictionary *batch=[FMDCChanges copy];
    FMDCChanges=NSMutableDictionary.dictionary;FMDCScheduled=NO;
    // Both slots are the native, pinned singleton initializer's own globals.
    // It is never initialized by this UI update: its normal first load already
    // resolves sidecars and publishes the original list.
    long state=__atomic_load_n((const long *)(FMDCImage+0x54e850),__ATOMIC_ACQUIRE);
    if(state!=-1)return;
    uintptr_t pointer=__atomic_load_n((const uintptr_t *)(FMDCImage+0x59ace8),__ATOMIC_ACQUIRE);
    if(!pointer)return;
    id owner=(__bridge id)(void *)pointer;
    Class expected=objc_lookUpClass("_TtC9FreeMusic12CacheManager");
    if(!expected||object_getClass(owner)!=expected)return;
    NSMutableDictionary *validated=NSMutableDictionary.dictionary;
    for(NSString *server in batch){
        NSMutableDictionary *valid=NSMutableDictionary.dictionary;
        for(NSString *identifier in batch[server]){
            NSDictionary *repair=batch[server][identifier];
            if([repair[@"stamp"] isEqual:FMDCStamp(repair[@"file"])])valid[identifier]=repair;
        }
        if(valid.count)validated[server]=valid;
    }
    if(!validated.count)return;
    void *path=FMDCMakeKeyPath(FMDCImage+0x418888,NULL);
    if(path)FMNativeDownloadCoverApply((__bridge const void *)owner,path,(__bridge const void *)validated);
}
void FMNativeDownloadCoverDisplayInstall(void) {
    static dispatch_once_t once;
    dispatch_once(&once,^{
        FMDCIdentify();if(!FMDCImage)return;
        FMDCChanges=NSMutableDictionary.dictionary;
        [NSNotificationCenter.defaultCenter addObserverForName:FMDownloadArtworkDidRecoverNotification object:nil
            queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *event){
            NSDictionary *info=event.userInfo;NSString *server=info[@"server"],*identifier=info[@"id"];
            NSURL *file=info[@"coverURL"];id previous=info[@"expectedCover"];
            if(![server isKindOfClass:NSString.class]||![identifier isKindOfClass:NSString.class]||
               ![file isKindOfClass:NSURL.class]||!file.isFileURL||
               (! [previous isKindOfClass:NSString.class] && previous!=NSNull.null))return;
            NSString *expectedFile=[NSString stringWithFormat:@"%@_%@_cover.jpg",server,identifier];
            NSFileManager *files=NSFileManager.defaultManager;
            NSURL *documents=[files URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
            NSURL *support=[files URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
            NSURL *cache=[files URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask].firstObject;
            if(!documents||!support||!cache||![file.lastPathComponent isEqual:expectedFile])return;
            NSString *first=[[documents URLByAppendingPathComponent:@"Downloads"] URLByAppendingPathComponent:expectedFile].URLByStandardizingPath.path;
            NSString *second=[[support URLByAppendingPathComponent:@"DownloadAssets"] URLByAppendingPathComponent:expectedFile].URLByStandardizingPath.path;
            NSString *legacy=[[cache URLByAppendingPathComponent:@"MusicCache"] URLByAppendingPathComponent:expectedFile].URLByStandardizingPath.path;
            if(![file.URLByStandardizingPath.path isEqual:first]&&![file.URLByStandardizingPath.path isEqual:second])return;
            NSDictionary *stamp=FMDCStamp(file);if(!stamp)return;
            NSMutableDictionary *byID=FMDCChanges[server];if(!byID)FMDCChanges[server]=byID=NSMutableDictionary.dictionary;
            // Native Track restoration also uses a ?v= revision. Varying
            // the in-memory URL invalidates the renderer's URL/track/size
            // image-cache key and its SwiftUI task identity for repaired bytes.
            NSString *revision=[NSString stringWithFormat:@"fm-%@-%@-%@-%@",stamp[@"inode"],stamp[@"bytes"],stamp[@"seconds"],stamp[@"nanoseconds"]];
            NSURLComponents *components=[NSURLComponents componentsWithURL:file resolvingAgainstBaseURL:NO];
            components.queryItems=@[[NSURLQueryItem queryItemWithName:@"v" value:revision]];
            if(!components.URL)return;
            byID[identifier]=@{@"file":file,@"stamp":stamp,@"url":components.URL.absoluteString,@"expectedCover":previous,
                               @"nativePaths":@[first,second,legacy]};
            if(!FMDCScheduled){FMDCScheduled=YES;dispatch_after(dispatch_time(DISPATCH_TIME_NOW,100*NSEC_PER_MSEC),dispatch_get_main_queue(),^{FMDCFlush();});}
        }];
    });
}
