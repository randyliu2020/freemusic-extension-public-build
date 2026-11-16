// Included within the independent Host's natural test sequence.
{
// Inactive SwiftUI tab/navigation controllers can remain attached. Traverse
// only the selected UITab and top NavigationStack on this fixture surface.
UIViewController *(^navVisible)(UIViewController *,BOOL(^)(UIViewController *))=^UIViewController *(UIViewController *root,BOOL(^predicate)(UIViewController *)) {
    if(!root)return nil;NSMutableArray *queue=[NSMutableArray arrayWithObject:root];
    for(NSUInteger i=0;i<queue.count&&i<128;i++) {
        UIViewController *value=queue[i];
        if(value.presentedViewController){[queue addObject:value.presentedViewController];continue;}
        if(!VisibleInWindow(value.viewIfLoaded))continue;
        if(predicate(value))return value;
        if([value isKindOfClass:UITabBarController.class]) {UIViewController *selected=((UITabBarController *)value).selectedViewController;if(selected)[queue addObject:selected];}
        else if([value isKindOfClass:UINavigationController.class]) {UIViewController *top=((UINavigationController *)value).topViewController;if(top)[queue addObject:top];}
        else [queue addObjectsFromArray:value.childViewControllers];
    }return nil;
};
BOOL (^sameObjects)(NSArray *,NSArray *)=^BOOL(NSArray *a,NSArray *b) {
    if(a.count!=b.count)return NO;for(NSUInteger i=0;i<a.count;i++)if(a[i]!=b[i])return NO;return YES;
};
[self test:@"native_tabs_hide_discovery_and_open_favorites_once" body:^NSDictionary *{
    void *(*factory)(void)=(void*(*)(void))dlsym(self.swiftUIFixtureHandle,"FMNavMakeAXEmptyFixture");
    NSDictionary *(*diagnostics)(void)=(NSDictionary*(*)(void))dlsym(self.extensionHandle,"FMNavigationDiagnostics");
    Check(factory&&diagnostics,@"Navigation production and real SwiftUI fixture exports");
    __block UIViewController *oldRoot,*host;__block UITabBarController *tabs;__block NSDictionary *state;
    @try {
        Main(^{oldRoot=self.window.rootViewController;host=CFBridgingRelease(factory());self.window.rootViewController=host;[self.window makeKeyAndVisible];});
        Check(Until(^BOOL{tabs=(id)navVisible(host,^BOOL(UIViewController *c){return [c isKindOfClass:UITabBarController.class];});return tabs!=nil&&tabs.tabs.count==5;},6),@"Original-shaped five-tab SwiftUI model appears");
        Check(Until(^BOOL{UITab *discovery=tabs.tabs[1];return discovery.isHidden&&discovery.preferredPlacement==UITabPlacementSidebarOnly&&![tabs.compactTabIdentifiers containsObject:discovery.identifier];},5),@"Discovery hidden in compact, regular and sidebar placements");
        BOOL opened=Until(^BOOL{state=diagnostics();return [state[@"startupState"] isEqual:@"opened"];},32);
        Main(^{state=diagnostics();});
        [[NSJSONSerialization dataWithJSONObject:state options:NSJSONWritingPrettyPrinted error:nil] writeToURL:[self.output URLByAppendingPathComponent:@"navigation-startup.json"] atomically:YES];
        [self captureSurfaceDiagnostics:@"navigation-favorites-state"];
        [self screenshot:@"navigation-favorites.png"];
        if(!opened) {
            void (*probe)(void)=(void(*)(void))dlsym(self.swiftUIFixtureHandle,"FMNavStartFixtureOCRProbe");
            void *(*copyProbe)(void)=(void*(*)(void))dlsym(self.swiftUIFixtureHandle,"FMNavCopyFixtureOCRProbe");
            if(probe&&copyProbe) {
                __block NSDictionary *report;Main(^{probe();});
                Until(^BOOL{void *value=copyProbe();if(value)report=CFBridgingRelease(value);return report!=nil;},8);
                if(report)[[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:nil] writeToURL:[self.output URLByAppendingPathComponent:@"navigation-fixture-ocr.json"] atomically:YES];
            }
        }
        Check(opened&&[NSUserDefaults.standardUserDefaults integerForKey:@"smoke.fmnav.likes-appearance-count"]==1,@"Original Favorites NavigationLink opens exactly once and destination appears");
        Check([state[@"axCandidateCount"] unsignedIntegerValue]==0&&[state[@"activationPath"] hasPrefix:@"selection_flow_"]&&[state[@"selectionCallbackDelivered"] boolValue],@"AX-empty visible Favorites row navigates through its original public cell selection delegate");
        return @{@"native_tab_model_count":@5,@"discovery_hidden":@YES,@"favorites_opened":@YES,@"ax_empty_public_selection_flow":@YES,@"original_app_used":@NO,@"diagnostics":state};
    } @finally {Main(^{if(host.presentedViewController)[host dismissViewControllerAnimated:NO completion:nil];self.window.rootViewController=oldRoot;[self.window makeKeyAndVisible];});}
}];
[self test:@"profile_keeps_original_gear_and_insights_stays_in_settings" body:^NSDictionary *{
    void *(*factory)(void)=(void*(*)(void))dlsym(self.swiftUIFixtureHandle,"FMNavMakeFixture");
    void (*selectProfile)(void)=(void(*)(void))dlsym(self.swiftUIFixtureHandle,"FMNavSelectProfile");
    void (*selectLibrary)(void)=(void(*)(void))dlsym(self.swiftUIFixtureHandle,"FMNavSelectLibrary");
    void (*originalGear)(void)=(void(*)(void))dlsym(self.swiftUIFixtureHandle,"FMNavRunOriginalGear");
    void (*closeSettings)(void)=(void(*)(void))dlsym(self.swiftUIFixtureHandle,"FMNavCloseOriginalSettings");
    void (*refresh)(void)=(void(*)(void))dlsym(self.extensionHandle,"FMNavigationRefresh");
    Check(factory&&selectProfile&&selectLibrary&&originalGear&&closeSettings&&refresh,@"Profile fixture and production navigation exports");
    __block UIViewController *oldRoot,*host,*profile;__block NSArray *originalItems,*originalGroups,*leading,*center,*groupItems;__block NSUInteger gearBefore,settingsBefore;
    BOOL (^toolbarIntact)(void)=^BOOL {
        if(!sameObjects(AllToolbarItems(profile.navigationItem),originalItems)||!sameObjects(ToolbarGroups(profile.navigationItem),originalGroups)||!sameObjects(leading,profile.navigationItem.leadingItemGroups)||!sameObjects(center,profile.navigationItem.centerItemGroups))return NO;
        for(NSUInteger i=0;i<originalGroups.count;i++)if(!sameObjects(groupItems[i],((UIBarButtonItemGroup *)originalGroups[i]).barButtonItems))return NO;
        for(UIBarButtonItem *item in AllToolbarItems(profile.navigationItem))if([item.accessibilityIdentifier isEqual:@"FMX.profileInsights"]||[item.title isEqual:@"画像"]||[item.accessibilityLabel isEqual:@"听歌画像"])return NO;
        return FindIdentifier(self.window,@"FMX.profileInsights")==nil;
    };
    @try {
        Main(^{oldRoot=self.window.rootViewController;host=CFBridgingRelease(factory());self.window.rootViewController=host;[self.window makeKeyAndVisible];});
        Check(Until(^BOOL{return navVisible(host,^BOOL(UIViewController *c){return [c isKindOfClass:UITabBarController.class];})!=nil;},5),@"Native tabs mounted for profile");
        Main(^{selectProfile();});
        Check(Until(^BOOL{profile=navVisible(host,^BOOL(UIViewController *c){return [c.navigationItem.title isEqual:@"我的"]&&c.navigationController.topViewController==c&&AllToolbarItems(c.navigationItem).count>0;});return profile!=nil;},5),@"Native profile and original gear toolbar mounted");
        Main(^{originalItems=[AllToolbarItems(profile.navigationItem) copy];originalGroups=[ToolbarGroups(profile.navigationItem) copy];leading=[profile.navigationItem.leadingItemGroups copy];center=[profile.navigationItem.centerItemGroups copy];
            Check(originalItems.count==1&&profile.navigationItem.trailingItemGroups.count>0,@"Real SwiftUI profile has only its original gear in modern toolbar groups");
            NSMutableArray *snapshots=NSMutableArray.array;for(UIBarButtonItemGroup *group in originalGroups)[snapshots addObject:[group.barButtonItems copy]?:@[]];groupItems=snapshots;
            gearBefore=[NSUserDefaults.standardUserDefaults integerForKey:@"smoke.fmnav.original-gear-count"];settingsBefore=[NSUserDefaults.standardUserDefaults integerForKey:@"smoke.fmnav.settings-appearance-count"];
        });
        NSTimeInterval deadline=NSProcessInfo.processInfo.systemUptime+1.7;
        do {__block BOOL intact;Main(^{refresh();intact=toolbarIntact();});Check(intact,@"Repeated production refresh preserves original gear/group identities and never adds a profile insights button");[NSThread sleepForTimeInterval:0.05];}while(NSProcessInfo.processInfo.systemUptime<deadline);
        [self screenshot:@"profile-original-gear-only.png"];
        Main(^{originalGear();});
        Check(Until(^BOOL{return [profile.navigationController.topViewController.navigationItem.title isEqual:@"设置"]&&[NSUserDefaults.standardUserDefaults integerForKey:@"smoke.fmnav.original-gear-count"]==gearBefore+1&&[NSUserDefaults.standardUserDefaults integerForKey:@"smoke.fmnav.settings-appearance-count"]==settingsBefore+1;},4),@"Original gear shared callback opens its native SwiftUI Settings destination exactly once");
        [self screenshot:@"profile-original-gear-opens-settings.png"];
        Main(^{closeSettings();});
        Check(Until(^BOOL{return profile.navigationController.topViewController==profile&&VisibleInWindow(profile.viewIfLoaded);},3),@"Returns to the same native profile controller");
        Main(^{selectLibrary();});
        Check(Until(^BOOL{return !VisibleInWindow(profile.viewIfLoaded);},3),@"Profile becomes inactive when selecting Library");
        Main(^{selectProfile();});
        Check(Until(^BOOL{refresh();return VisibleInWindow(profile.viewIfLoaded)&&toolbarIntact();},4),@"Returning to Profile retains only the original gear and the exact original toolbar objects");
        return @{@"group_and_item_identity_preserved":@YES,@"leading_center_untouched":@YES,@"profile_insights_button_absent":@YES,@"original_gear_opens_settings":@YES,@"settings_insights_route_verified_by_separate_settings_test":@YES,@"gear_callback_component_test":@YES,@"physical_tap_validated":@NO};
    } @finally {Main(^{if(host.presentedViewController)[host dismissViewControllerAnimated:NO completion:nil];self.window.rootViewController=oldRoot;[self.window makeKeyAndVisible];});}
}];
}
