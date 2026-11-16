#import "FMNavigation.h"
#import <objc/runtime.h>
#import <Vision/Vision.h>
#import <math.h>

static IMP FMNOriginalSetTabs;
static IMP FMNOriginalSetTabsAnimated;
static dispatch_source_t FMNTimer;
static BOOL FMNInstalled, FMNRefreshing, FMNAttempted, FMNFinished;
static BOOL FMNDiscoverHidden;
static NSTimeInterval FMNStarted, FMNVerifyDeadline;
static __weak UINavigationController *FMNStartupNavigation;
static __weak UIViewController *FMNBeforeActivation;
static __weak UIViewController *FMNObservedLibraryOwner;
static NSString *FMNStartupState = @"pending";
static NSUInteger FMNRecognizedControllers;
static BOOL FMNVisionInFlight;
static NSUInteger FMNVisionRequests, FMNAXCandidates;
static NSTimeInterval FMNLastVision;
static NSString *FMNActivationPath=@"none";
static VNRecognizeTextRequest *FMNActiveVisionRequest;
static BOOL FMNVisionCancelled,FMNVisionLastSucceeded,FMNVisionLastDrawn;
static NSTimeInterval FMNVisionLastDuration,FMNVisionStarted;
static NSInteger FMNVisionLastErrorCode;
static NSString *FMNVisionLastErrorDomain=@"",*FMNLastReject=@"none";
static NSUInteger FMNVisionLastLines,FMNVisionLastMatches,FMNVisionLastMappedCells,FMNVisibleCellCount;
static NSUInteger FMNVisionLastExactTitles,FMNVisionLastNormalizedTitles;
static float FMNVisionLastTitleConfidence;
static NSString *FMNListDelegateClass=@"";
static BOOL FMNShouldSelectImplemented,FMNDidSelectImplemented,FMNPrimaryImplemented,FMNSelectionAllowed,FMNSelectionDelivered,FMNPrimaryDelivered;
static char FMNApplyingKey, FMNProfileItemKey, FMNProfileTargetKey, FMNProfileGroupKey;
static void (^FMNProfileAction)(UIViewController *);
static NSHashTable<UIViewController *> *FMNProfileOwners;

@interface FMNProfileTarget : NSObject
@property(nonatomic,weak) UIViewController *controller;
- (void)open:(id)sender;
@end
@implementation FMNProfileTarget
- (void)open:(id)sender {
    UIViewController *controller=self.controller;
    if(controller && controller.view.window && !controller.presentedViewController && FMNProfileAction)FMNProfileAction(controller);
}
@end

static NSString *FMNText(id value) {
    return [value isKindOfClass:NSString.class] ? [value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] : @"";
}
static BOOL FMNRole(NSString *title,NSString *role) {
    NSDictionary *labels=@{@"home":@[@"首页",@"Home"],@"discover":@[@"发现",@"Discover"],@"library":@[@"资料库",@"Library"],
        @"profile":@[@"我的",@"Me"],@"search":@[@"搜索",@"Search"]};
    NSString *localized=[NSBundle.mainBundle localizedStringForKey:[@"tab." stringByAppendingString:role] value:@"" table:nil];
    return [labels[role] containsObject:FMNText(title)] || (localized.length && [FMNText(title) isEqual:localized]);
}
static BOOL FMNLikesTitle(NSString *title) {
    // The user's native playlist is named 我喜欢; never choose a generic playlist section or arbitrary first row.
    return [@[@"我喜欢",@"我喜欢的音乐"] containsObject:FMNText(title)];
}
static NSString *FMNNormalizedOCRTitle(NSString *title) {
    // Vision can include the List's separate trailing disclosure glyph in a
    // text line, or insert spacing between CJK characters. Keep exact title
    // equality after removing only that presentation whitespace/disclosure.
    NSString *value=[[FMNText(title) componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] componentsJoinedByString:@""];
    NSCharacterSet *disclosure=[NSCharacterSet characterSetWithCharactersInString:@">›❯〉》»"];
    while(value.length&&[disclosure characterIsMember:[value characterAtIndex:value.length-1]])value=[value substringToIndex:value.length-1];
    return value;
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
static UINavigationController *FMNVisibleNavigation(UIViewController *controller,NSUInteger depth) {
    if(!controller || depth>12 || controller.presentedViewController)return nil;
    if([controller isKindOfClass:UINavigationController.class])return (UINavigationController *)controller;
    if([controller isKindOfClass:UITabBarController.class])return FMNVisibleNavigation(((UITabBarController *)controller).selectedViewController,depth+1);
    for(UIViewController *child in controller.childViewControllers) {
        if(!child.isViewLoaded || child.view.hidden || child.view.alpha<0.01)continue;
        UINavigationController *found=FMNVisibleNavigation(child,depth+1); if(found)return found;
    }
    return nil;
}
static NSArray *FMNLikesLinks(UIView *root) {
    NSMutableArray *queue=[NSMutableArray arrayWithObject:@[root,@0]], *matches=NSMutableArray.array;
    NSHashTable *seen=[NSHashTable hashTableWithOptions:NSPointerFunctionsObjectPointerPersonality];
    for(NSUInteger cursor=0;cursor<queue.count && cursor<256;cursor++) {
        id object=queue[cursor][0]; NSUInteger depth=[queue[cursor][1] unsignedIntegerValue];
        if(depth>16 || [seen containsObject:object])continue; [seen addObject:object];
        if([object isKindOfClass:UIView.class]) {
            UIView *view=object;
            if(view.hidden || view.alpha<0.01 || view.accessibilityElementsHidden)continue;
            for(UIView *child in view.subviews)if(queue.count<768)[queue addObject:@[child,@(depth+1)]];
        }
        @try {
            NSString *label=[object respondsToSelector:@selector(accessibilityLabel)]?FMNText([object accessibilityLabel]):@"";
            NSString *first=FMNText([[label componentsSeparatedByCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@",，\n"]] firstObject]);
            UIAccessibilityTraits traits=[object respondsToSelector:@selector(accessibilityTraits)]?[object accessibilityTraits]:UIAccessibilityTraitNone;
            if(FMNLikesTitle(first) && (traits&(UIAccessibilityTraitButton|UIAccessibilityTraitLink)) && !(traits&UIAccessibilityTraitNotEnabled) && [object respondsToSelector:@selector(accessibilityActivate)])[matches addObject:object];
            NSArray *elements=[object respondsToSelector:@selector(accessibilityElements)]?[object accessibilityElements]:nil;
            if([elements isKindOfClass:NSArray.class] && elements.count) {
                for(id item in elements)if(item && queue.count<768)[queue addObject:@[item,@(depth+1)]];
            } else if([object respondsToSelector:@selector(accessibilityElementCount)] && [object respondsToSelector:@selector(accessibilityElementAtIndex:)]) {
                NSInteger count=[object accessibilityElementCount];
                if(count>0 && count!=NSNotFound)for(NSInteger i=0;i<MIN(count,96) && queue.count<768;i++) {
                    id item=[object accessibilityElementAtIndex:i]; if(item)[queue addObject:@[item,@(depth+1)]];
                }
            }
        } @catch(__unused NSException *exception) { }
    }
    return matches;
}
@interface FMNCellTarget : NSObject
@property(nonatomic,weak) UIView *cell;
@property(nonatomic,weak) UIScrollView *list;
@property(nonatomic,copy) NSIndexPath *indexPath;
@property(nonatomic) CGRect frame;
@end
@implementation FMNCellTarget @end

static BOOL FMNVisibleView(UIView *view) {
    if(!view.window || CGRectIsEmpty(view.bounds))return NO;
    for(UIView *parent=view;parent;parent=parent.superview)if(parent.hidden || parent.alpha<0.01)return NO;
    return !CGRectIsEmpty(CGRectIntersection([view convertRect:view.bounds toView:view.window],view.window.bounds));
}
static BOOL FMNCellHasTitle(UIView *cell) {
    NSMutableArray *queue=[NSMutableArray arrayWithObject:cell];
    NSHashTable *seen=[NSHashTable hashTableWithOptions:NSPointerFunctionsObjectPointerPersonality];
    for(NSUInteger i=0;i<queue.count&&i<128;i++) {
        id value=queue[i];if([seen containsObject:value])continue;[seen addObject:value];
        if([value isKindOfClass:UIView.class]) {
            UIView *view=value;if(!FMNVisibleView(view))continue;
            if([view isKindOfClass:UILabel.class]&&FMNLikesTitle(((UILabel *)view).text))return YES;
            if([view isKindOfClass:UIButton.class]&&FMNLikesTitle(((UIButton *)view).currentTitle))return YES;
            if(queue.count<384)[queue addObjectsFromArray:view.subviews];
        }
        @try {
            NSString *label=[value respondsToSelector:@selector(accessibilityLabel)]?FMNText([value accessibilityLabel]):@"";
            NSString *first=FMNText([[label componentsSeparatedByCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@",，\n"]] firstObject]);
            if(FMNLikesTitle(first))return YES;
            NSArray *elements=[value respondsToSelector:@selector(accessibilityElements)]?[value accessibilityElements]:nil;
            if([elements isKindOfClass:NSArray.class]&&queue.count<384)[queue addObjectsFromArray:elements];
        } @catch(__unused NSException *exception) {}
    }
    return NO;
}
static NSArray<FMNCellTarget *> *FMNVisibleCells(UIView *root) {
    NSMutableArray *queue=[NSMutableArray arrayWithObject:root],*targets=NSMutableArray.array;
    for(NSUInteger i=0;i<queue.count&&i<256;i++) {
        UIView *view=queue[i];if(!FMNVisibleView(view))continue;
        NSArray *cells=nil;
        if([view isKindOfClass:UICollectionView.class]&&!((UICollectionView *)view).isEditing)cells=((UICollectionView *)view).visibleCells;
        else if([view isKindOfClass:UITableView.class]&&!((UITableView *)view).isEditing)cells=((UITableView *)view).visibleCells;
        for(UIView *cell in cells) {
            if(!FMNVisibleView(cell))continue;
            CGRect rect=[cell convertRect:cell.bounds toView:root],clipped=CGRectIntersection(rect,root.bounds);
            if(CGRectIsEmpty(clipped)||clipped.size.width*clipped.size.height<rect.size.width*rect.size.height*0.9)continue;
            NSIndexPath *path=[view isKindOfClass:UICollectionView.class]?[(UICollectionView *)view indexPathForCell:(id)cell]:[(UITableView *)view indexPathForCell:(id)cell];
            if(!path)continue;
            FMNCellTarget *target=FMNCellTarget.new;target.cell=cell;target.list=(id)view;target.indexPath=path;target.frame=rect;[targets addObject:target];
        }
        if(!cells && queue.count<768)[queue addObjectsFromArray:view.subviews];
    }
    return targets;
}
static BOOL FMNLibraryStillSelected(UINavigationController *navigation,UIViewController *owner) {
    UIWindow *window=owner.viewIfLoaded.window;
    if(UIApplication.sharedApplication.applicationState!=UIApplicationStateActive||!window.isKeyWindow||window.windowScene.activationState!=UISceneActivationStateForegroundActive)return NO;
    if(navigation.topViewController!=owner || !FMNVisibleView(owner.viewIfLoaded) || owner.presentedViewController || navigation.presentedViewController)return NO;
    for(UIViewController *parent=navigation;parent;parent=parent.parentViewController)if([parent isKindOfClass:UITabBarController.class]) {
        UITabBarController *tabs=(id)parent;NSDictionary *roles=FMNRecognizeTabs(tabs);
        if(@available(iOS 18.0,*))return roles && tabs.selectedTab==roles[@"library"] && FMNVisibleNavigation(tabs.selectedViewController,0)==navigation;
        return NO;
    }
    return NO;
}
static BOOL FMNReject(NSString *reason) { FMNLastReject=reason;return NO; }
static BOOL FMNPerformCellAction(FMNCellTarget *target,UINavigationController *navigation,UIViewController *owner,NSString *path) {
    if(FMNFinished||FMNAttempted||!FMNLibraryStillSelected(navigation,owner)||!FMNVisibleView(target.cell))return FMNReject(@"owner_or_cell_not_current");
    UIView *cell=target.cell;UIScrollView *list=target.list;
    UIWindow *window=cell.window;CGPoint point=[cell convertPoint:CGPointMake(CGRectGetMidX(cell.bounds),CGRectGetMidY(cell.bounds)) toView:window];
    UIView *hit=[window hitTest:point withEvent:nil];if(hit!=cell&&![hit isDescendantOfView:cell])return FMNReject(@"cell_hit_obscured");
    CGRect frame=[cell convertRect:cell.bounds toView:owner.view];
    if(fabs(frame.origin.x-target.frame.origin.x)>2||fabs(frame.origin.y-target.frame.origin.y)>2||fabs(frame.size.width-target.frame.size.width)>2||fabs(frame.size.height-target.frame.size.height)>2)return FMNReject(@"cell_geometry_changed");
    if([list isKindOfClass:UICollectionView.class]) {
        UICollectionView *collection=(id)list;id<UICollectionViewDelegate> delegate=collection.delegate;
        if(collection.isEditing || [collection cellForItemAtIndexPath:target.indexPath]!=cell)return FMNReject(@"collection_cell_changed");
        FMNListDelegateClass=delegate?NSStringFromClass([delegate class]):@"";
        FMNShouldSelectImplemented=[delegate respondsToSelector:@selector(collectionView:shouldSelectItemAtIndexPath:)];
        FMNDidSelectImplemented=[delegate respondsToSelector:@selector(collectionView:didSelectItemAtIndexPath:)];
        FMNPrimaryImplemented=[delegate respondsToSelector:@selector(collectionView:performPrimaryActionForItemAtIndexPath:)];
        FMNSelectionDelivered=NO;FMNPrimaryDelivered=NO;
        if(!FMNDidSelectImplemented&&!FMNPrimaryImplemented)return FMNReject(@"collection_actions_missing");
        for(NSIndexPath *selected in collection.indexPathsForSelectedItems)if(![selected isEqual:target.indexPath])return FMNReject(@"collection_has_other_selection");
        BOOL primaryAllowed=FMNPrimaryImplemented&&(![delegate respondsToSelector:@selector(collectionView:canPerformPrimaryActionForItemAtIndexPath:)]||[delegate collectionView:collection canPerformPrimaryActionForItemAtIndexPath:target.indexPath]);
        FMNSelectionAllowed=collection.allowsSelection&&(!FMNShouldSelectImplemented||[delegate collectionView:collection shouldSelectItemAtIndexPath:target.indexPath]);
        if(!(FMNSelectionAllowed&&FMNDidSelectImplemented)&&!primaryAllowed)return FMNReject(@"collection_actions_denied");
        if(!FMNLibraryStillSelected(navigation,owner)||collection.delegate!=delegate||[collection cellForItemAtIndexPath:target.indexPath]!=cell)return FMNReject(@"collection_changed_during_permission");
        FMNAttempted=YES;FMNActivationPath=FMNSelectionAllowed&&FMNDidSelectImplemented?[path stringByReplacingOccurrencesOfString:@"primary_action_" withString:@"selection_flow_"]:path;FMNStartupState=@"activating_selection_flow";FMNStartupNavigation=navigation;FMNBeforeActivation=owner;FMNVerifyDeadline=NSProcessInfo.processInfo.systemUptime+3;
        // Mirror one public UIKit selection event. SwiftUI's List coordinator
        // can route NavigationLink in didSelect even when primaryAction is a
        // supplied no-op. No delayed second activation/fallback is scheduled.
        if(FMNSelectionAllowed) {
            [collection selectItemAtIndexPath:target.indexPath animated:NO scrollPosition:UICollectionViewScrollPositionNone];
            if(FMNDidSelectImplemented){FMNSelectionDelivered=YES;[delegate collectionView:collection didSelectItemAtIndexPath:target.indexPath];}
        }
        if(primaryAllowed&&navigation.topViewController==owner&&[collection cellForItemAtIndexPath:target.indexPath]==cell){FMNPrimaryDelivered=YES;[delegate collectionView:collection performPrimaryActionForItemAtIndexPath:target.indexPath];}
        FMNLastReject=@"none";return YES;
    }
    if([list isKindOfClass:UITableView.class]) {
        UITableView *table=(id)list;id<UITableViewDelegate> delegate=table.delegate;
        if(table.isEditing || [table cellForRowAtIndexPath:target.indexPath]!=cell)return FMNReject(@"table_cell_changed");
        FMNListDelegateClass=delegate?NSStringFromClass([delegate class]):@"";
        FMNShouldSelectImplemented=[delegate respondsToSelector:@selector(tableView:willSelectRowAtIndexPath:)];
        FMNDidSelectImplemented=[delegate respondsToSelector:@selector(tableView:didSelectRowAtIndexPath:)];
        FMNPrimaryImplemented=[delegate respondsToSelector:@selector(tableView:performPrimaryActionForRowAtIndexPath:)];
        FMNSelectionDelivered=NO;FMNPrimaryDelivered=NO;
        if(!FMNDidSelectImplemented&&!FMNPrimaryImplemented)return FMNReject(@"table_actions_missing");
        for(NSIndexPath *selected in table.indexPathsForSelectedRows)if(![selected isEqual:target.indexPath])return FMNReject(@"table_has_other_selection");
        BOOL primaryAllowed=FMNPrimaryImplemented&&(![delegate respondsToSelector:@selector(tableView:canPerformPrimaryActionForRowAtIndexPath:)]||[delegate tableView:table canPerformPrimaryActionForRowAtIndexPath:target.indexPath]);
        NSIndexPath *allowed=FMNShouldSelectImplemented?[delegate tableView:table willSelectRowAtIndexPath:target.indexPath]:target.indexPath;
        if(allowed&&![allowed isEqual:target.indexPath])return FMNReject(@"table_selection_redirected");
        FMNSelectionAllowed=table.allowsSelection&&allowed!=nil;
        if(!(FMNSelectionAllowed&&FMNDidSelectImplemented)&&!primaryAllowed)return FMNReject(@"table_actions_denied");
        if(!FMNLibraryStillSelected(navigation,owner)||table.delegate!=delegate||[table cellForRowAtIndexPath:target.indexPath]!=cell)return FMNReject(@"table_changed_during_permission");
        FMNAttempted=YES;FMNActivationPath=FMNSelectionAllowed&&FMNDidSelectImplemented?[path stringByReplacingOccurrencesOfString:@"primary_action_" withString:@"selection_flow_"]:path;FMNStartupState=@"activating_selection_flow";FMNStartupNavigation=navigation;FMNBeforeActivation=owner;FMNVerifyDeadline=NSProcessInfo.processInfo.systemUptime+3;
        if(FMNSelectionAllowed) {
            [table selectRowAtIndexPath:target.indexPath animated:NO scrollPosition:UITableViewScrollPositionNone];
            if(FMNDidSelectImplemented){FMNSelectionDelivered=YES;[delegate tableView:table didSelectRowAtIndexPath:target.indexPath];}
        }
        if(primaryAllowed&&navigation.topViewController==owner&&[table cellForRowAtIndexPath:target.indexPath]==cell){FMNPrimaryDelivered=YES;[delegate tableView:table performPrimaryActionForRowAtIndexPath:target.indexPath];}
        FMNLastReject=@"none";return YES;
    }
    return FMNReject(@"list_type_unsupported");
}
static NSData *FMNRGBAPixels(CGImageRef image) {
    if(!image)return nil;size_t width=CGImageGetWidth(image),height=CGImageGetHeight(image);
    if(!width||!height||width>2400||height>2400||width*height>2000000)return nil;
    CGColorSpaceRef space=CGColorSpaceCreateDeviceRGB();
    CGContextRef bitmap=CGBitmapContextCreate(NULL,width,height,8,width*4,space,kCGImageAlphaPremultipliedLast|kCGBitmapByteOrder32Big);CGColorSpaceRelease(space);
    if(!bitmap)return nil;CGContextDrawImage(bitmap,CGRectMake(0,0,width,height),image);
    NSData *pixels=[NSData dataWithBytes:CGBitmapContextGetData(bitmap) length:width*height*4];CGContextRelease(bitmap);return pixels;
}
static BOOL FMNTitlePixelsUnchanged(UIImage *snapshot,UIView *root,CGRect textRect,CGRect originalBounds) {
    if(!CGRectEqualToRect(root.bounds,originalBounds))return NO;
    CGRect crop=CGRectIntegral(CGRectIntersection(CGRectInset(textRect,-2,-2),originalBounds));
    CGFloat scale=snapshot.scale;
    CGRect points=CGRectOffset(crop,-originalBounds.origin.x,-originalBounds.origin.y);
    CGRect pixels=CGRectMake(points.origin.x*scale,points.origin.y*scale,points.size.width*scale,points.size.height*scale);
    CGImageRef oldImage=CGImageCreateWithImageInRect(snapshot.CGImage,pixels);if(!oldImage)return NO;
    NSData *before=FMNRGBAPixels(oldImage);CGImageRelease(oldImage);
    // Use identical full-view rendering geometry before cropping both images.
    // A small renderer with a nonzero bounds origin need not reproduce the
    // exact coordinate system of the original full-view snapshot.
    UIGraphicsImageRendererFormat *format=UIGraphicsImageRendererFormat.defaultFormat;format.scale=scale;format.opaque=YES;
    __block BOOL drawn=NO;
    UIImage *current=[[[UIGraphicsImageRenderer alloc] initWithBounds:originalBounds format:format] imageWithActions:^(UIGraphicsImageRendererContext *context){drawn=[root drawViewHierarchyInRect:originalBounds afterScreenUpdates:NO];}];
    if(!drawn||!current.CGImage)return NO;
    CGImageRef newImage=CGImageCreateWithImageInRect(current.CGImage,pixels);if(!newImage)return NO;
    NSData *after=FMNRGBAPixels(newImage);CGImageRelease(newImage);
    return before.length&&[before isEqual:after];
}
static void FMNRecognizeVisibleTitle(NSArray<FMNCellTarget *> *targets,UINavigationController *navigation,UIViewController *owner) {
    NSTimeInterval now=NSProcessInfo.processInfo.systemUptime;
    if(FMNVisionInFlight||FMNVisionRequests>=5||now-FMNLastVision<1||!targets.count||!FMNLibraryStillSelected(navigation,owner))return;
    UIView *root=owner.view;CGRect bounds=root.bounds;
    if(bounds.size.width<100||bounds.size.height<100||bounds.size.width>2400||bounds.size.height>2400||ceil(bounds.size.width)*ceil(bounds.size.height)>2000000)return;
    UIGraphicsImageRendererFormat *format=UIGraphicsImageRendererFormat.defaultFormat;format.scale=MIN(2,sqrt(1990000.0/(ceil(bounds.size.width)*ceil(bounds.size.height))));format.opaque=YES;
    __block BOOL drawn=NO;
    UIImage *snapshot=[[[UIGraphicsImageRenderer alloc] initWithBounds:bounds format:format] imageWithActions:^(UIGraphicsImageRendererContext *context){drawn=[root drawViewHierarchyInRect:bounds afterScreenUpdates:NO];}];
    FMNVisionLastDrawn=drawn;
    if(!drawn||!snapshot.CGImage||CGImageGetWidth(snapshot.CGImage)*CGImageGetHeight(snapshot.CGImage)>2000000){FMNLastReject=@"snapshot_unavailable";return;}
    NSTimeInterval captured=NSProcessInfo.processInfo.systemUptime;
    FMNVisionStarted=captured;
    FMNVisionInFlight=YES;FMNVisionRequests++;FMNLastVision=now;FMNVisionCancelled=NO;FMNLastReject=@"recognition_pending";
    // The first on-device model load can be slow. Bound the work, then verify
    // the current owner/cell/title pixels again instead of trusting old UI.
    NSTimeInterval budget=FMNVisionRequests==1?20:6;
    VNRecognizeTextRequest *request=VNRecognizeTextRequest.new;request.recognitionLevel=VNRequestTextRecognitionLevelAccurate;
    request.recognitionLanguages=@[@"zh-Hans",@"en-US"];request.usesLanguageCorrection=NO;FMNActiveVisionRequest=request;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(budget*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
        if(FMNActiveVisionRequest==request&&FMNVisionInFlight){FMNVisionCancelled=YES;FMNLastReject=@"recognition_deadline";[request cancel];}
    });
    __weak UINavigationController *weakNavigation=navigation;__weak UIViewController *weakOwner=owner;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{
        NSError *error=nil;VNImageRequestHandler *handler=[[VNImageRequestHandler alloc] initWithCGImage:snapshot.CGImage options:@{}];
        BOOL ok=[handler performRequests:@[request] error:&error];
        NSMutableArray *matches=NSMutableArray.array;NSUInteger exactTitles=0,normalizedTitles=0;float titleConfidence=0;
        if(ok&&!error)for(VNRecognizedTextObservation *observation in request.results) {
            VNRecognizedText *text=[observation topCandidates:1].firstObject;
            BOOL exact=FMNLikesTitle(text.string),normalized=FMNLikesTitle(FMNNormalizedOCRTitle(text.string));
            if(exact)exactTitles++;if(normalized)normalizedTitles++;
            if(normalized)titleConfidence=MAX(titleConfidence,text.confidence);
            if(text.confidence<0.9||!normalized)continue;
            CGRect box=observation.boundingBox;
            CGRect rect=CGRectMake(bounds.origin.x+box.origin.x*bounds.size.width,bounds.origin.y+(1-CGRectGetMaxY(box))*bounds.size.height,box.size.width*bounds.size.width,box.size.height*bounds.size.height);
            [matches addObject:[NSValue valueWithCGRect:rect]];
        }
        dispatch_async(dispatch_get_main_queue(),^{
            if(FMNActiveVisionRequest!=request)return;
            FMNVisionInFlight=NO;FMNActiveVisionRequest=nil;
            FMNVisionLastDuration=NSProcessInfo.processInfo.systemUptime-captured;FMNVisionLastErrorCode=error.code;FMNVisionLastErrorDomain=error.domain?:@"";
            FMNVisionLastSucceeded=ok;FMNVisionLastLines=request.results.count;FMNVisionLastMatches=matches.count;FMNVisionLastMappedCells=0;
            FMNVisionLastExactTitles=exactTitles;FMNVisionLastNormalizedTitles=normalizedTitles;FMNVisionLastTitleConfidence=titleConfidence;
            UINavigationController *currentNavigation=weakNavigation;UIViewController *currentOwner=weakOwner;
            if(FMNVisionCancelled||FMNVisionLastDuration>budget){FMNLastReject=@"recognition_deadline";return;}
            if(!ok||error){FMNLastReject=@"recognition_error";return;}
            if(matches.count!=1){FMNLastReject=@"recognition_no_unique_title";return;}
            if(FMNFinished||FMNAttempted||!FMNLibraryStillSelected(currentNavigation,currentOwner)){FMNLastReject=@"recognition_owner_changed";return;}
            CGRect textRect=[matches[0] CGRectValue];NSMutableArray *candidates=NSMutableArray.array;
            for(FMNCellTarget *target in targets)if(CGRectContainsRect(CGRectInset(target.frame,-1,-1),textRect))[candidates addObject:target];
            FMNVisionLastMappedCells=candidates.count;
            if(candidates.count!=1){FMNLastReject=@"recognition_cell_ambiguous";return;}
            if(!FMNTitlePixelsUnchanged(snapshot,currentOwner.view,textRect,bounds)){FMNLastReject=@"title_pixels_changed";return;}
            FMNPerformCellAction(candidates[0],currentNavigation,currentOwner,@"primary_action_vision");
        });
    });
}
static void FMNFinishStartup(NSString *state) {
    FMNFinished=YES;FMNStartupState=state;
    if(FMNActiveVisionRequest){FMNVisionCancelled=YES;[FMNActiveVisionRequest cancel];}
}
static void FMNProfileEntry(UITabBarController *controller) {
    if(!FMNProfileAction)return;
    NSDictionary *roles=FMNRecognizeTabs(controller); if(!roles)return;
    if(@available(iOS 18.0,*))if(controller.selectedTab!=roles[@"profile"])return;
    UINavigationController *navigation=FMNVisibleNavigation(controller.selectedViewController,0);
    UIViewController *profile=navigation.topViewController;
    if(!profile || !profile.isViewLoaded || !profile.view.window || profile.presentedViewController ||
       !FMNRole(profile.navigationItem.title?:profile.title,@"profile"))return;
    UIBarButtonItem *item=objc_getAssociatedObject(profile,&FMNProfileItemKey);
    if(!item) {
        FMNProfileTarget *target=FMNProfileTarget.new;target.controller=profile;
        item=[[UIBarButtonItem alloc] initWithTitle:@"画像" style:UIBarButtonItemStylePlain target:target action:@selector(open:)];
        item.accessibilityLabel=@"听歌画像";item.accessibilityIdentifier=@"FMX.profileInsights";
        objc_setAssociatedObject(item,&FMNProfileTargetKey,target,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(profile,&FMNProfileItemKey,item,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        UIBarButtonItemGroup *group=[[UIBarButtonItemGroup alloc] initWithBarButtonItems:@[item] representativeItem:nil];
        objc_setAssociatedObject(profile,&FMNProfileGroupKey,group,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if(!FMNProfileOwners)FMNProfileOwners=NSHashTable.weakObjectsHashTable;
        [FMNProfileOwners addObject:profile];
    }
    if(@available(iOS 16.0,*)) {
        NSArray<UIBarButtonItemGroup *> *groups=profile.navigationItem.trailingItemGroups;
        if(groups.count || profile.navigationItem.rightBarButtonItems.count==0) {
            UIBarButtonItemGroup *group=objc_getAssociatedObject(profile,&FMNProfileGroupKey);
            if(![groups containsObject:group])profile.navigationItem.trailingItemGroups=[(groups?:@[]) arrayByAddingObject:group];
            return; // Never overwrite SwiftUI-owned groups with the legacy rightBarButtonItems property.
        }
    }
    NSMutableArray *items=[profile.navigationItem.rightBarButtonItems mutableCopy]?:NSMutableArray.array;
    if(![items containsObject:item]) { [items addObject:item];profile.navigationItem.rightBarButtonItems=items; }
}
void FMNavigationSetProfileAction(void (^action)(UIViewController *)) {
    if(!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(),^{FMNavigationSetProfileAction(action);});return; }
    FMNProfileAction=[action copy];
    if(!action)for(UIViewController *owner in FMNProfileOwners) {
        UIBarButtonItem *item=objc_getAssociatedObject(owner,&FMNProfileItemKey);
        if(@available(iOS 16.0,*)) {
            UIBarButtonItemGroup *group=objc_getAssociatedObject(owner,&FMNProfileGroupKey);
            NSMutableArray *groups=[owner.navigationItem.trailingItemGroups mutableCopy];
            if([groups containsObject:group]) { [groups removeObjectIdenticalTo:group];owner.navigationItem.trailingItemGroups=groups;continue; }
            if(groups.count)continue;
        }
        NSMutableArray *items=[owner.navigationItem.rightBarButtonItems mutableCopy];
        if([items containsObject:item]) { [items removeObjectIdenticalTo:item];owner.navigationItem.rightBarButtonItems=items; }
    }
    FMNavigationRefresh();
}
static void FMNTryStartup(UITabBarController *controller) {
    if(FMNFinished || !controller.view.window || controller.presentedViewController)return;
    NSDictionary *roles=FMNRecognizeTabs(controller); if(!roles)return;
    NSTimeInterval now=NSProcessInfo.processInfo.systemUptime;
    if(FMNStarted==0)FMNStarted=now;
    if(FMNAttempted) {
        UINavigationController *navigation=FMNStartupNavigation;
        UIViewController *top=navigation.topViewController;
        if(top && top!=FMNBeforeActivation && FMNLikesTitle(top.navigationItem.title?:top.title))FMNFinishStartup(@"opened");
        else if(now>=FMNVerifyDeadline)FMNFinishStartup(@"activation_unconfirmed");
        return;
    }
    if(now-FMNStarted>=30) { FMNFinishStartup(@"likes_link_unavailable"); return; }
    if(@available(iOS 18.0,*)) {
        if(controller.selectedTab!=roles[@"library"]) {
            if(now-FMNStarted>=0.75)FMNFinishStartup(@"user_left_library");
            return;
        }
    }
    UINavigationController *navigation=FMNVisibleNavigation(controller.selectedViewController,0);
    UIViewController *top=navigation.topViewController;
    if(FMNObservedLibraryOwner&&top&&top!=FMNObservedLibraryOwner){FMNFinishStartup(@"user_left_library");return;}
    if(!top || !top.isViewLoaded || top.presentedViewController || !FMNRole(top.navigationItem.title?:top.title,@"library"))return;
    FMNObservedLibraryOwner=top;
    NSArray *matches=FMNLikesLinks(top.view);FMNAXCandidates=matches.count;
    NSArray *targets=FMNVisibleCells(top.view);NSMutableArray *labelled=NSMutableArray.array;
    FMNVisibleCellCount=targets.count;
    for(FMNCellTarget *target in targets)if(FMNCellHasTitle(target.cell))[labelled addObject:target];
    if(labelled.count==1&&FMNPerformCellAction(labelled[0],navigation,top,@"primary_action_label"))return;
    if(matches.count!=1) { if(!matches.count&&!labelled.count)FMNRecognizeVisibleTitle(targets,navigation,top);return; }
    FMNActivationPath=@"accessibility";
    FMNAttempted=YES; FMNStartupState=@"activating"; FMNStartupNavigation=navigation; FMNBeforeActivation=top; FMNVerifyDeadline=now+3;
    BOOL accepted=NO;
    @try { accepted=[matches[0] accessibilityActivate]; } @catch(__unused NSException *exception) { }
    if(!accepted)FMNFinishStartup(@"activation_rejected");
}
static void FMNVisit(UIViewController *controller,NSUInteger depth) {
    if(!controller || depth>12)return;
    if(controller.presentedViewController) { FMNVisit(controller.presentedViewController,depth+1);return; }
    if([controller isKindOfClass:UITabBarController.class]) {
        UITabBarController *tabs=(UITabBarController *)controller;
        if(FMNavigationConfigureTabController(tabs)) { FMNRecognizedControllers++; FMNTryStartup(tabs); FMNProfileEntry(tabs); }
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
static void FMNSetTabs(UITabBarController *controller,SEL selector,NSArray *tabs) {
    ((void (*)(id,SEL,id))FMNOriginalSetTabs)(controller,selector,tabs);
    FMNavigationConfigureTabController(controller);
}
static void FMNSetTabsAnimated(UITabBarController *controller,SEL selector,NSArray *tabs,BOOL animated) {
    ((void (*)(id,SEL,id,BOOL))FMNOriginalSetTabsAnimated)(controller,selector,tabs,animated);
    FMNavigationConfigureTabController(controller);
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
    FMNTimer=dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,0,0,dispatch_get_main_queue());
    dispatch_source_set_timer(FMNTimer,dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_MSEC*250),NSEC_PER_MSEC*750,NSEC_PER_MSEC*100);
    dispatch_source_set_event_handler(FMNTimer,^{FMNavigationRefresh();});dispatch_resume(FMNTimer);
}
NSDictionary<NSString *,id> *FMNavigationDiagnostics(void) {
    if(!NSThread.isMainThread) { __block NSDictionary *result;dispatch_sync(dispatch_get_main_queue(),^{result=FMNavigationDiagnostics();});return result; }
    return @{@"installed":@(FMNInstalled),@"discoverHidden":@(FMNDiscoverHidden),@"recognizedChecks":@(FMNRecognizedControllers),
             @"startupState":FMNStartupState,@"activationAttempted":@(FMNAttempted),@"activationPath":FMNActivationPath,
             @"axCandidateCount":@(FMNAXCandidates),@"visionRequests":@(FMNVisionRequests),@"visibleCellCount":@(FMNVisibleCellCount),
             @"visionInFlight":@(FMNVisionInFlight),@"visionCancelled":@(FMNVisionCancelled),@"visionLastSucceeded":@(FMNVisionLastSucceeded),
             @"visionCurrentElapsed":@(FMNVisionInFlight?NSProcessInfo.processInfo.systemUptime-FMNVisionStarted:0),
             @"visionLastDrawSucceeded":@(FMNVisionLastDrawn),@"visionLastDuration":@(FMNVisionLastDuration),@"visionLastErrorCode":@(FMNVisionLastErrorCode),
             @"visionLastErrorDomain":FMNVisionLastErrorDomain,@"visionLastLineCount":@(FMNVisionLastLines),@"visionLastMatchCount":@(FMNVisionLastMatches),
             @"visionLastExactTitleCount":@(FMNVisionLastExactTitles),@"visionLastNormalizedTitleCount":@(FMNVisionLastNormalizedTitles),@"visionLastTitleConfidence":@(FMNVisionLastTitleConfidence),
             @"listDelegateClass":FMNListDelegateClass,@"shouldSelectImplemented":@(FMNShouldSelectImplemented),@"didSelectImplemented":@(FMNDidSelectImplemented),@"primaryActionImplemented":@(FMNPrimaryImplemented),
             @"selectionAllowed":@(FMNSelectionAllowed),@"selectionCallbackDelivered":@(FMNSelectionDelivered),@"primaryActionDelivered":@(FMNPrimaryDelivered),
             @"visionLastMappedCells":@(FMNVisionLastMappedCells),@"lastRejection":FMNLastReject};
}
