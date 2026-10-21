import Foundation

@main struct RunJournalTests {
    static func check(_ condition: Bool, _ note: String) { assert(condition, note) }
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("OnyxJournal-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var clock = Date(timeIntervalSince1970: 1_000_000)
        let journal = RunJournal(directory: root, now: { clock })

        check(try journal.entries().isEmpty && (try journal.recoverUnfinished()).isEmpty, "empty journal")
        let a = try journal.begin(label: "Create folder Taxes\nand move files", tier: "act", idempotence: .nonIdempotent, precondition: "Finder")
        let b = try journal.begin(label: "Read screen", tier: "observe", idempotence: .readOnly)
        try journal.finish(b, as: .done)
        check(try journal.entries().first(where: { $0.id == a })?.label == "Create folder Taxes and move files", "label is one line")
        check(!String(decoding: try Data(contentsOf: root.appendingPathComponent("journal.aesgcm")), as: UTF8.self).contains("Taxes"), "file is encrypted")

        // Crash: a new instance (new process) finds the open step and reports it unknown, exactly once, never as done.
        let afterCrash = RunJournal(directory: root, now: { clock })
        let recovered = try afterCrash.recoverUnfinished()
        check(recovered.count == 1 && recovered[0].id == a && recovered[0].state == .unknown && recovered[0].idempotence == .nonIdempotent, "open step recovered as unknown")
        check(try afterCrash.recoverUnfinished().isEmpty, "reported once")
        check(try afterCrash.entries().first(where: { $0.id == b })?.state == .done, "closed step stays done")

        // Resume only when fresh and the precondition still holds.
        check(journal.canResume(recovered[0], currentPrecondition: "Finder") && !journal.canResume(recovered[0], currentPrecondition: "Safari"), "precondition revalidated")
        clock = clock.addingTimeInterval(RunJournal.ttl + 5)
        check(!journal.canResume(recovered[0], currentPrecondition: "Finder"), "expired checkpoint cannot resume")
        check(try journal.entries().isEmpty, "expired entries purged on read")

        // Bounds.
        clock = Date(timeIntervalSince1970: 2_000_000)
        for index in 0..<(RunJournal.maxEntries + 10) { try journal.finish(try journal.begin(label: "step \(index)", tier: "act", idempotence: .idempotent), as: .done) }
        check(try journal.entries().count == RunJournal.maxEntries, "bounded")

        // Corruption is an error, not a silent reset.
        try Data("garbage".utf8).write(to: root.appendingPathComponent("journal.aesgcm"))
        var threw = false
        do { _ = try journal.entries() } catch { threw = true }
        check(threw, "corrupt journal is reported")
        try journal.eraseAll()
        check(try journal.entries().isEmpty, "erase")
        let perms = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("journal.key").path)[.posixPermissions] as? Int
        check(perms == 0o600, "key file is 0600")
        print("RunJournalTests: PASS (intent before step, one-line labels, encrypted, crash recovery marks unknown once, precondition + TTL resume rules, bounded, corruption reported, erase, key 0600)")
    }
}
