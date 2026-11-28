import SwiftUI
import UIKit

// The presentation itself defines the coordinate space. Width comes from this
// player's view, including its actual window and clipping, even in split view.
private func isSide(_ x: CGFloat, width: CGFloat) -> Bool {
    guard width.isFinite, width > 0, x.isFinite, x >= 0, x <= width else { return false }
    let third = width / 3
    return x < third || x > 2 * third
}

#if FMX_ADAPTIVE_PLAYBACK_TESTING && targetEnvironment(simulator)
@_cdecl("FMXPlayerZoneForTest")
public func playerZoneForTest(_ x: Double, _ width: Double) -> UInt32 {
    isSide(CGFloat(x), width: CGFloat(width)) ? 1 : 0
}
#endif

private struct PlayerDragEnd {
    let time: Date
    let delta: CGSize

    init(_ drag: DragGesture.Value) {
        time = drag.time
        delta = drag.translation
    }

    func matches(_ other: Self) -> Bool {
        abs(time.timeIntervalSince(other.time)) <= 0.035 &&
            abs(delta.width - other.delta.width) <= 3 && abs(delta.height - other.delta.height) <= 3
    }
}

@MainActor
private final class PlayerDragState {
    static let presentations = NSHashTable<PlayerDragState>.weakObjects()
    weak var anchor: UIView?
    private weak var originWindow: UIWindow?
    private var frameAtStart = CGRect.null
    private var start: CGPoint?
    private var accepts = false
    private var latest: PlayerDragEnd?
    private var headerEnd: PlayerDragEnd?
    private var completion: PlayerDragEnd?

    func attach(_ view: UIView) {
        guard anchor !== view else { return }
        invalidate()
        anchor = view
        Self.presentations.add(self)
    }

    func invalidate() {
        start = nil
        accepts = false
        latest = nil
        completion = nil
        headerEnd = nil
        originWindow = nil
        frameAtStart = .null
    }

    func cancelTracking() {
        start = nil
        accepts = false
        latest = nil
    }

    func finishCancelledDrag() {
        guard let last = latest else { return }
        // SwiftUI may reset its gesture state before delivering onEnded.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.latest?.time == last.time else { return }
            self.cancelTracking()
        }
    }

    // Hit-test only the start of a side drag. UIKit controls and horizontal
    // scrolling strips continue to own touches beginning on them.
    private func reservedControl(_ point: CGPoint, in window: UIWindow) -> Bool {
        var view = window.hitTest(point, with: nil)
        while let item = view {
            if item is UIControl || item.accessibilityTraits.contains(.adjustable) { return true }
            if let scroll = item as? UIScrollView, scroll.isScrollEnabled,
               scroll.alwaysBounceHorizontal || (scroll.contentSize.width > scroll.bounds.width + 2 &&
                   scroll.contentSize.height <= scroll.bounds.height + 2) { return true }
            view = item.superview
        }
        return false
    }

    private func visibleFrame(of anchor: UIView, in window: UIWindow) -> CGRect {
        var area = anchor.convert(anchor.bounds, to: window).intersection(window.bounds)
        var container = anchor.superview
        while let parent = container, parent !== window {
            if parent.clipsToBounds {
                area = area.intersection(parent.convert(parent.bounds, to: window))
            }
            container = parent.superview
        }
        return area
    }

    func changed(_ drag: DragGesture.Value) {
        if start != drag.startLocation {
            invalidate()
            start = drag.startLocation
            guard let anchor, let window = anchor.window else { return }
            originWindow = window
            let frame = visibleFrame(of: anchor, in: window)
            let point = anchor.convert(drag.startLocation, to: window)
            frameAtStart = frame
            if frame.contains(point), isSide(point.x - frame.minX, width: frame.width) {
                accepts = !reservedControl(point, in: window)
            }
        }
        latest = PlayerDragEnd(drag)
        // Once a person starts scrubbing horizontally, going down later cannot
        // turn that same touch sequence into a dismissal.
        if abs(drag.translation.width) >= 14 &&
            abs(drag.translation.width) > 1.5 * abs(drag.translation.height) {
            accepts = false
        }
    }

    func ended(_ drag: DragGesture.Value, dismiss: @escaping () -> Void) {
        changed(drag)
        let accepted = accepts
        cancelTracking()
        let delta = drag.translation
        guard accepted, delta.height > 144, delta.height > 2 * abs(delta.width),
              let anchor, let window = originWindow, anchor.window === window,
              visibleFrame(of: anchor, in: window) == frameAtStart else { return }
        let event = PlayerDragEnd(drag)
        completion = event
        // Child and parent onEnded callback order is not a SwiftUI contract.
        // Give the existing top bar its original action, whichever callback ran
        // first. A later presentation or resize cannot consume the old gesture.
        DispatchQueue.main.async { [weak self, weak window, weak anchor] in
            guard let self, let window, let anchor, self.anchor === anchor, anchor.window === window,
                  self.completion?.matches(event) == true else { return }
            self.completion = nil
            guard self.headerEnd?.matches(event) != true,
                  self.visibleFrame(of: anchor, in: window) == self.frameAtStart else { return }
            dismiss()
        }
    }

    // A native header only marks an existing drag in the same event sequence.
    // Views in other windows without a corresponding drag stay independent.
    static func nativeHeaderEnded(_ drag: DragGesture.Value) {
        let event = PlayerDragEnd(drag)
        let active = presentations.allObjects.filter {
            $0.originWindow != nil && ($0.start != nil || $0.completion?.matches(event) == true)
        }
        let matched = active.filter {
            $0.completion?.matches(event) == true || $0.latest?.matches(event) == true
        }
        if matched.count == 1 {
            matched[0].headerEnd = event
        } else if active.count == 1 {
            active[0].headerEnd = event
        }
    }
}

@MainActor
private struct PlayerGestureAnchor: UIViewRepresentable {
    let state: PlayerDragState

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        view.accessibilityElementsHidden = true
        state.attach(view)
        return view
    }

    func updateUIView(_ view: UIView, context: Context) { state.attach(view) }
}

@MainActor
private struct PlayerGestureSurface: View {
    let content: AnyView
    @Environment(\.presentationMode) private var presentation
    @State private var state = PlayerDragState()
    @GestureState private var tracking = false

    init(content: AnyView) { self.content = content }

    var body: some View {
        content
            .background {
                GeometryReader { proxy in
                    PlayerGestureAnchor(state: state)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
            .simultaneousGesture(
                DragGesture(minimumDistance: 12, coordinateSpace: .local)
                    .updating($tracking) { _, tracking, _ in tracking = true }
                    .onChanged { state.changed($0) }
                    .onEnded { value in
                        state.ended(value) { presentation.wrappedValue.dismiss() }
                    }
            )
            .onChange(of: tracking) { _, active in
                if !active { state.finishCancelledDrag() }
            }
            .onDisappear { state.invalidate() }
    }
}

// Retain the existing App-to-extension entry point. This installs only a
// gesture on the player; no lyric text, geometry preferences or window-wide
// recognizers are collected.
@_cdecl("FMXAttachLyricTextLayout")
@MainActor
public func attachPlayerGesture(_ storage: UnsafeMutableRawPointer?) {
    guard Thread.isMainThread, let storage else { return }
    let slot = storage.assumingMemoryBound(to: AnyView.self)
    slot.pointee = AnyView(PlayerGestureSurface(content: slot.pointee))
}

@_cdecl("FMXPlayerHeaderWillDismiss")
@MainActor
public func playerHeaderWillDismiss(_ value: UnsafeRawPointer?) {
    guard Thread.isMainThread, let value else { return }
    PlayerDragState.nativeHeaderEnded(value.assumingMemoryBound(to: DragGesture.Value.self).pointee)
}
