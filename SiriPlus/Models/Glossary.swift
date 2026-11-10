import Foundation

/// Words a meeting is likely to contain, so speech recognition expects them and the model can restore
/// the ones it still mishears. Built-in glossaries ship with the app; others are text files the user adds.
struct Glossary: Identifiable, Equatable, Sendable {
    /// One term, and how on-device recognition tends to hear it.
    struct Term: Equatable, Sendable {
        let text: String
        var soundsLike: [String] = []
    }

    /// The file name without its extension: "it", "business", or an imported file's name.
    let id: String
    let title: String
    let terms: [Term]
    let isBuiltIn: Bool

    /// Reads a glossary file: one term per line, optionally followed by "|" and comma-separated mishearings
    /// ("Kubernetes | кубер, губерни"). Lines starting with "#" are comments; "# title: …" and
    /// "# title.ru: …" name the glossary. A CSV file's first column is the term.
    static func parse(_ text: String, id: String, isBuiltIn: Bool = false, language: String? = Locale.current.language.languageCode?.identifier) -> Glossary {
        var titles: [String: String] = [:]
        var terms: [Term] = []
        var seen: Set<String> = []
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") {
                let comment = line.dropFirst().trimmingCharacters(in: .whitespaces)
                if let colon = comment.firstIndex(of: ":") {
                    let key = comment[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                    if key == "title" || key.hasPrefix("title.") {
                        titles[key] = comment[comment.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                    }
                }
                continue
            }
            let parts = line.split(separator: "|", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard var term = parts.first, !term.isEmpty else { continue }
            // A CSV row without "|": the first column is the term.
            if parts.count == 1, term.contains(",") || term.contains(";") || term.contains("\t") {
                term = term.split(whereSeparator: { ",;\t".contains($0) }).first.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \"")) } ?? term
            }
            guard !term.isEmpty, seen.insert(term.lowercased()).inserted else { continue }
            let soundsLike = parts.count > 1
                ? parts[1].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                : []
            terms.append(Term(text: term, soundsLike: soundsLike))
        }
        let title = language.flatMap { titles["title.\($0)"] } ?? titles["title"] ?? id
        return Glossary(id: id, title: title, terms: terms, isBuiltIn: isBuiltIn)
    }

    /// Terms typed in Settings, one per line, in the same format as a file.
    static func custom(_ text: String) -> Glossary {
        let parsed = parse(text, id: "custom")
        return Glossary(id: "custom", title: String(localized: "My terms"), terms: parsed.terms, isBuiltIn: false)
    }
}

extension [Glossary.Term] {
    /// Recognition expects at most this many phrases: the materials' words first, then the glossaries.
    static let recognitionLimit = 150

    /// The phrases for speech recognition: `notes` terms first, then these, without repeats.
    func recognitionStrings(after notes: [String], limit: Int = recognitionLimit) -> [String] {
        var seen: Set<String> = []
        var strings: [String] = []
        for text in notes + map(\.text) where seen.insert(text.lowercased()).inserted {
            strings.append(text)
            if strings.count == limit { break }
        }
        return strings
    }

    /// The vocabulary block of a prompt: every term, and how recognition may have mangled it.
    var promptText: String {
        guard !isEmpty else { return "" }
        let plain = filter(\.soundsLike.isEmpty).map(\.text)
        let misheard = filter { !$0.soundsLike.isEmpty }.map { "\($0.soundsLike.joined(separator: ", ")) → \($0.text)" }
        var lines: [String] = []
        if !misheard.isEmpty { lines.append("Often misheard (heard → meant): " + misheard.joined(separator: "; ")) }
        if !plain.isEmpty { lines.append("Other terms that may come up: " + plain.joined(separator: ", ")) }
        return lines.joined(separator: "\n")
    }
}
