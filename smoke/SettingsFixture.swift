// Independent Simulator-only SwiftUI surface. No original application code.
import SwiftUI
import UIKit

private func count(_ key: String) {
    let defaults = UserDefaults.standard
    defaults.set(defaults.integer(forKey: key) + 1, forKey: key)
}

private struct OriginalSettingsList: View {
    @AppStorage("searchPlatform") private var selectedPlatform: Int = 3
    private func originalAction() { count("smoke.swiftui.original-action-count") }
    private func originalInfo() { count("smoke.swiftui.original-info-count") }
    private func chooseQishui() {
        selectedPlatform = 4
        let defaults = UserDefaults.standard
        defaults.set(selectedPlatform, forKey: "smoke.swiftui.selection-immediate")
        DispatchQueue.main.async { defaults.set(selectedPlatform, forKey: "smoke.swiftui.selection-next-turn") }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            let stable = selectedPlatform
            defaults.set(stable, forKey: "smoke.swiftui.selection-stable")
            if defaults.bool(forKey: "smoke.swiftui.dispatch-search") { dispatchFixtureSearch(platform: stable) }
        }
    }
    var body: some View {
        List {
            Section("音源设置") {
                Text("自定义音源")
                Button("原设置操作", action: originalAction)
                    .accessibilityIdentifier("smoke.swiftui.original-action")
                Button("选择汽水", action: chooseQishui)
                .accessibilityIdentifier("smoke.swiftui.select-qishui")
            }
            Section("偏好设置") {
                Picker("搜索音源", selection: $selectedPlatform) {
                    Text("网易云").tag(0)
                    Text("酷狗").tag(2)
                    Text("QQ 音乐").tag(3)
                    Text("汽水").tag(4)
                }
                .accessibilityIdentifier("smoke.swiftui.native-platform")
                LabeledContent("音质", value: "标准")
                LabeledContent("语言", value: "简体中文")
            }
            Section("存储") {
                LabeledContent("音乐缓存", value: "0 MB")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("设置")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: originalInfo) {
                    Image(systemName: "info.circle")
                }
                .accessibilityLabel("原设置详情")
                .accessibilityIdentifier("smoke.swiftui.original-info")
            }
        }
        .onAppear { count("smoke.swiftui.settings-appearance-count") }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("smoke.swiftui.select-qishui-command"))) { _ in chooseQishui() }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("smoke.swiftui.original-actions-command"))) { _ in originalAction(); originalInfo() }
    }
}

// Called only while the ObjC Host has installed its deny-all fixture transport.
// Mirrors the native branch: value 4 chooses the Qishui-specific response parser;
// values 0/2/3 use the common Track response and can carry all source identities.
private func dispatchFixtureSearch(platform: Int) {
    let defaults = UserDefaults.standard
    let keyword = "fixture-swiftui-wrapper"
    let address = platform == 4
        ? "https://open.douyin.com/api/luna/v1/platform/search/"
        : "https://aacert.com/ms/api.php?action=search&keyword=\(keyword)&page=0&platform=\(platform)"
    var request = URLRequest(url: URL(string: address)!, timeoutInterval: 6)
    if platform == 4 {
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("SMOKE_SELF_AUTHORED_CLIENT_TOKEN", forHTTPHeaderField: "access-token")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["q": keyword, "cursor": "0", "search_id": "smoke-native-search", "from_search_id": "smoke-native-search", "search_type": "track", "search_method": "input", "search_scene": "normal", "scene_name": "search", "ab_param": "", "last_viewed_media": [String: Any](), "common_params": [String: Any]()] as [String: Any])
    }
    defaults.set(address, forKey: "smoke.swiftui.dispatched-search-url")
    let session = URLSession(configuration: .default)
    session.dataTask(with: request) { data, _, error in
        if let data { defaults.set(data, forKey: "smoke.swiftui.search-response") }
        if let error { defaults.set(error.localizedDescription, forKey: "smoke.swiftui.search-error") }
        defaults.set(true, forKey: "smoke.swiftui.search-complete")
        session.finishTasksAndInvalidate()
    }.resume()
}

private struct OriginalNavigationFixture: View {
    @State private var path: [String] = []
    init(startAtSettings: Bool = false) { _path = State(initialValue: startAtSettings ? ["settings"] : []) }
    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 24) {
                Text("Independent SwiftUI fixture").font(.title2)
                Text("Original navigation and settings controls")
                Button("打开原设置") {
                    count("smoke.swiftui.open-settings-count")
                    path.append("settings")
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("smoke.swiftui.open-settings")
            }
            .navigationTitle("FreeMusic")
            .navigationDestination(for: String.self) { value in
                if value == "settings" { OriginalSettingsList() }
            }
        }
    }
}

@_cdecl("SmokeMakeSwiftUIFixture")
@MainActor
public func smokeMakeSwiftUIFixture() -> UnsafeMutableRawPointer {
    let controller = UIHostingController(rootView: OriginalNavigationFixture())
    return Unmanaged.passRetained(controller as UIViewController).toOpaque()
}

// Initial navigation state is a fixture setup, not a substitute for a UI tap.
// The actual NavigationStack destination, List and original toolbar are unchanged.
@_cdecl("SmokeMakeSwiftUISettingsFixture")
@MainActor
public func smokeMakeSwiftUISettingsFixture() -> UnsafeMutableRawPointer {
    let controller = UIHostingController(rootView: OriginalNavigationFixture(startAtSettings: true))
    return Unmanaged.passRetained(controller as UIViewController).toOpaque()
}

// Component-level test command: the real View receives a Publisher event and
// invokes the same @AppStorage callback used by its button. This is not a UI tap.
@_cdecl("SmokeSwiftUISelectQishui")
@MainActor
public func smokeSwiftUISelectQishui() {
    NotificationCenter.default.post(name: Notification.Name("smoke.swiftui.select-qishui-command"), object: nil)
}

@_cdecl("SmokeSwiftUIRunOriginalActions")
@MainActor
public func smokeSwiftUIRunOriginalActions() {
    NotificationCenter.default.post(name: Notification.Name("smoke.swiftui.original-actions-command"), object: nil)
}
