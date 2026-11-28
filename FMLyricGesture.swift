import SwiftUI
import UIKit

// Keep SwiftUI's measured visual lines in their scroll view's content
// coordinates. Text, audio and identifiers are never read by this observer.
@MainActor
private final class LyricViewport {
    weak var scroll: UIScrollView?
    let visible: CGRect
    let frameInWindow: CGRect
    let lines: [CGRect]

    init(scroll: UIScrollView, probe: UIView, rectangles: [CGRect]) {
        self.scroll = scroll
        visible = scroll.bounds
        frameInWindow = scroll.convert(scroll.bounds, to: nil)
        let bounds = scroll.bounds
        lines = rectangles.compactMap {
            let rect = scroll.convert($0, from: probe)
            // Ignore text outside the actual lyric viewport (header, controls).
            return rect.intersects(bounds) ? rect.intersection(bounds) : nil
        }
    }

    func isBlankBesideText(at point: CGPoint) -> Bool? {
        guard let scroll, visible.contains(point), scroll.bounds.contains(point),
              scroll.convert(scroll.bounds, to: nil).equalTo(frameInWindow) else { return nil }
        // SwiftUI may emit separate layouts for the individual karaoke words.
        // Gaps between those words belong to the same visual line.
        var row = CGRect.null
        for rect in lines where point.y >= rect.minY - 3 && point.y <= rect.maxY + 3 {
            row = row.union(rect)
        }
        guard !row.isNull else { return nil }
        return point.x < row.minX - 10 || point.x > row.maxX + 10
    }
}

@MainActor
private final class LyricGeometryView: UIView, UIGestureRecognizerDelegate {
    static let probes = NSHashTable<LyricGeometryView>.weakObjects()
    private var rectangles: [CGRect] = []
    private var measuredSize = CGSize.zero
    private var viewports: [LyricViewport] = []
    private weak var sampledScroll: UIScrollView?
    private var sampledOrigin = CGPoint.zero
    private var sampledSide: Bool?
    private var measuredBounds = CGRect.null
    private var recognizer: UITapGestureRecognizer?

    func update(rectangles: [CGRect], size: CGSize) {
        self.rectangles = rectangles
        measuredSize = size
        measure()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if let recognizer { recognizer.view?.removeGestureRecognizer(recognizer) }
        recognizer = nil
        Self.probes.remove(self)
        sampledScroll = nil
        sampledSide = nil
        viewports.removeAll()
        guard let window else { return }
        Self.probes.add(self)
        // Receive only the pre-recognition location. Reject every touch so the
        // observer never competes with selection, scrolling or native gestures.
        let observer = UITapGestureRecognizer(target: nil, action: nil)
        observer.cancelsTouchesInView = false
        observer.delaysTouchesBegan = false
        observer.delaysTouchesEnded = false
        observer.delegate = self
        window.addGestureRecognizer(observer)
        recognizer = observer
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds != measuredBounds || viewports.isEmpty { measure() }
    }

    private func measure() {
        viewports.removeAll()
        measuredBounds = bounds
        guard let window, !rectangles.isEmpty, measuredSize.width > 0,
              abs(measuredSize.width - bounds.width) <= 1,
              abs(measuredSize.height - bounds.height) <= 1 else { return }
        let area = convert(bounds, to: window)
        var stack: [UIView] = [window]
        while let view = stack.popLast() {
            guard !view.isHidden, view.alpha > 0.01 else { continue }
            stack.append(contentsOf: view.subviews)
            guard let scroll = view as? UIScrollView, scroll.isScrollEnabled,
                  scroll.bounds.height > 0, scroll.bounds.width > 0,
                  scroll.convert(scroll.bounds, to: window).intersects(area) else { continue }
            let viewport = LyricViewport(scroll: scroll, probe: self, rectangles: rectangles)
            if !viewport.lines.isEmpty { viewports.append(viewport) }
        }
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        sampledScroll = nil
        sampledSide = nil
        guard window != nil, bounds.contains(touch.location(in: self)) else { return false }
        var ancestor = touch.view
        while let view = ancestor {
            if let scroll = view as? UIScrollView,
               let viewport = viewports.first(where: { $0.scroll === scroll }) {
                let point = touch.location(in: scroll)
                sampledScroll = scroll
                sampledOrigin = CGPoint(x: point.x - scroll.bounds.minX, y: point.y - scroll.bounds.minY)
                sampledSide = viewport.isBlankBesideText(at: point)
                break
            }
            ancestor = view.superview
        }
        return false
    }

    static func sample(in scroll: UIScrollView, origin: CGPoint) -> (LyricGeometryView, Bool)? {
        let matches = probes.allObjects.filter {
            $0.window === scroll.window && $0.sampledScroll === scroll
                && abs($0.sampledOrigin.x - origin.x) <= 5 && abs($0.sampledOrigin.y - origin.y) <= 8
                && $0.sampledSide != nil
        }
        guard matches.count == 1, let probe = matches.first, let side = probe.sampledSide else { return nil }
        return (probe, side)
    }
}

@MainActor
private struct LyricLayoutObserver: UIViewRepresentable {
    let rectangles: [CGRect]
    let size: CGSize

    func makeUIView(context: Context) -> LyricGeometryView {
        let view = LyricGeometryView()
        view.isUserInteractionEnabled = false
        view.accessibilityElementsHidden = true
        return view
    }

    func updateUIView(_ view: LyricGeometryView, context: Context) {
        view.update(rectangles: rectangles, size: size)
    }
}

@_cdecl("FMXAttachLyricTextLayout")
@MainActor
public func attachLyricTextLayout(_ storage: UnsafeMutableRawPointer?) {
    guard Thread.isMainThread, let storage else { return }
    let slot = storage.assumingMemoryBound(to: AnyView.self)
    let content = slot.pointee
    slot.pointee = AnyView(content.overlayPreferenceValue(Text.LayoutKey.self) { layouts in
        GeometryReader { proxy in
            let visible = CGRect(origin: .zero, size: proxy.size)
            let lines: [CGRect] = layouts.flatMap { item -> [CGRect] in
                let anchor = proxy[item.origin]
                return item.layout.compactMap { line in
                    let rect = line.typographicBounds.rect.offsetBy(dx: anchor.x, dy: anchor.y)
                    return !rect.isEmpty && visible.intersects(rect) ? rect : nil
                }
            }
            LyricLayoutObserver(rectangles: lines, size: proxy.size)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    })
}

// DragGesture uses the lyric ScrollView's local coordinates. Match that gesture
// to its actively tracking viewport once, before UIKit ends its pan. In
// particular, neither the device's screen width nor the ending finger position
// locates the right gutter when the player is inset or shown in a smaller window.
@MainActor
private final class LyricDragOrigin {
    static let shared = LyricDragOrigin()
    private weak var scroll: UIScrollView?
    private var owner: UnsafeRawPointer?
    private var start = CGPoint.zero
    private var width: CGFloat = 0
    private var inset: CGFloat = 0
    private weak var probe: LyricGeometryView?
    private var blankBesideLine: Bool?

    private func matchingScroll(at finger: CGPoint) -> UIScrollView? {
        var match: UIScrollView?
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes
            where scene.activationState == .foregroundActive {
            for window in scene.windows where window.isKeyWindow && !window.isHidden {
                var stack: [UIView] = [window]
                while let view = stack.popLast() {
                    guard !view.isHidden, view.alpha > 0.01 else { continue }
                    stack.append(contentsOf: view.subviews)
                    guard let candidate = view as? UIScrollView, candidate.isScrollEnabled else { continue }
                    let pan = candidate.panGestureRecognizer
                    guard pan.state == .began || pan.state == .changed else { continue }
                    let bounds = candidate.bounds
                    let point = pan.location(in: candidate)
                    guard abs(point.x - bounds.minX - finger.x) <= 4,
                          abs(point.y - bounds.minY - finger.y) <= 12,
                          bounds.width > 0, bounds.height > 0 else { continue }
                    // Two simultaneously moving views with the same origin give
                    // us no trustworthy width. Keep the original scroll behavior.
                    guard match == nil else { return nil }
                    match = candidate
                }
            }
        }
        return match
    }

    func evaluate(owner current: UnsafeRawPointer, drag: DragGesture.Value,
                  ended: Bool, padding: CGFloat) -> Bool {
        let origin = drag.startLocation
        if owner != current || start != origin || inset != padding {
            owner = current
            start = origin
            inset = padding
            scroll = nil
            probe = nil
            blankBesideLine = nil
        }
        if !ended {
            if scroll == nil, let target = matchingScroll(at: drag.location) {
                scroll = target
                width = target.bounds.width
                if let (observer, isBlank) = LyricGeometryView.sample(in: target, origin: origin) {
                    probe = observer
                    blankBesideLine = isBlank
                }
            }
            return false
        }
        defer { owner = nil; scroll = nil; probe = nil; blankBesideLine = nil }
        guard let target = scroll, target.window != nil, width == target.bounds.width,
              width > 2 * padding, origin.x >= 0, origin.x <= width,
              origin.y >= 0, origin.y <= target.bounds.height else { return false }
        let delta = drag.translation
        let onSide: Bool
        if let blankBesideLine {
            guard let probe, probe.window === target.window else { return false }
            onSide = blankBesideLine
        } else {
            onSide = origin.x < padding || origin.x > width - padding
        }
        return onSide && delta.height > 144 && delta.height > 2 * abs(delta.width)
    }
}

// The existing 4.2.9 lyric callbacks provide their borrowed DragGesture.Value.
// The owner is only an identity token; we never dereference or retain it.
@_cdecl("FMXLyricGutterDismiss")
@MainActor
public func lyricGutterDismiss(_ owner: UnsafeRawPointer?, _ value: UnsafeRawPointer?,
                               _ ended: UInt32, _ style: UInt32) -> UInt32 {
    guard Thread.isMainThread, let owner, let value, style <= 1 else { return 0 }
    let drag = value.assumingMemoryBound(to: DragGesture.Value.self).pointee
    return LyricDragOrigin.shared.evaluate(owner: owner, drag: drag,
            ended: ended != 0, padding: style == 0 ? 24 : 32) ? 1 : 0
}

