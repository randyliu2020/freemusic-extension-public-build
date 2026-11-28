// Independent Simulator-only surfaces. No original application code or songs.
// Gestures must be driven by a real UI-testing client, not the exported setup
// functions. Counters are written only by SwiftUI's actual gesture callbacks.
import SwiftUI
import UIKit
import AVFAudio
import MediaPlayer
import Darwin

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

// XCUI sometimes reports the full tappable row for a word. Measure the
// visible sample words independently, only to place and observe real touches.
private struct InteractionWordBounds: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { _, newest in newest }
    }
}
private struct InteractionWord: View {
    let text: String
    let key: String
    var body: some View {
        Text(verbatim: text).fixedSize()
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(key: InteractionWordBounds.self,
                        value: [key: proxy.frame(in: .named("InteractionLyricsViewport"))])
                }
            }
    }
}

// The original independent header handles its own gestures; the complete
// presentation is wrapped in the same area policy as the shipped player.
private struct InteractionPlayerSwipeSurface: View {
    let regularLyrics: Bool
    @Environment(\.presentationMode) private var presentationMode
    @State private var progress = 0.5
    @State private var volume = 0.5
    @State private var selectedLine: Int?
    @State private var wordBounds: [String: CGRect] = [:]

    private func closeIfRequested(_ value: DragGesture.Value) {
        let dx = value.translation.width, dy = value.translation.height
        let left = dx < -80 && -dx > 1.5 * abs(dy)
        let originalDown = dy > 80 && abs(dx) < dy
        guard left || originalDown else { return }
        typealias Notify = @convention(c) (UnsafeRawPointer?) -> Void
        if let address = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "FMXPlayerHeaderWillDismiss") {
            let notify = unsafeBitCast(address, to: Notify.self)
            withUnsafePointer(to: value) { notify(UnsafeRawPointer($0)) }
        }
        presentationMode.wrappedValue.dismiss()
    }

    // Exercise the exact CGFloat cutoffs independently of touch pixel rounding.
    private static let thirdCutoffs: String = {
        typealias Zone = @convention(c) (Double, Double) -> UInt32
        guard let address = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "FMXPlayerZoneForTest") else { return "missing zone policy" }
        let zone = unsafeBitCast(address, to: Zone.self)
        let widths: [Double] = [300, 375, 393, 600]
        for width in widths {
            let third = width / 3
            let samples: [(Double, UInt32)] = [(third - 0.25, 1), (third, 0), (third + 0.25, 0),
                (2 * third - 0.25, 0), (2 * third, 0), (2 * third + 0.25, 1)]
            for (x, expected) in samples {
                if zone(x, width) != expected { return "wrong zone at \\(x) of \\(width)" }
            }
        }
        return "exact third cutoffs passed"
    }()

    // The production modifier receives the whole presentation, as it does in
    // the original player. The inner lyrics scroll deliberately has an inset.
    var body: some View {
        typealias Attach = @convention(c) (UnsafeMutableRawPointer?) -> Void
        var page = AnyView(surface)
        if let address = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "FMXAttachLyricTextLayout") {
            let attach = unsafeBitCast(address, to: Attach.self)
            withUnsafeMutablePointer(to: &page) { attach(UnsafeMutableRawPointer($0)) }
        }
        return page
    }

    @ViewBuilder
    private func lyric(_ index: Int) -> some View {
        if index == 0 {
            HStack {
                InteractionWord(text: "Left", key: "L")
                Spacer()
                Text("lyric")
                Spacer()
                InteractionWord(text: "Right", key: "R")
            }
        } else if index == 1 {
            VStack(spacing: 2) {
                HStack(spacing: 3) {
                    ForEach(["逐", "字", "歌", "词"], id: \.self) { Text($0) }
                }
                Text("Here is the translation across this line")
                    .font(.subheadline)
                    .accessibilityIdentifier("smoke.interaction.lyric-translation.1")
            }
        } else if index == 2 {
            InteractionWord(text: "Oh", key: "S")
        } else {
            Text(index.isMultiple(of: 3)
                 ? "A long self-authored scrolling lyric that wraps across two lines \(index)"
                 : "Lyric \(index)")
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("smoke.interaction.lyric-text.\(index)")
        }
    }

    private var surface: some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: "music.note")
                Text("Self-authored player title")
                Spacer()
                Image(systemName: "chevron.down")
            }
            .padding(.horizontal, 24)
            .frame(maxWidth: .infinity, minHeight: 76)
            .background(Color.secondary.opacity(0.15))
            .contentShape(Rectangle())
            .onTapGesture { presentationMode.wrappedValue.dismiss() }
            .gesture(DragGesture(minimumDistance: 20).onEnded(closeIfRequested), including: .all)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("smoke.interaction.player-topbar")

            Text(selectedLine.map { "Selected lyric \($0)" } ?? "Playback surface")
                .accessibilityValue(Text(verbatim: ["L", "R", "S"].map { key in
                    guard let rect = wordBounds[key] else { return "" }
                    return [rect.minX, rect.minY, rect.width, rect.height]
                        .map { String(Double($0)) }.joined(separator: ",")
                }.joined(separator: "|") + "|" + Self.thirdCutoffs))
                .accessibilityIdentifier("smoke.interaction.player-visible")
            ScrollView {
                VStack(spacing: 16) {
                    ForEach(0..<30, id: \.self) { index in
                        lyric(index)
                            .frame(maxWidth: .infinity, minHeight: 36)
                            .padding(.horizontal, regularLyrics ? 32 : 24)
                            .contentShape(Rectangle())
                            .onTapGesture { selectedLine = index }
                            .accessibilityElement(children: .contain)
                            .accessibilityIdentifier("smoke.interaction.scroll-lyric.\(index)")
                    }
                }
            }
            .frame(height: 220)
            .coordinateSpace(name: "InteractionLyricsViewport")
            .onPreferenceChange(InteractionWordBounds.self) { wordBounds = $0 }
            .accessibilityIdentifier("smoke.interaction.player-lyrics")
            // Offset only the lyric viewport. Window thirds and viewport thirds must differ.
            .padding(.leading, 48)
            .padding(.trailing, 4)
            Slider(value: $progress)
                .accessibilityIdentifier("smoke.interaction.player-progress")
            Slider(value: $volume)
                .accessibilityIdentifier("smoke.interaction.player-volume")
            ScrollView(.horizontal) {
                HStack(spacing: 20) {
                    ForEach(0..<14, id: \.self) { index in
                        Text("Horizontal \(index)").padding()
                    }
                }
            }
            .frame(height: 64)
            .accessibilityIdentifier("smoke.interaction.player-horizontal")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
    }
}

@MainActor
private final class FixturePlayback: ObservableObject {
    private var player: AVAudioPlayer?
    private(set) var startCount = 0
    var isPlaying: Bool { player?.isPlaying == true }

    func startIfNeeded() {
        guard !isPlaying else { return }
        // One second of original silent 8-bit PCM. Keep the actual audio player
        // above the presentation so a gesture only changes the presented view.
        var bytes = Data("RIFF".utf8)
        func word<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { bytes.append(contentsOf: $0) }
        }
        word(UInt32(8036)); bytes.append(contentsOf: "WAVEfmt ".utf8)
        word(UInt32(16)); word(UInt16(1)); word(UInt16(1)); word(UInt32(8000))
        word(UInt32(8000)); word(UInt16(1)); word(UInt16(8))
        bytes.append(contentsOf: "data".utf8); word(UInt32(8000))
        bytes.append(Data(repeating: 128, count: 8000))
        player = try? AVAudioPlayer(data: bytes)
        player?.numberOfLoops = -1
        if player?.play() == true { startCount += 1 }
    }
}

private struct InteractionPlayerSwipeFixture: View {
    @State private var showPlayer = false
    @State private var closeCount = 0
    @StateObject private var playback = FixturePlayback()
    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Text("Previous screen").accessibilityIdentifier("smoke.interaction.previous-screen")
                Text("Player binding: \(showPlayer ? "true" : "false")")
                    .accessibilityIdentifier("smoke.interaction.player-binding")
                Text("Closed: \(closeCount)").accessibilityIdentifier("smoke.interaction.player-close-count")
                Text(verbatim: playback.isPlaying ? "Playing; starts=\(playback.startCount)" : "Stopped")
                    .accessibilityIdentifier("smoke.interaction.audio-state")
                Button("Open player") { playback.startIfNeeded(); showPlayer = true }
                    .accessibilityIdentifier("smoke.interaction.open-player")
            }
            .navigationTitle("Library fixture")
            .fullScreenCover(isPresented: $showPlayer, onDismiss: { closeCount += 1 }) {
                InteractionPlayerSwipeSurface(regularLyrics: !closeCount.isMultiple(of: 2))
            }
        }
    }
}

@_cdecl("FMInteractionMakePlayerSwipeFixture")
@MainActor
public func interactionMakePlayerSwipeFixture() -> UnsafeMutableRawPointer {
    Unmanaged.passRetained(UIHostingController(rootView: InteractionPlayerSwipeFixture()) as UIViewController).toOpaque()
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


@MainActor
private struct InteractionSongMenuFixture: View {
    @State private var cleared = ""
    @State private var queued = ""

    @State private var translation = false
    @State private var switchToken: Int32 = 0

    private func playerLabel() -> Label<Text, Image> {
        var item = Label("显示翻译", systemImage: "character.book.closed")
        if let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "FMXMakePlayerMenuLabelForTest") {
            typealias Make = @convention(c) (UnsafeMutableRawPointer?) -> Void
            withUnsafeMutablePointer(to: &item) { unsafeBitCast(symbol, to: Make.self)(UnsafeMutableRawPointer($0)) }
        }
        return item
    }

    private func beginCurrentTrackFixture() {
        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = [MPMediaItemPropertyTitle: "Fixture A",
                                 MPNowPlayingInfoPropertyExternalContentIdentifier: "qq_a_01"]
        // XCUI cannot tap a second control through a presented native menu.
        // Switch the system's actual track metadata only after the runner has
        // seen the menu action, then acknowledge the value read from the center.
        var token: Int32 = 0
        let result = notify_register_dispatch("org.codex.fmx.smoke.switch-player-menu-track", &token, .main) { _ in
            DispatchQueue.main.async {
                let current = MPNowPlayingInfoCenter.default()
                current.nowPlayingInfo = [MPMediaItemPropertyTitle: "Fixture B",
                                          MPNowPlayingInfoPropertyExternalContentIdentifier: "wy_b"]
                if current.nowPlayingInfo?[MPNowPlayingInfoPropertyExternalContentIdentifier] as? String == "wy_b" {
                    notify_post("org.codex.fmx.smoke.player-menu-track-switched")
                }
            }
        }
        if result == NOTIFY_STATUS_OK { switchToken = token }
    }

    private func label(for id: String) -> Label<Text, Image> {
        var item = Label("下一首播放", systemImage: "text.line.first.and.arrowtriangle.forward")
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "FMXMakeSongMenuLabelForTest") else {
            return item
        }
        typealias Make = @convention(c) (UnsafeMutableRawPointer?, UnsafeRawPointer?, UnsafeRawPointer?) -> Void
        let server = (id == "A" ? "wy" : "qq") as NSString
        let track = id as NSString
        withExtendedLifetime((server, track)) {
            withUnsafeMutablePointer(to: &item) { slot in
                unsafeBitCast(symbol, to: Make.self)(slot, Unmanaged.passUnretained(server).toOpaque(), Unmanaged.passUnretained(track).toOpaque())
            }
        }
        return item
    }
    private func actions(_ id: String) -> some View {
        Button(action: { queued = id }, label: { label(for: id) })
    }
    var body: some View {
        VStack(spacing: 32) {
            Text("正在播放 C")
            ForEach(["A", "B"], id: \.self) { id in
                HStack {
                    Text("同名歌曲").accessibilityIdentifier("song.title." + id)
                    Spacer()
                    Menu { actions(id) } label: {
                        Label("更多", systemImage: "ellipsis")
                    }.accessibilityIdentifier("song.menu." + id)
                }
                .padding(.horizontal, 24)
                .contentShape(Rectangle())
                .contextMenu { actions(id) }
            }
            Menu {
                Toggle(isOn: $translation, label: playerLabel)
            } label: {
                Label("播放器更多", systemImage: "ellipsis.circle")
            }
            .accessibilityIdentifier("song.menu.player")
            Text(translation ? "translation-on" : "translation-off")
                .accessibilityIdentifier("song.menu.translation")
            Text("clear-" + cleared).accessibilityIdentifier("song.clear.result")
            Text("queue-" + queued).accessibilityIdentifier("song.queue.result")
        }
        .onAppear { beginCurrentTrackFixture() }
        .onDisappear {
            if switchToken != 0 { notify_cancel(switchToken); switchToken = 0 }
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("FMX.songCache.testCompleted"))) { event in
            if let server = event.userInfo?["server"] as? String, let id = event.userInfo?["id"] as? String {
                cleared = server + "-" + id
            }
        }
    }
}

@_cdecl("FMInteractionMakeSongMenuFixture")
@MainActor
public func interactionMakeSongMenuFixture() -> UnsafeMutableRawPointer {
    let controller = UIHostingController(rootView: InteractionSongMenuFixture())
    return Unmanaged.passRetained(controller as UIViewController).toOpaque()
}
