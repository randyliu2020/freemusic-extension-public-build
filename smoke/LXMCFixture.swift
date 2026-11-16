// Independent, self-authored native .alert fixture. Not the original IPA.
// Shared-callback commands below test View binding semantics, not physical taps.
import SwiftUI
import UIKit

private final class LXSmokeState {
    static let shared = LXSmokeState()
    var snapshot: [String: Any] = [:]
    func reset() { snapshot = ["ui_tap_validated": false, "original_import_callback_count": 0, "completed": false] }
}

private struct LXOriginalImportFixture: View {
    @State private var showImport = true
    @State private var importURL = ""
    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                Text("Independent playlist import fixture")
                Button("导入外部歌单") { showImport = true }
            }
            .navigationTitle("资料库")
            .alert("导入外部歌单", isPresented: $showImport) {
                TextField("支持QQ音乐/网易云/酷狗歌单的URL", text: $importURL)
                Button("取消", role: .cancel) { }
                Button("导入", action: originalImport)
            }
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("LXSmoke.import-current"))) { _ in originalImport() }
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("LXSmoke.reopen-original"))) { _ in showImport = true }
            .onChange(of: importURL) { _, value in
                // Do not persist tokens in UserDefaults or put them in diagnostics.
                LXSmokeState.shared.snapshot["binding_nonempty"] = !value.isEmpty
                LXSmokeState.shared.snapshot["binding_is_local_bridge"] = value.hasPrefix("https://fmx-lxmc.invalid/import/")
            }
        }
    }
    private func originalImport() {
        let state = LXSmokeState.shared
        state.snapshot["original_import_callback_count"] = (state.snapshot["original_import_callback_count"] as? Int ?? 0) + 1
        state.snapshot["submitted_nonempty"] = !importURL.isEmpty
        state.snapshot["submitted_is_local_bridge"] = importURL.hasPrefix("https://fmx-lxmc.invalid/import/")
        showImport = false
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        var request = URLRequest(url: URL(string: "https://aacert.com/ms/api.php?action=import_playlist&_t=123")!, timeoutInterval: 6)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = "url=\(importURL.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")".data(using: .utf8)
        let session = URLSession(configuration: .default)
        session.dataTask(with: request) { data, _, error in
            let value = data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
            DispatchQueue.main.async {
                state.snapshot["completed"] = true
                state.snapshot["error_code"] = (error as NSError?)?.code ?? 0
                state.snapshot["response_code"] = value?["code"] as? Int ?? 0
                let payload = value?["data"] as? [String: Any]
                let tracks = payload?["tracks"] as? [[String: Any]] ?? []
                state.snapshot["native_tracks_count"] = tracks.count
                state.snapshot["native_servers"] = tracks.compactMap { $0["server"] as? String }
                // Fixture title is authored, but output only equality to avoid
                // making this helper accidentally log a selected real file.
                state.snapshot["expected_fixture_title"] = payload?["title"] as? String == "LX Smoke Playlist"
            }
            session.finishTasksAndInvalidate()
        }.resume()
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
