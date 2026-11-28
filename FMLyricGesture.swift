import SwiftUI
import UIKit

#if FMX_ADAPTIVE_PLAYBACK_TESTING && targetEnvironment(simulator)
@MainActor
private enum LyricGestureTrace {
    static var layout = "no-layout"
    static var touch = "no-touch"
    static var decision = "no-gesture"
}

@_cdecl("FMXCopyLyricGestureTestTrace")
@MainActor
public func copyLyricGestureTestTrace() -> UnsafeMutableRawPointer? {
    guard Thread.isMainThread else { return nil }
    let report = "\(LyricGestureTrace.layout); \(LyricGestureTrace.touch); \(LyricGestureTrace.decision)"
    return Unmanaged.passRetained(report as NSString).toOpaque()
}
#endif

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
              scroll.convert(scroll.bounds, to: nil) == frameInWindow else { return nil }
        // SwiftUI may emit separate layouts for the individual karaoke words.
        // Gaps between those words belong to the same visual line.
        var row = CGRect.null
        for rect in lines where point.y >= rect.minY - 3 && point.y <= rect.maxY + 3 {
            row = row.union(rect)
        }
        #if FMX_ADAPTIVE_PLAYBACK_TESTING && targetEnvironment(simulator)
        LyricGestureTrace.touch += " view=\(scroll.bounds.size) point=\(point) row=\(row)"
        #endif
        guard !row.isNull else { return nil }
        if point.x >= row.minX && point.x <= row.maxX { return false }
        // Allow the native 24/32-point gutter to decide near an uncertain
        // typographic edge; interior touches there continue to scroll.
        if point.x > row.minX - 10 && point.x < row.maxX + 10 { return nil }
        return true
    }
}

@MainActor
private final class LyricGeometryView: UIView, UIGestureRecognizerDelegate {
    static let probes = NSHashTable<LyricGeometryView>.weakObjects()
    private var rectangles: [CGRect] = []
    private var measuredSize = CGSize.zero
    private var viewports: [LyricViewport] = []
    private struct Sample {
        weak var scroll: UIScrollView?
        let origin: CGPoint
        let side: Bool
    }
    private var samples: [Sample] = []
    private var measuredBounds = CGRect.null
    private var recognizer: UITapGestureRecognizer?

    func update(rectangles: [CGRect], size: CGSize) {
        guard rectangles != self.rectangles || size != measuredSize
                || measuredBounds != bounds || !viewports.contains(where: { $0.scroll?.window != nil }) else { return }
        self.rectangles = rectangles
        measuredSize = size
        measure()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if let recognizer { recognizer.view?.removeGestureRecognizer(recognizer) }
        recognizer = nil
        Self.probes.remove(self)
        samples.removeAll()
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
        #if FMX_ADAPTIVE_PLAYBACK_TESTING && targetEnvironment(simulator)
        defer { LyricGestureTrace.layout = "lines=\(rectangles.count) viewports=\(viewports.count) size=\(bounds.size)" }
        #endif
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
        samples.removeAll()
        #if FMX_ADAPTIVE_PLAYBACK_TESTING && targetEnvironment(simulator)
        LyricGestureTrace.touch = "touch=\(touch.location(in: self))"
        #endif
        guard window != nil, bounds.contains(touch.location(in: self)) else { return false }
        // A SwiftUI hosting view can be the UIKit hit target for sibling
        // subtrees. The native drag will identify the actual scrolling view.
        for viewport in viewports {
            guard let scroll = viewport.scroll, scroll.window === window else { continue }
            let point = touch.location(in: scroll)
            if let side = viewport.isBlankBesideText(at: point) {
                let origin = CGPoint(x: point.x - scroll.bounds.minX, y: point.y - scroll.bounds.minY)
                samples.append(Sample(scroll: scroll, origin: origin, side: side))
            }
        }
        return false
    }

    static func sample(in scroll: UIScrollView, origin: CGPoint) -> (LyricGeometryView, Bool)? {
        var result: (LyricGeometryView, Bool)?
        for probe in probes.allObjects where probe.window === scroll.window {
            guard let sample = probe.samples.first(where: {
                $0.scroll === scroll && abs($0.origin.x - origin.x) <= 5 && abs($0.origin.y - origin.y) <= 8
            }) else { continue }
            guard result == nil else { return nil }
            result = (probe, sample.side)
        }
        return result
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
                .frame(width: proxy.size.width, height: proxy.size.height)
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
    private var viewportAtStart = CGRect.null
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
                viewportAtStart = target.convert(target.bounds, to: nil)
                if let (observer, isBlank) = LyricGeometryView.sample(in: target, origin: origin) {
                    probe = observer
                    blankBesideLine = isBlank
                }
            }
            return false
        }
        #if FMX_ADAPTIVE_PLAYBACK_TESTING && targetEnvironment(simulator)
        let mode = blankBesideLine.map { $0 ? "blank" : "text" } ?? "fallback"
        LyricGestureTrace.decision = "matched=\(scroll != nil) mode=\(mode) origin=\(origin) delta=\(drag.translation)"
        #endif
        defer { owner = nil; scroll = nil; probe = nil; blankBesideLine = nil }
        let width = viewportAtStart.width
        guard let target = scroll, target.window != nil, target.convert(target.bounds, to: nil) == viewportAtStart,
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

