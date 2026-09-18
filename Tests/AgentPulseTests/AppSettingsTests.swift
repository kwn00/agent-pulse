import XCTest
@testable import AgentPulse

@MainActor
final class AppSettingsTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        let suite = "dev.agentpulse.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    func testNormalizedOrderDedupsAndAppendsMissingProviders() {
        XCTAssertEqual(AppSettings.normalizedOrder([]), ProviderID.allCases)
        XCTAssertEqual(AppSettings.normalizedOrder([.cursor, .cursor, .codex]), [.cursor, .codex, .antigravity, .copilot])
    }

    func testMovePersistsOrderAndDrivesVisibleProviders() {
        let defaults = makeDefaults()
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.providerOrder, ProviderID.allCases)

        settings.move(.cursor, to: 0)
        XCTAssertEqual(settings.providerOrder, [.cursor, .antigravity, .copilot, .codex])
        XCTAssertEqual(defaults.stringArray(forKey: "providerOrder"), ["cursor", "antigravity", "copilot", "codex"])

        settings.toggle(.copilot)
        XCTAssertEqual(settings.orderedEnabledProviders, [.cursor, .antigravity, .codex])

        // A fresh instance reads the stored order back.
        XCTAssertEqual(AppSettings(defaults: defaults).providerOrder, [.cursor, .antigravity, .copilot, .codex])
    }

    func testEffectivePinnedProviderFallsBackWhenUnsetOrDisabled() {
        let settings = AppSettings(defaults: makeDefaults())
        XCTAssertNil(settings.effectivePinnedProvider, "only meaningful in pinned mode")

        settings.menuBarStyle = .pinned
        XCTAssertEqual(settings.effectivePinnedProvider, .antigravity, "unset pin → first enabled agent")

        settings.pinnedProvider = .codex
        XCTAssertEqual(settings.effectivePinnedProvider, .codex)

        settings.toggle(.codex)
        XCTAssertEqual(settings.effectivePinnedProvider, .antigravity, "disabled pin → first enabled agent")
    }

    func testMoveClampsIndex() {
        let settings = AppSettings(defaults: makeDefaults())
        settings.move(.antigravity, to: 99)
        XCTAssertEqual(settings.providerOrder.last, .antigravity)
        settings.move(.antigravity, to: -5)
        XCTAssertEqual(settings.providerOrder.first, .antigravity)
    }
}
