import Foundation

// Authored real-Swift ABI fixture: both small inline and heap-backed values go
// through the production bridge. No native app string or image is embedded.
@_cdecl("FMArtworkSwiftOwnershipFixture")
public func artworkSwiftOwnershipFixture() -> Int32 {
    guard MemoryLayout<String?>.size == 16 else { return -1 }
    var completed: Int32 = 0
    for iteration in 0..<32 {
        let samples = ["", "small", "封面🎵", String(repeating: "authored-cover-\(iteration)", count: 1024)]
        for sample in samples {
            var value: String? = sample
            let survivingCopy = value!
            var artwork: UnsafeMutableRawPointer? = nil
            let cleared = withExtendedLifetime(survivingCopy) {
                withUnsafeMutablePointer(to: &value) { urlSlot in
                    withUnsafeMutablePointer(to: &artwork) { imageSlot in
                        FMXAC(UnsafeMutableRawPointer(urlSlot), UnsafeMutableRawPointer(imageSlot))
                    }
                }
            }
            guard cleared, value == nil, artwork == nil, survivingCopy == sample else { return -2 }
            completed += 1
        }
    }
    // Clearing an already-nil optional must be safe and idempotent as well.
    var empty: String? = nil
    var image: UnsafeMutableRawPointer? = nil
    let repeated = withUnsafeMutablePointer(to: &empty) { urlSlot in
        withUnsafeMutablePointer(to: &image) { imageSlot in
            FMXAC(UnsafeMutableRawPointer(urlSlot), UnsafeMutableRawPointer(imageSlot)) &&
            FMXAC(UnsafeMutableRawPointer(urlSlot), UnsafeMutableRawPointer(imageSlot))
        }
    }
    return repeated && empty == nil && image == nil ? completed + 2 : -3
}

private final class CoverOwner {
    var url: String?
    var artwork: NSString?
    init(_ url: String?, _ artwork: NSString?) {
        self.url = url
        self.artwork = artwork
    }
    func clearMissingCover() -> Bool {
        withUnsafeMutablePointer(to: &url) { urlSlot in
            withUnsafeMutablePointer(to: &artwork) { imageSlot in
                FMXAC(UnsafeMutableRawPointer(urlSlot), UnsafeMutableRawPointer(imageSlot))
            }
        }
    }
}
private final class DeliveryState { var completed = false }

// The verified native completion has this URL/nonnull-image guard, before its
// cachedArtwork and nowPlayingInfo writes (0x632cc/0x632ec/0x632f4). Queue a real
// main-thread callback, transition the owner first, then let the callback run.
private func deliverLater(_ owner: CoverOwner, url: String, image: NSString?, transition: () -> Bool) -> Bool {
    let state = DeliveryState()
    DispatchQueue.main.async {
        if let current = owner.url, current == url, let image = image {
            owner.artwork = image
        }
        state.completed = true
    }
    let transitioned = transition()
    let deadline = Date(timeIntervalSinceNow: 5)
    while !state.completed && Date() < deadline {
        _ = RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
    }
    return transitioned && state.completed
}

@_cdecl("FMArtworkSwiftLateCompletionFixture")
public func artworkSwiftLateCompletionFixture() -> Int32 {
    guard Thread.isMainThread, MemoryLayout<NSString?>.size == MemoryLayout<UnsafeRawPointer?>.size else { return -1 }
    var completed: Int32 = 0
    let missingURLs: [String?] = [nil, ""]
    for missingURL in missingURLs {
        let owner = CoverOwner("https://example.invalid/cover-a", "previous artwork")
        let ok = deliverLater(owner, url: "https://example.invalid/cover-a", image: "late A") {
            // The ARM64 tests execute both real branch sites that choose this
            // same bridge for nil or empty requested URLs.
            guard missingURL == nil || missingURL!.isEmpty else { return false }
            return owner.clearMissingCover()
        }
        guard ok, owner.url == nil, owner.artwork == nil else { return -2 }
        completed += 1
    }
    let changed = CoverOwner("https://example.invalid/cover-a", nil)
    let rejected = deliverLater(changed, url: "https://example.invalid/cover-a", image: "late A") {
        // Existing nonempty native branch remains unchanged by the patch.
        changed.url = "https://example.invalid/cover-b"
        changed.artwork = nil
        return true
    }
    guard rejected, changed.artwork == nil else { return -3 }
    completed += 1
    guard deliverLater(changed, url: "https://example.invalid/cover-b", image: "current B", transition: { true }),
          changed.artwork == "current B" else { return -4 }
    completed += 1
    let same = CoverOwner("https://example.invalid/shared-cover", nil)
    guard deliverLater(same, url: "https://example.invalid/shared-cover", image: "shared image", transition: { true }),
          same.artwork == "shared image" else { return -5 }
    completed += 1
    guard deliverLater(same, url: "https://example.invalid/shared-cover", image: nil, transition: { true }),
          same.artwork == "shared image" else { return -6 }
    return completed + 1
}
