import AppKit

/// The standard About window with what Siri+ is, its license and where to find it.
@MainActor
enum AboutPanel {
    static let repository = URL(string: "https://github.com/rtmo0/siri-plus")!
    static let support = URL(string: "https://boosty.to/rtm00")!

    static func show(version: String) {
        let existing = Set(NSApp.windows.map(ObjectIdentifier.init))
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Siri+",
            .applicationVersion: version,
            .version: "",
            .credits: credits,
        ])
        // macOS 26 may refuse to activate a menu bar app from its menu, and the panel then stays behind other
        // apps' windows. As with the main window, it is found once it appears and lifted above the others.
        Task { @MainActor in
            for _ in 0..<20 {
                let panel = NSApp.windows.first { !existing.contains(ObjectIdentifier($0)) && $0.isVisible }
                    ?? NSApp.windows.first { $0.className.localizedCaseInsensitiveContains("about") }
                if let panel {
                    panel.level = .floating
                    panel.orderFrontRegardless()
                    panel.makeKeyAndOrderFront(nil)
                    NSApp.activate()
                    try? await Task.sleep(for: .milliseconds(300))
                    panel.level = .normal
                    return
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    private static var credits: NSAttributedString {
        let center = NSMutableParagraphStyle()
        center.alignment = .center
        center.paragraphSpacing = 4
        let body: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: center,
        ]
        var tagline = body
        tagline[.font] = NSFont.systemFont(ofSize: 11, weight: .medium)
        tagline[.foregroundColor] = NSColor.labelColor
        func link(_ url: URL) -> [NSAttributedString.Key: Any] {
            var attributes = body
            attributes[.link] = url
            attributes[.foregroundColor] = NSColor.linkColor
            return attributes
        }
        let text = NSMutableAttributedString()
        text.append(NSAttributedString(string: String(localized: "Meeting hints and an assistant in the menu bar. Speech is recognized on this Mac.") + "\n\n", attributes: tagline))
        text.append(NSAttributedString(string: String(localized: "Free and open source under the GNU GPL v3.") + "\n", attributes: body))
        text.append(NSAttributedString(string: String(localized: "Provided “as is”, without warranty.") + "\n", attributes: body))
        text.append(NSAttributedString(string: repository.absoluteString.replacingOccurrences(of: "https://", with: ""), attributes: link(repository)))
        text.append(NSAttributedString(string: "\n\n" + String(localized: "Support development:") + " ", attributes: body))
        text.append(NSAttributedString(string: "boosty.to/rtm00", attributes: link(support)))
        return text
    }
}
