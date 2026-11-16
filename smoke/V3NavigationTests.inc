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
BOOL (^preservesObjects)(NSArray *,NSArray *)=^BOOL(NSArray *original,NSArray *current) {
    NSUInteger next=0;for(id object in current)if(next<original.count&&object==original[next])next++;return next==original.count;
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
        Check(opened&&[NSUserDefaults.standardUserDefaults integerForKey:@"smoke.fmnav.likes-appearance-count"]==1,@"Original Favorites NavigationLink opens exactly once and destination appears");
        Check([state[@"axCandidateCount"] unsignedIntegerValue]==0&&[state[@"activationPath"] hasPrefix:@"primary_action_"],@"AX-empty visible Favorites row navigates through its original public cell primary action");
        return @{@"native_tab_model_count":@5,@"discovery_hidden":@YES,@"favorites_opened":@YES,@"ax_empty_public_primary_action":@YES,@"original_app_used":@NO,@"diagnostics":state};
    } @finally {Main(^{if(host.presentedViewController)[host dismissViewControllerAnimated:NO completion:nil];self.window.rootViewController=oldRoot;[self.window makeKeyAndVisible];});}
}];
[self test:@"profile_insights_preserve_original_swiftui_toolbar_groups" body:^NSDictionary *{
    void *(*factory)(void)=(void*(*)(void))dlsym(self.swiftUIFixtureHandle,"FMNavMakeFixture");
    void (*selectProfile)(void)=(void(*)(void))dlsym(self.swiftUIFixtureHandle,"FMNavSelectProfile");
    void (*originalGear)(void)=(void(*)(void))dlsym(self.swiftUIFixtureHandle,"FMNavRunOriginalGear");
    void (*setAction)(void(^)(UIViewController *))=(void(*)(void(^)(UIViewController *)))dlsym(self.extensionHandle,"FMNavigationSetProfileAction");
    UIViewController *(*makeInsights)(void)=(UIViewController*(*)(void))dlsym(self.extensionHandle,"FMInsightsController");
    Check(factory&&selectProfile&&originalGear&&setAction&&makeInsights,@"Profile fixture exports");
    __block UIViewController *oldRoot,*host,*profile;__block NSArray *originalItems,*originalGroups,*leading,*center,*groupItems;__block BOOL intact=NO;
    @try {
        Main(^{setAction(nil);oldRoot=self.window.rootViewController;host=CFBridgingRelease(factory());self.window.rootViewController=host;[self.window makeKeyAndVisible];});
        Check(Until(^BOOL{return navVisible(host,^BOOL(UIViewController *c){return [c isKindOfClass:UITabBarController.class];})!=nil;},5),@"Native tabs mounted for profile");
        Main(^{selectProfile();});
        Check(Until(^BOOL{profile=navVisible(host,^BOOL(UIViewController *c){return [c.navigationItem.title isEqual:@"我的"]&&c.navigationController.topViewController==c&&AllToolbarItems(c.navigationItem).count>0;});return profile!=nil;},5),@"Native profile and original gear toolbar mounted");
        Main(^{originalItems=[AllToolbarItems(profile.navigationItem) copy];originalGroups=[ToolbarGroups(profile.navigationItem) copy];leading=[profile.navigationItem.leadingItemGroups copy];center=[profile.navigationItem.centerItemGroups copy];
            Check(profile.navigationItem.trailingItemGroups.count>0,@"Real SwiftUI fixture uses modern toolbar groups");NSMutableArray *snapshots=NSMutableArray.array;for(UIBarButtonItemGroup *group in originalGroups)[snapshots addObject:[group.barButtonItems copy]?:@[]];groupItems=snapshots;
            setAction(^(UIViewController *owner){Check(owner==profile,@"Insights callback has the same native profile owner");[owner.navigationController pushViewController:makeInsights() animated:NO];});});
        Check(Until(^BOOL{for(UIBarButtonItem *item in AllToolbarItems(profile.navigationItem))if([item.accessibilityIdentifier isEqual:@"FMX.profileInsights"])return YES;return NO;},4),@"Profile gets its own insights entry");
        Main(^{NSArray *items=AllToolbarItems(profile.navigationItem),*groups=ToolbarGroups(profile.navigationItem);intact=preservesObjects(originalItems,items)&&preservesObjects(originalGroups,groups)&&sameObjects(leading,profile.navigationItem.leadingItemGroups)&&sameObjects(center,profile.navigationItem.centerItemGroups);for(NSUInteger i=0;i<originalGroups.count;i++)if(!sameObjects(groupItems[i],((UIBarButtonItemGroup *)originalGroups[i]).barButtonItems))intact=NO;originalGear();});
        Check(intact&&[NSUserDefaults.standardUserDefaults integerForKey:@"smoke.fmnav.original-gear-count"]>0,@"Original group/item objects, leading/center and gear callback preserved");
        [self screenshot:@"profile-with-insights.png"];
        Main(^{for(UIBarButtonItem *item in AllToolbarItems(profile.navigationItem))if([item.accessibilityIdentifier isEqual:@"FMX.profileInsights"]){[UIApplication.sharedApplication sendAction:item.action to:item.target from:item forEvent:nil];break;}});
        Check(Until(^BOOL{return [profile.navigationController.topViewController isKindOfClass:NSClassFromString(@"FMInsightsViewController")];},4),@"Profile entry opens the production insights controller");
        Main(^{[profile.navigationController popViewControllerAnimated:NO];setAction(nil);});
        Check(Until(^BOOL{return profile.navigationController.topViewController==profile&&VisibleInWindow(profile.viewIfLoaded);},3),@"Returns to the same native profile controller");
        Main(^{intact=sameObjects(AllToolbarItems(profile.navigationItem),originalItems)&&sameObjects(ToolbarGroups(profile.navigationItem),originalGroups)&&sameObjects(leading,profile.navigationItem.leadingItemGroups)&&sameObjects(center,profile.navigationItem.centerItemGroups);for(NSUInteger i=0;i<originalGroups.count;i++)if(!sameObjects(groupItems[i],((UIBarButtonItemGroup *)originalGroups[i]).barButtonItems))intact=NO;});
        Check(intact,@"Removing only extension group restores original toolbar");
        return @{@"group_and_item_identity_preserved":@YES,@"leading_center_untouched":@YES,@"profile_to_production_insights":@YES,@"gear_callback_component_test":@YES,@"physical_tap_validated":@NO};
    } @finally {Main(^{setAction(^(UIViewController *owner){[owner.navigationController pushViewController:makeInsights() animated:YES];});if(host.presentedViewController)[host dismissViewControllerAnimated:NO completion:nil];self.window.rootViewController=oldRoot;[self.window makeKeyAndVisible];});}
}];
}
