#import "FMNavigation.h"
#import <objc/runtime.h>

static IMP FMNOriginalSetTabs;
static IMP FMNOriginalSetTabsAnimated;
static BOOL FMNInstalled, FMNRefreshing, FMNDiscoverHidden;
static NSUInteger FMNRecognizedControllers;
static char FMNApplyingKey, FMNPendingTabUpdateKey;

static NSString *FMNText(id value) {
    return [value isKindOfClass:NSString.class] ? [value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] : @"";
}
static BOOL FMNRole(NSString *title,NSString *role) {
    NSDictionary *labels=@{@"home":@[@"首页",@"Home"],@"discover":@[@"发现",@"Discover"],@"library":@[@"资料库",@"Library"],
        @"profile":@[@"我的",@"Me"],@"search":@[@"搜索",@"Search"]};
    NSString *localized=[NSBundle.mainBundle localizedStringForKey:[@"tab." stringByAppendingString:role] value:@"" table:nil];
    return [labels[role] containsObject:FMNText(title)] || (localized.length && [FMNText(title) isEqual:localized]);
}
static NSDictionary *FMNRecognizeTabs(UITabBarController *controller) {
    if (@available(iOS 18.0,*)) {
        NSArray<UITab *> *tabs=controller.tabs;
        if(tabs.count!=5)return nil;
        NSMutableDictionary *roles=NSMutableDictionary.dictionary; NSMutableSet *identifiers=NSMutableSet.set;
        for(UITab *tab in tabs) {
            if(![tab isKindOfClass:UITab.class] || !tab.identifier.length || [identifiers containsObject:tab.identifier])return nil;
            [identifiers addObject:tab.identifier]; NSString *match;
            for(NSString *role in @[@"home",@"discover",@"library",@"profile",@"search"])
                if(FMNRole(tab.title,role)) { if(match)return nil; match=role; }
            if(!match || roles[match])return nil;
            roles[match]=tab;
        }
        return roles.count==5?roles:nil;
    }
    return nil;
}
BOOL FMNavigationConfigureTabController(UITabBarController *controller) {
    if(!NSThread.isMainThread)return NO;
    NSDictionary *roles=FMNRecognizeTabs(controller); if(!roles)return NO;
    if(objc_getAssociatedObject(controller,&FMNApplyingKey))return YES;
    objc_setAssociatedObject(controller,&FMNApplyingKey,@YES,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    @try {
    if(@available(iOS 18.0,*)) {
        UITab *discover=roles[@"discover"];
        NSMutableArray *visible=NSMutableArray.array;
        NSArray *existing=controller.compactTabIdentifiers;
        if(existing) {
            for(NSString *identifier in existing)if(![identifier isEqual:discover.identifier])[visible addObject:identifier];
        } else for(UITab *tab in controller.tabs)if(tab!=discover)[visible addObject:tab.identifier];
        // Compact tab bar, regular tab bar and sidebar are covered separately by public UIKit properties.
        if(![controller.compactTabIdentifiers isEqual:visible])controller.compactTabIdentifiers=visible;
        if(discover.preferredPlacement!=UITabPlacementSidebarOnly)discover.preferredPlacement=UITabPlacementSidebarOnly;
        if(!discover.isHidden)discover.hidden=YES;
        if(discover.allowsHiding)discover.allowsHiding=NO;
        FMNDiscoverHidden=YES;
        return YES;
    }
    } @finally { objc_setAssociatedObject(controller,&FMNApplyingKey,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
    return NO;
}
static void FMNVisit(UIViewController *controller,NSUInteger depth) {
    if(!controller || depth>12)return;
    if(controller.presentedViewController) { FMNVisit(controller.presentedViewController,depth+1);return; }
    if([controller isKindOfClass:UITabBarController.class]) {
        UITabBarController *tabs=(UITabBarController *)controller;
        if(FMNavigationConfigureTabController(tabs))FMNRecognizedControllers++;
    }
    for(UIViewController *child in controller.childViewControllers)FMNVisit(child,depth+1);
}
void FMNavigationRefresh(void) {
    if(!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(),^{FMNavigationRefresh();});return; }
    if(FMNRefreshing || UIApplication.sharedApplication.applicationState!=UIApplicationStateActive)return;
    FMNRefreshing=YES;
    for(UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if(scene.activationState!=UISceneActivationStateForegroundActive || ![scene isKindOfClass:UIWindowScene.class])continue;
        for(UIWindow *window in ((UIWindowScene *)scene).windows)if(window.isKeyWindow && !window.hidden && window.alpha>0.01)
            FMNVisit(window.rootViewController,0);
    }
    FMNRefreshing=NO;
}
static void FMNTabsChanged(UITabBarController *controller) {
    if(!NSThread.isMainThread)return;
    if(objc_getAssociatedObject(controller,&FMNPendingTabUpdateKey))return;
    objc_setAssociatedObject(controller,&FMNPendingTabUpdateKey,@YES,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    FMNavigationConfigureTabController(controller);
    // SwiftUI may finish filling in the tab titles and placements after its setter returns.
    __weak UITabBarController *weakController=controller;
    dispatch_async(dispatch_get_main_queue(), ^{
        UITabBarController *current=weakController;
        if(!current)return;
        FMNavigationConfigureTabController(current);
        objc_setAssociatedObject(current,&FMNPendingTabUpdateKey,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    });
}
static void FMNSetTabs(UITabBarController *controller,SEL selector,NSArray *tabs) {
    ((void (*)(id,SEL,id))FMNOriginalSetTabs)(controller,selector,tabs);
    FMNTabsChanged(controller);
}
static void FMNSetTabsAnimated(UITabBarController *controller,SEL selector,NSArray *tabs,BOOL animated) {
    ((void (*)(id,SEL,id,BOOL))FMNOriginalSetTabsAnimated)(controller,selector,tabs,animated);
    FMNTabsChanged(controller);
}
void FMNavigationInstall(void) {
    if(!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(),^{FMNavigationInstall();});return; }
    if(FMNInstalled)return;FMNInstalled=YES;
    if(@available(iOS 18.0,*)) {
        Method setter=class_getInstanceMethod(UITabBarController.class,@selector(setTabs:));
        Method animated=class_getInstanceMethod(UITabBarController.class,@selector(setTabs:animated:));
        if(setter) { FMNOriginalSetTabs=method_getImplementation(setter);method_setImplementation(setter,(IMP)FMNSetTabs); }
        if(animated) { FMNOriginalSetTabsAnimated=method_getImplementation(animated);method_setImplementation(animated,(IMP)FMNSetTabsAnimated); }
    }
    // The native tab initializer chooses Library on cold launch. Later refreshes
    // only maintain Discover visibility and never touch selection or the navigation stack.
    [NSNotificationCenter.defaultCenter addObserverForName:UISceneDidActivateNotification object:nil
        queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note) { FMNavigationRefresh(); }];
    dispatch_async(dispatch_get_main_queue(), ^{ FMNavigationRefresh(); });
}
NSDictionary<NSString *, id> *FMNavigationDiagnostics(void) {
    if(!NSThread.isMainThread) {
        __block NSDictionary *result;
        dispatch_sync(dispatch_get_main_queue(), ^{ result=FMNavigationDiagnostics(); });
        return result;
    }
    return @{@"installed":@(FMNInstalled), @"discoverHidden":@(FMNDiscoverHidden),
             @"recognizedChecks":@(FMNRecognizedControllers)};
}
