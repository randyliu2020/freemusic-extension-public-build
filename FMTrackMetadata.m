#import "FMTrackMetadata.h"
#import <math.h>

static NSMutableDictionary<NSString *,NSDictionary *> *FMTracks;
static NSMutableArray<NSString *> *FMTrackOrder;
static NSObject *FMTrackLock;
static void FMTrackInit(void) { static dispatch_once_t once; dispatch_once(&once,^{FMTracks=NSMutableDictionary.dictionary;FMTrackOrder=NSMutableArray.array;FMTrackLock=NSObject.new;}); }
static NSString *FMText(id value,NSUInteger maximum) {
    if([value isKindOfClass:NSNumber.class])value=[value stringValue];
    return [value isKindOfClass:NSString.class] && [value length]<=maximum ? value : nil;
}
static NSString *FMFirst(NSArray *containers,NSArray<NSString *> *keys,NSUInteger maximum) {
    for(id container in containers)if([container isKindOfClass:NSDictionary.class])for(NSString *key in keys){NSString *value=FMText(container[key],maximum);if(value.length)return value;}
    return nil;
}
static NSString *FMPlatform(id value) {
    NSString *source=[FMText(value,16) lowercaseString];
    if([source isEqual:@"qq"])return @"tx";
    return [@[@"wy",@"tx",@"kg",@"kw",@"mg"] containsObject:source]?source:nil;
}
static NSDictionary *FMQualityItem(id raw,NSString *type) {
    if(![raw isKindOfClass:NSDictionary.class]||!type||![@[@"128k",@"192k",@"320k",@"flac",@"flac24bit"] containsObject:type])return nil;
    NSMutableDictionary *item=[@{@"type":type} mutableCopy];
    for(NSString *key in @[@"hash",@"size",@"ext",@"bitrate",@"fileSize"]){
        id value=raw[key];
        if([value isKindOfClass:NSNumber.class]){
            if([value doubleValue]>=0&&isfinite([value doubleValue]))item[key]=value;
        } else {NSString *text=FMText(value,128);if(text.length)item[key]=text;}
    }
    return item;
}
static NSDictionary *FMNormalize(NSDictionary *track,NSString *source,NSString *identifier) {
    NSDictionary *meta=[track[@"meta"] isKindOfClass:NSDictionary.class]?track[@"meta"]:@{};
    NSArray *containers=@[track,meta];
    NSMutableDictionary *result=[@{@"source":source,@"songmid":identifier,@"id":identifier,@"name":@"",@"singer":@"",@"albumName":@"",@"albumId":@"",@"img":@"",@"interval":@"",@"typeUrl":@{},@"types":@[],@"_types":@{}} mutableCopy];
    NSDictionary *fields=@{@"name":@[@"title",@"name"],@"singer":@[@"singer",@"artist"],@"albumName":@[@"albumName",@"album_name",@"album"],@"albumId":@[@"albumId",@"album_id"],@"albumMid":@[@"albumMid",@"album_mid"],@"strMediaMid":@[@"strMediaMid",@"media_mid"],@"songId":@[@"songId"],@"img":@[@"img",@"picUrl",@"pic",@"cover"],@"interval":@[@"interval"]};
    for(NSString *key in fields){NSString *value=FMFirst(containers,fields[key],[key isEqual:@"img"]?4096:1024);if(value.length)result[key]=value;}
    if(![result[@"interval"] length]){id duration=track[@"duration"]?:meta[@"duration"];if([duration isKindOfClass:NSNumber.class]){double seconds=[duration doubleValue];if(isfinite(seconds)&&seconds>=0&&seconds<=604800){NSUInteger total=(NSUInteger)seconds;result[@"interval"]=[NSString stringWithFormat:@"%02lu:%02lu",(unsigned long)(total/60),(unsigned long)(total%60)];}}}
    if([source isEqual:@"tx"]){NSString *songID=FMFirst(@[meta],@[@"id"],128);if(songID.length)result[@"songId"]=songID;}
    if([source isEqual:@"kg"])result[@"hash"]=FMFirst(containers,@[@"hash"],128)?:identifier;
    NSMutableDictionary *qualityMap=NSMutableDictionary.dictionary;
    for(NSDictionary *container in containers){
        for(NSString *mapKey in @[@"_types",@"_qualitys"]){id map=container[mapKey];if(![map isKindOfClass:NSDictionary.class]||[map count]>16)continue;
            for(NSString *key in map){if(![key isKindOfClass:NSString.class])continue;NSDictionary *item=FMQualityItem(map[key],key);if(item)qualityMap[key]=item;}}
        for(NSString *arrayKey in @[@"types",@"qualitys"]){id items=container[arrayKey];if(![items isKindOfClass:NSArray.class]||[items count]>16)continue;
            for(id item in items){if(![item isKindOfClass:NSDictionary.class])continue;NSString *type=FMText(item[@"type"],32);NSDictionary *safe=FMQualityItem(item,type);if(safe)qualityMap[type]=safe;}}
    }
    NSMutableArray *types=NSMutableArray.array;for(NSString *key in @[@"128k",@"192k",@"320k",@"flac",@"flac24bit"])if(qualityMap[key])[types addObject:qualityMap[key]];
    result[@"types"]=types;result[@"_types"]=qualityMap;
    return [result copy];
}
static NSString *FMIdentifier(NSDictionary *track,NSDictionary *meta,NSString *source) {
    // Modern LX's meta.songId is the platform identifier; QQ's flat songId is
    // instead the numeric song ID and must not replace songmid/native id.
    if([source isEqual:@"tx"])
        return FMFirst(@[meta],@[@"songId",@"songmid"],256)?:FMFirst(@[track],@[@"songmid",@"id"],256);
    if([source isEqual:@"kg"])
        return FMFirst(@[meta],@[@"hash"],256)?:FMFirst(@[track],@[@"hash",@"id",@"songmid"],256);
    return FMFirst(@[meta],@[@"songId",@"songmid",@"id"],256)?:FMFirst(@[track],@[@"songmid",@"id",@"songId"],256);
}
static NSDictionary *FMMergeObserved(NSDictionary *previous,NSDictionary *observed) {
    if(!previous)return observed;
    NSMutableDictionary *merged=[previous mutableCopy];
    for(NSString *field in observed){
        id value=observed[field];
        // Native import/search envelopes contain only a subset of LX metadata.
        // Their empty normalization defaults must not erase the accepted file's
        // album/media IDs or per-quality hashes for this exact platform+ID.
        if([value isKindOfClass:NSString.class] && [value length])merged[field]=value;
        else if([field isEqual:@"types"] && [value count]){
            merged[@"types"]=value;merged[@"_types"]=observed[@"_types"];
        }
    }
    return [merged copy];
}
static void FMObserve(id node,NSUInteger depth,NSUInteger *budget) {
    if(!*budget||depth>6)return;--*budget;
    if([node isKindOfClass:NSArray.class]){for(id child in node){if(!*budget)break;FMObserve(child,depth+1,budget);}return;}
    if(![node isKindOfClass:NSDictionary.class])return;
    NSString *source=FMPlatform(node[@"server"]?:node[@"source"]);
    NSDictionary *meta=[node[@"meta"] isKindOfClass:NSDictionary.class]?node[@"meta"]:@{};
    NSString *identifier=FMIdentifier(node,meta,source);
    if([source isEqual:@"kg"])identifier=identifier.uppercaseString;
    NSString *name=FMFirst(@[node],@[@"title",@"name"],1024);
    if(source.length&&identifier.length&&name.length){
        NSString *key=[NSString stringWithFormat:@"%@:%@",source,identifier];NSDictionary *safe=FMNormalize(node,source,identifier);
        @synchronized(FMTrackLock){FMTracks[key]=FMMergeObserved(FMTracks[key],safe);[FMTrackOrder removeObject:key];[FMTrackOrder addObject:key];while(FMTrackOrder.count>512){[FMTracks removeObjectForKey:FMTrackOrder.firstObject];[FMTrackOrder removeObjectAtIndex:0];}}
    }
    for(NSString *key in @[@"data",@"list",@"tracks",@"songs",@"playlists",@"items",@"musicInfo"]){id child=node[key];if(child)FMObserve(child,depth+1,budget);}
}
void FMTrackMetadataObserveResponse(id response){FMTrackInit();NSUInteger budget=4096;FMObserve(response,0,&budget);}
NSDictionary *FMTrackMetadataForParameters(NSDictionary *parameters,NSString *source) {
    FMTrackInit();NSString *platform=FMPlatform(source);NSString *identifier=FMText(parameters[@"id"],256)?:@"";
    if([platform isEqual:@"kg"])identifier=identifier.uppercaseString;
    if(!platform||!identifier.length)return @{};
    NSString *key=[NSString stringWithFormat:@"%@:%@",platform,identifier];NSDictionary *cached;
    @synchronized(FMTrackLock){cached=FMTracks[key];}
    NSMutableDictionary *merged=[cached mutableCopy]?:NSMutableDictionary.dictionary;
    // Only documented track fields are merged; src_cookie/src_api/auth never cross the bridge.
    for(NSString *field in @[@"title",@"name",@"singer",@"artist",@"albumName",@"albumId",@"albumMid",@"strMediaMid",@"songId",@"img",@"interval"]){NSString *value=FMText(parameters[field],[field isEqual:@"img"]?4096:1024);if(value.length)merged[field]=value;}
    NSString *currentSinger=FMFirst(@[parameters],@[@"singer",@"artist"],1024);
    if(currentSinger.length)merged[@"singer"]=currentSinger;
    return FMNormalize(merged,platform,identifier);
}
void FMTrackMetadataReset(void){FMTrackInit();@synchronized(FMTrackLock){[FMTracks removeAllObjects];[FMTrackOrder removeAllObjects];}}
