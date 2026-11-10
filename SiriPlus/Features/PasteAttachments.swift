import AppKit
import SwiftUI

extension View {
    /// ⌘V in this text box attaches copied files and pictures to the request; text pastes as usual.
    /// A text view pastes only text and drops pictures, so the shortcut is caught before it reaches it.
    func pastesAttachments(isActive: Bool, perform: @escaping (PastedContent) -> Void) -> some View {
        background(PasteCatcher(isActive: isActive, perform: perform))
    }
}

private struct PasteCatcher: NSViewRepresentable {
    let isActive: Bool
    let perform: (PastedContent) -> Void

    func makeNSView(context: Context) -> CatcherView { CatcherView() }

    func updateNSView(_ view: CatcherView, context: Context) {
        view.isActive = isActive
        view.perform = perform
    }

    final class CatcherView: NSView {
        var isActive = false
        var perform: ((PastedContent) -> Void)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, self.catches(event), let content = PastedContent.read() else { return event }
                self.perform?(content)
                return nil
            }
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        /// ⌘V in this box's window while the box has the focus. The key code covers non-Latin layouts.
        private func catches(_ event: NSEvent) -> Bool {
            guard isActive, event.window === window,
                  event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command else { return false }
            return event.charactersIgnoringModifiers?.lowercased() == "v" || event.keyCode == 9
        }
    }
}
