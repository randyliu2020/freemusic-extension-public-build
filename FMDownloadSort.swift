import Foundation

private let sortLocale = Locale(identifier: "en_US_POSIX")
private let latinLetter = try! NSRegularExpression(pattern: #"^\p{Latin}$"#)

private struct DownloadOrderKey: Comparable {
    let group: Int
    let text: String

    init(_ input: String) {
        let folded = input.folding(options: [.widthInsensitive], locale: sortLocale)
        let content = String(folded.drop(while: { $0.isWhitespace || $0.isPunctuation || $0.isSymbol }))
        let first = content.unicodeScalars.first(where: { CharacterSet.letters.contains($0) })
        if let first, first.properties.isIdeographic {
            group = 0
        } else if let first {
            let scalar = String(first)
            group = latinLetter.firstMatch(in: scalar, range: NSRange(scalar.startIndex..., in: scalar)) == nil ? 2 : 1
        } else {
            group = 2
        }
        // Retain digits, articles, and version suffixes when constructing the sort key.
        let base = content.isEmpty ? folded : content
        let reading = group == 0 ? (base.applyingTransform(.mandarinToLatin, reverse: false) ?? base) : base
        text = reading.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: sortLocale)
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.group != rhs.group { return lhs.group < rhs.group }
        return lhs.text.compare(rhs.text, options: .numeric, range: nil, locale: sortLocale) == .orderedAscending
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.group == rhs.group && lhs.text.compare(rhs.text, options: .numeric, range: nil, locale: sortLocale) == .orderedSame
    }
}

private struct DownloadSortRow {
    let offset: Int
    let title: DownloadOrderKey
    let singer: DownloadOrderKey
}

// Keep the original array alive along with its ordered projection. Native Swift
// Array copy-on-write gives a changed title, cover or membership a different
// buffer. A retained original prevents false hits from recycled addresses.
private struct DownloadProjection<Row> {
    let source: [Row]
    let sorted: [Row]

    func matches(_ rows: [Row]) -> Bool {
        guard source.count == rows.count else { return false }
        return rows.withUnsafeBufferPointer { r in
            source.withUnsafeBufferPointer { s in s.baseAddress == r.baseAddress }
        }
    }
}

private var lastProjection: Any?
private let projectionLock = NSLock()

private protocol LocalDownloadRows {
    static func project(_ slot: UnsafeMutableRawPointer, rowType: String)
}

extension Array: LocalDownloadRows {
    fileprivate static func project(_ slot: UnsafeMutableRawPointer, rowType: String) {
        guard String(reflecting: Element.self) == rowType else { return }
        let buffer = slot.assumingMemoryBound(to: [Element].self)
        let source = buffer.pointee
        guard source.count > 1 else {
            projectionLock.lock()
            lastProjection = nil
            projectionLock.unlock()
            return
        }
        projectionLock.lock()
        let previous = lastProjection as? DownloadProjection<Element>
        projectionLock.unlock()
        if let previous, previous.matches(source) {
            buffer.pointee = previous.sorted
            return
        }
        var keys: [DownloadSortRow] = []
        keys.reserveCapacity(source.count)
        for (offset, track) in source.enumerated() {
            var title: String?, singer: String?, artist: String?
            for field in Mirror(reflecting: track).children {
                switch field.label {
                case "title": title = field.value as? String
                case "singer": singer = field.value as? String
                case "artist": artist = field.value as? String
                default: continue
                }
            }
            guard let title else { return }
            let by = singer.flatMap { $0.isEmpty ? nil : $0 } ?? artist ?? ""
            keys.append(DownloadSortRow(offset: offset, title: DownloadOrderKey(title), singer: DownloadOrderKey(by)))
        }
        keys.sort { left, right in
            if left.title != right.title { return left.title < right.title }
            if left.singer != right.singer { return left.singer < right.singer }
            return left.offset < right.offset
        }
        let sorted = keys.enumerated().allSatisfy { $0.offset == $0.element.offset }
            ? source : keys.map { source[$0.offset] }
        projectionLock.lock()
        lastProjection = DownloadProjection(source: source, sorted: sorted)
        projectionLock.unlock()
        buffer.pointee = sorted
    }
}

func FMProjectDownloadRead(_ slot: UnsafeMutableRawPointer, path: AnyKeyPath, ownerType: String, rowType: String) {
    guard String(reflecting: type(of: path).rootType) == ownerType,
          let rows = type(of: path).valueType as? LocalDownloadRows.Type else { return }
    rows.project(slot, rowType: rowType)
}

// Only the downloaded-list rendering, queue, and selected-row reads in the
// verified host call this function. The app has already initialized and owns
// this temporary Array value. Its model, on-disk index and editable IDs
// stay native. Its borrowed key path supplies the precise Array type.
@_cdecl("FMProjectLocalDownloads")
public func FMProjectLocalDownloads(_ slot: UnsafeMutableRawPointer, _ borrowedKeyPath: UnsafeRawPointer) {
    let keyPath = Unmanaged<AnyKeyPath>.fromOpaque(borrowedKeyPath).takeUnretainedValue()
    FMProjectDownloadRead(slot, path: keyPath, ownerType: "FreeMusic.CacheManager", rowType: "FreeMusic.Track")
}
