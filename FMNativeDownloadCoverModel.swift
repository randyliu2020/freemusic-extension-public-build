import Foundation
@_spi(Reflection) import Swift

// Open the actual native Array specialization. Swift owns all copies and
// releases, including opaque fields in a row that this extension never reads.
private protocol FMDownloadRowArray {
    static func refresh<Owner>(_ owner: Owner, _ path: AnyKeyPath, _ changes: NSDictionary,
                               _ expectedRowType: String) -> Int
}
extension Array: FMDownloadRowArray {
    fileprivate static func refresh<Owner>(_ owner: Owner, _ path: AnyKeyPath, _ changes: NSDictionary,
                                          _ expectedRowType: String) -> Int {
        guard String(reflecting: Element.self) == expectedRowType,
              let list = path as? ReferenceWritableKeyPath<Owner, [Element]> else { return 0 }
        var id: KeyPath<Element, String>?
        var server: KeyPath<Element, String>?
        var cover: WritableKeyPath<Element, String?>?
        _forEachFieldWithKeyPath(of: Element.self, options: [.ignoreUnknown]) { name, field in
            switch String(cString: name) {
            case "id": id = field as? KeyPath<Element, String>
            case "server": server = field as? KeyPath<Element, String>
            case "cover": cover = field as? WritableKeyPath<Element, String?>
            default: break
            }
            return id == nil || server == nil || cover == nil
        }
        guard let id, let server, let cover else { return 0 }
        var rows = owner[keyPath: list]
        var count = 0
        for i in rows.indices {
            let platform = rows[i][keyPath: server]
            let identifier = rows[i][keyPath: id]
            guard let byID = changes[platform] as? NSDictionary,
                  let change = byID[identifier] as? NSDictionary,
                  let destination = change["url"] as? String,
                  let expected = change["expectedCover"] else { continue }
            let current = rows[i][keyPath: cover]
            if current == destination { continue }
            // Compare against the index snapshot used for this repair. A later
            // user edit, removal, or another track's artwork wins.
            let sameNativeSidecar: Bool
            if let current, let prior = URL(string: current), prior.isFileURL,
               let target = URL(string: destination), target.isFileURL {
                let priorPath = prior.standardizedFileURL.path
                sameNativeSidecar = priorPath == target.standardizedFileURL.path ||
                    (change["nativePaths"] as? [String])?.contains(priorPath) == true
            } else { sameNativeSidecar = false }
            let matches = sameNativeSidecar ||
                (expected is NSNull && (current == nil || current == "")) ||
                ((expected as? String).map { current == $0 } ?? false)
            guard matches else { continue }
            rows[i][keyPath: cover] = destination
            count += 1
        }
        if count > 0 { owner[keyPath: list] = rows }
        return count
    }
}

func FMRefreshDownloadCoverModel(_ owner: AnyObject, _ path: AnyKeyPath, _ changes: NSDictionary,
                                 expectedRowType: String) -> Int {
    guard Thread.isMainThread, let array = type(of: path).valueType as? FMDownloadRowArray.Type else { return 0 }
    func update<Owner>(_ root: Owner.Type) -> Int {
        guard let native = owner as? Owner else { return 0 }
        return array.refresh(native, path, changes, expectedRowType)
    }
    return _openExistential(type(of: path).rootType, do: update)
}

@_cdecl("FMNativeDownloadCoverApply")
public func FMNativeDownloadCoverApply(_ owner: UnsafeRawPointer, _ retainedKeyPath: UnsafeRawPointer,
                                       _ changes: UnsafeRawPointer) -> Int {
    let model = Unmanaged<AnyObject>.fromOpaque(owner).takeUnretainedValue()
    let path = Unmanaged<AnyKeyPath>.fromOpaque(retainedKeyPath).takeRetainedValue()
    let requests = Unmanaged<NSDictionary>.fromOpaque(changes).takeUnretainedValue()
    return FMRefreshDownloadCoverModel(model, path, requests, expectedRowType: "FreeMusic.Track")
}
