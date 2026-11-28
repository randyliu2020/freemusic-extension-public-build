import Foundation

// Swift's stable struct metadata has a nominal descriptor and a field-offset
// vector. Mirror supplies the actual member name/type. Only the checked
// mutable Optional<String> member of an owned array element is ever assigned.
private func coverMember<Row>(in row: Row) -> Int? {
    let view = Mirror(reflecting: row)
    guard view.displayStyle == .struct, MemoryLayout<UnsafeRawPointer>.size == 8,
          let index = view.children.enumerated().first(where: { $0.element.label == "cover" })?.offset,
          let reflected = view.children.first(where: { $0.label == "cover" }),
          type(of: reflected.value) == Optional<String>.self else { return nil }
    let metadata = unsafeBitCast(Row.self, to: UnsafeRawPointer.self)
    guard metadata.load(as: UInt.self) == 0x200 else { return nil }
    let descriptor = metadata.load(fromByteOffset: 8, as: UnsafeRawPointer.self)
    guard descriptor.load(as: UInt32.self) & 0x1f == 17 else { return nil }
    let count = Int(descriptor.load(fromByteOffset: 20, as: UInt32.self))
    let vectorWords = Int(descriptor.load(fromByteOffset: 24, as: UInt32.self))
    let fieldsRef = descriptor.advanced(by: 16)
    let relative = fieldsRef.load(as: Int32.self)
    guard count == view.children.count, index < count, count <= 128,
          (2...128).contains(vectorWords), relative != 0 else { return nil }
    let fields = fieldsRef.advanced(by: Int(relative))
    let recordSize = Int(fields.load(fromByteOffset: 10, as: UInt16.self))
    guard fields.load(fromByteOffset: 8, as: UInt16.self) == 0, (12...64).contains(recordSize),
          Int(fields.load(fromByteOffset: 12, as: UInt32.self)) == count else { return nil }
    let record = fields.advanced(by: 16 + index * recordSize)
    let nameRef = record.advanced(by: 8)
    let nameOffset = nameRef.load(as: Int32.self)
    guard record.load(as: UInt32.self) & 2 != 0, nameOffset != 0,
          String(validatingUTF8: nameRef.advanced(by: Int(nameOffset)).assumingMemoryBound(to: CChar.self)) == "cover"
    else { return nil }
    let offset = Int(metadata.load(fromByteOffset: 8 * vectorWords + 4 * index, as: UInt32.self))
    guard offset % MemoryLayout<String?>.alignment == 0,
          offset + MemoryLayout<String?>.size <= MemoryLayout<Row>.size else { return nil }
    return offset
}

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
        var rows = owner[keyPath: list]
        guard let first = rows.first, let offset = coverMember(in: first) else { return 0 }
        var count = 0
        for i in rows.indices {
            let fields = Mirror(reflecting: rows[i]).children
            guard let platform = fields.first(where: { $0.label == "server" })?.value as? String,
                  let identifier = fields.first(where: { $0.label == "id" })?.value as? String,
                  let field = fields.first(where: { $0.label == "cover" }),
                  type(of: field.value) == Optional<String>.self,
                  let byID = changes[platform] as? NSDictionary,
                  let change = byID[identifier] as? NSDictionary,
                  let destination = change["url"] as? String,
                  let expected = change["expectedCover"] else { continue }
            let current = field.value as? String
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
            let changed = withUnsafeMutablePointer(to: &rows[i]) { element -> Bool in
                let cover = UnsafeMutableRawPointer(element).advanced(by: offset).assumingMemoryBound(to: String?.self)
                guard cover.pointee == current else { return false }
                cover.pointee = destination
                return true
            }
            if changed { count += 1 }
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
