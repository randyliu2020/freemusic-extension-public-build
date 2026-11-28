#pragma once
#import <Foundation/Foundation.h>
#import <sys/stat.h>
#import <unistd.h>

static inline BOOL FMDARegular(NSURL *url, struct stat *result) {
    struct stat s;
    if (!url.isFileURL || lstat(url.fileSystemRepresentation, &s) || !S_ISREG(s.st_mode) || s.st_size <= 0) return NO;
    if (result) *result = s;
    return YES;
}
static inline BOOL FMDASameFile(struct stat a, struct stat b) {
    return a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_size == b.st_size &&
        a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec;
}
static inline BOOL FMDADirectory(NSURL *url) {
    struct stat s;
    return url.isFileURL && !lstat(url.fileSystemRepresentation,&s) && S_ISDIR(s.st_mode);
}
static inline NSString *FMDAIdentifier(id value) {
    if ([value isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)value) != CFBooleanGetTypeID()) value=[value stringValue];
    if (![value isKindOfClass:NSString.class] || ![value length] || [value length] > 220) return nil;
    static NSCharacterSet *invalid;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        invalid=[[NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-."]
                 invertedSet];
    });
    return [value rangeOfCharacterFromSet:invalid].location == NSNotFound ? value : nil;
}
static inline NSString *FMDASource(id server) {
    if (![server isKindOfClass:NSString.class]) return nil;
    return @{@"wy":@"wy", @"netease":@"wy", @"qq":@"tx", @"tx":@"tx", @"kg":@"kg", @"kugou":@"kg",
             @"kw":@"kw", @"kuwo":@"kw", @"mg":@"mg", @"migu":@"mg", @"qs":@"qishui", @"qishui":@"qishui"}[server];
}
static inline BOOL FMDownloadHash(NSString *server, NSString *identifier) {
    if (![server isEqual:@"kg"] || identifier.length != 32) return NO;
    static NSCharacterSet *invalid;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        invalid = [NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdefABCDEF"].invertedSet;
    });
    return [identifier rangeOfCharacterFromSet:invalid].location == NSNotFound;
}

static inline NSString *FMDownloadLookupID(NSString *server, id value) {
    NSString *identifier = FMDAIdentifier(value);
    return FMDownloadHash(server,identifier) ? identifier.uppercaseString : identifier;
}

// Track has a separate optional song_id (the original playlist APIs call it
// song_id as well). A visible row ID or record_id alone is not a substitute.
static inline NSString *FMDownloadRowAlias(NSDictionary *row, NSString *platform) {
    NSString *alias = FMDAIdentifier(row[@"song_id"]);
    if (!alias) return nil;
    id code = row[@"platform"];
    if (code && code != NSNull.null) {
        NSDictionary *codes = @{@0:@"wy", @2:@"kg", @3:@"tx", @4:@"qishui"};
        if (![code isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)code) == CFBooleanGetTypeID() ||
            ![codes[code] isEqual:platform]) return nil;
    }
    return alias;
}

static inline NSArray *FMDAExtensions(void) {
    static NSArray *extensions;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ extensions = @[@"mp3",@"flac",@"m4a",@"wav",@"ogg",@"opus",@"aac",@"aif",@"aiff",@"aifc",@"caf",@"mp4",@"ape",@"wv",@"mpc",@"tta",@"spx",@"dsf",@"dff"]; });
    return extensions;
}
static inline NSArray *FMDAReadIndex(NSURL *url) {
    struct stat s;
    if (!FMDARegular(url, &s) || s.st_size > 64 * 1024 * 1024) return nil;
    NSData *data = [NSData dataWithContentsOfURL:url options:NSDataReadingUncached error:nil];
    if (!data.length) return nil;
    id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    return [json isKindOfClass:NSArray.class] ? json : nil;
}

