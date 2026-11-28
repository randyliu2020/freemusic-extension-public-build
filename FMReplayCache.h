#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Private, purgeable playback data. An opaque key belongs to a single
/// activation namespace, platform, native track identity and requested quality.
@interface FMReplayCache : NSObject
+ (instancetype)sharedCache;
- (instancetype)initWithDirectory:(NSURL *)directory
                   audioByteLimit:(unsigned long long)byteLimit
                       entryLimit:(NSUInteger)entryLimit NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

/// Called at source selection. The identity hashes the imported filename and
/// script contents. Reopening the same selection restores its persisted epoch;
/// switching or disabling revokes all keys and pending writes from that epoch.
- (nullable NSString *)selectSourceFile:(nullable NSString *)file script:(nullable NSString *)script;
- (nullable NSString *)keyForNamespace:(nullable NSString *)namespaceID
                              platform:(NSString *)platform
                               trackID:(NSString *)trackID
                               quality:(NSString *)quality;

/// Removes replay addresses and complete automatic files in one song's namespace.
/// The count is the number of stored quality entries. Pending keys are retired
/// even on a cache miss. A failed clear can be retried.
- (BOOL)clearPlatform:(NSString *)platform trackID:(NSString *)trackID removedEntries:(NSUInteger * _Nullable)removed;
/// Changes on source switch and after the user clears this exact recording.
- (BOOL)isCurrentKey:(nullable NSString *)key;
/// When a player is already reading a complete replay file, retire its index
/// immediately but keep its bytes available until the last bound item releases it.
- (void)protectAudio:(NSURL *)file forPlaybackItem:(id)item;

- (nullable NSURL *)addressForKey:(nullable NSString *)key;
- (nullable NSURL *)audioForKey:(nullable NSString *)key;
- (void)saveAddress:(NSURL *)address forKey:(nullable NSString *)key;
- (void)discardAddress:(NSURL *)address forKey:(nullable NSString *)key;
- (void)discardAudio:(NSURL *)file forKey:(nullable NSString *)key;

/// Synchronously copies a complete, validated local file. The caller owns the
/// original. The extension is the detected audio container, without a dot.
- (BOOL)publishVerifiedAudio:(NSURL *)file fileExtension:(NSString *)extension forKey:(nullable NSString *)key;
/// Use for in-flight network transfers. A late completion cannot publish over
/// a new resolver result for the same source and requested quality.
- (BOOL)publishVerifiedAudio:(NSURL *)file fileExtension:(NSString *)extension
                      forKey:(nullable NSString *)key expectedAddress:(nullable NSURL *)expectedAddress;
@end

NS_ASSUME_NONNULL_END
