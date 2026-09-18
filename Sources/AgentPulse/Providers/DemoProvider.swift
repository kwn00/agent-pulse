import Foundation

/// Fictional but realistic snapshots. Used by `--demo` so the panel can be previewed
/// (and screenshotted) without any agent installed or any personal data on screen.
struct DemoProvider: UsageProvider {
    let id: ProviderID

    func fetch() async throws -> UsageSnapshot {
        try? await Task.sleep(for: .milliseconds(.random(in: 200...700)))
        let now = Date()
        let hours: (Double) -> Date = { now.addingTimeInterval($0 * 3600) }

        switch id {
        case .antigravity:
            return UsageSnapshot(
                plan: "AI Pro",
                account: "ada@lovelace.dev",
                metrics: [
                    UsageMetric(id: "g-w", label: "Gemini · Weekly", usedFraction: 0.38, resetsAt: hours(52), isPrimary: true),
                    UsageMetric(id: "g-5", label: "Gemini · 5-hour", usedFraction: 0.12, resetsAt: hours(3.2), isPrimary: true),
                    UsageMetric(id: "c-w", label: "Claude & GPT · Weekly", usedFraction: 0.81, resetsAt: hours(52), isPrimary: true),
                    UsageMetric(id: "c-5", label: "Claude & GPT · 5-hour", usedFraction: 0.27, resetsAt: hours(3.2), isPrimary: true),
                ],
                fetchedAt: now
            )
        case .copilot:
            return UsageSnapshot(
                plan: "Pro+",
                account: "adalovelace",
                metrics: [
                    UsageMetric(id: "premium", label: "Premium requests", usedFraction: 0.62, detail: "930 / 1,500", resetsAt: hours(24 * 9), isPrimary: true),
                    UsageMetric(id: "chat", label: "Chat", isUnlimited: true),
                    UsageMetric(id: "completions", label: "Completions", isUnlimited: true),
                ],
                fetchedAt: now,
                note: "Overage billing enabled"
            )
        case .codex:
            return UsageSnapshot(
                plan: "Pro",
                account: "ada@lovelace.dev",
                metrics: [
                    UsageMetric(id: "5h", label: "5-hour limit", usedFraction: 0.44, resetsAt: hours(2.4), isPrimary: true),
                    UsageMetric(id: "week", label: "Weekly limit", usedFraction: 0.91, resetsAt: hours(31), isPrimary: true),
                ],
                fetchedAt: now
            )
        case .cursor:
            return UsageSnapshot(
                plan: "Pro",
                account: "ada@lovelace.dev",
                metrics: [
                    UsageMetric(id: "plan", label: "Included usage", usedFraction: 0.57, detail: "$11.40 / $20.00", resetsAt: hours(24 * 17), isPrimary: true),
                    UsageMetric(id: "on-demand", label: "On-demand", usedFraction: 0.18, detail: "$9.10 / $50.00", resetsAt: hours(24 * 17)),
                ],
                fetchedAt: now
            )
        }
    }
}

extension ProviderRegistry {
    static func makeDemo() -> [any UsageProvider] {
        ProviderID.allCases.map(DemoProvider.init)
    }

    static var isDemo: Bool { CommandLine.arguments.contains("--demo") }

    /// `--demo` swaps in fictional data everywhere.
    static func makeDefault(http: HTTPClient = .shared) -> [any UsageProvider] {
        isDemo ? makeDemo() : makeAll(http: http)
    }
}
