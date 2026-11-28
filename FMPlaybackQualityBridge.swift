import Foundation

// The exact 4.2.7 key-path setter consumes x0 = &String, x1 = &AnyObject.
// Swift owns both values for the complete call. No String layout is invented,
// no object offsets are written, and this bridge does not choose an address.
// The Objective-C caller verifies the image, getter, setter and UI key paths.
@_cdecl("FMPlaybackQualityBridgeSetLabel")
public func FMPlaybackQualityBridgeSetLabel(_ setter: UnsafeRawPointer,
                                            _ receiver: UnsafeRawPointer,
                                            _ label: UnsafeRawPointer) {
    var owner = Unmanaged<AnyObject>.fromOpaque(receiver).takeUnretainedValue()
    var text = Unmanaged<NSString>.fromOpaque(label).takeUnretainedValue() as String
    typealias IndirectSetter = @convention(c) (UnsafeRawPointer, UnsafeRawPointer) -> Void
    let call = unsafeBitCast(setter, to: IndirectSetter.self)
    withUnsafePointer(to: &text) { stringAddress in
        withUnsafePointer(to: &owner) { objectAddress in
            call(UnsafeRawPointer(stringAddress), UnsafeRawPointer(objectAddress))
        }
    }
}

// The native key builder already owns a complete Swift String at this call.
@_silgen_name("FMPlaybackCacheCopySuffixForString")
private func copySuffixForKey(_ key: UnsafeRawPointer) -> UnsafeRawPointer?

@_cdecl("FMPlaybackCacheCopyKeySuffix")
public func FMPlaybackCacheCopyKeySuffix(_ storage: UnsafeRawPointer?) -> UnsafeRawPointer? {
    guard let storage else { return nil }
    let string = storage.assumingMemoryBound(to: String.self).pointee as NSString
    return withExtendedLifetime(string) {
        copySuffixForKey(Unmanaged.passUnretained(string).toOpaque())
    }
}
