import AppKit
import SwiftUI

extension View {
    /// ⌘V in this text box attaches copied files and pictures to the request; text pastes as usual.
    /// A text view pastes only text and drops pictures, so the shortcut is caught before it reaches it.
    func pastesAttachments(isActive: Bool, perform: @escaping (PastedContent) -> Void) -> some View {
        modifier(PasteAttachments(isActive: isActive, perform: perform))
    }
}

/// Registers the focused text box's handler for its window. No AppKit view is added to the layout:
/// a representable inside a growing text box took part in every layout pass of the window.
private struct PasteAttachments: ViewModifier {
    let isActive: Bool
    let perform: (PastedContent) -> Void
    @State private var token = UUID()

    func body(content: Content) -> some View {
        content
            .onChange(of: isActive, initial: true) { _, active in
                if active {
                    PasteRouter.shared.register(token, window: NSApp.keyWindow, perform: perform)
                } else {
                    PasteRouter.shared.unregister(token)
                }
            }
            .onDisappear { PasteRouter.shared.unregister(token) }
    }
}

/// One key monitor for the app: ⌘V in a window whose focused text box asked for attachments.
@MainActor
final class PasteRouter {
    static let shared = PasteRouter()

    private struct Entry {
        weak var window: NSWindow?
        let perform: (PastedContent) -> Void
    }

    private var entries: [UUID: Entry] = [:]
    private var monitor: Any?

    func register(_ token: UUID, window: NSWindow?, perform: @escaping (PastedContent) -> Void) {
        guard let window else { return }
        entries[token] = Entry(window: window, perform: perform)
        installMonitor()
    }

    func unregister(_ token: UUID) {
        entries[token] = nil
    }

    private func installMonitor() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Local monitors run on the main thread.
            nonisolated(unsafe) let event = event
            let handled = MainActor.assumeIsolated { PasteRouter.shared.handle(event) }
            return handled ? nil : event
        }
    }

    /// ⌘V while a registered text box of the event's window is being edited. The key code covers non-Latin layouts.
    private func handle(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
              event.charactersIgnoringModifiers?.lowercased() == "v" || event.keyCode == 9,
              let window = event.window, window.firstResponder is NSTextView,
              let entry = entries.values.first(where: { $0.window === window }),
              let content = PastedContent.read() else { return false }
        entry.perform(content)
        return true
    }
}
