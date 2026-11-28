#import <Foundation/Foundation.h>
#import "FMLXMCLocalStore.h"

static unsigned checks;
static void Check(BOOL ok,NSString *name){if(!ok){fprintf(stderr,"FAILED: %s\n",name.UTF8String);exit(1);}checks++;}
static NSDictionary *Cloud(NSNumber *list,NSNumber *owner,NSString *name) {return @{@"id":list,@"title":name,@"user_id":owner,@"count":@3,@"native_unknown_field":@"preserve"};}
static NSDictionary *Record(NSNumber *record,NSString *song){return @{@"record_id":record,@"id":song,@"server":@"qq",@"title":song,@"singer":@"artist",@"cover":@"",@"native_extra":@"untouched"};}
static NSDictionary *Reply(NSArray *rows){return @{@"code":@200,@"data":rows,@"original":@7};}

int main(int argc,const char *argv[]){@autoreleasepool{
    NSURL *root=[[NSURL fileURLWithPath:NSTemporaryDirectory() isDirectory:YES] URLByAppendingPathComponent:NSUUID.UUID.UUIDString isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:root withIntermediateDirectories:YES attributes:nil error:nil];
    NSDictionary *initial=@{@"schema":@1,@"nextPlaylist":@(-1000001),@"nextRecord":@(-1000000002),@"revision":@0,
        @"playlists":@[@{@"id":@(-1000000),@"title":@"Imported",@"revision":@1,
        @"tracks":@[Record(@(-1000000000),@"local1"),Record(@(-1000000001),@"local2")]}]};
    NSData *old=[NSJSONSerialization dataWithJSONObject:initial options:0 error:nil];
    NSURL *file=[root URLByAppendingPathComponent:@"playlists.json"];
    [old writeToURL:file atomically:YES];
    FMLXMCLocalStore *store=[[FMLXMCLocalStore alloc] initWithDirectory:root];
    NSArray *cloud=@[Cloud(@17,@7,@"Cloud One"),Cloud(@18,@7,@"Cloud Two")];
    NSDictionary *response=Reply(cloud);
    [store mergePlaylistList:response];
    NSArray *lists=store.editorPlaylists;
    Check(lists.count==3&&[lists[2][@"title"] isEqual:@"Imported"],@"existing 4.2.9 imports and cloud lists available");
    NSString *cloudKey=lists[0][@"key"],*other=lists[1][@"key"],*local=lists[2][@"key"];
    NSError *err=nil;
    Check([store saveEditorListOrder:@[local,other,cloudKey] error:&err],@"cross-cloud/local playlist reorder");
    NSDictionary *arranged=[store mergePlaylistList:response];
    Check([arranged[@"data"][0][@"id"] isEqual:@(-1000000)]&&[arranged[@"data"][2][@"id"] isEqual:@17]&&
        [arranged[@"original"] isEqual:@7]&&[arranged[@"data"][2][@"native_unknown_field"] isEqual:@"preserve"],@"original native list response projects order and preserves extras");
    Check(![store saveEditorListOrder:@[cloudKey,local] error:&err],@"stale list inventory does not overwrite");
    Check([store renameEditorPlaylist:cloudKey title:@"Cloud local alias" error:&err]&&[store renameEditorPlaylist:local title:@"New import name" error:&err],@"cloud local alias and local playlist rename");
    Check(![store renameEditorPlaylist:local title:@"  " error:&err],@"blank rename rejected");
    Check([store.nativePlaylists.firstObject[@"title"] isEqual:@"New import name"]&&[[[store mergePlaylistList:response][@"data"] lastObject][@"title"] isEqual:@"Cloud local alias"],@"both original and import entry names reflect changes");
    NSArray *localRows=[store editorTracks:local];NSArray *localKeys=[localRows valueForKey:@"key"];
    Check([store saveEditorTracks:@[localKeys[1],localKeys[0]] replacing:localKeys playlist:local error:&err],@"imported playlist track order saved");
    Check(![store saveEditorTracks:@[] replacing:localKeys playlist:local error:&err],@"stale detail edit rejected");
    Check([store saveEditorTracks:@[localKeys[1]] replacing:@[localKeys[1],localKeys[0]] playlist:local error:&err],@"remove single imported membership");
    NSDictionary *tracksReply=[store responseForAction:@"playlist_get_tracks" parameters:@{@"playlist_id":@"-1000000"} importRequest:nil];
    Check([tracksReply[@"data"] count]==1&&[tracksReply[@"data"][0][@"id"] isEqual:@"local2"],@"local native playback sees edited records");
    NSArray *songs=@[Record(@51,@"one"),Record(@52,@"two"),Record(@53,@"three")];NSDictionary *data=Reply(songs);
    [store mergeTracks:data playlistID:@"17"];
    NSArray *trackKeys=[[store editorTracks:cloudKey] valueForKey:@"key"];
    Check(trackKeys.count==3,@"cloud detail identified");
    Check([store saveEditorTracks:@[trackKeys[2],trackKeys[0]] replacing:trackKeys playlist:cloudKey error:&err],@"cloud reorder and membership removal saved locally");
    NSDictionary *edited=[store mergeTracks:data playlistID:@"17"];
    Check([edited[@"data"] count]==2&&[edited[@"data"][0][@"record_id"] isEqual:@53]&&[edited[@"data"][1][@"record_id"] isEqual:@51]&&
        [edited[@"data"][0][@"native_extra"] isEqual:@"untouched"]&&[edited[@"original"] isEqual:@7],@"native tracks preserve file IDs metadata and ordered members");
    Check([[[[store mergePlaylistList:response][@"data"] lastObject] objectForKey:@"count"] isEqual:@2],@"edited list counts match actual tracks");
    [store mergeTracks:Reply(@[Record(@59,@"new"),songs[0],songs[1],songs[2]]) playlistID:@"17"];
    Check([[[store editorTracks:cloudKey] lastObject][@"title"] isEqual:@"new"],@"new cloud songs appended and edits preserved");
    FMLXMCLocalStore *reload=[[FMLXMCLocalStore alloc] initWithDirectory:root];[reload mergePlaylistList:response];[reload mergeTracks:data playlistID:@"17"];
    Check([reload.editorPlaylists.firstObject[@"key"] isEqual:local]&&[reload.editorPlaylists.lastObject[@"title"] isEqual:@"Cloud local alias"]&&
        [[reload editorTracks:cloudKey] count]==2&&[[reload editorTracks:local] count]==1,@"all four edit types survive restart");
    [reload mergePlaylistList:nil];
    Check([reload saveEditorListOrder:@[local] error:&err],@"offline library still editable");
    [reload mergePlaylistList:response];
    Check([[reload.editorPlaylists valueForKey:@"key"] isEqual:@[local,other,cloudKey]],@"temporarily absent cloud lists retain their order");
    NSDictionary *foreign=[reload mergePlaylistList:Reply(@[Cloud(@17,@8,@"Second account")])];
    Check(![foreign[@"data"][0][@"title"] isEqual:@"Cloud local alias"]&&![reload editorTracks:cloudKey],@"another account cannot see former cloud edits");
    NSDictionary *otherResponse=[reload mergeTracks:data playlistID:@"17"];
    Check([otherResponse[@"data"] count]==3,@"another account retains all songs");
    [reload mergePlaylistList:response];
    NSDictionary *ambiguous=Reply(@[songs[0],songs[0]]);
    Check([[reload mergeTracks:ambiguous playlistID:@"17"] isEqual:ambiguous]&&![reload editorTracks:cloudKey],@"ambiguous records rendered without destructive editing");
    [NSFileManager.defaultManager removeItemAtURL:root error:nil];
    if(argc>1){NSData *report=[NSJSONSerialization dataWithJSONObject:@{@"passed":@YES,@"assertion_count":@(checks),@"original_app_used":@NO} options:0 error:nil];Check([report writeToFile:@(argv[1]) atomically:YES],@"write results");}
    printf("PASS playlist editor (%u checks)\n",checks);
}return 0;}
