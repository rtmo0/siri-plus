import AppKit
import SwiftUI

extension View {
    /// A close button on the top-left corner that shows while the pointer is over the view, as on macOS notifications.
    func cornerCloseButton(_ help: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        modifier(CornerCloseButton(help: help, action: action))
    }
}

private struct CornerCloseButton: ViewModifier {
    let help: LocalizedStringKey
    let action: () -> Void
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            // The tracked area reaches past the corner so the pointer can get onto the button.
            .background(HoverTracker { isHovering = $0 }.padding(-10))
            .overlay(alignment: .topLeading) {
                // Not drawn at all until hovered: glass ignores opacity and would show through.
                if isHovering {
                    Button(action: action) {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.secondary)
                            .frame(width: 20, height: 20)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: Circle())
                    .offset(x: -6, y: -6)
                    .transition(.opacity)
                    .help(help)
                    .accessibilityLabel(Text(help))
                }
            }
            .animation(.easeOut(duration: 0.15), value: isHovering)
    }
}

/// Reports whether the pointer moves over the view, also in panels of an app that is not active.
/// A window appearing under a resting pointer does not count. It takes no clicks, so the views under it keep theirs.
private struct HoverTracker: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> TrackingView {
        TrackingView(onChange: onChange)
    }

    func updateNSView(_ view: TrackingView, context: Context) {
        view.onChange = onChange
    }

    final class TrackingView: NSView {
        var onChange: (Bool) -> Void
        private var occlusion: NSObjectProtocol?

        init(onChange: @escaping (Bool) -> Void) {
            self.onChange = onChange
            super.init(frame: .zero)
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self))
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func mouseEntered(with event: NSEvent) { onChange(true) }
        override func mouseMoved(with event: NSEvent) { onChange(true) }
        override func mouseExited(with event: NSEvent) { onChange(false) }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            occlusion.map(NotificationCenter.default.removeObserver)
            occlusion = nil
            guard let window else { return }
            // A panel shown or hidden gets no exit event; it starts without the button until the pointer moves.
            occlusion = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.onChange(false) }
            }
        }
    }
}
