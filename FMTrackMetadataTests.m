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
    NSString *neteaseCover=@"https://p4.music.126.net/authored%2Fcover.jpg?param=500y500&signature=A%2BB";
    FMTrackMetadataObserveResponse(@{@"code":@200,@"data":@[@{@"server":@"wy",@"id":@"71001",@"title":@"Authored W",@"cover":neteaseCover}]});
    Check([FMTrackMetadataForParameters(@{@"id":@"71001"},@"wy")[@"img"] isEqual:neteaseCover],@"native NetEase search cover and encoded query are retained for ID-only download lookup");
    NSString *modernCover=@"https://p3.music.126.net/authored-modern.jpg";
    FMTrackMetadataObserveResponse(@{@"source":@"wy",@"id":@"wy_71002",@"name":@"Authored LX",@"meta":@{@"songId":@71002,@"picUrl":@"//p3.music.126.net/authored-modern.jpg"}});
    Check([FMTrackMetadataForParameters(@{@"id":@"71002"},@"wy")[@"img"] isEqual:modernCover],@"modern LX cover resolves to HTTPS and uses the exact platform song ID");
    NSString *rawCover=@"http://p4.music.126.net:80/authored%2Fcover.jpg?param=500y500&signature=A%2BB";
    track=FMTrackMetadataForParameters(@{@"id":@"71003",@"img":@12345,@"al":@{@"picUrl":rawCover}},@"wy");
    Check([track[@"img"] isEqual:neteaseCover]&&[FMTrackMetadataForParameters(@{@"id":@"71003"},@"wy")[@"img"] isEqual:neteaseCover],@"NetEase album cover in current parameters is available to later download without another search");
    track=FMTrackMetadataForParameters(@{@"id":@"71003",@"cover":@"file:///private/local.jpg",@"img":@"https://user:password@example.invalid/image.jpg"},@"wy");
    Check([track[@"img"] isEqual:neteaseCover]&&[FMTrackMetadataForParameters(@{@"id":@"71003"},@"tx")[@"img"] length]==0,@"invalid current covers preserve the same track's artwork without crossing provider boundaries");
    track=FMTrackMetadataForParameters(@{@"id":@"71003",@"cover":modernCover},@"wy");
    Check([track[@"img"] isEqual:modernCover]&&[FMTrackMetadataForParameters(@{@"id":@"71003"},@"wy")[@"img"] isEqual:modernCover],@"explicit native cover overrides older artwork even when the parse contains no img field");
    track=FMTrackMetadataForParameters(@{@"id":@"71004",@"album":@{@"picUrl":@"http://p3.music.126.net.example.invalid/fixture.jpg"}},@"wy");
    Check([track[@"img"] isEqual:@"http://p3.music.126.net.example.invalid/fixture.jpg"],@"only the NetEase image CDN is upgraded from HTTP");
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
