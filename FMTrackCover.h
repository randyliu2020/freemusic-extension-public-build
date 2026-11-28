#import <Foundation/Foundation.h>

// LX v2 stores artwork in meta.picUrl, older LX uses img, and FreeMusic uses cover.
// NetEase's original track metadata may instead carry the URL on its album.
static inline NSString *FMValidTrackCover(id candidate, BOOL secureNetEaseCDN) {
    if (![candidate isKindOfClass:NSString.class] || ![candidate length] || [candidate length] > 4096 ||
        [candidate rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound) return nil;
    NSString *text = [candidate hasPrefix:@"//"] ? [@"https:" stringByAppendingString:candidate] : candidate;
    NSURLComponents *parts = [NSURLComponents componentsWithString:text];
    NSString *scheme = parts.scheme.lowercaseString;
    if (!parts.host.length || parts.user != nil || parts.password != nil ||
        !([scheme isEqual:@"https"] || [scheme isEqual:@"http"]) || !parts.URL) return nil;
    if (secureNetEaseCDN && [scheme isEqual:@"http"] && [parts.host.lowercaseString hasSuffix:@".music.126.net"] &&
        (parts.port == nil || parts.port.integerValue == 80)) {
        parts.scheme = @"https";
        parts.port = nil;
        return parts.string;
    }
    return text;
}

static inline NSString *FMTrackCover(NSDictionary *track, NSString *platform, BOOL secureNetEaseCDN) {
    NSDictionary *meta = [track[@"meta"] isKindOfClass:NSDictionary.class] ? track[@"meta"] : @{};
    NSString *modernLX = FMValidTrackCover(meta[@"picUrl"], secureNetEaseCDN);
    if (modernLX) return modernLX;
    for (NSDictionary *container in @[track, meta]) {
        for (NSString *key in @[@"cover", @"img", @"picUrl", @"pic"]) {
            NSString *cover = FMValidTrackCover(container[key], secureNetEaseCDN);
            if (cover) return cover;
        }
    }
    if ([platform isEqual:@"wy"]) {
        for (NSString *key in @[@"al", @"album"]) {
            NSDictionary *album = track[key];
            if (![album isKindOfClass:NSDictionary.class]) continue;
            NSString *cover = FMValidTrackCover(album[@"picUrl"], secureNetEaseCDN);
            if (cover) return cover;
        }
    }
    return nil;
}
