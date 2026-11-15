import AppKit
import SwiftUI

/// Takes the close button away from the window that contains it while `isLocked`.
///
/// Closing the only window quits the app (see `AppDelegate`). While a recording is running
/// the quit asks for confirmation, and answering "Don't Quit" would leave a windowless app
/// that is still recording. With the close button (and so Cmd-W) disabled the window cannot
/// go away under a live recording; Cmd-Q still asks, and keeps the window when declined.
///
/// A window's `.closable` style flag drives both the red button and the Close menu item,
/// and, unlike a window delegate, SwiftUI leaves it alone.
struct WindowCloseLock: NSViewRepresentable {
    let isLocked: Bool

    func makeNSView(context: Context) -> LockView {
        LockView()
    }

    func updateNSView(_ view: LockView, context: Context) {
        view.isLocked = isLocked
    }

    final class LockView: NSView {
        var isLocked = false {
            didSet { apply() }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
        }

        private func apply() {
            guard let window else { return }
            // Only on a change: the model redraws ~10 times a second while recording.
            let shouldBeClosable = !isLocked
            guard window.styleMask.contains(.closable) != shouldBeClosable else { return }
            if shouldBeClosable {
                window.styleMask.insert(.closable)
            } else {
                window.styleMask.remove(.closable)
            }
        }
    }
}
