#import <Foundation/Foundation.h>
#import "FMSettingsMigration.h"

static NSUInteger failures;static NSMutableArray *rows;
static void Check(BOOL value,NSString *name){[rows addObject:@{@"name":name,@"passed":@(value)}];if(!value)failures++;printf("%s %s\n",value?"PASS":"FAIL",name.UTF8String);}
@interface FMFaultDefaults : NSUserDefaults
@property(nonatomic,copy) NSString *failSetKey,*failRemoveKey;
@property(nonatomic) NSInteger failuresLeft,syncFailures;
@property(nonatomic) NSUInteger syncCalls,failSyncAt;
@property(nonatomic) BOOL throwInstead;
@end
@implementation FMFaultDefaults
- (void)setObject:(id)value forKey:(NSString *)key {
    if([key isEqual:self.failSetKey]&&self.failuresLeft>0){self.failuresLeft--;if(self.throwInstead)@throw [NSException exceptionWithName:@"AuthoredWriteFault" reason:@"authored failure" userInfo:nil];return;}
    [super setObject:value forKey:key];
}
- (void)removeObjectForKey:(NSString *)key {
    if([key isEqual:self.failRemoveKey]&&self.failuresLeft>0){self.failuresLeft--;return;}[super removeObjectForKey:key];
}
- (BOOL)synchronize {self.syncCalls++;if(self.syncCalls==self.failSyncAt)return NO;if(self.syncFailures>0){self.syncFailures--;return NO;}return [super synchronize];}
@end
static NSDictionary *Read(NSUserDefaults *d,NSString *domain){return [d persistentDomainForName:domain]?:@{};}
static NSDictionary *Legacy(void){return @{@"FMX.aggregateSearch":@NO,@"FMX.dynamicArtwork":@NO,@"FMX.listeningInsightsEnabled":@NO,
    @"FMX.selectedSource":@"Authored-source.js",@"FMX.name.Authored-source.js":@"Authored source",
    @"FMX.singleSearchPlatform":@4,@"FMX.managesSearchPlatform":@NO,
    @"searchPlatform":@4,@"playQuality":@9,@"volume":@0.45,@"accountCookie":@"AUTHORED_PRIVATE_VALUE"};}
static NSDictionary *Journal(NSDictionary *before){
    NSArray *keys=@[@"FMX.aggregateSearch",@"FMX.dynamicArtwork",@"FMX.listeningInsightsEnabled",@"FMX.settingsAndQishuiConfigured",@"FMX.settings.schemaVersion",@"FMX.settings.preUpgradeBackup"];
    NSMutableDictionary *old=NSMutableDictionary.dictionary;NSMutableArray *missing=NSMutableArray.array;
    for(NSString *key in keys)if(before[key])old[key]=before[key];else [missing addObject:key];
    return @{@"fromVersion":@0,@"targetVersion":@1,@"before":old,@"absent":missing};
}
int main(int argc,const char *argv[]) {@autoreleasepool{
    rows=NSMutableArray.array;NSString *domain=[@"org.codex.fmx.settings." stringByAppendingString:NSUUID.UUID.UUIDString];
    FMFaultDefaults *d=[[FMFaultDefaults alloc] initWithSuiteName:domain];NSError *error=nil;
    [d removePersistentDomainForName:domain];
    Check(FMSettingsMigrate(d,domain,&error)&&!error, @"fresh_install_commits_schema_and_defaults");
    NSDictionary *fresh=Read(d,domain);
    Check([fresh[@"FMX.settings.schemaVersion"] isEqual:@(FMSettingsCurrentSchema())]&&[fresh[@"FMX.aggregateSearch"] isEqual:@YES]&&
          [fresh[@"FMX.dynamicArtwork"] isEqual:@YES]&&[fresh[@"FMX.listeningInsightsEnabled"] isEqual:@YES]&&!fresh[@"FMX.selectedSource"]&&!fresh[@"FMX.settings.upgradeJournal"], @"fresh_defaults_do_not_invent_selected_source");

    [d setPersistentDomain:Legacy() forName:domain];error=nil;
    Check(FMSettingsMigrate(d,domain,&error)&&!error,@"legacy_preferences_migrate_without_old_one_time_flag");
    NSDictionary *upgraded=Read(d,domain);BOOL preserved=YES;
    for(NSString *key in Legacy())if(![upgraded[key] isEqual:Legacy()[key]])preserved=NO;
    Check(preserved,@"all_explicit_opt_outs_source_labels_and_native_preferences_preserved");
    NSDictionary *backup=upgraded[@"FMX.settings.preUpgradeBackup"][@"preferences"];
    Check([backup[@"FMX.selectedSource"] isEqual:@"Authored-source.js"]&&[backup[@"FMX.aggregateSearch"] isEqual:@NO]&&
          !backup[@"accountCookie"]&&!backup[@"playQuality"]&&!backup[@"volume"]&&!backup[@"searchPlatform"],@"backup_contains_extension_preferences_only_no_account_or_native_values");
    Check(FMSettingsMigrate(d,domain,&error)&&[Read(d,domain) isEqual:upgraded],@"repeated_upgrade_is_idempotent_and_does_not_refresh_defaults");
    [d setBool:YES forKey:@"FMX.aggregateSearch"];[d removeObjectForKey:@"FMX.selectedSource"];
    NSDictionary *userChanged=Read(d,domain);
    Check(FMSettingsMigrate(d,domain,&error)&&[Read(d,domain) isEqual:userChanged],@"later_user_changes_and_explicit_source_disable_survive_restart");

    NSMutableDictionary *v7=[Legacy() mutableCopy];v7[@"FMX.settingsAndQishuiConfigured"]=@YES;
    v7[@"FMX.playbackCache.taintedServers"]=@[@"qq",@"wy"];
    [d setPersistentDomain:v7 forName:domain];
    Check(FMSettingsMigrate(d,domain,&error)&&[Read(d,domain)[@"FMX.playbackCache.taintedServers"] isEqual:v7[@"FMX.playbackCache.taintedServers"]]&&
          [Read(d,domain)[@"FMX.aggregateSearch"] isEqual:@NO],@"v7_upgrade_preserves_cache_isolation_and_existing_opt_out");

    for(NSString *badKey in @[@"FMX.aggregateSearch",@"FMX.settings.schemaVersion",@"FMX.selectedSource"]){
        NSMutableDictionary *bad=[Legacy() mutableCopy];bad[badKey]=[badKey isEqual:@"FMX.selectedSource"]?@"../escape.js":@"invalid";
        [d setPersistentDomain:bad forName:domain];error=nil;
        Check(!FMSettingsMigrate(d,domain,&error)&&error&&[Read(d,domain) isEqual:bad],[NSString stringWithFormat:@"malformed_%@_is_reported_without_reset",badKey]);
    }
    NSMutableDictionary *future=[Legacy() mutableCopy];future[@"FMX.settings.schemaVersion"]=@99;future[@"FMX.settings.upgradeJournal"]=Journal(@{});
    [d setPersistentDomain:future forName:domain];error=nil;
    Check(!FMSettingsMigrate(d,domain,&error)&&error.code==4&&[Read(d,domain) isEqual:future],@"future_schema_is_never_downgraded_even_with_a_pending_journal");

    NSMutableDictionary *pending=[Legacy() mutableCopy];pending[@"FMX.settings.upgradeJournal"]=Journal(Legacy());
    pending[@"FMX.aggregateSearch"]=@YES;pending[@"FMX.dynamicArtwork"]=@YES;pending[@"FMX.settings.schemaVersion"]=@1;
    [d setPersistentDomain:pending forName:domain];error=nil;
    Check(FMSettingsMigrate(d,domain,&error)&&!error&&[Read(d,domain)[@"FMX.aggregateSearch"] isEqual:@NO]&&[Read(d,domain)[@"FMX.dynamicArtwork"] isEqual:@NO]&&
          [Read(d,domain)[@"FMX.settings.preUpgradeBackup"][@"preferences"][@"FMX.selectedSource"] isEqual:@"Authored-source.js"]&&!Read(d,domain)[@"FMX.settings.upgradeJournal"],@"interrupted_schema_write_recovers_original_choices_then_replays_upgrade");

    NSMutableDictionary *unsafe=[Legacy() mutableCopy];NSMutableDictionary *unsafeJournal=[Journal(Legacy()) mutableCopy];
    NSMutableDictionary *unsafeBefore=[unsafeJournal[@"before"] mutableCopy];unsafeBefore[@"accountCookie"]=@"attempted overwrite";unsafeJournal[@"before"]=unsafeBefore;unsafe[@"FMX.settings.upgradeJournal"]=unsafeJournal;
    [d setPersistentDomain:unsafe forName:domain];error=nil;
    Check(!FMSettingsMigrate(d,domain,&error)&&error.code==5&&[Read(d,domain) isEqual:unsafe],@"journal_cannot_claim_unrelated_account_keys");

    for(NSString *faultKey in @[@"FMX.settings.preUpgradeBackup",@"FMX.settings.schemaVersion"]){
        [d setPersistentDomain:Legacy() forName:domain];d.failSetKey=faultKey;d.failuresLeft=1;error=nil;
        Check(!FMSettingsMigrate(d,domain,&error)&&error&&[Read(d,domain) isEqual:Legacy()],[NSString stringWithFormat:@"failed_write_%@_rolls_back_exact_values",faultKey]);
        d.failSetKey=nil;
        Check(FMSettingsMigrate(d,domain,&error)&&[Read(d,domain)[@"FMX.aggregateSearch"] isEqual:@NO],[NSString stringWithFormat:@"retry_after_%@_succeeds_without_reset",faultKey]);
    }
    [d setPersistentDomain:Legacy() forName:domain];d.failSetKey=@"FMX.settings.preUpgradeBackup";d.failuresLeft=1;d.throwInstead=YES;error=nil;
    Check(!FMSettingsMigrate(d,domain,&error)&&error&&[Read(d,domain) isEqual:Legacy()],@"setter_exception_restores_original_settings");d.failSetKey=nil;d.throwInstead=NO;
    [d setPersistentDomain:Legacy() forName:domain];d.failRemoveKey=@"FMX.settings.upgradeJournal";d.failuresLeft=1;error=nil;
    Check(!FMSettingsMigrate(d,domain,&error)&&error&&[Read(d,domain) isEqual:Legacy()],@"failed_journal_cleanup_restores_settings_before_returning_failure");d.failRemoveKey=nil;
    [d setPersistentDomain:Legacy() forName:domain];d.syncFailures=1;error=nil;
    Check(!FMSettingsMigrate(d,domain,&error)&&error&&!Read(d,domain)[@"FMX.settings.schemaVersion"]&&[Read(d,domain)[@"FMX.selectedSource"] isEqual:@"Authored-source.js"],@"journal_persistence_failure_never_bumps_version_or_changes_source");
    Check(FMSettingsMigrate(d,domain,&error)&&[Read(d,domain)[@"FMX.aggregateSearch"] isEqual:@NO],@"restart_after_journal_persistence_failure_recovers");

    for(NSNumber *stage in @[@2,@3,@4]){
        [d setPersistentDomain:Legacy() forName:domain];d.syncCalls=0;d.failSyncAt=stage.unsignedIntegerValue;error=nil;
        Check(!FMSettingsMigrate(d,domain,&error)&&error&&[Read(d,domain) isEqual:Legacy()],
              [NSString stringWithFormat:@"sync_stage_%@_failure_restores_exact_previous_preferences",stage]);
        d.failSyncAt=0;
        Check(FMSettingsMigrate(d,domain,&error)&&!error&&[Read(d,domain)[@"FMX.aggregateSearch"] isEqual:@NO],
              [NSString stringWithFormat:@"sync_stage_%@_failure_can_retry_without_reset",stage]);
    }

    NSUserDefaults *reopened=[[NSUserDefaults alloc] initWithSuiteName:domain];
    Check([Read(reopened,domain)[@"FMX.selectedSource"] isEqual:@"Authored-source.js"]&&[Read(reopened,domain)[@"FMX.aggregateSearch"] isEqual:@NO]&&[Read(reopened,domain)[@"FMX.settings.schemaVersion"] isEqual:@1],@"new_defaults_instance_reads_durable_source_and_preferences");
    NSDictionary *report=@{@"passed":@(failures==0),@"failures":@(failures),@"cases":rows,@"evidence":@{@"real_defaults_suite":@YES,@"external_network_used":@NO,@"original_app_runtime_verified":@NO,@"injected_write_failures":@YES}};
    if(argc>1)[[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:nil] writeToFile:[NSString stringWithUTF8String:argv[1]] atomically:YES];
    [d removePersistentDomainForName:domain];[d synchronize];printf("%s settings migration (%lu checks)\n",failures?"FAILED":"DONE",(unsigned long)rows.count);return failures?1:0;
}}
