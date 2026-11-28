#import "FMSongMenu.h"
#import <MediaPlayer/MediaPlayer.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

extern void *FMXSongMenuParts(const void *title);
extern void *FMXPlayerMenuIdentity(const void *externalIdentifier);
extern void FMXClearSongCache(NSString *server, NSString *trackID);

static UIActionIdentifier const FMClearActionID = @"FreeMusic.FMX.ClearSongCache";
static _Thread_local BOOL FMUpdatingSongMenu;

static UIAction *FMClearAction(NSString *server, NSString *identifier) {
    return [UIAction actionWithTitle:@"清除缓存" image:[UIImage systemImageNamed:@"arrow.counterclockwise"]
                          identifier:FMClearActionID handler:^(__unused UIAction *sender) {
        FMXClearSongCache(server, identifier);
    }];
}

static UIDeferredMenuElement *FMPlayerClearAction(void) {
    return [UIDeferredMenuElement elementWithUncachedProvider:^(void (^completion)(NSArray<UIMenuElement *> *)) {
        id external = MPNowPlayingInfoCenter.defaultCenter.nowPlayingInfo[MPNowPlayingInfoPropertyExternalContentIdentifier];
        NSArray<NSString *> *pair = [external isKindOfClass:NSString.class] ?
            CFBridgingRelease(FMXPlayerMenuIdentity((__bridge const void *)external)) : nil;
        completion(pair ? @[FMClearAction(pair[0], pair[1])] : @[]);
    }];
}

static NSArray<UIMenuElement *> *FMDecorateChildren(NSArray<UIMenuElement *> *original) {
    UIAction *marker = nil;
    NSArray<NSString *> *identity = nil;
    BOOL installed = NO;
    for (UIMenuElement *element in original) {
        if (![element isKindOfClass:UIAction.class]) continue;
        UIAction *action = (UIAction *)element;
        if ([action.identifier isEqualToString:FMClearActionID]) installed = YES;
        if ([action.title rangeOfString:@"\u2063" options:NSLiteralSearch].location == NSNotFound) continue;
        NSArray *parts = CFBridgingRelease(FMXSongMenuParts((__bridge const void *)action.title));
        if (!parts) continue;
        // If a host ever combines several songs in one menu, no action may
        // target a guessed row. Each independent nested menu is handled below.
        if (marker) return original;
        marker = action;
        identity = parts;
    }
    NSMutableArray *children = nil;
    for (NSUInteger i = 0; i < original.count; i++) {
        UIMenuElement *element = original[i];
        if ([element isKindOfClass:UIMenu.class]) {
            UIMenu *child = (UIMenu *)element;
            NSArray *oldChildren = child.children;
            NSArray *updated = FMDecorateChildren(oldChildren);
            if (updated != oldChildren) {
                if (!children) children = original.mutableCopy;
                children[i] = [child menuByReplacingChildren:updated];
            }
        } else if (element == marker) {
            UIAction *clean = [marker copy];
            clean.title = identity[0];
            if (!children) children = original.mutableCopy;
            children[i] = clean;
        }
    }
    if (marker && !installed) {
        if (identity[1].length) [children addObject:FMClearAction(identity[1], identity[2])];
        else [children addObject:FMPlayerClearAction()];
    }
    return children ?: original;
}

static UIMenu *FMDecorate(UIMenu *menu) {
    if (!menu || FMUpdatingSongMenu) return menu;
    FMUpdatingSongMenu = YES;
    @try {
        NSArray *old = menu.children, *modified = FMDecorateChildren(old);
        return modified == old ? menu : [menu menuByReplacingChildren:modified];
    } @finally { FMUpdatingSongMenu = NO; }
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
