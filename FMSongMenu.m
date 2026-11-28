#import "FMSongMenu.h"
#import <MediaPlayer/MediaPlayer.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <stdatomic.h>

extern void *FMXSongMenuParts(const void *title);
extern void *FMXPlayerMenuIdentity(const void *externalIdentifier);
extern void FMXClearSongCache(NSString *server, NSString *trackID);

static UIActionIdentifier const FMClearActionID = @"FreeMusic.FMX.ClearSongCache";
static _Thread_local BOOL FMUpdatingSongMenu;
static NSArray *(*FMOriginalChildren)(UIMenu *, SEL);
static char FMChildrenKey, FMPlayerPlaceholderKey;

#if TARGET_OS_SIMULATOR && defined(FMX_PLAYBACK_CACHE_TESTING)
static void FMMenuTrace(NSString *phase, NSArray<UIMenuElement *> *children) {
    static _Atomic(unsigned int) events;
    if (atomic_fetch_add(&events, 1) >= 320) return;
    NSMutableArray *types = [NSMutableArray array];
    for (UIMenuElement *child in children) {
        BOOL marked = [child.title rangeOfString:@"\u2063" options:NSLiteralSearch].location != NSNotFound;
        [types addObject:[NSString stringWithFormat:@"%@%@", NSStringFromClass([child class]), marked ? @"*" : @""]];
    }
    NSLog(@"FMXSongMenu %@ %@", phase, [types componentsJoinedByString:@","]);
}
#else
#define FMMenuTrace(phase, children) ((void)0)
#endif

static NSArray *FMRawChildren(UIMenu *menu) {
    return FMOriginalChildren ? FMOriginalChildren(menu, @selector(children)) : menu.children;
}

static UIAction *FMClearAction(NSString *server, NSString *identifier) {
    return [UIAction actionWithTitle:@"清除缓存" image:[UIImage systemImageNamed:@"arrow.counterclockwise"]
                          identifier:FMClearActionID handler:^(__unused UIAction *sender) {
        FMXClearSongCache(server, identifier);
    }];
}

static UIAction *FMCurrentPlayerAction(void) {
    id external = MPNowPlayingInfoCenter.defaultCenter.nowPlayingInfo[MPNowPlayingInfoPropertyExternalContentIdentifier];
    NSArray<NSString *> *pair = [external isKindOfClass:NSString.class] ?
        CFBridgingRelease(FMXPlayerMenuIdentity((__bridge const void *)external)) : nil;
    FMMenuTrace(pair ? @"player-identified" : @"player-unidentified", @[]);
    return pair ? FMClearAction(pair[0], pair[1]) : nil;
}

static UIDeferredMenuElement *FMPlayerClearAction(void) {
    UIDeferredMenuElement *element = [UIDeferredMenuElement elementWithUncachedProvider:^(void (^completion)(NSArray<UIMenuElement *> *)) {
        UIAction *action = FMCurrentPlayerAction();
        completion(action ? @[action] : @[]);
    }];
    objc_setAssociatedObject(element, &FMPlayerPlaceholderKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return element;
}

static NSArray<UIMenuElement *> *FMDecorateChildren(NSArray<UIMenuElement *> *original, BOOL presenting) {
    UIMenuElement *marker = nil;
    NSArray<NSString *> *identity = nil;
    BOOL installed = NO;
    for (UIMenuElement *element in original) {
        BOOL action = [element isKindOfClass:UIAction.class];
        if (!action && ![element isKindOfClass:UICommand.class]) continue;
        if (action && [((UIAction *)element).identifier isEqualToString:FMClearActionID]) installed = YES;
        if (!element.title.length || [element.title rangeOfString:@"\u2063" options:NSLiteralSearch].location == NSNotFound) continue;
        NSArray *parts = CFBridgingRelease(FMXSongMenuParts((__bridge const void *)element.title));
        if (!parts) continue;
        // If a host ever combines several songs in one menu, no action may
        // target a guessed row. Each independent nested menu is handled below.
        if (marker) return original;
        marker = element;
        identity = parts;
    }
    NSMutableArray *children = nil;
    for (NSUInteger i = 0; i < original.count; i++) {
        UIMenuElement *element = original[i];
        if ([element isKindOfClass:UIMenu.class]) {
            UIMenu *child = (UIMenu *)element;
            NSArray *oldChildren = FMRawChildren(child);
            NSArray *updated = FMDecorateChildren(oldChildren, presenting);
            if (updated != oldChildren) {
                if (!children) children = original.mutableCopy;
                children[i] = [child menuByReplacingChildren:updated];
            }
        } else if (element == marker) {
            UIMenuElement *clean = [marker copy];
            if ([clean isKindOfClass:UIAction.class]) ((UIAction *)clean).title = identity[0];
            else ((UICommand *)clean).title = identity[0];
            if (!children) children = original.mutableCopy;
            children[i] = clean;
        }
    }
    if (marker && !installed) {
        FMMenuTrace(presenting ? @"resolved-marker" : @"prepared-marker", @[marker]);
        if (identity[1].length) [children addObject:FMClearAction(identity[1], identity[2])];
        else if (presenting) {
            UIAction *action = FMCurrentPlayerAction();
            if (action) [children addObject:action];
        } else [children addObject:FMPlayerClearAction()];
    }
    if (presenting) {
        // UIKit does not have to traverse a second deferred placeholder when
        // one already-resolved array is delivered by SwiftUI's provider.
        for (NSInteger i = (NSInteger)original.count - 1; i >= 0; i--) {
            if (!objc_getAssociatedObject(original[i], &FMPlayerPlaceholderKey)) continue;
            if (!children) children = original.mutableCopy;
            UIAction *action = FMCurrentPlayerAction();
            if (action) children[i] = action;
            else [children removeObjectAtIndex:i];
        }
    }
    return children ?: original;
}

static NSArray *FMUpdateChildren(NSArray *original, BOOL presenting) {
    if (!original.count || FMUpdatingSongMenu) return original;
    FMUpdatingSongMenu = YES;
    @try { return FMDecorateChildren(original, presenting); }
    @finally { FMUpdatingSongMenu = NO; }
}

static UIMenu *FMDecorate(UIMenu *menu) {
    if (!menu || FMUpdatingSongMenu) return menu;
    FMUpdatingSongMenu = YES;
    @try {
        NSArray *old = FMRawChildren(menu), *modified = FMDecorateChildren(old, NO);
        return modified == old ? menu : [menu menuByReplacingChildren:modified];
    } @finally { FMUpdatingSongMenu = NO; }
}

// SwiftUI can produce its final actions after the menu container has already
// been created. Transform the elements delivered by that provider, and cover
// menus which update their immutable children through the public copy API.
typedef void (^FMMenuCompletion)(NSArray<UIMenuElement *> *);
typedef void (^FMMenuProvider)(FMMenuCompletion);
static FMMenuProvider FMProvider(FMMenuProvider provider, BOOL uncached) {
    if (!provider) return nil;
    return ^(FMMenuCompletion completion) {
        provider(^(NSArray<UIMenuElement *> *children) {
            FMMenuTrace(@"deferred", children);
            completion(FMUpdateChildren(children, uncached));
        });
    };
}
static UIDeferredMenuElement *(*FMOriginalDeferred)(id, SEL, FMMenuProvider);
static UIDeferredMenuElement *FMDeferred(id cls, SEL sel, FMMenuProvider provider) {
    return FMOriginalDeferred(cls, sel, FMProvider(provider, NO));
}
static UIDeferredMenuElement *(*FMOriginalUncached)(id, SEL, FMMenuProvider);
static UIDeferredMenuElement *FMUncached(id cls, SEL sel, FMMenuProvider provider) {
    return FMOriginalUncached(cls, sel, FMProvider(provider, YES));
}
static UIMenu *(*FMOriginalReplace)(UIMenu *, SEL, NSArray *);
static UIMenu *FMReplace(UIMenu *menu, SEL sel, NSArray *children) {
    FMMenuTrace(@"replacement", children);
    return FMOriginalReplace(menu, sel, FMUpdateChildren(children, NO));
}
static NSArray *FMChildren(UIMenu *menu, SEL sel) {
    NSArray *original = FMOriginalChildren(menu, sel);
    if (FMUpdatingSongMenu || !original.count) return original;
    NSArray *cached = objc_getAssociatedObject(menu, &FMChildrenKey);
    if (cached) return cached;
    FMMenuTrace(@"children", original);
    NSArray *updated = FMUpdateChildren(original, NO);
    if (updated != original) objc_setAssociatedObject(menu, &FMChildrenKey, updated, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return updated;
}

static void (*FMOriginalSetMenu)(UIButton *, SEL, UIMenu *);
static void FMButtonMenu(UIButton *button, SEL sel, UIMenu *menu) {
    FMOriginalSetMenu(button, sel, FMDecorate(menu));
}

static UIContextMenuConfiguration *(*FMOriginalConfiguration)(id, SEL, id<NSCopying>,
        UIContextMenuContentPreviewProvider, UIContextMenuActionProvider);
static UIContextMenuConfiguration *FMConfiguration(id cls, SEL sel, id<NSCopying> identifier,
        UIContextMenuContentPreviewProvider preview, UIContextMenuActionProvider provider) {
    if (!provider) return FMOriginalConfiguration(cls, sel, identifier, preview, nil);
    return FMOriginalConfiguration(cls, sel, identifier, preview, ^UIMenu *(NSArray<UIMenuElement *> *suggested) {
        return FMDecorate(provider(suggested));
    });
}

// SwiftUI also builds menus through UIMenu's public constructors, including
// menus attached to a control before it is added to a window.
static UIMenu *(*FMOriginalFullMenu)(id, SEL, NSString *, UIImage *, UIMenuIdentifier, UIMenuOptions, NSArray *);
static UIMenu *FMFullMenu(id cls, SEL sel, NSString *title, UIImage *image, UIMenuIdentifier identifier,
                          UIMenuOptions options, NSArray *children) {
    return FMDecorate(FMOriginalFullMenu(cls, sel, title, image, identifier, options, children));
}
static UIMenu *(*FMOriginalMenuWithSize)(id, SEL, NSString *, UIImage *, UIMenuIdentifier, UIMenuOptions, UIMenuElementSize, NSArray *);
static UIMenu *FMMenuWithSize(id cls, SEL sel, NSString *title, UIImage *image, UIMenuIdentifier identifier,
                              UIMenuOptions options, UIMenuElementSize size, NSArray *children) {
    return FMDecorate(FMOriginalMenuWithSize(cls, sel, title, image, identifier, options, size, children));
}
static UIMenu *(*FMOriginalSimpleMenu)(id, SEL, NSString *, NSArray *);
static UIMenu *FMSimpleMenu(id cls, SEL sel, NSString *title, NSArray *children) {
    return FMDecorate(FMOriginalSimpleMenu(cls, sel, title, children));
}

void FMSongMenuInstall(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        FMMenuTrace(@"installed", @[]);
        Method children = class_getInstanceMethod(UIMenu.class, @selector(children));
        if (children) FMOriginalChildren = (void *)method_setImplementation(children, (IMP)FMChildren);
        Method replace = class_getInstanceMethod(UIMenu.class, @selector(menuByReplacingChildren:));
        if (replace) FMOriginalReplace = (void *)method_setImplementation(replace, (IMP)FMReplace);
        Method deferred = class_getClassMethod(UIDeferredMenuElement.class, @selector(elementWithProvider:));
        if (deferred) FMOriginalDeferred = (void *)method_setImplementation(deferred, (IMP)FMDeferred);
        Method uncached = class_getClassMethod(UIDeferredMenuElement.class, @selector(elementWithUncachedProvider:));
        if (uncached) FMOriginalUncached = (void *)method_setImplementation(uncached, (IMP)FMUncached);
        Method setMenu = class_getInstanceMethod(UIButton.class, @selector(setMenu:));
        if (setMenu) FMOriginalSetMenu = (void *)method_setImplementation(setMenu, (IMP)FMButtonMenu);
        Method config = class_getClassMethod(UIContextMenuConfiguration.class, @selector(configurationWithIdentifier:previewProvider:actionProvider:));
        if (config) FMOriginalConfiguration = (void *)method_setImplementation(config, (IMP)FMConfiguration);
        Method full = class_getClassMethod(UIMenu.class, @selector(menuWithTitle:image:identifier:options:children:));
        if (full) FMOriginalFullMenu = (void *)method_setImplementation(full, (IMP)FMFullMenu);
        Method sized = class_getClassMethod(UIMenu.class, @selector(menuWithTitle:image:identifier:options:preferredElementSize:children:));
        if (sized) FMOriginalMenuWithSize = (void *)method_setImplementation(sized, (IMP)FMMenuWithSize);
        Method simple = class_getClassMethod(UIMenu.class, @selector(menuWithTitle:children:));
        if (simple) FMOriginalSimpleMenu = (void *)method_setImplementation(simple, (IMP)FMSimpleMenu);
    });
}
