import Foundation
import Darwin

// Foundation creates/destroys the actual resilient URL value. The C helper only
// borrows its address while invoking the verified Swift instance-method entry.
// Darwin RTLD_DEFAULT is (void *)-2; nil is not a valid dlsym search handle.
@_cdecl("FMAdaptiveBridgeSetupURL")
public func adaptiveBridgeSetupURL(_ owner: UnsafeMutableRawPointer?,
                                   _ urlObject: UnsafeMutableRawPointer?) -> Bool {
    guard Thread.isMainThread, let owner, let urlObject,
          let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "FMAdaptiveNativeSetupValue") else { return false }
    let nsURL = Unmanaged<NSURL>.fromOpaque(urlObject).takeUnretainedValue()
    var value = nsURL as URL
    typealias Call = @convention(c) (UnsafeRawPointer?, UnsafeMutableRawPointer?) -> Bool
    let call = unsafeBitCast(symbol, to: Call.self)
    return withUnsafePointer(to: &value) { call(UnsafeRawPointer($0), owner) }
}

