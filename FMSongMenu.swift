import CryptoKit
import Foundation
import SwiftUI
import UIKit

// SwiftUI does not propagate a Button identifier to its UIKit menu action.
// Use an invisible, lossless suffix on one original label; the native menu
// adapter removes it from the displayed action and keeps its original handler.
private let songMark = "\u{2063}"
private let authenticationKey = SymmetricKey(size: .bits256)
private let menuPrefix = "FMX.song:"
private let menuServers: Set<String> = ["wy", "netease", "qq", "tx", "kg", "kugou", "qs", "qishui", "kw", "kuwo", "mg", "migu"]

private func validTarget(_ server: String, _ id: String) -> Bool {
    menuServers.contains(server) && !id.isEmpty && id.utf8.count <= 220 &&
        id.utf8.allSatisfy { $0 >= 65 && $0 <= 90 || $0 >= 97 && $0 <= 122 ||
            $0 >= 48 && $0 <= 57 || $0 == 45 || $0 == 46 || $0 == 95 }
}

private let playerMarker = "player:now-playing"

private func taggedTitle(_ title: String, target: String) -> String {
    let code = HMAC<SHA256>.authenticationCode(for: Data(target.utf8), using: authenticationKey)
    let signature = Data(code).base64EncodedString()
    var tagged = title + songMark
    for byte in (menuPrefix + target + ":" + signature).utf8 {
        tagged.unicodeScalars.append(Unicode.Scalar(0xE0000 + UInt32(byte))!)
    }
    tagged.unicodeScalars.append("\u{E007F}")
    return tagged
}

private func taggedSongTitle(_ title: String, server: String, trackID: String) -> String {
    guard validTarget(server, trackID) else { return title }
    return taggedTitle(title, target: server + ":" + trackID)
}

@MainActor
private func playerMenuLabel() -> Label<Text, Image> {
    let title = String(localized: "显示翻译", bundle: .main)
    return Label(taggedTitle(title, target: playerMarker), systemImage: "character.book.closed")
}

@MainActor
func FMSongMenuLabel(_ title: String, systemImage: String, server: String, trackID: String) -> Label<Text, Image> {
    Label(taggedSongTitle(title, server: server, trackID: trackID), systemImage: systemImage)
}

private func identity(_ label: String) -> (String, String, String)? {
    let all = label.unicodeScalars
    guard label.utf8.count < 2048, let mark = all.lastIndex(where: { $0.value == 0x2063 }) else { return nil }
    let scalars = all[all.index(after: mark)...]
    guard scalars.last?.value == 0xE007F else { return nil }
    var bytes: [UInt8] = []
    for s in scalars.dropLast() {
        guard (0xE0020...0xE007E).contains(s.value) else { return nil }
        bytes.append(UInt8(s.value - 0xE0000))
    }
    guard let raw = String(bytes: bytes, encoding: .ascii), raw.hasPrefix(menuPrefix) else { return nil }
    let fields = raw.dropFirst(menuPrefix.count).split(separator: ":", maxSplits: 2)
    guard fields.count == 3 else { return nil }
    let server = String(fields[0]), id = String(fields[1])
    let target = server + ":" + id
    guard (target == playerMarker || validTarget(server, id)), let code = Data(base64Encoded: String(fields[2])),
          HMAC<SHA256>.isValidAuthenticationCode(code, authenticating: Data(target.utf8),
                                                 using: authenticationKey) else { return nil }
    return (String(all[..<mark]), target == playerMarker ? "" : server, id)
}

@_cdecl("FMXSongMenuParts")
public func songMenuParts(_ borrowedTitle: UnsafeRawPointer?) -> UnsafeMutableRawPointer? {
    guard let borrowedTitle else { return nil }
    let label = Unmanaged<NSString>.fromOpaque(borrowedTitle).takeUnretainedValue() as String
    guard let (plain, server, id) = identity(label) else { return nil }
    return Unmanaged.passRetained([plain, server, id] as NSArray).toOpaque()
}

// Build 4381 writes server + "_" + track.id to Apple's Now Playing info.
// IDs may themselves contain underscores so only the first one separates them.
@_cdecl("FMXPlayerMenuIdentity")
public func playerMenuIdentity(_ external: UnsafeRawPointer?) -> UnsafeMutableRawPointer? {
    guard let external else { return nil }
    let value = Unmanaged<NSString>.fromOpaque(external).takeUnretainedValue() as String
    guard value.utf8.count <= 240, let sep = value.firstIndex(of: "_") else { return nil }
    let server = String(value[..<sep]), id = String(value[value.index(after: sep)...])
    guard validTarget(server, id) else { return nil }
    return Unmanaged.passRetained([server, id] as NSArray).toOpaque()
}

@_cdecl("FMXInitPlayerMenuLabel")
@MainActor
public func initPlayerMenuLabel(_ storage: UnsafeMutableRawPointer?) {
    storage?.assumingMemoryBound(to: Label<Text, Image>.self).initialize(to: playerMenuLabel())
}

#if FMX_ADAPTIVE_PLAYBACK_TESTING && targetEnvironment(simulator)
@_cdecl("FMXMakeSongMenuLabelForTest")
@MainActor
public func makeSongMenuLabelForTest(_ storage: UnsafeMutableRawPointer?, _ server: UnsafeRawPointer?, _ id: UnsafeRawPointer?) {
    guard let storage, let server, let id else { return }
    storage.assumingMemoryBound(to: Label<Text,Image>.self).pointee = FMSongMenuLabel(
        "下一首播放", systemImage: "text.line.first.and.arrowtriangle.forward",
        server: Unmanaged<NSString>.fromOpaque(server).takeUnretainedValue() as String,
        trackID: Unmanaged<NSString>.fromOpaque(id).takeUnretainedValue() as String)
}

@_cdecl("FMXMakePlayerMenuLabelForTest")
@MainActor
public func makePlayerMenuLabelForTest(_ storage: UnsafeMutableRawPointer?) {
    storage?.assumingMemoryBound(to: Label<Text, Image>.self).pointee = playerMenuLabel()
}
#endif

// Four verified native label builders borrow the exact track captured by
// the adjacent play-next action. The host retains and consumes the resulting
// localized String through its original Label initializer.
@_cdecl("FMXTagSongMenuTitle")
public func tagSongMenuTitle(_ storage: UnsafeMutableRawPointer?, _ track: UnsafeRawPointer?) {
    guard let storage, let track else { return }
    let title = storage.assumingMemoryBound(to: String.self)
    let server = track.load(fromByteOffset: 64, as: String.self)
    let id = track.load(as: String.self)
    title.pointee = taggedSongTitle(title.pointee, server: server, trackID: id)
}
