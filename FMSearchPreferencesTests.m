#import <Foundation/Foundation.h>
#import "FMSearchPreferences.h"

static void Check(BOOL ok, NSString *message) {
    if (!ok) { fprintf(stderr, "FAILED: %s\n", message.UTF8String); exit(1); }
}

int main(void) {
    @autoreleasepool {
        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        NSString *domain = NSBundle.mainBundle.bundleIdentifier ?: NSProcessInfo.processInfo.processName;
        [defaults removePersistentDomainForName:domain];
        for (NSString *key in @[@"FMX.aggregateSearch", @"FMX.singleSearchPlatform", @"FMX.managesSearchPlatform", @"FMX.settingsAndQishuiConfigured", @"searchPlatform"])
            [defaults removeObjectForKey:key];
        [defaults setInteger:4 forKey:@"searchPlatform"];
        [defaults setObject:@"ExistingSource.js" forKey:@"FMX.selectedSource"];
        FMSearchPreferencesInstall();
        Check([defaults boolForKey:@"FMX.aggregateSearch"], @"First v2 launch enables requested aggregate mode");
        Check([defaults integerForKey:@"searchPlatform"] == 3, @"Home uses unified search decoder");
        Check([defaults integerForKey:@"FMX.singleSearchPlatform"] == 4, @"Original source selection retained");
        Check([[defaults stringForKey:@"FMX.selectedSource"] isEqual:@"ExistingSource.js"], @"Imported-source selection preserved");
        [defaults setInteger:4 forKey:@"searchPlatform"];
        Check([defaults integerForKey:@"searchPlatform"] == 3, @"Integer setter cannot briefly launch Qishui-only decoder in aggregate mode");
        [defaults setObject:@4 forKey:@"searchPlatform"];
        Check([defaults integerForKey:@"searchPlatform"] == 3, @"Object setter uses same source-selection contract");
        [defaults setInteger:4 forKey:@"unrelatedPreference"];
        Check([defaults integerForKey:@"unrelatedPreference"] == 4, @"Other keys preserved");
        NSUserDefaults *suite = [[NSUserDefaults alloc] initWithSuiteName:@"org.codex.fmx.preferences.fixture"];
        [suite setBool:YES forKey:@"FMX.aggregateSearch"];
        [suite setInteger:4 forKey:@"searchPlatform"];
        Check([suite integerForKey:@"searchPlatform"] == 4, @"Other suites preserved");
        [suite removePersistentDomainForName:@"org.codex.fmx.preferences.fixture"];
        FMSearchPreferencesSetAggregateEnabled(NO);
        Check([defaults integerForKey:@"searchPlatform"] == 4, @"Turning off aggregate restores original Qishui choice");
        Check(![defaults boolForKey:@"FMX.managesSearchPlatform"], @"Selection ownership released");
        [defaults setInteger:2 forKey:@"searchPlatform"];
        FMSearchPreferencesInstall();
        Check(![defaults boolForKey:@"FMX.aggregateSearch"], @"Repeated install does not override later opt-out");
        FMSearchPreferencesSetAggregateEnabled(YES);
        Check([defaults integerForKey:@"searchPlatform"] == 2, @"Other common search selectors remain valid");
        [defaults setInteger:0 forKey:@"searchPlatform"];
        Check([defaults integerForKey:@"searchPlatform"] == 0, @"Normal source selectors do not get forced to QQ");
        FMSearchPreferencesSetAggregateEnabled(NO);
        Check([defaults integerForKey:@"searchPlatform"] == 2, @"Prior single-platform choice restored after aggregate session");
        [defaults removePersistentDomainForName:domain];
        puts("DONE global Home search preference tests passed");
    }
    return 0;
}
