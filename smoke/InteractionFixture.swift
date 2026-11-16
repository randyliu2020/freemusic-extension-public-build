// Independent Simulator-only surfaces. No original application code or songs.
// Gestures must be driven by a real UI-testing client, not the exported setup
// functions. Counters are written only by SwiftUI's actual gesture callbacks.
import SwiftUI
import UIKit

private func interactionCount(_ name: String) {
    let key = "smoke.interaction." + name
    UserDefaults.standard.set(UserDefaults.standard.integer(forKey: key) + 1, forKey: key)
}

private struct InteractionLyricFixture: View {
    @State private var expanded = false
    @State private var selectedTime = 0.0
    @State private var seekCount = 0
    private let times = [12.5, 37.0, 63.25]

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Text("自建歌词手势测试").font(.headline)
                ScrollView {
                    VStack(spacing: 20) {
                        ForEach(times.indices, id: \.self) { index in
                            Text("Fixture lyric line \(index + 1)")
                                .font(.title2)
                                .frame(maxWidth: .infinity, minHeight: 54)
                                .contentShape(Rectangle())
                                .id(index)
                                .onTapGesture(count: 1) {
                                    selectedTime = times[index]
                                    seekCount += 1
                                    interactionCount("seek-count")
                                    UserDefaults.standard.set(times[index], forKey: "smoke.interaction.seek-time")
                                }
                                .accessibilityIdentifier("smoke.interaction.lyric.\(index)")
                        }
                    }
                }
                .frame(height: 260)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    interactionCount("expand-count")
                    expanded = true
                }
                .accessibilityIdentifier("smoke.interaction.lyric-preview")
                Text("Selected: \(selectedTime)").accessibilityIdentifier("smoke.interaction.selected-time")
                Text("Seek count: \(seekCount)").accessibilityIdentifier("smoke.interaction.seek-count")
                Text("Single tap seeks; double tap expands")
            }
            .padding()
            .navigationTitle("播放")
            .sheet(isPresented: $expanded) {
                VStack {
                    Text("完整歌词页").accessibilityIdentifier("smoke.interaction.full-lyrics")
                    Button("关闭") { expanded = false }
                }
            }
        }
    }
}

private struct InteractionSearchFixture: View {
    @State private var keyword = ""
    var body: some View {
        NavigationStack {
            List {
                Section("来源") {
                    ScrollView(.horizontal) {
                        HStack { ForEach(0..<12, id: \.self) { Text("Source \($0)").padding() } }
                    }
                    .accessibilityIdentifier("smoke.interaction.horizontal-sources")
                }
                ForEach(0..<40, id: \.self) { index in
                    Text("Self-authored result \(index)")
                        .accessibilityIdentifier("smoke.interaction.result.\(index)")
                }
            }
            // Reproduce the original SearchView's missing drag dismissal policy
            // explicitly, so the test cannot pass only on an OS default.
            .scrollDismissesKeyboard(.never)
            .navigationTitle("搜索")
            .searchable(text: $keyword, placement: .navigationBarDrawer(displayMode: .always), prompt: "Fixture search")
        }
    }
}

@MainActor
private final class InteractionKeyboardController: UIViewController {
    let results = UIScrollView()
    let horizontal = UIScrollView()
    let existingInteractive = UIScrollView()
    let search = UISearchController(searchResultsController: nil)
    override func viewDidLoad() {
        super.viewDidLoad()
        title = "搜索"
        view.backgroundColor = .systemBackground
        definesPresentationContext = true
        search.obscuresBackgroundDuringPresentation = false
        navigationItem.searchController = search
        navigationItem.hidesSearchBarWhenScrolling = false
        results.accessibilityIdentifier = "smoke.interaction.vertical-results"
        results.contentSize = CGSize(width: 300, height: 2400)
        results.alwaysBounceVertical = true
        horizontal.accessibilityIdentifier = "smoke.interaction.horizontal-results"
        horizontal.contentSize = CGSize(width: 2400, height: 40)
        horizontal.alwaysBounceHorizontal = true
        existingInteractive.accessibilityIdentifier = "smoke.interaction.existing-interactive"
        existingInteractive.contentSize = CGSize(width: 300, height: 1200)
        existingInteractive.keyboardDismissMode = .interactive
        let label = UILabel(frame: CGRect(x: 12, y: 12, width: 280, height: 40))
        label.text = "Independent UIKit results"
        results.addSubview(label)
        view.addSubview(results); view.addSubview(horizontal); view.addSubview(existingInteractive)
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let top = view.safeAreaInsets.top + 12
        results.frame = CGRect(x: 10, y: top, width: view.bounds.width - 20, height: 240)
        horizontal.frame = CGRect(x: 10, y: top + 250, width: view.bounds.width - 20, height: 44)
        existingInteractive.frame = CGRect(x: 10, y: top + 306, width: view.bounds.width - 20, height: 100)
    }
}

@MainActor
private func interactionControllers(_ controller: UIViewController) -> [UIViewController] {
    var result = [controller]
    for child in controller.children { result += interactionControllers(child) }
    if let presented = controller.presentedViewController { result += interactionControllers(presented) }
    return result
}

@MainActor
private func interactionViews(_ view: UIView) -> [UIView] {
    [view] + view.subviews.flatMap(interactionViews)
}

@_cdecl("FMInteractionMakeLyricFixture")
@MainActor
public func interactionMakeLyricFixture() -> UnsafeMutableRawPointer {
    for key in ["seek-count", "seek-time", "expand-count"] {
        UserDefaults.standard.removeObject(forKey: "smoke.interaction." + key)
    }
    return Unmanaged.passRetained(UIHostingController(rootView: InteractionLyricFixture()) as UIViewController).toOpaque()
}

@_cdecl("FMInteractionMakeSwiftUISearchFixture")
@MainActor
public func interactionMakeSwiftUISearchFixture() -> UnsafeMutableRawPointer {
    Unmanaged.passRetained(UIHostingController(rootView: InteractionSearchFixture()) as UIViewController).toOpaque()
}

@_cdecl("FMInteractionMakeKeyboardFixture")
@MainActor
public func interactionMakeKeyboardFixture() -> UnsafeMutableRawPointer {
    Unmanaged.passRetained(UINavigationController(rootViewController: InteractionKeyboardController()) as UIViewController).toOpaque()
}

// Setup only: activates a real UISearchController / UISearchTextField. No gesture
// callback, keyboard notification, or production recognizer is faked.
@_cdecl("FMInteractionFixtureSetSearchEditing")
@MainActor
public func interactionFixtureSetSearchEditing(_ pointer: UnsafeMutableRawPointer, _ editing: Int32) -> Int32 {
    let controller = Unmanaged<UIViewController>.fromOpaque(pointer).takeUnretainedValue()
    for owner in interactionControllers(controller) {
        guard let search = owner.navigationItem.searchController else { continue }
        search.isActive = editing != 0
        if editing != 0 { return search.searchBar.searchTextField.becomeFirstResponder() ? 1 : 0 }
        search.searchBar.searchTextField.resignFirstResponder()
        return 1
    }
    return 0
}

@_cdecl("FMInteractionFixtureShowTextSheet")
@MainActor
public func interactionFixtureShowTextSheet(_ pointer: UnsafeMutableRawPointer) {
    let controller = Unmanaged<UIViewController>.fromOpaque(pointer).takeUnretainedValue()
    var presenter = controller
    for _ in 0..<16 {
        if let presented = presenter.presentedViewController { presenter = presented; continue }
        if let navigation = presenter as? UINavigationController, let visible = navigation.visibleViewController {
            presenter = visible; continue
        }
        break
    }
    let sheet = UIViewController()
    sheet.view.backgroundColor = .systemBackground
    let scroll = UIScrollView(frame: CGRect(x: 0, y: 80, width: 300, height: 400))
    scroll.accessibilityIdentifier = "smoke.interaction.sheet-scroll"
    scroll.contentSize = CGSize(width: 300, height: 1800)
    let field = UITextField(frame: CGRect(x: 12, y: 12, width: 270, height: 44))
    field.placeholder = "Ordinary text field, not search"
    field.borderStyle = .roundedRect
    field.accessibilityIdentifier = "smoke.interaction.ordinary-field"
    scroll.addSubview(field); sheet.view.addSubview(scroll)
    presenter.present(sheet, animated: false) { field.becomeFirstResponder() }
}

// Returns a retained NSDictionary; caller consumes with CFBridgingRelease.
// Modes/IDs belong exclusively to this self-authored test surface.
@_cdecl("FMInteractionFixtureSnapshot")
@MainActor
public func interactionFixtureSnapshot(_ pointer: UnsafeMutableRawPointer) -> UnsafeMutableRawPointer {
    let controller = Unmanaged<UIViewController>.fromOpaque(pointer).takeUnretainedValue()
    var modes: [String: Int] = [:]
    var searchCount = 0, editing = 0
    for owner in interactionControllers(controller) {
        if let search = owner.navigationItem.searchController {
            searchCount += 1
            if search.searchBar.searchTextField.isFirstResponder { editing += 1 }
        }
        if let view = owner.viewIfLoaded {
            for child in interactionViews(view) {
                if let scroll = child as? UIScrollView, let identifier = scroll.accessibilityIdentifier,
                   identifier.hasPrefix("smoke.interaction.") { modes[identifier] = scroll.keyboardDismissMode.rawValue }
            }
        }
    }
    let defaults = UserDefaults.standard
    let snapshot: NSDictionary = ["searchControllerCount": searchCount, "editingSearchCount": editing, "modes": modes,
        "seekCount": defaults.integer(forKey: "smoke.interaction.seek-count"),
        "seekTime": defaults.double(forKey: "smoke.interaction.seek-time"),
        "expandCount": defaults.integer(forKey: "smoke.interaction.expand-count")]
    return Unmanaged.passRetained(snapshot).toOpaque()
}
