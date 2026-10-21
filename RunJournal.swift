import Foundation
import CryptoKit

/// Crash recovery for agent work (CAP-7, AD-6). An intent record is written BEFORE a step runs and closed AFTER it ends.
/// After a crash, any step left open is reported as `unknown` (it may or may not have happened) and is never re-run silently.
/// Encrypted (AES-GCM, key file 0600), bounded and expiring. Separate from the opt-in activity ledger: this is operational state.
enum JournalIdempotence: String, Codable { case readOnly, idempotent, nonIdempotent }
enum JournalState: String, Codable { case intent, done, failed, cancelled, unknown }

struct JournalEntry: Codable, Identifiable, Equatable {
    let id: UUID
    var label: String
    var tier: String
    var idempotence: JournalIdempotence
    var precondition: String?
    var state: JournalState
    let startedAt: Date
    var finishedAt: Date?
}

enum RunJournalError: Error, LocalizedError {
    case unreadable(String)
    var errorDescription: String? { if case .unreadable(let why) = self { return "The run journal could not be read (\(why))." }; return nil }
}

final class RunJournal: @unchecked Sendable {
    static let maxEntries = 50
    static let ttl: TimeInterval = 24 * 3600
    private static let lock = NSRecursiveLock()
    private let directory: URL
    private let now: () -> Date
    private var file: URL { directory.appendingPathComponent("journal.aesgcm") }
    private var keyFile: URL { directory.appendingPathComponent("journal.key") }

    init(directory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Onyx/Journal", isDirectory: true),
         now: @escaping () -> Date = Date.init) {
        self.directory = directory.standardizedFileURL; self.now = now
    }

    /// Writes the intent record before the step runs. The label is a short, single-line description (never a transcript).
    @discardableResult
    func begin(label: String, tier: String, idempotence: JournalIdempotence, precondition: String? = nil) throws -> UUID {
        try Self.synchronized {
            var entries = try load()
            let clean = String(label.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines).prefix(160))
            let entry = JournalEntry(id: UUID(), label: clean.isEmpty ? "(unnamed step)" : clean, tier: tier, idempotence: idempotence,
                                     precondition: precondition.map { String($0.prefix(120)) }, state: .intent, startedAt: now(), finishedAt: nil)
            entries.append(entry)
            try save(entries)
            return entry.id
        }
    }

    func finish(_ id: UUID, as state: JournalState) throws {
        try Self.synchronized {
            var entries = try load()
            guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
            entries[index].state = state; entries[index].finishedAt = now()
            try save(entries)
        }
    }

    /// Steps that were started and never closed: the crash or kill left them in an unknown state.
    /// Marks them `unknown` so they are reported once and never silently repeated.
    func recoverUnfinished() throws -> [JournalEntry] {
        try Self.synchronized {
            var entries = try load()
            var recovered: [JournalEntry] = []
            for index in entries.indices where entries[index].state == .intent {
                entries[index].state = .unknown; entries[index].finishedAt = now(); recovered.append(entries[index])
            }
            if !recovered.isEmpty { try save(entries) }
            return recovered
        }
    }

    func entries() throws -> [JournalEntry] { try Self.synchronized { try load() } }
    func eraseAll() throws { try Self.synchronized { if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) } } }

    /// A preconditions check for resuming later: the stored precondition must still equal the current one, and the entry must be fresh.
    func canResume(_ entry: JournalEntry, currentPrecondition: String?) -> Bool {
        now().timeIntervalSince(entry.startedAt) <= Self.ttl && entry.precondition == currentPrecondition.map { String($0.prefix(120)) }
    }

    // MARK: storage

    private static func synchronized<T>(_ body: () throws -> T) rethrows -> T { lock.lock(); defer { lock.unlock() }; return try body() }

    private func key() throws -> SymmetricKey {
        let fm = FileManager.default
        if let data = try? Data(contentsOf: keyFile), data.count == 32 { return SymmetricKey(data: data) }
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw RunJournalError.unreadable("no random key") }
        try Data(bytes).write(to: keyFile, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyFile.path)
        return SymmetricKey(data: Data(bytes))
    }

    /// Missing file means an empty journal. A file that exists but cannot be decrypted or decoded is an error, never a silent reset.
    private func load() throws -> [JournalEntry] {
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        do {
            let box = try AES.GCM.SealedBox(combined: Data(contentsOf: file))
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            let all = try decoder.decode([JournalEntry].self, from: AES.GCM.open(box, using: key()))
            let cutoff = now().addingTimeInterval(-Self.ttl)
            return all.filter { $0.startedAt >= cutoff }
        } catch { throw RunJournalError.unreadable(error.localizedDescription) }
    }

    private func save(_ entries: [JournalEntry]) throws {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let bounded = Array(entries.suffix(Self.maxEntries))
        let sealed = try AES.GCM.seal(encoder.encode(bounded), using: key())
        guard let combined = sealed.combined else { throw RunJournalError.unreadable("seal failed") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try combined.write(to: file, options: .atomic)
    }
}
