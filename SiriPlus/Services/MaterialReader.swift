import AppKit
import Foundation
import Vision

/// Turns files added to the meeting materials into text, all on this Mac: documents are read,
/// pictures go through text recognition, audio and video through speech recognition.
enum MaterialReader {
    /// Materials go with every hint, so each file adds at most this much.
    static let fileLimit = 40_000

    static func text(from url: URL, locales: [Locale]) async throws -> String {
        if MediaTranscriber.isMedia(url) {
            return limited(try await MediaTranscriber.transcribe(url, locales: locales).text)
        }
        let attachment = try ChatAttachment.load(from: url)
        switch attachment.content {
        case .text(let text):
            return limited(text)
        case .image(let jpeg):
            guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw AttachmentError.unreadable(attachment.name) }
            return try await text(from: image, name: attachment.name, locales: locales)
        }
    }

    /// The text visible on a picture. An `NSImage` is turned into a `CGImage` by the caller, on the main actor:
    /// a drawn image may draw only there.
    static func text(from cgImage: CGImage, name: String, locales: [Locale]) async throws -> String {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let languages = locales.map(\.language) + [Locale.Language(identifier: "en-US"), Locale.Language(identifier: "ru-RU")]
        request.recognitionLanguages = languages.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
        let lines = try await request.perform(on: cgImage).compactMap { $0.topCandidates(1).first?.string }
        let text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw AttachmentError.empty(name) }
        return limited(text)
    }

    /// One file as a block of the materials: its name, then its text.
    static func block(name: String, text: String) -> String {
        "— \(name) —\n\(text)"
    }

    static func limited(_ text: String) -> String {
        text.count > fileLimit ? String(text.prefix(fileLimit)) + "\n[…]" : text
    }
}
