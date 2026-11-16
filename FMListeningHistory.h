#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
/// Local day/track aggregates. No network, account identifiers or artwork are stored.
@interface FMListeningHistory : NSObject
- (instancetype)initWithURL:(NSURL *)url calendar:(NSCalendar *)calendar;
- (void)observeTrack:(nullable NSDictionary *)track elapsed:(double)elapsed rate:(double)rate
               date:(NSDate *)date uptime:(double)uptime;
- (void)resetSample;
- (NSDictionary *)summaryForDate:(NSDate *)date yearly:(BOOL)yearly;
- (BOOL)save:(NSError **)error;
- (BOOL)clear:(NSError **)error;
@property (nonatomic, readonly, nullable) NSString *storageError;
@end
NS_ASSUME_NONNULL_END
