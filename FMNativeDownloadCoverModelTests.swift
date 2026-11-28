import Foundation
import Combine

private final class Token {}
private struct Track {
    let id: String
    let server: String
    var cover: String?
    var title: String
    var extra: [String: Int]
    var token: Token
}
private final class Library: ObservableObject {
    @Published var downloaded: [Track]
    var unrelated: [Track] = []
    init(_ rows: [Track]) { downloaded = rows }
}
@main struct NativeCoverTests {
    static func main() throws {
        var checks: [String] = []
        func check(_ ok: @autoclosure () -> Bool, _ name: String) {
            guard ok() else { fatalError(name) }
            checks.append(name)
        }
        let model = Library([])
        let token = Token()
        func row(_ server: String, _ id: String, _ cover: String?) -> Track {
            Track(id: id, server: server, cover: cover, title: "Same title", extra: ["keep": 9], token: token)
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("wy_1_cover.jpg")
        let second = root.appendingPathComponent("wy_2_cover.jpg")
        try Data([1,2,3]).write(to: first)
        var v = URLComponents(url: first, resolvingAgainstBaseURL: false)!
        v.queryItems = [URLQueryItem(name: "v", value: "fm-new")]
        let revision = v.url!
        check(tryRead(revision) == Data([1,2,3]), "file_url_revision_remains_readable_locally")
        let remote = "https://cdn.example.invalid/old"
        let newer = "https://cdn.example.invalid/new"
        let oldCache = root.appendingPathComponent("MusicCache/wy_5_cover.jpg")
        let migrated = root.appendingPathComponent("DownloadAssets/wy_5_cover.jpg")
        model.downloaded = [row("wy","1",first.absoluteString), row("wy","2",nil),
                            row("qq","1",remote), row("wy","3",newer), row("wy","5",oldCache.absoluteString)]
        var emissions = 0
        let observation = model.$downloaded.dropFirst().sink { _ in emissions += 1 }
        defer { observation.cancel() }
        let changes: NSDictionary = ["wy": [
            "1": ["url": revision.absoluteString, "expectedCover": remote as Any],
            "2": ["url": second.absoluteString, "expectedCover": NSNull() as Any],
            "3": ["url": second.absoluteString, "expectedCover": remote as Any],
            "4": ["url": second.absoluteString, "expectedCover": NSNull() as Any],
            "5": ["url": migrated.absoluteString, "expectedCover": remote as Any, "nativePaths": [oldCache.path]]]]
        let type = String(reflecting: Track.self)
        let path: AnyKeyPath = \Library.downloaded
        let changed = FMRefreshDownloadCoverModel(model, path, changes, expectedRowType: type)
        check(changed == 3 && emissions == 1, "native_published_list_rerenders_once_for_batch")
        check(model.downloaded[0].cover == revision.absoluteString, "repaired_same_native_file_changes_task_identity")
        check(model.downloaded[1].cover == second.absoluteString, "nil_cover_is_rebound_for_next_selection")
        check(model.downloaded[2].cover == remote, "same_id_different_platform_kept")
        check(model.downloaded[3].cover == newer && model.downloaded.count == 5, "late_repair_does_not_override_edit_or_resurrect_removed_row")
        check(model.downloaded[4].cover == migrated.absoluteString, "old_known_native_cache_reference_switches_to_durable_sidecar")
        check(model.downloaded.allSatisfy { $0.title == "Same title" && $0.extra["keep"] == 9 && $0.token === token },
              "all_other_fields_and_reference_identity_preserved")
        check(FMRefreshDownloadCoverModel(model, path, changes, expectedRowType: type) == 0 && emissions == 1,
              "repeated_revision_does_not_invalidate_ui")
        model.downloaded.removeAll { $0.id == "2" }
        check(FMRefreshDownloadCoverModel(model, path, changes, expectedRowType: type) == 0 && model.downloaded.count == 4,
              "deletion_between_notification_and_apply_preserved")
        check(FMRefreshDownloadCoverModel(model, path, changes, expectedRowType: "Unrelated.Track") == 0 &&
              FMRefreshDownloadCoverModel(Token(), path, changes, expectedRowType: type) == 0,
              "foreign_row_and_owner_types_rejected")
        let result: [String: Any] = ["passed": true, "checks": checks, "evidence": [
            "native_style_published_rows_updated": changed, "batch_notifications": 1,
            "matched_by_platform_and_id": true, "old_file_url_revised": true,
            "next_selected_track_reads_new_cover": true]]
        if CommandLine.arguments.count > 1 {
            try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
                .write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
        }
        print("DONE native download cover model tests")
    }
    private static func tryRead(_ url: URL) -> Data? { try? Data(contentsOf: url) }
}
