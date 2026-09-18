import Foundation

/// The agents Agent Pulse knows how to read. Order here is the default display order.
enum ProviderID: String, CaseIterable, Codable, Sendable, Identifiable {
    case antigravity
    case copilot
    case codex
    case cursor

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .antigravity: "Antigravity"
        case .copilot: "Copilot"
        case .codex: "Codex"
        case .cursor: "Cursor"
        }
    }

    var vendor: String {
        switch self {
        case .antigravity: "Google"
        case .copilot: "GitHub"
        case .codex: "OpenAI"
        case .cursor: "Anysphere"
        }
    }

    /// SF Symbol used on the brand tile.
    var symbolName: String {
        switch self {
        case .antigravity: "sparkles"
        case .copilot: "airplane"
        case .codex: "terminal"
        case .cursor: "cursorarrow.rays"
        }
    }
}

/// One measurable quota / window for a provider.
struct UsageMetric: Identifiable, Hashable, Codable, Sendable {
    var id: String
    var label: String
    /// 0…1 share of the quota that has been consumed. `nil` when unknown or unlimited.
    var usedFraction: Double?
    /// Free-form value shown at the trailing edge, e.g. "245 / 300" or "$12.40 / $20".
    var detail: String?
    var resetsAt: Date?
    var isUnlimited = false
    /// Primary metrics drive the ring and the headline percentage.
    var isPrimary = false

    var usedPercent: Int? {
        usedFraction.map { Int(($0 * 100).rounded()) }
    }
}

/// A successful read of a provider.
struct UsageSnapshot: Hashable, Codable, Sendable {
    var plan: String?
    var account: String?
    var metrics: [UsageMetric]
    var fetchedAt: Date
    var note: String?

    /// Cached snapshots older than this read as "last known", not "current".
    func isStale(now: Date = Date(), tolerance: TimeInterval = 120) -> Bool {
        now.timeIntervalSince(fetchedAt) > tolerance
    }

    var primaryMetric: UsageMetric? {
        metrics.first(where: \.isPrimary) ?? metrics.first
    }

    /// Highest consumed fraction across primary metrics, used for the ring + menu bar.
    var headlineFraction: Double? {
        let primaries = metrics.filter(\.isPrimary)
        let pool = primaries.isEmpty ? metrics : primaries
        return pool.compactMap(\.usedFraction).max()
    }
}

enum ProviderFailureKind: Sendable, Hashable {
    case notInstalled
    case notSignedIn
    case notRunning
    case unauthorized
    case network
    case parsing
    case unknown
}

struct ProviderFailure: Error, Hashable, Sendable {
    var kind: ProviderFailureKind
    var message: String
    /// Short actionable suggestion, e.g. "Run `codex login`".
    var hint: String?
    /// Overrides the kind's generic label ("Not running") in compact UI when more precision helps.
    var title: String?

    var shortLabel: String { title ?? kind.shortLabel }

    static func notInstalled(_ message: String, hint: String? = nil) -> Self {
        .init(kind: .notInstalled, message: message, hint: hint)
    }

    static func notSignedIn(_ message: String, hint: String? = nil) -> Self {
        .init(kind: .notSignedIn, message: message, hint: hint)
    }

    static func notRunning(_ message: String, hint: String? = nil, title: String? = nil) -> Self {
        .init(kind: .notRunning, message: message, hint: hint, title: title)
    }

    static func unauthorized(_ message: String, hint: String? = nil) -> Self {
        .init(kind: .unauthorized, message: message, hint: hint)
    }

    static func network(_ message: String) -> Self {
        .init(kind: .network, message: message, hint: nil)
    }

    static func parsing(_ message: String) -> Self {
        .init(kind: .parsing, message: message, hint: nil)
    }

    static func wrap(_ error: Error) -> Self {
        if let failure = error as? ProviderFailure { return failure }
        if let urlError = error as? URLError {
            return .network(urlError.localizedDescription)
        }
        if error is DecodingError {
            return .parsing("Unexpected response format.")
        }
        return .init(kind: .unknown, message: error.localizedDescription, hint: nil)
    }
}

enum ProviderState: Hashable, Sendable {
    case idle
    case loading(previous: UsageSnapshot?)
    case ready(UsageSnapshot)
    case failed(ProviderFailure, previous: UsageSnapshot?)

    var snapshot: UsageSnapshot? {
        switch self {
        case .idle: nil
        case .loading(let previous): previous
        case .ready(let snapshot): snapshot
        case .failed(_, let previous): previous
        }
    }

    var failure: ProviderFailure? {
        if case .failed(let failure, _) = self { return failure }
        return nil
    }

    var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }

    /// A snapshot the provider produced this session (or is about to replace), as opposed to a
    /// cached one being shown behind a failure.
    var liveSnapshot: UsageSnapshot? {
        switch self {
        case .ready(let snapshot): snapshot
        case .loading(let previous): previous
        case .idle, .failed: nil
        }
    }
}
