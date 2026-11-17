import Foundation
import Combine

// Authored manager, never the original executable. Its Published value exercises
// String lifetime and notification delivery through the two indirect arguments.
private final class FMPQFixtureManager: NSObject, ObservableObject {
    @Published var currentQuality = "HQ"
    let selectedQuality = "flac24bit"
    var changes = 0
    var subscription: AnyCancellable?
    override init() {
        super.init()
        subscription = objectWillChange.sink { [weak self] in self?.changes += 1 }
    }
}

@_cdecl("FMPlaybackQualityFixtureCreate")
public func FMPlaybackQualityFixtureCreate() -> UnsafeMutableRawPointer {
    Unmanaged.passRetained(FMPQFixtureManager()).toOpaque()
}

// Export the Swift entry itself (no C adapter thunk), with the same two
// indirect typed arguments as the version-locked original key-path setter.
@_silgen_name("FMPlaybackQualityFixtureSetIndirect")
public func FMPlaybackQualityFixtureSetIndirect(_ text: UnsafePointer<String>,
                                                _ owner: UnsafePointer<AnyObject>) {
    let label = text.pointee
    let object = owner.pointee
    guard let manager = object as? FMPQFixtureManager else { return }
    manager.currentQuality = label
}

@_cdecl("FMPlaybackQualityFixtureCopyState")
public func FMPlaybackQualityFixtureCopyState(_ raw: UnsafeRawPointer) -> UnsafeMutableRawPointer {
    let manager = Unmanaged<FMPQFixtureManager>.fromOpaque(raw).takeUnretainedValue()
    let state: NSDictionary = ["label": manager.currentQuality,
                               "selectedQuality": manager.selectedQuality,
                               "changes": manager.changes]
    return Unmanaged.passRetained(state).toOpaque()
}
