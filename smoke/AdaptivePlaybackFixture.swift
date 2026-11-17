// Authored test host. No original app code, songs, credentials or external URLs.
import Foundation
import AVFoundation
import Darwin

private final class AdaptiveHTTPServer {
    private let lock = NSLock()
    private var fd: Int32 = -1
    private var closed = false
    let port: UInt16
    private let audio: Data
    init() throws {
        let rate: UInt32 = 22050, count: UInt32 = 22050 * 12
        var wave = Data()
        func u16(_ x: UInt16) { var v = x.littleEndian; withUnsafeBytes(of: &v) { wave.append(contentsOf: $0) } }
        func u32(_ x: UInt32) { var v = x.littleEndian; withUnsafeBytes(of: &v) { wave.append(contentsOf: $0) } }
        wave.append(contentsOf: Array("RIFF".utf8)); u32(36 + count * 2)
        wave.append(contentsOf: Array("WAVEfmt ".utf8)); u32(16); u16(1); u16(1)
        u32(rate); u32(rate * 2); u16(2); u16(16)
        wave.append(contentsOf: Array("data".utf8)); u32(count * 2)
        for n in 0..<count { u16(UInt16(bitPattern: Int16(500 * sin(2 * Double.pi * 220 * Double(n) / Double(rate))))) }
        audio = wave
        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else { throw NSError(domain: "AdaptiveHTTP", code: 1) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0; addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard bound == 0, listen(socketFD, 8) == 0 else { Darwin.close(socketFD); throw NSError(domain: "AdaptiveHTTP", code: 2) }
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(socketFD, $0, &size) } }
        port = UInt16(bigEndian: addr.sin_port); fd = socketFD
        DispatchQueue.global(qos: .utility).async { [weak self] in self?.serve(socketFD) }
    }
    func stop() {
        lock.lock(); if closed { lock.unlock(); return }; closed = true; let value = fd; fd = -1; lock.unlock()
        if value >= 0 { shutdown(value, SHUT_RDWR); Darwin.close(value) }
    }
    private func serve(_ listener: Int32) {
        while true {
            lock.lock(); let finished = closed; lock.unlock(); if finished { return }
            let client = accept(listener, nil, nil); if client < 0 { return }
            handle(client); Darwin.close(client)
        }
    }
    private func handle(_ client: Int32) {
        var yes: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
        var deadline = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &deadline, socklen_t(MemoryLayout<timeval>.size))
        var request = Data(), buffer = [UInt8](repeating: 0, count: 2048)
        while request.count < 16384 && request.range(of: Data([13,10,13,10])) == nil {
            let readCount = recv(client, &buffer, buffer.count, 0)
            if readCount <= 0 { return }; request.append(contentsOf: buffer.prefix(readCount))
        }
        guard let string = String(data: request, encoding: .utf8) else { return }
        let lines = string.components(separatedBy: "\r\n")
        let first = (lines.first ?? "").split(separator: " ")
        guard first.count >= 2 else { return }
        let bad = first[1].hasPrefix("/bad")
        let payload = bad ? Data("This is deliberately invalid audio; self-authored fixture.".utf8) : audio
        var start = 0, end = payload.count - 1
        var partial = false
        if let rangeLine = lines.first(where: { $0.lowercased().hasPrefix("range: bytes=") }) {
            let ranges = rangeLine.dropFirst("range: bytes=".count).split(separator: "-", omittingEmptySubsequences: false)
            if ranges.count == 2, let parsed = Int(ranges[0]), parsed >= 0, parsed < payload.count {
                start = parsed; end = min(Int(ranges[1]) ?? end, end); partial = end >= start
            }
        }
        if !partial { start = 0; end = payload.count - 1 }
        var response = "HTTP/1.1 \(partial ? "206 Partial Content" : "200 OK")\r\nContent-Type: audio/wav\r\nAccept-Ranges: bytes\r\nContent-Length: \(end-start+1)\r\nConnection: close\r\n"
        if partial { response += "Content-Range: bytes \(start)-\(end)/\(payload.count)\r\n" }
        response += "\r\n"
        var bytes = Data(response.utf8)
        if first[0] != "HEAD" { bytes.append(payload.subdata(in: start..<(end + 1))) }
        bytes.withUnsafeBytes { raw in
            var sent = 0
            while sent < raw.count {
                let amount = Darwin.send(client, raw.baseAddress!.advanced(by: sent), raw.count - sent, 0)
                if amount <= 0 { break }; sent += amount
            }
        }
    }
    deinit { stop() }
}

public final class AdaptivePlaybackFixture: NSObject {
    private let server: AdaptiveHTTPServer
    public private(set) var player: AVPlayer?
    private var observation: NSKeyValueObservation?
    private var ended: NSObjectProtocol?
    private(set) var setups = 0, failures = 0, nativeFailures = 0
    private(set) var lastURL = ""
    var pauseBeforeAttach = false
    var badURL: URL { URL(string: "http://127.0.0.1:\(server.port)/bad.wav")! }
    var goodURL: URL { URL(string: "http://127.0.0.1:\(server.port)/tone.wav?fixture=%E9%9F%B3%E4%B9%90")! }
    override init() {
        server = try! AdaptiveHTTPServer()
        super.init()
    }
    // Genuine Swift URL + optional ObjC player + Swift self instance method ABI.
    @_silgen_name("FMAdaptiveFixtureSetupNative")
    @inline(never)
    public func nativeSetup(_ url: URL, _ adopted: AVPlayer?) {
        precondition(Thread.isMainThread)
        observation?.invalidate(); observation = nil
        if let ended { NotificationCenter.default.removeObserver(ended) }; ended = nil
        player?.pause()
        player = adopted ?? AVPlayer(url: url); player?.isMuted = true
        setups += 1; lastURL = url.absoluteString
        let item = player!.currentItem!
        observation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            guard item.status == .failed else { return }
            DispatchQueue.main.async { self?.realFailure(item) }
        }
        ended = NotificationCenter.default.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main) { [weak self] _ in self?.realFailure(item) }
        player!.play()
        if pauseBeforeAttach { player!.pause(); pauseBeforeAttach = false }
        if let symbol = dlsym(nil, "FMAdaptiveNativeDidSetup") {
            typealias Call = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void
            unsafeBitCast(symbol, to: Call.self)(Unmanaged.passUnretained(self).toOpaque(), Unmanaged.passUnretained(player!).toOpaque())
        }
    }
    private func realFailure(_ item: AVPlayerItem) {
        // The original app also rejects late notifications for a noncurrent item.
        guard player?.currentItem === item else { return }
        failures += 1
        var handled = false
        if let symbol = dlsym(nil, "FMAdaptiveNativeHandleFailure") {
            typealias Call = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Bool
            handled = unsafeBitCast(symbol, to: Call.self)(Unmanaged.passUnretained(self).toOpaque(), player.map { Unmanaged.passUnretained($0).toOpaque() })
        }
        if !handled { nativeFailure(1, nil, 4) }
    }
    @_silgen_name("FMAdaptiveFixtureFailureNative")
    @inline(never)
    public func nativeFailure(_ flag: UInt, _ optional: UnsafeMutableRawPointer?, _ reason: UInt32) {
        precondition(Thread.isMainThread && flag == 1 && optional == nil && reason == 4)
        nativeFailures += 1
    }
    func stop() {
        observation?.invalidate(); observation = nil
        if let ended { NotificationCenter.default.removeObserver(ended) }; ended = nil
        player?.pause(); player?.replaceCurrentItem(with: nil); server.stop()
    }
    var state: NSDictionary {
        ["setups": setups, "actual_failures": failures, "native_failures": nativeFailures,
         "url": lastURL, "status": player?.currentItem?.status.rawValue ?? -1,
         "rate": player?.rate ?? 0, "time": player.map { CMTimeGetSeconds($0.currentTime()) } ?? 0,
         "bad": badURL.absoluteString, "good": goodURL.absoluteString]
    }
    deinit { stop() }
}
@_cdecl("FMAdaptiveFixtureCreate")
public func adaptiveFixtureCreate() -> UnsafeMutableRawPointer { Unmanaged.passRetained(AdaptivePlaybackFixture()).toOpaque() }
@_cdecl("FMAdaptiveFixtureCopyState")
public func adaptiveFixtureCopyState(_ pointer: UnsafeMutableRawPointer) -> UnsafeMutableRawPointer {
    Unmanaged.passRetained(Unmanaged<AdaptivePlaybackFixture>.fromOpaque(pointer).takeUnretainedValue().state).toOpaque()
}
@_cdecl("FMAdaptiveFixtureStart")
public func adaptiveFixtureStart(_ pointer: UnsafeMutableRawPointer, _ url: UnsafeMutableRawPointer) {
    Unmanaged<AdaptivePlaybackFixture>.fromOpaque(pointer).takeUnretainedValue().nativeSetup(Unmanaged<NSURL>.fromOpaque(url).takeUnretainedValue() as URL, nil)
}
@_cdecl("FMAdaptiveFixtureCopyPlayer")
public func adaptiveFixtureCopyPlayer(_ pointer: UnsafeMutableRawPointer) -> UnsafeMutableRawPointer? {
    guard let player = Unmanaged<AdaptivePlaybackFixture>.fromOpaque(pointer).takeUnretainedValue().player else { return nil }
    return Unmanaged.passRetained(player).toOpaque()
}
@_cdecl("FMAdaptiveFixtureStop")
public func adaptiveFixtureStop(_ pointer: UnsafeMutableRawPointer) {
    Unmanaged<AdaptivePlaybackFixture>.fromOpaque(pointer).takeUnretainedValue().stop()
}


@_cdecl("FMAdaptiveFixtureStartPaused")
public func adaptiveFixtureStartPaused(_ pointer: UnsafeMutableRawPointer, _ url: UnsafeMutableRawPointer) {
    let fixture = Unmanaged<AdaptivePlaybackFixture>.fromOpaque(pointer).takeUnretainedValue()
    fixture.pauseBeforeAttach = true
    fixture.nativeSetup(Unmanaged<NSURL>.fromOpaque(url).takeUnretainedValue() as URL, nil)
}
