#import "FMSettingsMigration.h"
#import <CoreFoundation/CoreFoundation.h>
#import <math.h>

static NSString *const FMSchema=@"FMX.settings.schemaVersion";
static NSString *const FMJournal=@"FMX.settings.upgradeJournal";
static NSString *const FMBackup=@"FMX.settings.preUpgradeBackup";
static NSString *const FMConfigured=@"FMX.settingsAndQishuiConfigured";
static NSInteger const FMVersion=1;

NSInteger FMSettingsCurrentSchema(void){return FMVersion;}
static NSError *FMError(NSInteger code,NSString *message){return [NSError errorWithDomain:@"FMX.SettingsMigration" code:code userInfo:@{NSLocalizedDescriptionKey:message}];}
static BOOL FMFail(NSError **error,NSInteger code,NSString *message){if(error)*error=FMError(code,message);return NO;}
static NSDictionary *FMDefaults(void){return @{@"FMX.aggregateSearch":@YES,@"FMX.dynamicArtwork":@YES,@"FMX.listeningInsightsEnabled":@YES};}
static NSSet *FMWritableKeys(void){return [NSSet setWithArray:@[@"FMX.aggregateSearch",@"FMX.dynamicArtwork",@"FMX.listeningInsightsEnabled",FMConfigured,FMSchema,FMBackup]];}
static BOOL FMInteger(id value){return [value isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)value)!=CFBooleanGetTypeID() && isfinite([value doubleValue]) && [value doubleValue]>=0 && [value doubleValue]==[value integerValue];}
static BOOL FMBool(id value){return [value isKindOfClass:NSNumber.class] && ([value isEqual:@0] || [value isEqual:@1]);}
static BOOL FMFileName(id value){return [value isKindOfClass:NSString.class] && [value length]>0 && [value length]<=255 && [[value lastPathComponent] isEqual:value] && ![value containsString:@"\\"] && ![value containsString:[NSString stringWithFormat:@"%C",(unichar)0]] && [[value pathExtension].lowercaseString isEqual:@"js"];} 
static BOOL FMValidateExisting(NSDictionary *values,NSError **error){
    for(NSString *key in FMDefaults())if(values[key]&&!FMBool(values[key]))return FMFail(error,1,@"已有扩展设置格式异常，已保留原值，未重置设置。");
    for(NSString *key in @[FMConfigured,@"FMX.sourceActivationPending"])
        if(values[key]&&!FMBool(values[key]))return FMFail(error,1,@"旧版设置标记异常，已保留原设置。");
    if(values[@"FMX.selectedSource"]&&!FMFileName(values[@"FMX.selectedSource"]))return FMFail(error,1,@"保存的音源选择格式异常，已保留原设置。");
    return YES;
}
static NSDictionary *FMSnapshot(NSDictionary *values){
    NSMutableDictionary *snapshot=NSMutableDictionary.dictionary;
    NSSet *keys=[NSSet setWithArray:@[@"FMX.aggregateSearch",@"FMX.dynamicArtwork",@"FMX.listeningInsightsEnabled",@"FMX.selectedSource",@"FMX.sourceActivationPending",FMConfigured,@"FMX.singleSearchPlatform",@"FMX.managesSearchPlatform"]];
    for(NSString *key in values)if([keys containsObject:key]||[key hasPrefix:@"FMX.name."])snapshot[key]=values[key];
    return snapshot;
}
static BOOL FMWrite(NSUserDefaults *defaults,NSString *domain,NSString *key,id value){
    if(value)[defaults setObject:value forKey:key];else [defaults removeObjectForKey:key];
    id stored=[defaults persistentDomainForName:domain][key];
    return value?[stored isEqual:value]:stored==nil;
}
static BOOL FMValidJournal(NSDictionary *journal){
    if(![journal isKindOfClass:NSDictionary.class] || ![journal[@"targetVersion"] isEqual:@(FMVersion)] ||
       !FMInteger(journal[@"fromVersion"]) || [journal[@"fromVersion"] integerValue]>=FMVersion ||
       ![journal[@"before"] isKindOfClass:NSDictionary.class] || ![journal[@"absent"] isKindOfClass:NSArray.class])return NO;
    NSSet *allowed=FMWritableKeys();NSMutableSet *seen=NSMutableSet.set;
    for(id key in journal[@"before"]){if(![key isKindOfClass:NSString.class]||![allowed containsObject:key])return NO;[seen addObject:key];}
    for(id key in journal[@"absent"]){if(![key isKindOfClass:NSString.class]||![allowed containsObject:key]||[seen containsObject:key])return NO;[seen addObject:key];}
    return [seen isEqual:allowed];
}
static BOOL FMRestore(NSUserDefaults *defaults,NSString *domain,NSDictionary *journal){
    // Keep the journal until every old value is restored and synchronized.
    @try {
        for(NSString *key in FMWritableKeys()){
            id old=journal[@"before"][key];
            if(!FMWrite(defaults,domain,key,old))return NO;
        }
        if(![defaults synchronize])return NO;
        if(!FMWrite(defaults,domain,FMJournal,nil))return NO;
        return [defaults synchronize];
    } @catch(NSException *exception){return NO;}
}

BOOL FMSettingsMigrate(NSUserDefaults *defaults,NSString *domain,NSError **error){
    if(error)*error=nil;
    if(!defaults||![domain isKindOfClass:NSString.class]||!domain.length)return FMFail(error,2,@"无法确定设置保存位置，未修改原设置。");
    @synchronized(defaults){
        NSDictionary *journal=nil;
        @try {
            NSDictionary *values=[defaults persistentDomainForName:domain]?:@{};
            id rawVersion=values[FMSchema];
            if(rawVersion&&!FMInteger(rawVersion))return FMFail(error,3,@"设置版本格式异常，未修改原设置。");
            NSInteger version=[rawVersion integerValue];
            if(version>FMVersion)return FMFail(error,4,@"设置来自更新版本，已保留原设置，请使用相应版本。");
            id pending=values[FMJournal];
            if(pending){
                if(!FMValidJournal(pending))return FMFail(error,5,@"设置恢复记录异常，未修改原设置。");
                // A surviving journal always means the transaction did not finish.
                // This includes interruption between the schema write and journal
                // deletion, and a previous rollback that stopped partway through.
                if(!FMRestore(defaults,domain,pending))return FMFail(error,7,@"设置恢复未完成，已保留恢复记录，稍后可重试。");
                values=[defaults persistentDomainForName:domain]?:@{};
                version=[values[FMSchema] integerValue];
            }
            if(!FMValidateExisting(values,error))return NO;
            if(version==FMVersion){[defaults registerDefaults:FMDefaults()];return YES;}
            NSMutableDictionary *before=NSMutableDictionary.dictionary;NSMutableArray *absent=NSMutableArray.array;
            for(NSString *key in FMWritableKeys())if(values[key])before[key]=values[key];else [absent addObject:key];
            journal=@{@"fromVersion":@(version),@"targetVersion":@(FMVersion),@"before":before,@"absent":absent};
            if(!FMWrite(defaults,domain,FMJournal,journal)||![defaults synchronize]){
                // No settings have been changed yet. Leave a written journal for
                // the next launch if its durable deletion cannot be confirmed.
                return FMFail(error,8,@"无法保存设置恢复记录，原设置未改变。");
            }
            BOOL written=YES;
            for(NSString *key in FMDefaults())if(!values[key])written=FMWrite(defaults,domain,key,FMDefaults()[key])&&written;
            // An explicit old opt-out wins even when the old one-time flag is absent.
            written=FMWrite(defaults,domain,FMConfigured,@YES)&&written;
            NSDictionary *backup=@{@"schemaVersion":@(version),@"preferences":FMSnapshot(values)};
            written=FMWrite(defaults,domain,FMBackup,backup)&&written;
            if(!written||![defaults synchronize]){
                BOOL restored=FMRestore(defaults,domain,journal);
                return FMFail(error,restored?9:10,restored?@"设置迁移未完成，原设置已恢复。":@"设置迁移未完成，已保留恢复记录。");
            }
            // Commit last, after all projections are durable. No schema bump on a
            // partial write; startup can roll back the exact extension keys only.
            if(!FMWrite(defaults,domain,FMSchema,@(FMVersion))||![defaults synchronize]){
                BOOL restored=FMRestore(defaults,domain,journal);
                return FMFail(error,restored?9:10,restored?@"设置版本未保存，原设置已恢复。":@"设置版本未保存，已保留恢复记录。");
            }
            if(!FMWrite(defaults,domain,FMJournal,nil)||![defaults synchronize]){
                // Restore now rather than returning with a pending undo record
                // that could later overwrite new user changes.
                FMWrite(defaults,domain,FMJournal,journal);
                BOOL restored=FMRestore(defaults,domain,journal);
                return FMFail(error,restored?9:10,restored?@"设置迁移未完成，原设置已恢复。":@"设置迁移未完成，已保留恢复记录。");
            }
            journal=nil;
            [defaults registerDefaults:FMDefaults()];return YES;
        } @catch(NSException *exception){
            if(journal)FMRestore(defaults,domain,journal);
            return FMFail(error,11,@"设置迁移遇到错误，未重置原有设置。");
        }
    }
}
BOOL FMSettingsPrepareStandard(NSError **error){
    NSString *domain=NSBundle.mainBundle.bundleIdentifier?:NSProcessInfo.processInfo.processName;
    return FMSettingsMigrate(NSUserDefaults.standardUserDefaults,domain,error);
}
