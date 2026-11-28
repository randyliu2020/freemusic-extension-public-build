#import "FMQualityResolver.h"
#import <math.h>

NSString * const FMQualityResolverErrorDomain = @"FMQualityResolver";
static NSError *FMQError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:FMQualityResolverErrorDomain code:code
                          userInfo:@{NSLocalizedDescriptionKey:message}];
}
static void FMQMain(dispatch_block_t block) {
    if (NSThread.isMainThread) block(); else dispatch_async(dispatch_get_main_queue(), block);
}
static BOOL FMQValidURL(NSURL *URL) {
    return [URL isKindOfClass:NSURL.class] && URL.host.length &&
        [@[@"http", @"https"] containsObject:URL.scheme.lowercaseString];
}

@implementation FMQualityResolver {
    NSArray<NSString *> *_qualities;
    NSUInteger _nextIndex, _attemptToken;
    NSTimeInterval _remaining, _resolutionBudget, _attemptStarted;
    BOOL (^_isCurrent)(void);
    FMQualityAttemptResolver _resolve;
    FMQualityResolutionCompletion _completion;
    dispatch_block_t _cancelAttempt;
    dispatch_source_t _timer;
    NSMutableSet<NSString *> *_returnedURLs;
    FMQualityCacheLookup _lookup;
    FMQualityCacheMutation _saveAddress, _discardFailed;
    NSString *_lastQuality, *_resumeQuality;
    NSURL *_lastURL;
    FMQualityCandidateOrigin _lastCandidateOrigin;
    BOOL _lastWasRefresh;
    NSError *_terminalError;
    BOOL _attemptActive, _deliveryPending, _renewBudget;
}
- (void)setReplayLookup:(FMQualityCacheLookup)lookup saveAddress:(FMQualityCacheMutation)saveAddress
          discardFailed:(FMQualityCacheMutation)discardFailed {
    NSAssert(NSThread.isMainThread && !_nextIndex && !_completion, @"Configure replay before starting on main");
    _lookup = [lookup copy];
    _saveAddress = [saveAddress copy];
    _discardFailed = [discardFailed copy];
}
- (FMQualityCandidateOrigin)lastCandidateOrigin { return _lastCandidateOrigin; }
+ (NSArray<NSString *> *)orderedQualitiesForPlatform:(NSString *)platform supportedQualities:(NSArray<NSString *> *)supportedQualities {
    NSArray *order;
    if ([platform isEqualToString:@"kg"]) order = @[@"128k"];
    else if ([@[@"wy", @"tx", @"qq"] containsObject:platform]) order = @[@"flac24bit", @"flac", @"320k", @"128k"];
    else return @[];
    NSMutableArray *result = NSMutableArray.array;
    for (NSString *quality in order) if ([supportedQualities containsObject:quality]) [result addObject:quality];
    return [result copy];
}
- (instancetype)initWithPlatform:(NSString *)platform supportedQualities:(NSArray<NSString *> *)supportedQualities
                         timeout:(NSTimeInterval)timeout isCurrent:(BOOL (^)(void))isCurrent resolve:(FMQualityAttemptResolver)resolve {
    if ((self = [super init])) {
        _qualities = [self.class orderedQualitiesForPlatform:platform supportedQualities:supportedQualities];
        _resolutionBudget = isfinite(timeout) && timeout > 0 ? MIN(timeout, 60) : 35;
        _remaining = _resolutionBudget;
        _isCurrent = [isCurrent copy]; _resolve = [resolve copy];
        _returnedURLs = NSMutableSet.set;
    }
    return self;
}
- (void)dealloc {
    if (_timer) dispatch_source_cancel(_timer);
    dispatch_block_t cancel = _cancelAttempt;
    if (cancel) FMQMain(^{ cancel(); });
}
- (BOOL)sourceIsCurrent {
    @try { return _isCurrent && _isCurrent(); }
    @catch (__unused NSException *exception) { return NO; }
}
- (void)stopAttempt:(BOOL)cancel {
    if (_attemptActive) {
        _remaining = MAX(0, _remaining - (NSProcessInfo.processInfo.systemUptime - _attemptStarted));
        _attemptActive = NO;
    }
    if (_timer) { dispatch_source_cancel(_timer); _timer = nil; }
    dispatch_block_t cancellation = _cancelAttempt; _cancelAttempt = nil;
    if (cancel && cancellation) { @try { cancellation(); } @catch (__unused NSException *exception) {} }
}
- (void)completeURL:(NSURL *)URL quality:(NSString *)quality error:(NSError *)error {
    FMQualityResolutionCompletion completion = _completion; _completion = nil;
    // Defer delivery so even an immediately exhausted/unsupported session is asynchronous.
    if (completion) {
        _deliveryPending = YES;
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_deliveryPending = NO;
            NSError *finalError = self->_terminalError ?: error;
            if (URL && !finalError && ![self sourceIsCurrent]) finalError = FMQError(FMQualityResolverSourceChanged,@"Source or playback generation changed");
            // A later next means this candidate failed during actual media IO.
            // Give remaining qualities a fresh bounded call, without resetting
            // the index/deduplication or refreshing failures within this call.
            if (URL && !finalError) {
                self->_renewBudget = YES;
                if (self.willUseRemoteURL && FMQValidURL(URL)) self.willUseRemoteURL(quality,URL);
            }
            completion(finalError ? nil : URL, finalError ? nil : quality, finalError);
        });
    }
}
- (void)terminate:(NSError *)error {
    if (!_terminalError) _terminalError = error;
    ++_attemptToken;
    [self stopAttempt:YES];
    [self completeURL:nil quality:nil error:_terminalError];
}
- (void)nextWithCompletion:(FMQualityResolutionCompletion)completion {
    FMQMain(^{
        if (self->_completion || self->_deliveryPending) {
            dispatch_async(dispatch_get_main_queue(), ^{ completion(nil,nil,FMQError(FMQualityResolverBusy,@"A quality attempt is already in progress")); });
            return;
        }
        if (self->_renewBudget && !self->_terminalError) {
            self->_remaining = self->_resolutionBudget;
            self->_renewBudget = NO;
            if (self->_lookup && [self sourceIsCurrent]) {
                if (self->_discardFailed) self->_discardFailed(self->_lastQuality,self->_lastURL);
                // First failure of a cached file falls through to the remote
                // tiers at this quality. A remote failure gets one forced JS
                // refresh, whether the original URL came from disk or JS.
                if (!self->_lastWasRefresh) self->_resumeQuality = self->_lastQuality;
            }
        }
        self->_completion = [completion copy];
        [self attemptNext];
    });
}
- (void)deliverCandidate:(NSURL *)URL quality:(NSString *)quality origin:(FMQualityCandidateOrigin)origin
                refreshed:(BOOL)refreshed {
    _lastURL = URL;
    _lastQuality = [quality copy];
    _lastCandidateOrigin = origin;
    _lastWasRefresh = refreshed;
    [_returnedURLs addObject:URL.absoluteString];
    if (_saveAddress && origin == FMQualityCandidateFromJS) _saveAddress(quality,URL);
    [self completeURL:URL quality:quality error:nil];
}
- (void)attemptNext {
    if (!_completion) return;
    if (_terminalError) { [self completeURL:nil quality:nil error:_terminalError]; return; }
    if (![self sourceIsCurrent]) { [self terminate:FMQError(FMQualityResolverSourceChanged,@"Source or playback generation changed")]; return; }
    if (!_qualities.count || !_resolve) { [self terminate:FMQError(FMQualityResolverNoSupportedQuality,@"No supported common quality")]; return; }
    if (_remaining <= 0.001) { [self terminate:FMQError(NSURLErrorTimedOut,@"Total quality resolution time exhausted")]; return; }
    if (!_resumeQuality && _nextIndex >= _qualities.count) { [self terminate:FMQError(FMQualityResolverExhausted,@"All supported qualities failed or returned a previously failed URL")]; return; }
    BOOL resuming = _resumeQuality != nil;
    BOOL refresh = resuming && _lastCandidateOrigin != FMQualityCandidateFromAudioCache;
    NSString *quality = _resumeQuality ?: _qualities[_nextIndex++];
    _resumeQuality = nil;
    if (_lookup && !refresh) {
        NSURL *local = resuming ? nil : _lookup(quality,FMQualityCandidateFromAudioCache);
        if (local.isFileURL && ![_returnedURLs containsObject:local.absoluteString]) {
            [self deliverCandidate:local quality:quality origin:FMQualityCandidateFromAudioCache refreshed:NO];
            return;
        }
        NSURL *remote = _lookup(quality,FMQualityCandidateFromAddressCache);
        if (FMQValidURL(remote) && ![_returnedURLs containsObject:remote.absoluteString]) {
            [self deliverCandidate:remote quality:quality origin:FMQualityCandidateFromAddressCache refreshed:NO];
            return;
        }
    }
    // Match LX mobile's userApi request ceiling. The enclosing call's shorter
    // budget still wins; several slow qualities cannot each consume 20 seconds
    // inside a single 35-second host request.
    NSTimeInterval budget = MIN(20, _remaining);
    NSUInteger token = ++_attemptToken;
    _attemptStarted = NSProcessInfo.processInfo.systemUptime; _attemptActive = YES;
    _timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_timer(_timer, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(budget * NSEC_PER_SEC)), DISPATCH_TIME_FOREVER, 0);
    dispatch_source_set_event_handler(_timer, ^{
        typeof(self) self = weakSelf;
        if (!self || !self->_attemptActive || token != self->_attemptToken) return;
        // Invalidate this callback before canceling: cancellation may itself complete synchronously.
        ++self->_attemptToken; [self stopAttempt:YES];
        [self attemptNext];
    });
    dispatch_resume(_timer);
    @try {
        dispatch_block_t cancellation = _resolve(quality, budget, ^(NSURL *URL, NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                typeof(self) self = weakSelf;
                if (!self || token != self->_attemptToken || !self->_attemptActive) return;
                ++self->_attemptToken; [self stopAttempt:NO];
                if (![self sourceIsCurrent]) { [self terminate:FMQError(FMQualityResolverSourceChanged,@"Source or playback generation changed")]; return; }
                if (error && (error.code == NSURLErrorCancelled || error.code == NSUserCancelledError)) {
                    [self terminate:FMQError(NSURLErrorCancelled,@"Quality resolution cancelled")]; return;
                }
                BOOL refreshedSameURL = refresh && [URL.absoluteString isEqual:self->_lastURL.absoluteString];
                if (!error && FMQValidURL(URL) && (refreshedSameURL || ![self->_returnedURLs containsObject:URL.absoluteString])) {
                    [self deliverCandidate:URL quality:quality origin:FMQualityCandidateFromJS refreshed:refresh];
                } else [self attemptNext];
            });
        });
        if (_attemptActive && token == _attemptToken) _cancelAttempt = [cancellation copy];
        else if (cancellation) cancellation();
    } @catch (__unused NSException *exception) {
        ++_attemptToken; [self stopAttempt:YES];
        dispatch_async(dispatch_get_main_queue(), ^{ [self attemptNext]; });
    }
}
- (void)cancel { FMQMain(^{ [self terminate:FMQError(NSURLErrorCancelled,@"Quality session cancelled")]; }); }
@end
