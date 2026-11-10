import Combine
import Foundation

enum GlossaryError: LocalizedError, Equatable {
    case unreadable(String)
    case empty(String)

    var errorDescription: String? {
        switch self {
        case .unreadable(let name): String(localized: "\(name) could not be read as text.")
        case .empty(let name): String(localized: "\(name) has no terms: put one term on each line.")
        }
    }
}

/// The glossaries Settings offers: the built-in ones from the app bundle and text files the user imported,
/// kept in Application Support/SiriPlus/Glossaries where they can also be edited or added by hand.
@MainActor
final class GlossaryLibrary: ObservableObject {
    @Published private(set) var builtIn: [Glossary] = []
    @Published private(set) var imported: [Glossary] = []

    /// Where imported glossaries live; nil keeps none (tests).
    let folder: URL?
    private let bundleFolder: URL?

    init(bundleFolder: URL? = Bundle.main.url(forResource: "Glossaries", withExtension: nil),
         folder: URL? = URL.applicationSupportDirectory.appending(path: "SiriPlus/Glossaries")) {
        self.bundleFolder = bundleFolder
        self.folder = folder
        reload()
    }

    var all: [Glossary] { builtIn + imported }

    /// Reads both folders again, for files added or edited in Finder.
    func reload() {
        builtIn = Self.load(bundleFolder, builtIn: true)
        imported = Self.load(folder, builtIn: false)
    }

    /// Copies a text or CSV file into the glossary folder and returns it; a file with the same name is replaced.
    @discardableResult
    func importFile(_ url: URL) throws -> Glossary {
        let name = url.deletingPathExtension().lastPathComponent
        guard let text = Self.text(of: url) else { throw GlossaryError.unreadable(url.lastPathComponent) }
        let glossary = Glossary.parse(text, id: Self.importedID(name))
        guard !glossary.terms.isEmpty else { throw GlossaryError.empty(url.lastPathComponent) }
        guard let folder else { return glossary }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try text.write(to: folder.appending(path: "\(name).txt"), atomically: true, encoding: .utf8)
        reload()
        return imported.first { $0.id == glossary.id } ?? glossary
    }

    func delete(_ id: String) {
        guard let folder, id.hasPrefix(Self.importedPrefix) else { return }
        try? FileManager.default.removeItem(at: folder.appending(path: "\(id.dropFirst(Self.importedPrefix.count)).txt"))
        reload()
    }

    /// The terms of the glossaries switched on in Settings, the user's own terms first.
    func activeTerms(_ preferences: AssistantPreferences) -> [Glossary.Term] {
        let enabled = all.filter { preferences.glossaries.contains($0.id) }
        return Glossary.custom(preferences.customTerms).terms + enabled.flatMap(\.terms)
    }

    static let importedPrefix = "file:"

    static func importedID(_ name: String) -> String { importedPrefix + name }

    private static func load(_ folder: URL?, builtIn: Bool) -> [Glossary] {
        guard let folder, let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return [] }
        return files
            .filter { ["txt", "csv", "md"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { url in
                let name = url.deletingPathExtension().lastPathComponent
                return text(of: url).map { Glossary.parse($0, id: builtIn ? name : importedID(name), isBuiltIn: builtIn) }
            }
            .filter { !$0.terms.isEmpty }
    }

    private static func text(of url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1251)
    }
}
