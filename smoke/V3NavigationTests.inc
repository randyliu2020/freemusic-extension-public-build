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
[self test:@"native_tabs_hide_discovery_and_leave_library_root" body:^NSDictionary *{
    void *(*factory)(void)=(void*(*)(void))dlsym(self.swiftUIFixtureHandle,"FMNavMakeFixture");
    void (*openFavorites)(void)=(void(*)(void))dlsym(self.swiftUIFixtureHandle,"FMNavOpenFavorites");
    void (*selectProfile)(void)=(void(*)(void))dlsym(self.swiftUIFixtureHandle,"FMNavSelectProfile");
    void (*refresh)(void)=(void(*)(void))dlsym(self.extensionHandle,"FMNavigationRefresh");
    NSDictionary *(*diagnostics)(void)=(NSDictionary*(*)(void))dlsym(self.extensionHandle,"FMNavigationDiagnostics");
    Check(factory&&openFavorites&&selectProfile&&refresh&&diagnostics,@"Navigation and fixture exports");
    NSUserDefaults *defaults=NSUserDefaults.standardUserDefaults;
    NSInteger likesBefore=[defaults integerForKey:@"smoke.fmnav.likes-appearance-count"];
    NSInteger likesRowBefore=[defaults integerForKey:@"smoke.fmnav.likes-row-count"];
    NSInteger otherRowBefore=[defaults integerForKey:@"smoke.fmnav.other-row-count"];
    __block UIViewController *oldRoot,*host,*library,*favorites,*profile;
    __block UITabBarController *tabs;
    __block NSDictionary *state;
    UIViewController *(^visibleTitle)(NSString *)=^UIViewController *(NSString *title){
        return navVisible(host,^BOOL(UIViewController *c){return [c.navigationItem.title isEqual:title]&&c.navigationController.topViewController==c;});
    };
    void (^sceneRefresh)(void)=^{
        [NSNotificationCenter.defaultCenter postNotificationName:UISceneDidActivateNotification object:self.window.windowScene];
        refresh();
    };
    @try {
        Main(^{oldRoot=self.window.rootViewController;host=CFBridgingRelease(factory());self.window.rootViewController=host;[self.window makeKeyAndVisible];});
        Check(Until(^BOOL{
            tabs=(id)navVisible(host,^BOOL(UIViewController *c){return [c isKindOfClass:UITabBarController.class];});
            library=visibleTitle(@"资料库");
            return library&&tabs.tabs.count==5&&tabs.selectedTab==tabs.tabs[2]&&
                [defaults integerForKey:@"smoke.fmnav.likes-row-count"]>likesRowBefore&&[defaults integerForKey:@"smoke.fmnav.other-row-count"]>otherRowBefore;
        },6),@"Cold-start Library shows Favorites and another playlist on its root");
        Check(Until(^BOOL{
            UITab *discover=tabs.tabs[1];
            return discover.isHidden&&discover.preferredPlacement==UITabPlacementSidebarOnly&&![tabs.compactTabIdentifiers containsObject:discover.identifier];
        },5),@"Discovery hidden while Library stays selected");
        Main(^{
            sceneRefresh();
            Check(visibleTitle(@"资料库")==library&&[defaults integerForKey:@"smoke.fmnav.likes-appearance-count"]==likesBefore,@"Refresh leaves the native Library root and both playlists reachable");
            state=diagnostics();
        });
        [[NSJSONSerialization dataWithJSONObject:state options:NSJSONWritingPrettyPrinted error:nil] writeToURL:[self.output URLByAppendingPathComponent:@"navigation-startup.json"] atomically:YES];
        [self captureSurfaceDiagnostics:@"navigation-library-root-state"];
        [self screenshot:@"navigation-library-root.png"];
        Main(^{openFavorites();});
        Check(Until(^BOOL{
            favorites=visibleTitle(@"我喜欢");
            return favorites&&[defaults integerForKey:@"smoke.fmnav.likes-appearance-count"]>likesBefore;
        },5),@"Selecting Favorites navigates using the fixture's native navigation path");
        Main(^{
            sceneRefresh();
            Check(visibleTitle(@"我喜欢")==favorites,@"Foreground refresh preserves an explicitly selected playlist");
            selectProfile();
        });
        Check(Until(^BOOL{profile=visibleTitle(@"我的");return profile&&tabs.selectedTab==tabs.tabs[3];},5),@"Selecting another tab reaches its own root");
        Main(^{
            sceneRefresh();
            Check(tabs.selectedTab==tabs.tabs[3]&&visibleTitle(@"我的")==profile,@"Foreground refresh preserves the user's current tab");
        });
        return @{@"native_tab_model_count":@5,@"discovery_hidden":@YES,@"library_root_visible":@YES,
                 @"favorites_opened_by_user":@YES,@"manual_destination_preserved_on_refresh":@YES,
                 @"tab_selection_preserved_on_foreground":@YES,@"native_path_component_test":@YES,
                 @"physical_tap_validated":@NO,@"original_app_used":@NO,@"diagnostics":state};
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
