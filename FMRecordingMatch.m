#import "FMRecordingMatch.h"
#import "FMDownloadFiles.h"
#import <math.h>

static NSString *FMRecordingText(id raw) {
    if (![raw isKindOfClass:NSString.class] || [raw length] > 2048) return nil;
    static NSLocale *locale;
    static NSSet *placeholders;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        placeholders = [NSSet setWithArray:@[@"unknown", @"unknown artist", @"unknown album", @"未知", @"未知歌手", @"未知专辑", @"-"]];
    });
    NSString *value = [[raw precomposedStringWithCompatibilityMapping] lowercaseStringWithLocale:locale];
    value = [value stringByReplacingOccurrencesOfString:@"’" withString:@"'"];
    NSArray *pieces = [value componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSMutableArray *words = [NSMutableArray arrayWithCapacity:pieces.count];
    for (NSString *piece in pieces) if (piece.length) [words addObject:piece];
    NSString *result = [words componentsJoinedByString:@" "];
    return result.length && ![placeholders containsObject:result] ? result : nil;
}

static NSString *FMRecordingISRC(id raw) {
    if (![raw isKindOfClass:NSString.class] || [raw length] > 20) return nil;
    NSString *value = [[raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] uppercaseString];
    static NSRegularExpression *format;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        format = [NSRegularExpression regularExpressionWithPattern:@"^(?:[A-Z]{2}[A-Z0-9]{3}[0-9]{7}|[A-Z]{2}-[A-Z0-9]{3}-[0-9]{2}-[0-9]{5})$" options:0 error:nil];
    });
    if (![format firstMatchInString:value options:0 range:NSMakeRange(0,value.length)]) return nil;
    return [value stringByReplacingOccurrencesOfString:@"-" withString:@""];
}

static NSSet *FMRecordingArtists(id credits) {
    NSArray *raw = [credits isKindOfClass:NSArray.class] ? credits : (credits ? @[credits] : @[]);
    if (!raw.count || raw.count > 32) return nil;
    NSMutableSet *artists = [NSMutableSet set];
    for (id credit in raw) {
        NSString *name = FMRecordingText(credit);
        if (!name) return nil;
        // Whitespace around a slash distinguishes a separator from a band like AC/DC.
        name = [name stringByReplacingOccurrencesOfString:@" / " withString:@"、"];
        for (NSString *part in [name componentsSeparatedByCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"、,;"]]) {
            NSString *artist = FMRecordingText(part);
            if (!artist) return nil;
            [artists addObject:artist];
        }
    }
    return artists.copy;
}

static double FMRecordingDuration(NSDictionary *track) {
    id duration = track[@"duration"];
    if ([duration isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)duration) != CFBooleanGetTypeID()) {
        double seconds = [duration doubleValue];
        if (isfinite(seconds) && seconds > 0 && seconds <= 604800) return seconds;
    }
    NSString *interval = track[@"interval"];
    if (![interval isKindOfClass:NSString.class] || interval.length > 12) return 0;
    NSArray *parts = [interval componentsSeparatedByString:@":"];
    if (parts.count < 2 || parts.count > 3) return 0;
    NSCharacterSet *nonDigits = [NSCharacterSet characterSetWithCharactersInString:@"0123456789"].invertedSet;
    NSUInteger total = 0;
    for (NSUInteger i=0; i<parts.count; i++) {
        NSString *part = parts[i];
        if (!part.length || part.length > 5 || [part rangeOfCharacterFromSet:nonDigits].location != NSNotFound) return 0;
        NSUInteger value = part.integerValue;
        if (i && (part.length != 2 || value >= 60)) return 0;
        total = total*60 + value;
    }
    return total <= 604800 ? total : 0;
}

NSDictionary *FMConfirmedLocalRecording(NSDictionary *request, NSArray<NSDictionary *> *registeredRows) {
    NSString *platform = FMDASource(request[@"server"]);
    if (!platform || !FMDAIdentifier(request[@"id"])) return nil;
    NSString *code = FMRecordingISRC(request[@"isrc"]);
    NSString *title = FMRecordingText(request[@"title"]);
    NSString *album = FMRecordingText(request[@"album"] ?: request[@"albumName"]);
    NSSet *artists = FMRecordingArtists(request[@"singer"] ?: request[@"artist"]);
    double seconds = FMRecordingDuration(request);
    BOOL hasMetadata = title && album && artists.count && seconds > 0;
    if (!code && !hasMetadata) return nil;
    NSDictionary *best = nil;
    NSUInteger bestRank = 0, bestCount = 0;
    for (id row in registeredRows) {
        if (![row isKindOfClass:NSDictionary.class]) continue;
        NSString *other = FMDASource(row[@"server"]);
        if (!other || [platform isEqual:other] || !FMDAIdentifier(row[@"id"])) continue;
        NSString *otherCode = code ? FMRecordingISRC(row[@"isrc"]) : nil;
        NSUInteger rank = 0;
        if (code && otherCode) {
            if (![code isEqual:otherCode]) continue;
            rank = 2;
        } else if (hasMetadata && [title isEqual:FMRecordingText(row[@"title"])] &&
                   [album isEqual:FMRecordingText(row[@"album"] ?: row[@"albumName"])] &&
                   [artists isEqual:FMRecordingArtists(row[@"singer"] ?: row[@"artist"])]) {
            double otherSeconds = FMRecordingDuration(row);
            if (otherSeconds <= 0 || fabs(seconds - otherSeconds) > 2.0) continue;
            rank = 1;
        }
        if (!rank || rank < bestRank) continue;
        if (rank > bestRank) {
            bestRank = rank;
            best = row;
            bestCount = 0;
        }
        bestCount++;
    }
    return bestCount == 1 ? best : nil;
}
