// Independent Simulator-only model for the native cache bridge's Swift self ABI.
// This is authored test code, not a copy of the original application's function.
import Foundation
import AVFoundation

fileprivate final class FixturePreload {
    let player: AVPlayer
    private var observer: Any?
    private(set) var invalidated = false

    init(url: URL) {
        player = AVPlayer(url: url)
        player.isMuted = true
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main) { _ in }
    }

    func invalidate() {
        if let observer { player.removeTimeObserver(observer) }
        observer = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        invalidated = true
    }

    deinit { invalidate() }
}

public final class PlaybackCacheFixture: NSObject {
    let audioURL: URL
    let manualDownloadURL: URL
    private(set) var currentPlayer: AVPlayer!
    private var originalCurrentItem: AVPlayerItem!
    // Adopted players leave the pending dictionary. Keep their owning wrapper
    // alive until the fixture ends so deinit cannot invalidate the active item.
    private var adoptedCurrent: FixturePreload?
    private var currentWasAdoptedFromPreloads = false
    var prefetched: [String: String] = [:]
    fileprivate var preloads: [String: FixturePreload] = [:]
    var prefetchedFor: UUID?
    var preloadedFor: UUID?
    var oldKey = ""
    fileprivate var retiredPreloads: [FixturePreload] = []
    var invalidations = 0
    var invalidationsOnMain = true
    var lateResultsAccepted = 0

    init(audioURL: URL, manualDownloadURL: URL) {
        self.audioURL = audioURL
        self.manualDownloadURL = manualDownloadURL
        super.init()
        let adoptedKey = "qq_adopted-current|standard"
        preloads[adoptedKey] = FixturePreload(url: audioURL)
        let adopted = preloads.removeValue(forKey: adoptedKey)!
        adoptedCurrent = adopted
        currentPlayer = adopted.player
        originalCurrentItem = adopted.player.currentItem!
        currentWasAdoptedFromPreloads = preloads[adoptedKey] == nil
    }

    func seed(key: String) {
        precondition(Thread.isMainThread)
        for item in preloads.values { item.invalidate() }
        oldKey = key
        prefetched = [key: "https://fixture.invalid/old-source"]
        preloads = [key: FixturePreload(url: audioURL)]
        prefetchedFor = UUID()
        preloadedFor = UUID()
    }

    // A real Swift instance entry point: its receiver is passed with the Swift
    // self calling convention, not as the first argument to a C wrapper.
    @_silgen_name("FMCacheFixtureInvalidateNative")
    @inline(never)
    public func invalidateNative() {
        invalidations += 1
        invalidationsOnMain = invalidationsOnMain && Thread.isMainThread
        prefetchedFor = nil
        preloadedFor = nil
        prefetched.removeAll()
        for preload in preloads.values {
            preload.invalidate()
            retiredPreloads.append(preload)
        }
        preloads.removeAll()
    }

    func completeOldResults() {
        precondition(Thread.isMainThread)
        // Deliberately model the original weak completion guards: clearing the
        // UUIDs alone does NOT prevent a late result from being written back.
        // The test must prove the new production epoch key cannot retrieve it.
        prefetched[oldKey] = "https://fixture.invalid/late-old-source"
        preloads[oldKey] = FixturePreload(url: audioURL)
        lateResultsAccepted += 2
    }

    var snapshot: NSDictionary {
        let time = CMTimeGetSeconds(currentPlayer.currentTime())
        return [
            "invalidations": invalidations,
            "invalidations_on_main": invalidationsOnMain,
            "prefetched_count": prefetched.count,
            "preloads_count": preloads.count,
            "prefetched_token_present": prefetchedFor != nil,
            "preloaded_token_present": preloadedFor != nil,
            "retired_preloads_clean": retiredPreloads.allSatisfy { $0.invalidated && $0.player.currentItem == nil && $0.player.rate == 0 },
            "current_item_preserved": currentPlayer.currentItem === originalCurrentItem,
            "current_adopted_from_preloads": currentWasAdoptedFromPreloads,
            "adopted_wrapper_still_valid": adoptedCurrent?.invalidated == false,
            "current_time": time.isFinite ? time : -1,
            "current_rate": currentPlayer.rate,
            "late_results_accepted": lateResultsAccepted,
            "manual_download_exists": FileManager.default.fileExists(atPath: manualDownloadURL.path)
        ]
    }

    deinit {
        currentPlayer.pause()
        for preload in preloads.values { preload.invalidate() }
    }
}

private func playbackCacheFixture(_ pointer: UnsafeMutableRawPointer) -> PlaybackCacheFixture {
    Unmanaged<PlaybackCacheFixture>.fromOpaque(pointer).takeUnretainedValue()
}

@_cdecl("FMCacheFixtureCreate")
public func fmCacheFixtureCreate(_ audioPath: UnsafePointer<CChar>, _ downloadPath: UnsafePointer<CChar>) -> UnsafeMutableRawPointer {
    precondition(Thread.isMainThread)
    let fixture = PlaybackCacheFixture(audioURL: URL(fileURLWithPath: String(cString: audioPath)), manualDownloadURL: URL(fileURLWithPath: String(cString: downloadPath)))
    return Unmanaged.passRetained(fixture).toOpaque()
}

@_cdecl("FMCacheFixtureSeed")
public func fmCacheFixtureSeed(_ pointer: UnsafeMutableRawPointer, _ key: UnsafePointer<CChar>) {
    playbackCacheFixture(pointer).seed(key: String(cString: key))
}

@_cdecl("FMCacheFixtureKeyHit")
public func fmCacheFixtureKeyHit(_ pointer: UnsafeMutableRawPointer, _ key: UnsafePointer<CChar>) -> Int32 {
    let fixture = playbackCacheFixture(pointer), value = String(cString: key)
    return (fixture.prefetched[value] == nil ? 0 : 1) | (fixture.preloads[value] == nil ? 0 : 2)
}

@_cdecl("FMCacheFixtureCompleteOldResults")
public func fmCacheFixtureCompleteOldResults(_ pointer: UnsafeMutableRawPointer) { playbackCacheFixture(pointer).completeOldResults() }

@_cdecl("FMCacheFixtureCopyState")
public func fmCacheFixtureCopyState(_ pointer: UnsafeMutableRawPointer) -> UnsafeMutableRawPointer {
    Unmanaged.passRetained(playbackCacheFixture(pointer).snapshot).toOpaque()
}

@_cdecl("FMCacheFixtureCopyPlayer")
public func fmCacheFixtureCopyPlayer(_ pointer: UnsafeMutableRawPointer) -> UnsafeMutableRawPointer {
    Unmanaged.passRetained(playbackCacheFixture(pointer).currentPlayer!).toOpaque()
}
