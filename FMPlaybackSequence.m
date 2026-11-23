#import "FMPlaybackSequence.h"
#import "FMAdaptivePlayback.h"
#import "FMPlaybackQualityDisplay.h"
#import <CommonCrypto/CommonDigest.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <objc/runtime.h>
#import <math.h>
#import <stdio.h>
#import <string.h>

typedef void (*FMNativeReconcile)(void * __attribute__((swift_context))) __attribute__((swiftcall));
@interface FMSequenceWatch : NSObject
@property(nonatomic,weak) id owner;
@property(nonatomic,weak) AVPlayer *player;
@property(nonatomic,strong) AVPlayerItem *item;
@property(nonatomic,strong) id timer;
@property(nonatomic) BOOL requested, retired;
@property(nonatomic) NSUInteger generation;
- (void)detach;
@end
@implementation FMSequenceWatch
- (void)detach {
    self.retired=YES;
    AVPlayer *player=self.player;
    if(self.timer && player)[player removeTimeObserver:self.timer];
    self.timer=nil;
}
- (void)dealloc { [self detach]; }
@end
static NSMapTable *FMSequenceWatches,*FMSequenceGenerations,*FMSequencePendingPlayers;
static FMNativeReconcile FMSequenceReconcile;
static const uint8_t *FMSequenceBase;
static BOOL FMSequenceAllowed,FMSequenceFixture;
static NSUInteger FMSequenceSelections,FMSequenceCompensations,FMSequenceIgnored,FMSequenceExceptions;

static void FMSequenceState(void) {
    static dispatch_once_t once;
    dispatch_once(&once,^{FMSequenceWatches=NSMapTable.weakToStrongObjectsMapTable;
        FMSequenceGenerations=NSMapTable.weakToStrongObjectsMapTable;FMSequencePendingPlayers=NSMapTable.weakToWeakObjectsMapTable;});
}
static BOOL FMSequenceHash(const uint8_t *bytes,size_t length,const char *expected) {
    unsigned char digest[32];char hex[65];CC_SHA256(bytes,(CC_LONG)length,digest);
    for(NSUInteger i=0;i<32;i++)snprintf(hex+i*2,3,"%02x",digest[i]);return !strcmp(hex,expected);
}
static BOOL FMSequenceVerify(void) {
    const struct mach_header_64 *header=(const struct mach_header_64 *)_dyld_get_image_header(0);
    if(!header||header->magic!=MH_MAGIC_64||header->cputype!=CPU_TYPE_ARM64||header->filetype!=MH_EXECUTE||header->ncmds>1024||header->sizeofcmds>65536)return NO;
    const uint8_t UUID[]={0x21,0x2e,0x31,0x08,0x9a,0x0c,0x33,0x09,0xbe,0xdc,0x7e,0x99,0x6e,0x81,0x99,0xd1};
    const uint8_t *cursor=(const uint8_t *)(header+1),*end=cursor+header->sizeofcmds;
    BOOL uuid=NO,text=NO,data=NO;
    for(uint32_t i=0;i<header->ncmds;i++) {
        if((size_t)(end-cursor)<sizeof(struct load_command))return NO;
        const struct load_command *command=(const struct load_command *)cursor;
        if(command->cmdsize<sizeof(*command)||command->cmdsize>(size_t)(end-cursor))return NO;
        if(command->cmd==LC_UUID&&command->cmdsize==sizeof(struct uuid_command))uuid=!memcmp(((const struct uuid_command *)command)->uuid,UUID,16);
        if(command->cmd==LC_SEGMENT_64&&command->cmdsize>=sizeof(struct segment_command_64)) {
            const struct segment_command_64 *segment=(const struct segment_command_64 *)command;
            if(!strncmp(segment->segname,"__TEXT",16)&&segment->vmaddr==0x100000000ull&&segment->fileoff==0&&segment->filesize>=0x509f40&&(segment->initprot&5)==5)text=YES;
            if(segment->vmaddr<=0x10054d748ull&&segment->vmaddr+segment->vmsize>=0x10054d750ull&&(segment->initprot&1))data=YES;
        }
        cursor+=command->cmdsize;
    }
    if(!uuid||!text||!data)return NO;
    const uint8_t *base=(const uint8_t *)header;uint32_t word=0;memcpy(&word,base+0x4fec8,4);
    if(word!=(0x14000000u|(((0x509e40-0x4fec8)/4)&0x03ffffffu))||
        !FMSequenceHash(base+0x4fecc,0x30,"ce96b7b35fb5fb0bc32900557f1fa71c33f474d6c6cf93d50acf12333a3649ed")||
        !FMSequenceHash(base+0x509e40,0x100,"803d479955a09b2043fd698803fb832cb90a52ef108470bc9cee6bc244f12e74")||
        !FMSequenceHash(base+0x56e18,0x40,"0f194e8b2a8848a100504b54fa62d28c7a832752a5ea6e8c54ad03c0d37b3d99"))return NO;
    FMSequenceBase=base;FMSequenceReconcile=(FMNativeReconcile)(base+0x56e18);return YES;
}
void FMPlaybackSequenceInstall(void) {
    FMSequenceState();static dispatch_once_t once;dispatch_once(&once,^{FMSequenceAllowed=FMSequenceVerify();});
}
static BOOL FMSequenceCurrent(FMSequenceWatch *watch) {
    if(!NSThread.isMainThread||!FMSequenceAllowed||watch.retired||!watch.owner||!watch.player||watch.player.currentItem!=watch.item||
       [FMSequenceWatches objectForKey:watch.owner]!=watch||
       [[FMSequenceGenerations objectForKey:watch.owner] unsignedIntegerValue]!=watch.generation)return NO;
    if(FMSequenceFixture)return YES;
    Class type=NSClassFromString(@"_TtC9FreeMusic18AudioPlayerManager");
    if(!type||![watch.owner isKindOfClass:type])return NO;
    ptrdiff_t offset=0;memcpy(&offset,FMSequenceBase+0x54d748,sizeof(offset));
    size_t size=class_getInstanceSize(object_getClass(watch.owner));
    if(offset<16||(offset&7)||size<sizeof(void *)||(size_t)offset>size-sizeof(void *))return NO;
    void *nativePlayer=NULL;memcpy(&nativePlayer,(const uint8_t *)(__bridge void *)watch.owner+offset,sizeof(nativePlayer));
    return nativePlayer==(__bridge void *)watch.player;
}
static void FMSequenceTick(FMSequenceWatch *watch,double elapsed,double duration) {
    if(!FMSequenceCurrent(watch)){FMSequenceIgnored++;return;}
    if(watch.requested||!FMSequenceReconcile||watch.player.rate<=0||watch.item.status!=AVPlayerItemStatusReadyToPlay||
       !isfinite(elapsed)||!isfinite(duration)||elapsed<3||duration<=0||duration-elapsed<=0||duration-elapsed>10)return;
    // Mark first: a native reconciliation can synchronously notify UI/observers.
    watch.requested=YES;FMSequenceCompensations++;
    // This exact native method keeps the current queue's successful entries,
    // clears attempted-for UUIDs, and retries only missing preloaded players.
    // Its candidate is also the one consumed by original next/shuffle playback.
    FMSequenceReconcile((__bridge void *)watch.owner);
}
void FMPlaybackSequenceNativeSelection(id manager) {
    // Never let an Objective-C exception unwind through the small ARM bridge.
    @try {
        FMSequenceState();if(!FMSequenceAllowed||!NSThread.isMainThread||!manager)return;
        NSUInteger generation=[[FMSequenceGenerations objectForKey:manager] unsignedIntegerValue]+1;
        [FMSequenceGenerations setObject:@(generation) forKey:manager];
        FMSequenceWatch *old=[FMSequenceWatches objectForKey:manager];
        if(old.player) {
            [FMSequencePendingPlayers setObject:old.player forKey:manager];
            FMPlaybackQualityDisplayObserve(manager,old.player,nil);
        }
        [old detach];[FMSequenceWatches removeObjectForKey:manager];
        FMAdaptivePlaybackSelectionWillChange(manager);FMSequenceSelections++;
    } @catch(NSException *exception) {FMSequenceExceptions++;}
}
void FMPlaybackSequenceDidSetup(id manager,AVPlayer *player) {
    FMSequenceState();if(!FMSequenceAllowed||!NSThread.isMainThread||!manager||!player.currentItem)return;
    [FMSequencePendingPlayers removeObjectForKey:manager];
    [[FMSequenceWatches objectForKey:manager] detach];
    FMSequenceWatch *watch=[FMSequenceWatch new];watch.owner=manager;watch.player=player;watch.item=player.currentItem;
    watch.generation=[[FMSequenceGenerations objectForKey:manager] unsignedIntegerValue];
    [FMSequenceWatches setObject:watch forKey:manager];__weak FMSequenceWatch *weak=watch;
    watch.timer=[player addPeriodicTimeObserverForInterval:CMTimeMakeWithSeconds(0.5,600) queue:dispatch_get_main_queue() usingBlock:^(CMTime time){
        FMSequenceWatch *current=weak;if(!current)return;
        // A queued periodic callback may carry a pre-seek timestamp. Read the
        // player's present time instead of using the delivered old argument.
        FMSequenceTick(current,CMTimeGetSeconds(current.player.currentTime),CMTimeGetSeconds(current.item.duration));
    }];
}
BOOL FMPlaybackSequenceSuppressOldFailure(id manager,AVPlayer *player) {
    if(!FMSequenceAllowed||!NSThread.isMainThread||!manager||!player)return NO;
    return [FMSequencePendingPlayers objectForKey:manager]==player;
}
void FMPlaybackSequenceSourceTransition(void) {
    FMSequenceState();if(!NSThread.isMainThread)return;
    // Current healthy playback is preserved, while a newly selected source can
    // supply the next song after the cache module resets native preload state.
    for(FMSequenceWatch *watch in FMSequenceWatches.objectEnumerator.allObjects)watch.requested=NO;
}
NSDictionary *FMPlaybackSequenceDiagnostics(void) {
    if(!NSThread.isMainThread)return @{};FMSequenceState();
    return @{@"installed":@(FMSequenceAllowed),@"selections":@(FMSequenceSelections),@"nearEndCompensations":@(FMSequenceCompensations),
        @"ignoredStaleTicks":@(FMSequenceIgnored),@"exceptions":@(FMSequenceExceptions),@"owners":@(FMSequenceWatches.count),@"thresholdSeconds":@10};
}
#if defined(FMX_ADAPTIVE_PLAYBACK_TESTING) && FMX_ADAPTIVE_PLAYBACK_TESTING && TARGET_OS_SIMULATOR
void FMPlaybackSequenceTestConfigure(void *reconcile) {
    FMSequenceState();NSCAssert(NSThread.isMainThread,@"Fixture is main-thread only");
    for(FMSequenceWatch *watch in FMSequenceWatches.objectEnumerator.allObjects)[watch detach];
    [FMSequenceWatches removeAllObjects];[FMSequenceGenerations removeAllObjects];[FMSequencePendingPlayers removeAllObjects];
    FMSequenceFixture=YES;FMSequenceAllowed=reconcile!=NULL;FMSequenceReconcile=(FMNativeReconcile)reconcile;
}
void FMPlaybackSequenceTestTick(id manager,AVPlayer *player,double elapsed,double duration) {
    FMSequenceWatch *watch=[FMSequenceWatches objectForKey:manager];
    if(watch.player!=player){FMSequenceIgnored++;return;}
    FMSequenceTick(watch,elapsed,duration);
}
#endif
