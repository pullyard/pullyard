import UIKit

final class KeyboardDismisser: NSObject, UIGestureRecognizerDelegate {
    static let shared = KeyboardDismisser()

    @MainActor
    static func install() {
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            for window in scene.windows where !(window.gestureRecognizers ?? []).contains(where: { $0.name == "pullyard.dismissKeyboard" }) {
                let tap = UITapGestureRecognizer(target: shared, action: #selector(dismiss(_:)))
                tap.name = "pullyard.dismissKeyboard"
                tap.cancelsTouchesInView = false
                tap.requiresExclusiveTouchType = false
                tap.delegate = shared
                window.addGestureRecognizer(tap)
            }
        }
    }

    @objc private func dismiss(_ recognizer: UITapGestureRecognizer) {
        recognizer.view?.endEditing(true)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        var view = touch.view
        while let current = view {
            if current is UITextField || current is UITextView || current is UISearchBar { return false }
            view = current.superview
        }
        return true
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }
}
