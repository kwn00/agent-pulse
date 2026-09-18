import Foundation

/// Persists the last good snapshot per provider so a closed IDE or a flaky network still leaves
/// something useful on screen ("Not running · last read 12m ago").
struct SnapshotCache: Sendable {
    let fileURL: URL

    static let `default` = SnapshotCache(
        fileURL: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Agent Pulse/snapshots.json")
    )

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    func load() -> [ProviderID: UsageSnapshot] {
        guard let data = try? Data(contentsOf: fileURL),
              let stored = try? Self.decoder.decode([String: UsageSnapshot].self, from: data) else {
            return [:]
        }
        var result: [ProviderID: UsageSnapshot] = [:]
        for (key, snapshot) in stored {
            if let id = ProviderID(rawValue: key) { result[id] = snapshot }
        }
        return result
    }

    func save(_ snapshots: [ProviderID: UsageSnapshot]) {
        let stored = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.key.rawValue, $0.value) })
        guard let data = try? Self.encoder.encode(stored) else { return }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // A missing cache only costs the "last known" fallback; never worth surfacing.
        }
    }
}
