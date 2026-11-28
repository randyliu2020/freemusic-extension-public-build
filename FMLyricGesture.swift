import SwiftUI
import UIKit

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
        }
        if !ended {
            if scroll == nil, let target = matchingScroll(at: drag.location) {
                scroll = target
                width = target.bounds.width
            }
            return false
        }
        defer { owner = nil; scroll = nil }
        guard let target = scroll, target.window != nil, width == target.bounds.width,
              width > 2 * padding, origin.x >= 0, origin.x <= width,
              origin.y >= 0, origin.y <= target.bounds.height else { return false }
        let delta = drag.translation
        return (origin.x < padding || origin.x > width - padding)
            && delta.height > 144 && delta.height > 2 * abs(delta.width)
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
