#import "FMInteraction.h"
#import "FMNavigation.h"
#import <objc/runtime.h>

@interface FMSearchScrollRegistration : NSObject
@property(nonatomic, weak) UIScrollView *scroll;
@property(nonatomic) UIScrollViewKeyboardDismissMode originalMode;
@end
@implementation FMSearchScrollRegistration
@end

@interface FMInteractionCoordinator : NSObject
@property(nonatomic, strong) NSMapTable<UIScrollView *, FMSearchScrollRegistration *> *registrations;
@property(nonatomic) BOOL queued, editing, scanning;
@property(nonatomic) NSUInteger configurationCount, restorationCount;
@property(nonatomic) NSTimeInterval nextLayoutScan;
- (void)schedule;
- (void)scan;
@end

static FMInteractionCoordinator *FMInteractions;
static NSDictionary<NSString *, NSNumber *> *FMInteractionSnapshot;
static void (*FMInteractionOriginalLayout)(id, SEL);
static void (*FMInteractionOriginalAppear)(id, SEL, BOOL);
static void (*FMInteractionOriginalDisappear)(id, SEL, BOOL);

static BOOL FMIVisible(UIView *view) {
    if (!view.window || CGRectIsEmpty(view.bounds)) return NO;
    for (UIView *node = view; node; node = node.superview) if (node.hidden || node.alpha < 0.01) return NO;
    return YES;
}

static void FMIVisibleControllers(UIViewController *controller, NSMutableArray *result, NSUInteger depth) {
    if (!controller || depth > 16 || result.count >= 64) return;
    UIViewController *presented = controller.presentedViewController;
    // A search presentation belongs to the existing results page. Other modals
    // replace it, so editing a sheet never configures the obscured page's list.
    if (presented && !presented.isBeingDismissed && ![presented isKindOfClass:UISearchController.class]) {
        FMIVisibleControllers(presented, result, depth + 1); return;
    }
    if ([controller isKindOfClass:UINavigationController.class]) {
        UINavigationController *navigation = (id)controller;
        UISearchController *ownedSearch = navigation.topViewController.navigationItem.searchController;
        if (navigation.visibleViewController == navigation.topViewController ||
            (ownedSearch && navigation.visibleViewController == ownedSearch))
            FMIVisibleControllers(navigation.topViewController, result, depth + 1);
        return;
    }
    if ([controller isKindOfClass:UITabBarController.class]) {
        FMIVisibleControllers(((UITabBarController *)controller).selectedViewController, result, depth + 1); return;
    }
    if (!FMIVisible(controller.viewIfLoaded) || controller.isBeingDismissed || controller.isMovingFromParentViewController) return;
    [result addObject:controller];
    for (UIViewController *child in controller.childViewControllers) FMIVisibleControllers(child, result, depth + 1);
}

static void FMICollectResultLists(UIView *root, NSMutableSet<UIScrollView *> *result) {
    if (!FMIVisible(root)) return;
    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:root];
    for (NSUInteger index = 0; index < queue.count && index < 384; ++index) {
        UIView *view = queue[index];
        if (!FMIVisible(view) || [view isKindOfClass:UISearchBar.class] || [view conformsToProtocol:@protocol(UITextInput)]) continue;
        if ([view isKindOfClass:UIScrollView.class]) {
            UIScrollView *scroll = (id)view;
            BOOL vertical = [scroll isKindOfClass:UITableView.class] || scroll.alwaysBounceVertical ||
                scroll.contentSize.height > scroll.bounds.size.height + 1;
            // Horizontal source pickers and the text field's internal scrolling
            // retain their original behavior. No gesture recognizer is added.
            if (vertical && scroll.scrollEnabled) [result addObject:scroll];
        }
        for (UIView *child in view.subviews) if (queue.count < 768) [queue addObject:child];
    }
}

@implementation FMInteractionCoordinator
- (instancetype)init {
    if ((self = [super init])) {
        _registrations = [NSMapTable weakToStrongObjectsMapTable];
        NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
        for (NSString *name in @[UITextFieldTextDidBeginEditingNotification, UITextFieldTextDidEndEditingNotification,
                                UIKeyboardWillShowNotification, UIKeyboardDidHideNotification,
                                UIApplicationDidBecomeActiveNotification, UIApplicationDidEnterBackgroundNotification,
                                UIWindowDidBecomeKeyNotification])
            [center addObserver:self selector:@selector(changed:) name:name object:nil];
    }
    return self;
}
- (void)changed:(NSNotification *)notification { [self schedule]; }
- (void)schedule {
    if (!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(), ^{ [self schedule]; }); return; }
    if (self.queued || self.scanning) return;
    self.queued = YES;
    dispatch_async(dispatch_get_main_queue(), ^{ self.queued = NO; [self scan]; });
}
- (void)scan {
    NSAssert(NSThread.isMainThread, @"UIKit interaction checks run on the main queue");
    if (self.scanning) return;
    self.scanning = YES;
    NSMutableSet<UIScrollView *> *wanted = [NSMutableSet set];
    BOOL editing = NO;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class] || scene.activationState != UISceneActivationStateForegroundActive) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (!window.isKeyWindow || window.hidden || window.windowLevel != UIWindowLevelNormal) continue;
            NSMutableArray<UIViewController *> *controllers = [NSMutableArray array];
            FMIVisibleControllers(window.rootViewController, controllers, 0);
            for (UIViewController *owner in controllers) {
                UISearchController *search = owner.navigationItem.searchController;
                UISearchTextField *field = search.searchBar.searchTextField;
                // UIKit's floating search presentation can move the public
                // searchTextField into a visible container while its UISearchBar
                // has no window. Validate the exact owned editing field instead
                // of assuming it remains a descendant of the bar.
                if (!search.isActive || !field.isFirstResponder || field.window != window || !FMIVisible(field)) continue;
                editing = YES;
                FMICollectResultLists(owner.viewIfLoaded, wanted);
                if (search.isActive) FMICollectResultLists(search.searchResultsController.viewIfLoaded, wanted);
            }
        }
    }
    for (UIScrollView *scroll in self.registrations.keyEnumerator.allObjects) {
        if ([wanted containsObject:scroll]) continue;
        FMSearchScrollRegistration *registration = [self.registrations objectForKey:scroll];
        if (scroll.keyboardDismissMode == UIScrollViewKeyboardDismissModeOnDrag) {
            scroll.keyboardDismissMode = registration.originalMode; self.restorationCount += 1;
        }
        [self.registrations removeObjectForKey:scroll];
    }
    for (UIScrollView *scroll in wanted) {
        if ([self.registrations objectForKey:scroll]) {
            if (scroll.keyboardDismissMode == UIScrollViewKeyboardDismissModeOnDrag) continue;
            [self.registrations removeObjectForKey:scroll];
        }
        // Preserve an existing interactive/on-drag policy supplied by the host.
        if (scroll.keyboardDismissMode != UIScrollViewKeyboardDismissModeNone) continue;
        FMSearchScrollRegistration *registration = [FMSearchScrollRegistration new];
        registration.scroll = scroll; registration.originalMode = scroll.keyboardDismissMode;
        [self.registrations setObject:registration forKey:scroll];
        scroll.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
        self.configurationCount += 1;
    }
    self.editing = editing;
    NSDictionary *snapshot = @{@"editingSearch":@(editing), @"configuredLists":@(self.registrations.count),
        @"configurationCount":@(self.configurationCount), @"restorationCount":@(self.restorationCount)};
    @synchronized (FMInteractionCoordinator.class) { FMInteractionSnapshot = snapshot; }
    self.scanning = NO;
}
@end

static void FMIListLayout(UIScrollView *self, SEL command) {
    FMInteractionOriginalLayout(self, command);
    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    if (FMInteractions.editing && now >= FMInteractions.nextLayoutScan) {
        FMInteractions.nextLayoutScan = now + 0.25; [FMInteractions schedule];
    }
}
static void FMIControllerAppeared(UIViewController *self, SEL command, BOOL animated) {
    FMInteractionOriginalAppear(self, command, animated);
    [FMInteractions schedule];
    // SwiftUI finishes installing the visible navigation item after appearance.
    dispatch_async(dispatch_get_main_queue(), ^{ FMNavigationRefresh(); });
}
static void FMIControllerDisappeared(UIViewController *self, SEL command, BOOL animated) {
    FMInteractionOriginalDisappear(self, command, animated); [FMInteractions schedule];
}
void FMInteractionInstall(void) {
    if (!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(), ^{ FMInteractionInstall(); }); return; }
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        FMInteractions = [FMInteractionCoordinator new];
        Method layout = class_getInstanceMethod(UIScrollView.class, @selector(layoutSubviews));
        FMInteractionOriginalLayout = (void *)method_getImplementation(layout);
        method_setImplementation(layout, (IMP)FMIListLayout);
        Method appeared = class_getInstanceMethod(UIViewController.class, @selector(viewDidAppear:));
        FMInteractionOriginalAppear = (void *)method_getImplementation(appeared);
        method_setImplementation(appeared, (IMP)FMIControllerAppeared);
        Method disappeared = class_getInstanceMethod(UIViewController.class, @selector(viewDidDisappear:));
        FMInteractionOriginalDisappear = (void *)method_getImplementation(disappeared);
        method_setImplementation(disappeared, (IMP)FMIControllerDisappeared);
        [FMInteractions schedule];
    });
}
void FMInteractionRefresh(void) { [FMInteractions schedule]; }
NSDictionary<NSString *, NSNumber *> *FMInteractionDiagnostics(void) {
    @synchronized (FMInteractionCoordinator.class) { return FMInteractionSnapshot ?: @{}; }
}
