import SwiftUI
import UIKit

/// A horizontal-only `UIPanGestureRecognizer` bridged into SwiftUI. It begins
/// only when the initial movement is predominantly horizontal, so a horizontal
/// swipe (row delete, drawer close) and a List's vertical scroll never contend
/// for the same touch.
///
/// A UIKit recognizer, not a SwiftUI `DragGesture`: on iOS 26, any SwiftUI drag
/// attached in or over a List — even `simultaneousGesture` — suppresses the
/// list's scroll pan entirely, freezing vertical scrolling. UIKit's
/// `gestureRecognizerShouldBegin` is the platform-sanctioned arbitration:
/// vertical drags never leave the scroll view's ownership.
struct HorizontalPanGesture: UIGestureRecognizerRepresentable {
    var onBegan: () -> Void = {}
    /// Horizontal translation since the drag began, per tracked frame.
    let onChanged: (CGFloat) -> Void
    /// Final horizontal translation, on end/cancel/fail.
    let onEnded: (CGFloat) -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        Coordinator()
    }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.maximumNumberOfTouches = 1
        pan.delegate = context.coordinator
        return pan
    }

    func handleUIGestureRecognizerAction(
        _ recognizer: UIPanGestureRecognizer, context: Context
    ) {
        // Translation in the window, not the attached view: a consumer may move
        // its view with the drag (the drawer follows the finger), which would
        // cancel out a view-relative translation.
        switch recognizer.state {
        case .began:
            onBegan()
        case .changed:
            onChanged(recognizer.translation(in: recognizer.view?.window).x)
        case .ended, .cancelled, .failed:
            onEnded(recognizer.translation(in: recognizer.view?.window).x)
        default:
            break
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
            guard let pan = gesture as? UIPanGestureRecognizer,
                  let view = pan.view else { return false }
            let velocity = pan.velocity(in: view)
            return abs(velocity.x) > abs(velocity.y)
        }
    }
}
