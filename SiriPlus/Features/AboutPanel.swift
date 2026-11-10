import AppKit

/// The standard About window with what Siri+ is, its license and where to find it.
@MainActor
enum AboutPanel {
    static let repository = URL(string: "https://github.com/rtmo0/siri-plus")!
    static let support = URL(string: "https://boosty.to/rtm00")!

    static func show(version: String) {
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Siri+",
            .applicationVersion: version,
            .version: "",
            .credits: credits,
        ])
        // The panel opens behind other apps' windows without this, as Siri+ has no Dock icon.
        NSApp.windows.first { $0.className.contains("About") }?.orderFrontRegardless()
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
