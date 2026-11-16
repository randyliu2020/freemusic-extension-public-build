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
        NSArray<UIScrollView *> *(^configuredLists)(void) = ^NSArray<UIScrollView *> *{
            // Presentation may reparent a child controller's view outside the
            // navigation controller's view. Query the fixture's owned surfaces,
            // not only fixture.view; still require an actually visible list.
            NSMutableArray<UIViewController *> *owners = [NSMutableArray arrayWithObject:fixture];
            NSMutableArray<UIView *> *queue = [NSMutableArray array];
            NSMutableSet *seenOwners = [NSMutableSet set], *seenViews = [NSMutableSet set];
            for (NSUInteger index = 0; index < owners.count && index < 64; ++index) {
                UIViewController *owner = owners[index];
                if ([seenOwners containsObject:owner]) continue;
                [seenOwners addObject:owner];
                if (owner.viewIfLoaded) [queue addObject:owner.viewIfLoaded];
                [owners addObjectsFromArray:owner.childViewControllers];
                if (owner.presentedViewController) [owners addObject:owner.presentedViewController];
                UIViewController *results = owner.navigationItem.searchController.searchResultsController;
                if (results) [owners addObject:results];
            }
            NSMutableArray<UIScrollView *> *result = [NSMutableArray array];
            for (NSUInteger index = 0; index < queue.count && index < 1024; ++index) {
                UIView *view = queue[index];
                if ([seenViews containsObject:view]) continue;
                [seenViews addObject:view];
                if ([view isKindOfClass:UIScrollView.class] && VisibleInWindow(view)) {
                    UIScrollView *scroll = (id)view;
                    if (scroll.scrollEnabled && scroll.keyboardDismissMode == UIScrollViewKeyboardDismissModeOnDrag &&
                        scroll.contentSize.height > scroll.bounds.size.height + 1) [result addObject:scroll];
                }
                for (UIView *child in view.subviews) if (queue.count < 2048) [queue addObject:child];
            }
            return result;
        };
        @try {
            Check(Until(^BOOL{before = snapshot(); return fixture.view.window != nil && [before[@"searchControllerCount"] integerValue] > 0;}, 8), @"Actual navigation surface has a public UISearchController");
            // Public UIKit activation is setup, not a synthetic keyboard event or
            // a gesture callback. Retrying only handles initial SwiftUI layout.
            Check(Until(^BOOL{setEditing((__bridge void *)fixture, 1); editing = snapshot(); return [editing[@"editingSearchCount"] integerValue] > 0;}, 6), @"Actual UISearchTextField becomes first responder");
            Main(^{refresh();});
            BOOL configuredBeforeDeadline = Until(^BOOL{
                editing = snapshot(); configured = [configuredLists() mutableCopy];
                return configured.count > 0;
            }, 8);
            // Persist evidence before the assertion so a failure cannot discard
            // the actual modes, responder state and presentation hierarchy.
            Main(^{
                NSDictionary *(*diagnostics)(void) = (void *)dlsym(self.extensionHandle, "FMInteractionDiagnostics");
                NSMutableArray *owners = [NSMutableArray arrayWithObject:fixture], *relations = [NSMutableArray array];
                NSMutableSet *seen = [NSMutableSet set];
                for (NSUInteger index = 0; index < owners.count && index < 64; ++index) {
                    UIViewController *owner = owners[index];
                    if ([seen containsObject:owner]) continue;
                    [seen addObject:owner];
                    UISearchController *search = owner.navigationItem.searchController;
                    NSMutableDictionary *row = [@{@"class":NSStringFromClass(owner.class),
                        @"visible":@(VisibleInWindow(owner.viewIfLoaded)),
                        @"view_inside_root_view":@([owner.viewIfLoaded isDescendantOfView:fixture.view]),
                        @"presented_class":owner.presentedViewController ? NSStringFromClass(owner.presentedViewController.class) : @""} mutableCopy];
                    if (search) [row addEntriesFromDictionary:@{@"search_active":@(search.active),
                        @"search_editing":@(search.searchBar.searchTextField.isFirstResponder),
                        @"search_in_host_window":@(search.searchBar.window == self.window),
                        @"search_presenting":@(search.isBeingPresented)}];
                    if ([owner isKindOfClass:UINavigationController.class]) {
                        UINavigationController *nav = (id)owner;
                        row[@"nav_visible_is_top"] = @(nav.visibleViewController == nav.topViewController);
                        row[@"nav_visible_is_owned_search"] = @(nav.visibleViewController == nav.topViewController.navigationItem.searchController);
                    }
                    [relations addObject:row]; [owners addObjectsFromArray:owner.childViewControllers];
                    if (owner.presentedViewController) [owners addObject:owner.presentedViewController];
                }
                NSDictionary *evidence = @{@"fixture":snapshot(), @"production":diagnostics ? diagnostics() : @{},
                    @"visible_configured_lists":@(configured.count), @"controller_relations":relations};
                NSString *name = [NSString stringWithFormat:@"v3-%@-search-policy.json", interactionKind.lowercaseString];
                [[NSJSONSerialization dataWithJSONObject:evidence options:NSJSONWritingPrettyPrinted error:nil] writeToURL:[self.output URLByAppendingPathComponent:name] atomically:YES];
            });
            [self captureSurfaceDiagnostics:[NSString stringWithFormat:@"v3-%@-search-editing", interactionKind.lowercaseString]];
            Check(configuredBeforeDeadline, @"Production module enables on-drag dismissal on a real vertical result list");
            if ([interactionKind isEqual:@"UIKit"]) {
                NSDictionary *modes = editing[@"modes"];
                BOOL originalResultsVisible = NO;
                for (UIScrollView *scroll in configured) if ([scroll.accessibilityIdentifier isEqual:@"smoke.interaction.vertical-results"]) originalResultsVisible = YES;
                Check(originalResultsVisible, @"The configured UIKit result list belongs to the current fixture, is visible and has scrollable vertical content");
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
                NSArray<UIScrollView *> *current = configuredLists();
                if (current.count) { configured = [current mutableCopy]; return YES; }
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
