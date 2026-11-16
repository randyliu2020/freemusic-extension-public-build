// Independent original-shaped SwiftUI surface. No original IPA code or private data.
import SwiftUI
import UIKit

private func fmNavCount(_ key: String) {
    let defaults = UserDefaults.standard
    defaults.set(defaults.integer(forKey: key) + 1, forKey: key)
}

private struct FMNavLibrary: View {
    let hideAccessibility: Bool
    var body: some View {
        NavigationStack {
            List {
                NavigationLink("我喜欢") {
                    List { Text("Independent fixture song") }
                        .navigationTitle("我喜欢")
                        .onAppear { fmNavCount("smoke.fmnav.likes-appearance-count") }
                }
                .accessibilityIdentifier("smoke.fmnav.likes-link")
                .accessibilityHidden(hideAccessibility)
                NavigationLink("其他歌单") {
                    Text("Other playlist").navigationTitle("其他歌单")
                }
            }
            .navigationTitle("资料库")
            .onAppear { fmNavCount("smoke.fmnav.library-appearance-count") }
        }
    }
}

private struct FMNavProfile: View {
    private func originalGear() { fmNavCount("smoke.fmnav.original-gear-count") }
    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                Image(systemName: "person.crop.circle.fill").font(.system(size: 64))
                Text("Independent profile")
                HStack { Text("编辑资料"); Text("最近播放") }
                Spacer()
            }
            .navigationTitle("我的")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: originalGear) { Image(systemName: "gearshape") }
                        .accessibilityLabel("原设置")
                        .accessibilityIdentifier("smoke.fmnav.original-gear")
                }
            }
            .onAppear { fmNavCount("smoke.fmnav.profile-appearance-count") }
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("smoke.fmnav.original-gear-command"))) { _ in originalGear() }
        }
    }
}

@available(iOS 18.0, *)
private struct FMNavRoot: View {
    @State private var selection = 2
    let matched: Bool
    var hideAccessibility = false
    var body: some View {
        TabView(selection: $selection) {
            Tab("首页", systemImage: "house", value: 0) { Text("Home fixture") }
            Tab(matched ? "发现" : "Unrelated tab", systemImage: "square.grid.2x2", value: 1) { Text("Discover fixture") }
            Tab("资料库", systemImage: "music.note.list", value: 2) { FMNavLibrary(hideAccessibility: hideAccessibility) }
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

// The same visible native List/NavigationLink with its AX link deliberately
// absent. Navigation must still use the original cell's public primary action.
@_cdecl("FMNavMakeAXEmptyFixture")
@MainActor
public func fmNavMakeAXEmptyFixture() -> UnsafeMutableRawPointer {
    let controller: UIViewController
    if #available(iOS 18.0, *) { controller = UIHostingController(rootView: FMNavRoot(matched: true, hideAccessibility: true)) }
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
