#import "FMSearchPreferences.h"
#import <dispatch/dispatch.h>
#import <objc/runtime.h>

static NSString *const FMXAggregatePreference = @"FMX.aggregateSearch";
// Verified original AppStorage<Int> key in FreeMusic 4.2.7 at 0x22a678.
// Native value 4 has a Qishui-only decoder that discards other sources' identity.
static NSString *const FMXNativeSearchPlatform = @"searchPlatform";
static NSString *const FMXPreviousPlatform = @"FMX.singleSearchPlatform";
static NSString *const FMXPlatformManaged = @"FMX.managesSearchPlatform";
static NSString *const FMXV2Configured = @"FMX.settingsAndQishuiConfigured";
static BOOL FMXUpdatingPreferences;
static IMP FMXOriginalSetInteger;
static IMP FMXOriginalSetObject;

static void FMXRefreshAppStorageAfterWrite(NSUserDefaults *defaults) {
    // AppStorage may cache the caller's proposed value after the defaults setter
    // returns. Notify its key observers on the next turn, when that cache exists.
    // The persisted value stays normalized throughout; no source-only value is
    // temporarily written and no other preference key is notified.
    dispatch_async(dispatch_get_main_queue(), ^{
        if (![defaults boolForKey:FMXAggregatePreference] ||
            ![@[@0, @2, @3] containsObject:@([defaults integerForKey:FMXNativeSearchPlatform])]) return;
        [defaults willChangeValueForKey:FMXNativeSearchPlatform];
        [defaults didChangeValueForKey:FMXNativeSearchPlatform];
    });
}

static BOOL FMXShouldUseUnifiedSearch(NSUserDefaults *defaults, NSString *key, NSInteger value) {
    return defaults == NSUserDefaults.standardUserDefaults && [key isEqual:FMXNativeSearchPlatform]
        && value == 4 && [defaults boolForKey:FMXAggregatePreference];
}

static void FMXSetInteger(NSUserDefaults *defaults, SEL selector, NSInteger value, NSString *key) {
    BOOL normalized = FMXShouldUseUnifiedSearch(defaults, key, value);
    if (normalized) value = 3;
    ((void (*)(id, SEL, NSInteger, NSString *))FMXOriginalSetInteger)(defaults, selector, value, key);
    if (normalized) FMXRefreshAppStorageAfterWrite(defaults);
}

static void FMXSetObject(NSUserDefaults *defaults, SEL selector, id value, NSString *key) {
    BOOL normalized = [value isKindOfClass:NSNumber.class] && FMXShouldUseUnifiedSearch(defaults, key, [value integerValue]);
    if (normalized) value = @3;
    ((void (*)(id, SEL, id, NSString *))FMXOriginalSetObject)(defaults, selector, value, key);
    if (normalized) FMXRefreshAppStorageAfterWrite(defaults);
}

static void FMXInstallPreferenceSetter(Class cls, SEL selector, IMP replacement, IMP *original) {
    Method method = class_getInstanceMethod(cls, selector);
    if (!method) return;
    *original = method_getImplementation(method);
    // Add an override on the concrete class when this method is inherited.
    if (!class_addMethod(cls, selector, replacement, method_getTypeEncoding(method)))
        method_setImplementation(class_getInstanceMethod(cls, selector), replacement);
}

void FMSearchPreferencesRefresh(void) {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ FMSearchPreferencesRefresh(); });
        return;
    }
    if (FMXUpdatingPreferences) return;
    FMXUpdatingPreferences = YES;
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    BOOL aggregate = [defaults boolForKey:FMXAggregatePreference];
    BOOL managed = [defaults boolForKey:FMXPlatformManaged];
    id currentObject = [defaults objectForKey:FMXNativeSearchPlatform];
    NSInteger current = [currentObject isKindOfClass:NSNumber.class] ? [currentObject integerValue] : 3;
    if (aggregate) {
        if (!managed) {
            NSInteger previous = [@[@0, @2, @3, @4] containsObject:@(current)] ? current : 3;
            [defaults setInteger:previous forKey:FMXPreviousPlatform];
            [defaults setBool:YES forKey:FMXPlatformManaged];
        }
        if (![currentObject isKindOfClass:NSNumber.class] || ![@[@0, @2, @3] containsObject:@(current)]) {
            [defaults setInteger:3 forKey:FMXNativeSearchPlatform];
        }
    } else if (managed) {
        NSInteger previous = [defaults integerForKey:FMXPreviousPlatform];
        if (![@[@0, @2, @3, @4] containsObject:@(previous)]) previous = 3;
        [defaults setBool:NO forKey:FMXPlatformManaged];
        [defaults removeObjectForKey:FMXPreviousPlatform];
        [defaults setInteger:previous forKey:FMXNativeSearchPlatform];
    }
    FMXUpdatingPreferences = NO;
}

void FMSearchPreferencesSetAggregateEnabled(BOOL enabled) {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ FMSearchPreferencesSetAggregateEnabled(enabled); });
        return;
    }
    [NSUserDefaults.standardUserDefaults setBool:enabled forKey:FMXAggregatePreference];
    FMSearchPreferencesRefresh();
}

void FMSearchPreferencesInstall(void) {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ FMSearchPreferencesInstall(); });
        return;
    }
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        // Normalize only this host preference, before SwiftUI can observe value 4
        // and launch the source-specific decoder. Other keys/suites pass through.
        FMXInstallPreferenceSetter(object_getClass(defaults), @selector(setInteger:forKey:), (IMP)FMXSetInteger, &FMXOriginalSetInteger);
        FMXInstallPreferenceSetter(object_getClass(defaults), @selector(setObject:forKey:), (IMP)FMXSetObject, &FMXOriginalSetObject);
        // The requested v2 behavior is aggregate search from Home by default.
        // This migration runs once; later explicit opt-out survives restarts.
        if (![defaults boolForKey:FMXV2Configured]) {
            [defaults setBool:YES forKey:FMXAggregatePreference];
            [defaults setBool:YES forKey:FMXV2Configured];
        }
        FMSearchPreferencesRefresh();
        [NSNotificationCenter.defaultCenter addObserverForName:NSUserDefaultsDidChangeNotification
            object:defaults queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
                FMSearchPreferencesRefresh();
            }];
    });
}
