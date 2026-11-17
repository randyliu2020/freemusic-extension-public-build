#import "FMArtworkSelection.h"
#import <dlfcn.h>
#include <stdint.h>

extern int32_t FMArtworkSwiftOwnershipFixture(void);
extern int32_t FMArtworkSwiftLateCompletionFixture(void);
static NSUInteger failures, destroyed;
static NSMutableArray *rows;
static void Check(BOOL passed, NSString *name) {
    [rows addObject:@{@"name":name, @"passed":@(passed)}];
    if (!passed) failures++;
    printf("%s %s\n", passed ? "PASS" : "FAIL", name.UTF8String);
}
@interface FMArtworkLifetimeSentinel : NSObject
@end
@implementation FMArtworkLifetimeSentinel
- (void)dealloc { destroyed++; }
@end

int main(int argc, const char *argv[]) { @autoreleasepool {
    rows = NSMutableArray.array;
    Check(dlsym(RTLD_DEFAULT, "FMXAC") == (void *)&FMXAC, @"native bridge resolves the linked production export");
    int32_t swiftCases = FMArtworkSwiftOwnershipFixture();
    Check(swiftCases == 130, @"real Swift optional strings clear safely with surviving shared copies and repeated nil cleanup");
    int32_t completionCases = FMArtworkSwiftLateCompletionFixture();
    Check(completionCases == 6, @"real delayed callbacks reject old artwork after nil empty or changed URL while accepting the current and shared URL");
    uintptr_t url[2] = {0, 0};
    void *artwork = (__bridge_retained void *)FMArtworkLifetimeSentinel.new;
    __weak id witness = (__bridge id)artwork;
    Check(witness != nil && destroyed == 0, @"authored native artwork slot owns one live Objective-C reference");
    Check(FMXAC(url, &artwork) && artwork == NULL && url[0] == 0 && url[1] == 0,
          @"missing-cover transition clears URL identity and cached artwork storage");
    Check(witness == nil && destroyed == 1, @"original cached artwork retain is released exactly once");
    Check(FMXAC(url, &artwork) && destroyed == 1, @"repeated missing-cover transition does not over-release artwork");
    id shared = FMArtworkLifetimeSentinel.new;
    artwork = (__bridge_retained void *)shared;
    Check(FMXAC(url, &artwork) && shared != nil && destroyed == 1,
          @"clearing native ownership preserves another live artwork owner");
    shared = nil;
    Check(destroyed == 2, @"shared artwork releases exactly after its final remaining owner leaves");
    Check(!FMXAC(NULL, &artwork) && !FMXAC(url, NULL), @"invalid bridge slots fail without touching owned values");
    NSDictionary *report = @{@"passed":@(failures == 0), @"failures":@(failures), @"cases":rows,
        @"evidence":@{@"real_swift_string_cases":@(MAX(0, swiftCases)), @"real_async_cover_scenarios":@(MAX(0, completionCases)), @"objc_deallocations":@(destroyed),
            @"production_export_resolved":@(dlsym(RTLD_DEFAULT, "FMXAC") == (void *)&FMXAC),
            @"external_network_used":@NO, @"original_app_runtime_verified":@NO}};
    if (argc > 1) {
        NSData *json = [NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:NULL];
        if (![json writeToFile:[NSString stringWithUTF8String:argv[1]] atomically:YES]) failures++;
    }
    printf("%s artwork selection ownership tests\n", failures ? "FAILED" : "DONE");
    return failures ? 1 : 0;
}}
