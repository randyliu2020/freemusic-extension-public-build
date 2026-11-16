// Include INSIDE SmokeRunner's natural `run` branch, after loading the extension.
// Independent UIKit + SwiftUI pages; no host binary or user music is executed.
for (NSString *interactionKind in @[@"UIKit", @"SwiftUI"]) {
    [self test:[NSString stringWithFormat:@"v3_%@_real_search_keyboard_policy_and_modal_restoration", interactionKind] body:^NSDictionary *{
        __block UIViewController *originalRoot = nil, *fixture = nil;
        __block NSString *loadFailure = nil;
        __block void *(*factory)(void) = NULL;
        __block int32_t (*setEditing)(void *, int32_t) = NULL;
        __block void (*showSheet)(void *) = NULL;
        __block void *(*copySnapshot)(void *) = NULL;
        __block void (*refresh)(void) = NULL;
        Main(^{
            if (!self.swiftUIFixtureHandle) {
                NSString *path = [NSBundle.mainBundle.privateFrameworksPath stringByAppendingPathComponent:@"SmokeSettingsFixture.dylib"];
                self.swiftUIFixtureHandle = dlopen(path.fileSystemRepresentation, RTLD_NOW | RTLD_GLOBAL);
                if (!self.swiftUIFixtureHandle) { loadFailure = @(dlerror() ?: "SwiftUI fixture load failed"); return; }
            }
            const char *symbol = [interactionKind isEqual:@"UIKit"] ? "FMInteractionMakeKeyboardFixture" : "FMInteractionMakeSwiftUISearchFixture";
            factory = (void *(*)(void))dlsym(self.swiftUIFixtureHandle, symbol);
            setEditing = (int32_t (*)(void *, int32_t))dlsym(self.swiftUIFixtureHandle, "FMInteractionFixtureSetSearchEditing");
            showSheet = (void (*)(void *))dlsym(self.swiftUIFixtureHandle, "FMInteractionFixtureShowTextSheet");
            copySnapshot = (void *(*)(void *))dlsym(self.swiftUIFixtureHandle, "FMInteractionFixtureSnapshot");
            refresh = (void (*)(void))dlsym(self.extensionHandle, "FMInteractionRefresh");
            if (factory && setEditing && showSheet && copySnapshot && refresh) { fixture = CFBridgingRelease(factory()); originalRoot = self.window.rootViewController; self.window.rootViewController = fixture; [self.window makeKeyAndVisible]; }
        });
        Check(!loadFailure && fixture && setEditing && showSheet && copySnapshot && refresh, loadFailure ?: @"Interaction fixture and production entry points load");
        __block NSDictionary *before = nil, *editing = nil, *sheetState = nil, *ended = nil;
        __block NSMutableArray<UIScrollView *> *configured = [NSMutableArray array];
        NSDictionary *(^snapshot)(void) = ^NSDictionary *{ return CFBridgingRelease(copySnapshot((__bridge void *)fixture)); };
        @try {
            Check(Until(^BOOL{before = snapshot(); return fixture.view.window != nil && [before[@"searchControllerCount"] integerValue] > 0;}, 8), @"Actual navigation surface has a public UISearchController");
            // Public UIKit activation is setup, not a synthetic keyboard event or
            // a gesture callback. Retrying only handles initial SwiftUI layout.
            Check(Until(^BOOL{setEditing((__bridge void *)fixture, 1); editing = snapshot(); return [editing[@"editingSearchCount"] integerValue] > 0;}, 6), @"Actual UISearchTextField becomes first responder");
            Main(^{refresh();});
            Check(Until(^BOOL{
                editing = snapshot(); [configured removeAllObjects];
                NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:fixture.view];
                for (NSUInteger index = 0; index < queue.count && index < 1024; ++index) {
                    UIView *view = queue[index];
                    if ([view isKindOfClass:UIScrollView.class] && VisibleInWindow(view)) {
                        UIScrollView *scroll = (id)view;
                        if (scroll.keyboardDismissMode == UIScrollViewKeyboardDismissModeOnDrag &&
                            (scroll.alwaysBounceVertical || scroll.contentSize.height > scroll.bounds.size.height + 1)) [configured addObject:scroll];
                    }
                    for (UIView *child in view.subviews) if (queue.count < 2048) [queue addObject:child];
                }
                return configured.count > 0;
            }, 8), @"Production module enables on-drag dismissal on a real vertical result list");
            if ([interactionKind isEqual:@"UIKit"]) {
                NSDictionary *modes = editing[@"modes"];
                Check([modes[@"smoke.interaction.vertical-results"] integerValue] == UIScrollViewKeyboardDismissModeOnDrag, @"Vertical result list adopts on-drag dismissal");
                Check([modes[@"smoke.interaction.horizontal-results"] integerValue] == UIScrollViewKeyboardDismissModeNone, @"Horizontal source selector is not changed");
                Check([modes[@"smoke.interaction.existing-interactive"] integerValue] == UIScrollViewKeyboardDismissModeInteractive, @"Existing interactive policy is preserved");
            }
            [self screenshot:[NSString stringWithFormat:@"v3-%@-search-keyboard.png", interactionKind.lowercaseString]];
            // First test ordinary end-editing restoration, without any modal.
            Main(^{setEditing((__bridge void *)fixture, 0); refresh();});
            Check(Until(^BOOL{
                ended = snapshot();
                if ([ended[@"editingSearchCount"] integerValue]) return NO;
                for (UIScrollView *scroll in configured) if (scroll.keyboardDismissMode != UIScrollViewKeyboardDismissModeNone) return NO;
                return YES;
            }, 6), @"Ending search editing restores the original no-dismiss policy");
            Check(Until(^BOOL{setEditing((__bridge void *)fixture, 1); return [snapshot()[@"editingSearchCount"] integerValue] > 0;}, 6), @"Search can be activated again");
            Main(^{refresh();});
            Check(Until(^BOOL{
                NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:fixture.view];
                NSMutableArray<UIScrollView *> *current = [NSMutableArray array];
                for (NSUInteger index = 0; index < queue.count && index < 1024; ++index) {
                    UIView *view = queue[index];
                    if ([view isKindOfClass:UIScrollView.class] && VisibleInWindow(view)) {
                        UIScrollView *scroll = (id)view;
                        if (scroll.keyboardDismissMode == UIScrollViewKeyboardDismissModeOnDrag &&
                            (scroll.alwaysBounceVertical || scroll.contentSize.height > scroll.bounds.size.height + 1)) [current addObject:scroll];
                    }
                    for (UIView *child in view.subviews) if (queue.count < 2048) [queue addObject:child];
                }
                if (current.count) { configured = current; return YES; }
                return NO;
            }, 6), @"Repeated search restores drag dismissal even if SwiftUI recreates its list");
            Main(^{showSheet((__bridge void *)fixture); refresh();});
            Check(Until(^BOOL{
                sheetState = snapshot();
                if (!sheetState[@"modes"][@"smoke.interaction.sheet-scroll"]) return NO;
                for (UIScrollView *scroll in configured) if (scroll.keyboardDismissMode != UIScrollViewKeyboardDismissModeNone) return NO;
                return [sheetState[@"modes"][@"smoke.interaction.sheet-scroll"] integerValue] == UIScrollViewKeyboardDismissModeNone;
            }, 6), @"Ordinary text-entry sheet is excluded and obscured search lists are restored");
            [self screenshot:[NSString stringWithFormat:@"v3-%@-ordinary-sheet.png", interactionKind.lowercaseString]];
        } @finally {
            Main(^{if (fixture.presentedViewController) [fixture dismissViewControllerAnimated:NO completion:nil]; self.window.rootViewController = originalRoot; [self.window makeKeyAndVisible]; refresh();});
        }
        return @{@"real_search_controller":@YES, @"real_search_first_responder":@YES,
            @"production_keyboard_policy_and_restoration":@YES, @"real_swiftui":@([interactionKind isEqual:@"SwiftUI"]),
            @"input_setup":@"Public UISearchController activation and UISearchTextField becomeFirstResponder",
            @"physical_drag_validated_in_this_test":@NO, @"physical_drag_test":@"Separate XCTest UI test",
            @"before":before ?: @{}, @"editing":editing ?: @{}, @"ended":ended ?: @{}, @"sheet":sheetState ?: @{},
            @"original_app_code_used":@NO};
    }];
}
