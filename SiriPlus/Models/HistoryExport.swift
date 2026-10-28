import Foundation

extension ChatConversation {
    /// The chat as Markdown: each message under its author and time, with attached files named.
    func markdown(meetingTitle: String? = nil) -> String {
        var lines = ["# \(title)", "", "\(createdAt.formatted(date: .long, time: .shortened)) · \(String(localized: "\(messages.count) messages"))"]
        if let meetingTitle {
            lines += ["", "**\(String(localized: "About the meeting")):** \(meetingTitle)"]
        }
        for message in messages {
            let author = message.role == .user ? String(localized: "You") : "Siri+"
            lines += ["", "### \(author) · \(message.createdAt.formatted(date: .omitted, time: .shortened))", ""]
            var files = message.attachments.map(\.name)
            if message.imageJPEG != nil { files.append(String(localized: "Screenshot")) }
            if !files.isEmpty {
                lines += ["*\(String(localized: "Attached")): \(files.joined(separator: ", "))*", ""]
            }
            lines.append(message.text)
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }
}

/// Writes the whole history as Markdown files: a folder with meetings, chats and an index linking them.
enum HistoryExport {
    /// Creates "Siri+ History <date>" inside `directory` and returns it. A meeting's recorded sound, if any,
    /// is copied next to its Markdown and linked from it.
    @discardableResult
    static func write(
        meetings: [MeetingRecord],
        chats: [ChatConversation],
        into directory: URL,
        now: Date = Date(),
        recording: (UUID) -> URL? = { _ in nil }
    ) throws -> URL {
        let files = FileManager.default
        let folder = uniqueURL(in: directory, name: String(localized: "Siri+ History \(dateStamp(now))"), extension: nil)
        let meetingsName = String(localized: "Meetings")
        let chatsName = String(localized: "Chats")
        try files.createDirectory(at: folder, withIntermediateDirectories: true)

        var index = ["# \(String(localized: "Siri+ History"))", "", String(localized: "Exported \(now.formatted(date: .long, time: .shortened))")]
        var meetingLinks: [String] = []
        if !meetings.isEmpty {
            let subfolder = folder.appendingPathComponent(meetingsName, isDirectory: true)
            try files.createDirectory(at: subfolder, withIntermediateDirectories: true)
            for record in meetings.sorted(by: { $0.startedAt > $1.startedAt }) {
                let url = uniqueURL(in: subfolder, name: fileName(record.startedAt, record.displayTitle), extension: "md")
                var audioName: String?
                if let audio = recording(record.id) {
                    let audioURL = url.deletingPathExtension().appendingPathExtension("m4a")
                    try files.copyItem(at: audio, to: audioURL)
                    audioName = audioURL.lastPathComponent.precomposedStringWithCanonicalMapping
                }
                try record.markdown(includingTranscript: true, recording: audioName).write(to: url, atomically: true, encoding: .utf8)
                let summary = record.summary.split(whereSeparator: \.isNewline).first.map { " — " + $0.trimmingCharacters(in: CharacterSet(charactersIn: "-•* ")) } ?? ""
                meetingLinks.append("- \(record.startedAt.formatted(date: .abbreviated, time: .shortened)) [\(label(record.displayTitle))](\(link(meetingsName, url)))\(summary)")
            }
            index += ["", "## \(meetingsName) (\(meetings.count))", ""] + meetingLinks
        }
        if !chats.isEmpty {
            let subfolder = folder.appendingPathComponent(chatsName, isDirectory: true)
            try files.createDirectory(at: subfolder, withIntermediateDirectories: true)
            var chatLinks: [String] = []
            for chat in chats.sorted(by: { $0.updatedAt > $1.updatedAt }) {
                let meeting = chat.meetingID.flatMap { id in meetings.first { $0.id == id } }
                let url = uniqueURL(in: subfolder, name: fileName(chat.createdAt, chat.title), extension: "md")
                try chat.markdown(meetingTitle: meeting?.displayTitle).write(to: url, atomically: true, encoding: .utf8)
                chatLinks.append("- \(chat.createdAt.formatted(date: .abbreviated, time: .shortened)) [\(label(chat.title))](\(link(chatsName, url)))")
            }
            index += ["", "## \(chatsName) (\(chats.count))", ""] + chatLinks
        }
        if meetings.isEmpty && chats.isEmpty {
            index += ["", String(localized: "The history is empty.")]
        }
        try (index.joined(separator: "\n") + "\n").write(to: folder.appendingPathComponent("index.md"), atomically: true, encoding: .utf8)
        return folder
    }

    /// "2026-10-28 14.05 Title", safe for Finder and other systems.
    static func fileName(_ date: Date, _ title: String) -> String {
        let unsafe = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters).union(.newlines)
        let cleaned = title.components(separatedBy: unsafe).joined(separator: " ")
            .split(separator: " ").joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        let time = Calendar.current.dateComponents([.hour, .minute], from: date)
        let stamp = "\(dateStamp(date)) " + String(format: "%02d.%02d", time.hour ?? 0, time.minute ?? 0)
        return cleaned.isEmpty ? stamp : "\(stamp) \(String(cleaned.prefix(80)))"
    }

    private static func dateStamp(_ date: Date) -> String {
        let day = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", day.year ?? 0, day.month ?? 0, day.day ?? 0)
    }

    /// A relative link in angle brackets, so spaces and Cyrillic stay readable in the file.
    private static func link(_ subfolder: String, _ url: URL) -> String {
        "<\(subfolder)/\(url.lastPathComponent.precomposedStringWithCanonicalMapping)>"
    }

    /// Link text with the brackets that would end it escaped.
    private static func label(_ title: String) -> String {
        title.replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]")
    }

    /// The name, or the name with " 2", " 3"… when a file or folder already has it.
    private static func uniqueURL(in directory: URL, name: String, extension ext: String?) -> URL {
        var candidate = name
        var number = 2
        func url(_ base: String) -> URL {
            let url = directory.appendingPathComponent(base, isDirectory: ext == nil)
            return ext.map { url.appendingPathExtension($0) } ?? url
        }
        while FileManager.default.fileExists(atPath: url(candidate).path) {
            candidate = "\(name) \(number)"
            number += 1
        }
        return url(candidate)
    }
}
