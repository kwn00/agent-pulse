import Foundation

/// `AgentPulse --probe`: fetch every provider once, print what the panel would show, exit.
/// Handy for debugging credentials without clicking around the menu bar.
enum ProbeCommand {
    static func run() async {
        let providers = ProviderRegistry.makeDefault()
        var exitCode: Int32 = 0

        await withTaskGroup(of: (ProviderID, Result<UsageSnapshot, ProviderFailure>).self) { group in
            for provider in providers {
                group.addTask {
                    do {
                        return (provider.id, .success(try await provider.fetch()))
                    } catch {
                        return (provider.id, .failure(ProviderFailure.wrap(error)))
                    }
                }
            }

            var results: [ProviderID: Result<UsageSnapshot, ProviderFailure>] = [:]
            for await (id, result) in group { results[id] = result }

            for id in ProviderID.allCases {
                guard let result = results[id] else { continue }
                print("── \(id.displayName) (\(id.vendor))")
                switch result {
                case .success(let snapshot):
                    print("   plan: \(snapshot.plan ?? "-")   account: \(snapshot.account ?? "-")")
                    for metric in snapshot.metrics {
                        let percent = metric.usedPercent.map { "\($0)%" } ?? (metric.isUnlimited ? "∞" : "?")
                        let reset = ResetFormatter.text(for: metric.resetsAt) ?? ""
                        let detail = metric.detail ?? ""
                        print("   • \(metric.label.padding(toLength: 28, withPad: " ", startingAt: 0)) \(percent.padding(toLength: 5, withPad: " ", startingAt: 0)) \(detail)  \(reset)")
                    }
                    if let note = snapshot.note { print("   note: \(note)") }
                case .failure(let failure):
                    exitCode = 1
                    print("   ✗ \(failure.kind): \(failure.message)")
                    if let hint = failure.hint { print("     ↳ \(hint)") }
                }
            }
        }

        exit(exitCode)
    }
}
