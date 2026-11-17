// Independent, self-authored native .alert fixture. Not the original IPA.
// Shared-callback commands below test View binding semantics, not physical taps.
import SwiftUI
import UIKit

// Field types verified against the host's Codable metadata. These declarations
// are authored fixtures, not copied original source or original-app execution.
private struct LXEnvelope<T: Decodable>: Decodable { let code: Int; let data: T? }
private struct LXNativeTrack: Decodable {
    let id: String; let title: String; let server: String
    let singer: String?; let artist: String?; let cover: String?; let album: String?
    let duration: Double?; let song_id: String?; let platform: Int?; let record_id: Int?
    let singer_ids: [String]?
    var bulkFields: [String: String] { ["id": id, "title": title, "server": server, "singer": singer ?? artist ?? "Unknown Artist", "cover": cover ?? ""] }
}
private struct LXImported: Decodable { let title: String; let tracks: [LXNativeTrack] }
private struct LXCreated: Decodable { let id: Int }
private struct LXNativePlaylist: Decodable, Identifiable {
    let id: Int; let title: String; let user_id: Int; let count: Int?
}

private final class LXSmokeState {
    static let shared = LXSmokeState()
    var snapshot: [String: Any] = [:]
    var generation = UUID()
    private var mountedPlaylists: Set<Int> = []
    func reset() {
        generation = UUID()
        mountedPlaylists = []
        snapshot = ["ui_tap_validated": false, "original_import_callback_count": 0,
                    "completed": false, "mounted_playlist_ids": [Int]()]
    }
    func rowMounted(_ id: Int, mounted: Bool, generation: UUID) {
        guard generation == self.generation else { return }
        if mounted { mountedPlaylists.insert(id) } else { mountedPlaylists.remove(id) }
        snapshot["mounted_playlist_ids"] = mountedPlaylists.sorted()
    }
}

private struct LXOriginalImportFixture: View {
    private let generation = LXSmokeState.shared.generation
    @State private var showImport = true
    @State private var importURL = ""
    @State private var playlists: [LXNativePlaylist] = []
    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                Text("Independent playlist import fixture")
                Button("导入外部歌单") { showImport = true }
                List(playlists) { playlist in
                    NavigationLink(playlist.title) {
                        Text("Native playlist \(playlist.id): \(playlist.count ?? 0) tracks")
                    }
                    .accessibilityIdentifier("LXFixture.Library.\(playlist.id)")
                    // SwiftUI rows can expose virtual accessibility elements
                    // without assigning that identifier to a backing UIView.
                    // Observe the actual row lifecycle instead of traversing
                    // UIKit's private hosting hierarchy in the component test.
                    .onAppear { LXSmokeState.shared.rowMounted(playlist.id, mounted: true, generation: generation) }
                    .onDisappear { LXSmokeState.shared.rowMounted(playlist.id, mounted: false, generation: generation) }
                }
            }
            .navigationTitle("资料库")
            .alert("导入外部歌单", isPresented: $showImport) {
                TextField("支持QQ音乐/网易云/酷狗歌单的URL", text: $importURL)
                Button("取消", role: .cancel) { }
                Button("导入", action: originalImport)
            }
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("LXSmoke.import-current"))) { _ in originalImport() }
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("LXSmoke.reopen-original"))) { _ in
                if generation == LXSmokeState.shared.generation { showImport = true }
            }
            .onChange(of: importURL) { _, value in
                // Do not persist tokens in UserDefaults or put them in diagnostics.
                LXSmokeState.shared.snapshot["binding_nonempty"] = !value.isEmpty
                LXSmokeState.shared.snapshot["binding_is_local_bridge"] = value.hasPrefix("https://fmx-lxmc.invalid/import/")
            }
        }
    }
    private func originalImport() {
        let state = LXSmokeState.shared
        guard generation == state.generation else { return }
        state.snapshot["original_import_callback_count"] = (state.snapshot["original_import_callback_count"] as? Int ?? 0) + 1
        state.snapshot["submitted_nonempty"] = !importURL.isEmpty
        state.snapshot["submitted_is_local_bridge"] = importURL.hasPrefix("https://fmx-lxmc.invalid/import/")
        showImport = false
        let selectedURL = importURL
        let session = URLSession(configuration: .default)
        state.snapshot["completed"] = false
        Task { @MainActor in
            defer { state.snapshot["completed"] = true; session.finishTasksAndInvalidate() }
            do {
                let parsed: LXImported = try await nativeRequest(session, action: "import_playlist", fields: ["url": selectedURL])
                state.snapshot["native_tracks_count"] = parsed.tracks.count
                state.snapshot["native_servers"] = parsed.tracks.map(\.server)
                if parsed.title.hasPrefix("FMX-LXMC-LOCAL:") {
                    // The same native save chain, with no replacement UI model:
                    // imported payload -> create ID -> bulk songs -> published list.
                    let created: LXCreated = try await nativeRequest(session, action: "playlist_create", fields: ["token": "authored-fixture", "title": parsed.title])
                    let bulk = try JSONSerialization.data(withJSONObject: parsed.tracks.map(\.bulkFields))
                    let _: Bool = try await nativeRequest(session, action: "playlist_add_tracks_bulk", fields: ["token": "authored-fixture", "playlist_id": String(created.id), "tracks": String(decoding: bulk, as: UTF8.self)])
                    let listed: [LXNativePlaylist] = try await nativeRequest(session, action: "playlist_list", fields: ["token": "authored-fixture"], get: true)
                    playlists = listed
                    let saved: [LXNativeTrack] = try await nativeRequest(session, action: "playlist_get_tracks", fields: ["token": "authored-fixture", "playlist_id": String(created.id)], get: true)
                    state.snapshot["native_playlist_id"] = created.id
                    state.snapshot["library_playlist_count"] = listed.count
                    state.snapshot["library_contains_saved_id"] = listed.contains { $0.id == created.id }
                    state.snapshot["expected_fixture_title"] = listed.contains { $0.id == created.id && $0.title == "LX Smoke Playlist" }
                    state.snapshot["native_record_ids_valid"] = !saved.isEmpty && saved.allSatisfy { ($0.record_id ?? 0) <= -1_000_000_000 }
                    state.snapshot["saved_track_ids"] = saved.map(\.id)
                    state.snapshot["swift_codable_native_chain"] = true
                    state.snapshot["negative_id_swiftui_list"] = created.id < 0 && listed.contains { $0.id == created.id }
                    state.snapshot["native_tracks_count"] = saved.count
                } else { state.snapshot["expected_fixture_title"] = parsed.title == "LX Smoke Playlist" }
                state.snapshot["response_code"] = 200
                state.snapshot["error_code"] = 0
                importURL = ""
            } catch {
                state.snapshot["error_code"] = (error as NSError).code
                state.snapshot["response_code"] = 500
            }
        }
    }
    private func nativeRequest<T: Decodable>(_ session: URLSession, action: String, fields: [String: String], get: Bool = false) async throws -> T {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        let form = fields.keys.sorted().map { "\($0.addingPercentEncoding(withAllowedCharacters: allowed)!)=\(fields[$0]!.addingPercentEncoding(withAllowedCharacters: allowed)!)" }.joined(separator: "&")
        var request = URLRequest(url: URL(string: "https://aacert.com/ms/api.php?action=\(action)" + (get ? "&\(form)" : ""))!, timeoutInterval: 6)
        request.httpMethod = get ? "GET" : "POST"
        if !get { request.httpBody = form.data(using: .utf8); request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type") }
        let (data, _) = try await session.data(for: request)
        let envelope = try JSONDecoder().decode(LXEnvelope<T>.self, from: data)
        guard envelope.code == 200, let result = envelope.data else { throw NSError(domain: "Authored.NativePlaylist", code: envelope.code) }
        return result
    }
}

@_cdecl("LXSmokeMakeImportFixture")
@MainActor
public func lxSmokeMakeImportFixture() -> UnsafeMutableRawPointer {
    LXSmokeState.shared.reset()
    let controller = UIHostingController(rootView: LXOriginalImportFixture())
    return Unmanaged.passRetained(controller as UIViewController).toOpaque()
}
@_cdecl("LXSmokeImportCurrent")
@MainActor
public func lxSmokeImportCurrent() {
    // Invoking the shared callback through a Publisher does not invoke the
    // system alert button's automatic UIKit dismissal. Reproduce that public
    // transition explicitly; this remains a component command, not a tap test.
    if let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
        .flatMap(\.windows).first(where: \.isKeyWindow) {
        var front = window.rootViewController
        while let presented = front?.presentedViewController { front = presented }
        if let alert = front as? UIAlertController, alert.title == "导入外部歌单" {
            alert.dismiss(animated: true)
        }
    }
    NotificationCenter.default.post(name: Notification.Name("LXSmoke.import-current"), object: nil)
}
@_cdecl("LXSmokeReopenOriginal")
@MainActor
public func lxSmokeReopenOriginal() {
    NotificationCenter.default.post(name: Notification.Name("LXSmoke.reopen-original"), object: nil)
}
@_cdecl("LXSmokeCopyState")
@MainActor
public func lxSmokeCopyState() -> UnsafeMutableRawPointer {
    Unmanaged.passRetained(LXSmokeState.shared.snapshot as NSDictionary).toOpaque()
}
