#import "FMArtworkSelection.h"
#import <dispatch/dispatch.h>
#import <dlfcn.h>
#include <stdint.h>
#include <string.h>

typedef void (*FMArtworkRelease)(void *);

bool FMXAC(void *urlStorage, void *artworkStorage) {
    static FMArtworkRelease releaseString, releaseArtwork;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        releaseString = (FMArtworkRelease)dlsym(RTLD_DEFAULT, "swift_bridgeObjectRelease");
        releaseArtwork = (FMArtworkRelease)dlsym(RTLD_DEFAULT, "objc_release");
    });
    if (!urlStorage || !artworkStorage || !releaseString || !releaseArtwork) return false;

    // Match the exact original initialization/deinitialization operations: nil
    // Optional<String> is two zero words; its second word goes through Swift's
    // bridge-object release (never CFRelease). Artwork owns one ObjC reference.
    // Clear both identities before releasing either object so reentrant cleanup
    // cannot see an old URL and accept its late image result.
    uintptr_t oldURL[2], nilURL[2] = {0, 0};
    void *oldArtwork = NULL, *nilArtwork = NULL;
    memcpy(oldURL, urlStorage, sizeof(oldURL));
    memcpy(&oldArtwork, artworkStorage, sizeof(oldArtwork));
    memcpy(urlStorage, nilURL, sizeof(nilURL));
    memcpy(artworkStorage, &nilArtwork, sizeof(nilArtwork));
    if (oldURL[1]) releaseString((void *)oldURL[1]);
    if (oldArtwork) releaseArtwork(oldArtwork);
    return true;
}
