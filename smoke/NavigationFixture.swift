// Independent original-shaped SwiftUI surface. No original IPA code or private data.
import SwiftUI
import UIKit

private func fmNavCount(_ key: String) {
    let defaults = UserDefaults.standard
    defaults.set(defaults.integer(forKey: key) + 1, forKey: key)
}

private struct FMNavLibrary: View {
    @State private var path: [String] = []
    var body: some View {
        NavigationStack(path: $path) {
            List {
                NavigationLink("我喜欢", value: "我喜欢")
                    .accessibilityIdentifier("smoke.fmnav.likes-link")
                    .onAppear { fmNavCount("smoke.fmnav.likes-row-count") }
                NavigationLink("其他歌单", value: "其他歌单")
                    .onAppear { fmNavCount("smoke.fmnav.other-row-count") }
            }
            .navigationTitle("资料库")
            .navigationDestination(for: String.self) { title in
                List { Text("Independent fixture song") }
                    .navigationTitle(title)
                    .onAppear {
                        if title == "我喜欢" { fmNavCount("smoke.fmnav.likes-appearance-count") }
                    }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("smoke.fmnav.open-favorites-command"))) { _ in path.append("我喜欢") }
    }
}

private struct FMNavProfile: View {
    @State private var showSettings = false
    private func originalGear() {
        fmNavCount("smoke.fmnav.original-gear-count")
        showSettings = true
    }
    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                Image(systemName: "person.crop.circle.fill").font(.system(size: 64))
                Text("Independent profile")
                HStack { Text("编辑资料"); Text("最近播放") }
                Spacer()
            }
            .navigationTitle("我的")
            .navigationDestination(isPresented: $showSettings) {
                List {
                    Text("自定义音源")
                    Text("音质")
                    Text("音乐缓存")
                    Text("关于 FreeMusic")
                }
                .navigationTitle("设置")
                .onAppear { fmNavCount("smoke.fmnav.settings-appearance-count") }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: originalGear) { Image(systemName: "gearshape") }
                        .accessibilityLabel("原设置")
                        .accessibilityIdentifier("smoke.fmnav.original-gear")
                }
            }
            .onAppear { fmNavCount("smoke.fmnav.profile-appearance-count") }
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("smoke.fmnav.original-gear-command"))) { _ in originalGear() }
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("smoke.fmnav.close-settings-command"))) { _ in showSettings = false }
        }
    }
}

@available(iOS 18.0, *)
private struct FMNavRoot: View {
    @State private var selection = 2
    let matched: Bool
    var body: some View {
        TabView(selection: $selection) {
            Tab("首页", systemImage: "house", value: 0) { Text("Home fixture") }
            Tab(matched ? "发现" : "Unrelated tab", systemImage: "square.grid.2x2", value: 1) { Text("Discover fixture") }
            Tab("资料库", systemImage: "music.note.list", value: 2) { FMNavLibrary() }
            Tab("我的", systemImage: "person.crop.circle", value: 3) { FMNavProfile() }
            Tab("搜索", systemImage: "magnifyingglass", value: 4, role: .search) { Text("Search fixture") }
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("smoke.fmnav.select-profile-command"))) { _ in selection = 3 }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("smoke.fmnav.select-library-command"))) { _ in selection = 2 }
    }
}

@_cdecl("FMNavMakeFixture")
@MainActor
public func fmNavMakeFixture() -> UnsafeMutableRawPointer {
    let controller: UIViewController
    if #available(iOS 18.0, *) { controller = UIHostingController(rootView: FMNavRoot(matched: true)) }
    else { controller = UIViewController() }
    return Unmanaged.passRetained(controller).toOpaque()
}

@_cdecl("FMNavMakeMismatchedFixture")
@MainActor
public func fmNavMakeMismatchedFixture() -> UnsafeMutableRawPointer {
    let controller: UIViewController
    if #available(iOS 18.0, *) { controller = UIHostingController(rootView: FMNavRoot(matched: false)) }
    else { controller = UIViewController() }
    return Unmanaged.passRetained(controller).toOpaque()
}

// Fixture commands exercise the same state/action callbacks; they are not UI-tap claims.
@_cdecl("FMNavSelectProfile")
@MainActor
public func fmNavSelectProfile() {
    NotificationCenter.default.post(name: Notification.Name("smoke.fmnav.select-profile-command"), object: nil)
}
@_cdecl("FMNavSelectLibrary")
@MainActor
public func fmNavSelectLibrary() {
    NotificationCenter.default.post(name: Notification.Name("smoke.fmnav.select-library-command"), object: nil)
}
@_cdecl("FMNavRunOriginalGear")
@MainActor
public func fmNavRunOriginalGear() {
    NotificationCenter.default.post(name: Notification.Name("smoke.fmnav.original-gear-command"), object: nil)
}
@_cdecl("FMNavCloseOriginalSettings")
@MainActor
public func fmNavCloseOriginalSettings() {
    NotificationCenter.default.post(name: Notification.Name("smoke.fmnav.close-settings-command"), object: nil)
}

@_cdecl("FMNavOpenFavorites")
@MainActor
public func fmNavOpenFavorites() {
    NotificationCenter.default.post(name: Notification.Name("smoke.fmnav.open-favorites-command"), object: nil)
}
