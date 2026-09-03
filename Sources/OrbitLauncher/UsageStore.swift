import Foundation

/// Frecency: how often a row has been activated, and how recently. The launcher
/// otherwise has no memory at all — `MenuController` ranks by the config author's
/// `order` or by a raw fuzzy score, so the app you open forty times a day sorts
/// exactly where it did on first run.
///
/// This cannot live in Lua. A provider is re-loaded into a throwaway state on every
/// keystroke and gets no `io`, so it is stateless by construction; only the host can
/// remember anything across activations.
@MainActor
final class UsageStore {
    private struct Record: Codable {
        var count: Int
        var lastUsed: Date
    }

    private var records: [String: Record] = [:]
    /// `nil` keeps the whole store in memory. Tests construct it that way so a run
    /// can never read — or write — the developer's real usage data.
    private let url: URL?
    private var flushScheduled = false

    var spec = RankingSpec()

    static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Orbit/usage.json")
    }

    init(url: URL?) {
        self.url = url
        load()
    }

    /// Called for every activation, whatever the row kind. `DisplayRow.id` is already
    /// stable per kind — `app:<path>` for apps, the node id for nodes, `<menu>.<value>`
    /// for provider rows — so one key space covers all three without a special case.
    func record(_ id: String, now: Date = Date()) {
        guard spec.enabled, !id.isEmpty else { return }
        var record = records[id] ?? Record(count: 0, lastUsed: now)
        record.count += 1
        record.lastUsed = now
        records[id] = record
        scheduleFlush()
    }

    /// How much to subtract from a row's score. Scores sort ascending and a lower one
    /// ranks higher, so frecency is a *discount*, not a bonus added on.
    ///
    /// Frequency enters logarithmically and recency as a half-life decay: the 200th
    /// launch should not outrank a close text match forever, and an app abandoned six
    /// months ago should fade rather than sit at the top of the list.
    func bonus(for id: String, now: Date = Date()) -> Int {
        guard spec.enabled, spec.weight > 0, let record = records[id] else { return 0 }
        let age = max(0, now.timeIntervalSince(record.lastUsed))
        let decay = pow(0.5, age / max(1, spec.halfLife))
        return Int((spec.weight * decay * log2(Double(record.count) + 1)).rounded())
    }

    func reset() {
        records = [:]
        scheduleFlush()
    }

    // MARK: - Persistence

    private func load() {
        guard let url, let data = try? Data(contentsOf: url) else { return }
        records = (try? JSONDecoder().decode([String: Record].self, from: data)) ?? [:]
    }

    /// Writes are coalesced: activation is on the hot path to launching something, and
    /// a launcher that pauses to touch the disk before every action is a launcher that
    /// feels slow. One write per burst, off the main queue.
    private func scheduleFlush() {
        guard url != nil, !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            flushScheduled = false
            flush()
        }
    }

    private func flush() {
        guard let url, let data = try? JSONEncoder().encode(records) else { return }
        DispatchQueue.global(qos: .utility).async {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }
}
