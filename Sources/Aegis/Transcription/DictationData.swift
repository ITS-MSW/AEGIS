import Foundation
import Combine

struct DictationWord: Codable, Identifiable, Equatable {
    var id = UUID()
    var heard: String
    var replacement: String
}

struct DictationDay: Codable, Identifiable {
    var id: String
    var words = 0
    var sessions = 0
    var seconds: Double = 0

    var date: Date {
        let parts = id.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return .distantPast }
        return Calendar(identifier: .gregorian).date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) ?? .distantPast
    }

    static func key(_ date: Date) -> String {
        let parts = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}

@MainActor
final class DictationData: ObservableObject {
    static let shared = DictationData()
    @Published private(set) var vocabulary: [DictationWord] = []
    @Published private(set) var days: [DictationDay] = []
    @Published var error: String?
    private let directory: URL
    private var unreadable = Set<String>()

    init(directory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Aegis/Dictation", isDirectory: true)) {
        self.directory = directory
        vocabulary = load([DictationWord].self, name: "vocabulary") ?? []
        days = load([DictationDay].self, name: "insights") ?? []
    }

    private func load<T: Decodable>(_ type: T.Type, name: String) -> T? {
        let file = directory.appendingPathComponent(name + ".json")
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        do { return try JSONDecoder().decode(type, from: Data(contentsOf: file)) }
        catch {
            unreadable.insert(name)
            self.error = "Could not read saved \(name)."
            return nil
        }
    }

    private func save<T: Encodable>(_ value: T, name: String) throws {
        guard !unreadable.contains(name) else { throw DictationFailure(message: "Could not read saved \(name). Existing data has been preserved.") }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let file = directory.appendingPathComponent(name + ".json")
            try JSONEncoder().encode(value).write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            error = nil
        } catch {
            throw DictationFailure(message: "Could not save \(name). Check available storage and try again.")
        }
    }

    func saveWord(id: UUID? = nil, heard: String, replacement: String) throws {
        let heard = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        let replacement = replacement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !heard.isEmpty, !replacement.isEmpty, heard.count <= 120, replacement.count <= 120,
              !heard.contains(where: \.isNewline), !replacement.contains(where: \.isNewline) else {
            throw DictationFailure(message: "Enter both phrases using 120 characters or fewer.")
        }
        var updated = vocabulary
        if updated.contains(where: { $0.id != id && $0.heard.caseInsensitiveCompare(heard) == .orderedSame }), id != nil {
            throw DictationFailure(message: "That phrase already exists. Edit its replacement instead.")
        }
        if let index = updated.firstIndex(where: { $0.id == id || $0.heard.caseInsensitiveCompare(heard) == .orderedSame }) {
            updated[index].heard = heard
            updated[index].replacement = replacement
        } else {
            guard updated.count < 200 else { throw DictationFailure(message: "Remove a phrase before adding another.") }
            updated.append(DictationWord(heard: heard, replacement: replacement))
        }
        try save(updated, name: "vocabulary")
        vocabulary = updated
    }

    func deleteWord(_ id: UUID) {
        let updated = vocabulary.filter { $0.id != id }
        do { try save(updated, name: "vocabulary"); vocabulary = updated }
        catch { self.error = "Could not save vocabulary. Try again." }
    }

    func learn(_ corrections: [LearnedCorrection]) {
        for correction in corrections {
            // Explicit vocabulary entries win over later automatic observations.
            guard !vocabulary.contains(where: { $0.heard.caseInsensitiveCompare(correction.heard) == .orderedSame }) else { continue }
            do { try saveWord(heard: correction.heard, replacement: correction.corrected) }
            catch { self.error = "Could not save the correction. Try adding it in Vocabulary."; break }
        }
    }

    func record(words: Int, seconds: Double, date: Date = .now) {
        guard words > 0, seconds.isFinite, seconds > 0 else { return }
        var updated = days
        let key = DictationDay.key(date)
        if let index = updated.firstIndex(where: { $0.id == key }) {
            updated[index].words += words
            updated[index].sessions += 1
            updated[index].seconds += seconds
        } else {
            updated.append(DictationDay(id: key, words: words, sessions: 1, seconds: seconds))
        }
        do { try save(updated, name: "insights"); days = updated }
        catch { self.error = "Could not save insights. Try again." }
    }

    func resetInsights() {
        do { try save([DictationDay](), name: "insights"); days = [] }
        catch { self.error = "Could not reset insights. Try again." }
    }

    nonisolated static func replace(_ text: String, using entries: [DictationWord]) -> String {
        let entries = entries.filter { !$0.heard.isEmpty }.sorted { $0.heard.count > $1.heard.count }
        guard !entries.isEmpty else { return text }
        let alternatives = entries.map { NSRegularExpression.escapedPattern(for: $0.heard) }.joined(separator: "|")
        guard let regex = try? NSRegularExpression(pattern: "(?<![\\p{L}\\p{M}\\p{N}_])(?:\(alternatives))(?![\\p{L}\\p{M}\\p{N}_])", options: .caseInsensitive) else { return text }
        let source = text as NSString
        let result = NSMutableString(string: text)
        for match in regex.matches(in: text, range: NSRange(location: 0, length: source.length)).reversed() {
            let phrase = source.substring(with: match.range)
            if let entry = entries.first(where: { $0.heard.caseInsensitiveCompare(phrase) == .orderedSame }) {
                result.replaceCharacters(in: match.range, with: entry.replacement)
            }
        }
        return result as String
    }
}
