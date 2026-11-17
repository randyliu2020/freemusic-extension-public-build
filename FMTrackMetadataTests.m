#import <Foundation/Foundation.h>
#import "FMTrackMetadata.h"
#import <math.h>
static void Check(BOOL value,NSString *name){if(!value){fprintf(stderr,"FAIL %s\n",name.UTF8String);exit(1);}printf("PASS %s\n",name.UTF8String);}
int main(void){@autoreleasepool{
    FMTrackMetadataReset();
    FMTrackMetadataObserveResponse(@{@"code":@200,@"data":@[@{@"server":@"qq",@"id":@"mid-1",@"title":@"Authored song",@"singer":@"Author",@"album":@"Album",@"duration":@125,@"albumMid":@"album-mid",@"strMediaMid":@"media-mid",@"types":@[@{@"type":@"flac",@"size":@"12MB",@"ext":@"flac",@"cookie":@"never"}],@"src_cookie":@"private",@"src_api":@"private-url"}]});
    NSDictionary *track=FMTrackMetadataForParameters(@{@"id":@"mid-1",@"title":@"Updated",@"src_cookie":@"must-not-pass"},@"tx");
    Check([track[@"name"] isEqual:@"Updated"]&&[track[@"singer"] isEqual:@"Author"]&&[track[@"albumName"] isEqual:@"Album"],@"native metadata is enriched and explicit current title wins");
    Check([track[@"albumMid"] isEqual:@"album-mid"]&&[track[@"strMediaMid"] isEqual:@"media-mid"]&&[track[@"interval"] isEqual:@"02:05"],@"QQ media fields and duration are retained");
    Check([track[@"_types"] count]==1&&[track[@"_types"][@"flac"][@"ext"] isEqual:@"flac"],@"only observed quality metadata is provided");
    track=FMTrackMetadataForParameters(@{@"id":@"mid-1",@"artist":@"Current Artist"},@"tx");
    Check([track[@"singer"] isEqual:@"Current Artist"],@"explicit current artist alias overrides the cached singer");
    track=FMTrackMetadataForParameters(@{@"id":@"mid-1",@"singer":@"Current Singer",@"artist":@"Other Artist"},@"tx");
    Check([track[@"singer"] isEqual:@"Current Singer"],@"explicit canonical singer wins when both artist aliases are present");
    NSString *encoded=[[NSString alloc]initWithData:[NSJSONSerialization dataWithJSONObject:track options:0 error:nil] encoding:NSUTF8StringEncoding];
    Check(![encoded containsString:@"private"]&&![encoded containsString:@"cookie"]&&![encoded containsString:@"must-not-pass"],@"credentials are excluded recursively");
    NSDictionary *other=FMTrackMetadataForParameters(@{@"id":@"mid-1"},@"wy");
    Check([other[@"name"] isEqual:@""]&&[other[@"types"] count]==0,@"platform namespaces never share metadata or invent qualities");
    FMTrackMetadataObserveResponse(@{@"source":@"tx",@"id":@"tx_opaque",@"name":@"LX song",@"singer":@"LX singer",@"meta":@{@"songId":@"real-mid",@"id":@123,@"albumId":@456,@"albumMid":@"another-album",@"strMediaMid":@"another-media",@"_qualitys":@{@"320k":@{@"size":@12345,@"ext":@"mp3"}}}});
    track=FMTrackMetadataForParameters(@{@"id":@"real-mid"},@"qq");
    Check([track[@"songId"] isEqual:@"123"]&&[track[@"songmid"] isEqual:@"real-mid"]&&[track[@"albumId"] isEqual:@"456"],@"LX numeric QQ songId remains distinct from songmid");
    FMTrackMetadataObserveResponse(@{@"server":@"qq",@"id":@"real-mid",@"title":@"Native title",@"singer":@"Native singer",@"album":@"Native album"});
    track=FMTrackMetadataForParameters(@{@"id":@"real-mid"},@"qq");
    Check([track[@"name"] isEqual:@"Native title"]&&[track[@"songId"] isEqual:@"123"]&&[track[@"strMediaMid"] isEqual:@"another-media"]&&[track[@"_types"][@"320k"][@"size"] isEqual:@12345],@"later sparse native response preserves the exact track's richer LX metadata");
    FMTrackMetadataObserveResponse(@{@"source":@"tx",@"songmid":@"old-mid",@"songId":@987,@"name":@"Old LX",@"albumMid":@"old-album"});
    track=FMTrackMetadataForParameters(@{@"id":@"old-mid"},@"tx");
    Check([track[@"albumMid"] isEqual:@"old-album"]&&[track[@"songId"] isEqual:@"987"]&&[track[@"songmid"] isEqual:@"old-mid"],@"legacy flat QQ songmid is the cache key while numeric songId stays metadata");
    Check([FMTrackMetadataForParameters(@{@"id":@"987"},@"tx")[@"name"] length]==0,@"numeric QQ songId does not create a conflicting cache alias");
    FMTrackMetadataObserveResponse(@{@"server":@"qq",@"id":@"native-mid",@"songId":@654,@"title":@"Native enriched",@"strMediaMid":@"native-media"});
    track=FMTrackMetadataForParameters(@{@"id":@"native-mid"},@"tx");
    Check([track[@"strMediaMid"] isEqual:@"native-media"]&&[track[@"songId"] isEqual:@"654"],@"native QQ id is not displaced by an additional numeric songId");
    FMTrackMetadataObserveResponse(@{@"server":@"kg",@"id":@"abcdef",@"title":@"K song",@"_types":@{@"flac":@{@"hash":@"quality-hash"}}});
    track=FMTrackMetadataForParameters(@{@"id":@"ABCDEF"},@"kg");
    Check([track[@"name"] isEqual:@"K song"]&&[track[@"hash"] isEqual:@"ABCDEF"]&&[track[@"_types"][@"flac"][@"hash"] isEqual:@"quality-hash"],@"Kugou identity casing and per-quality hash are preserved");
    FMTrackMetadataObserveResponse(@{@"data":@[@{@"server":@"qq",@"id":@"bad",@"title":NSNull.null,@"cookie":@"bad"},@{@"server":@"qq",@"id":@"valid",@"title":@"Valid",@"types":@[@{@"type":@"unknown",@"hash":@"bad"},@"invalid"]}]});
    track=FMTrackMetadataForParameters(@{@"id":@"valid"},@"tx");
    Check([track[@"types"] count]==0,@"malformed and unsupported quality items are rejected");
    FMTrackMetadataObserveResponse(@{@"server":@"qq",@"id":@"numeric-quality",@"title":@"Quality validation",@"_types":@{@"flac":@{@"size":@(INFINITY),@"fileSize":@(NAN),@"bitrate":@(-1),@"hash":@(-3),@"ext":@"flac"}}});
    track=FMTrackMetadataForParameters(@{@"id":@"numeric-quality"},@"tx");
    NSDictionary *quality=track[@"_types"][@"flac"];
    Check(quality.count==2&&[quality[@"ext"] isEqual:@"flac"]&&[NSJSONSerialization isValidJSONObject:track],@"negative and nonfinite quality numbers are dropped instead of stringified");
    for(NSUInteger i=0;i<520;i++)FMTrackMetadataObserveResponse(@{@"server":@"wy",@"id":[NSString stringWithFormat:@"%lu",(unsigned long)i],@"title":@"Bounded"});
    Check([FMTrackMetadataForParameters(@{@"id":@"mid-1"},@"tx")[@"name"] length]==0,@"metadata memory cache is bounded");
    FMTrackMetadataReset();Check([FMTrackMetadataForParameters(@{@"id":@"519"},@"wy")[@"name"] length]==0,@"reset retires cached metadata");
    return 0;
}}
