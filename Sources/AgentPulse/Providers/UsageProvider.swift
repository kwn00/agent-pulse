import Foundation

/// Reads usage for one agent from credentials the official tool already stores locally.
protocol UsageProvider: Sendable {
    var id: ProviderID { get }
    func fetch() async throws -> UsageSnapshot
}

enum ProviderRegistry {
    static func makeAll(http: HTTPClient = .shared) -> [any UsageProvider] {
        [
            AntigravityProvider(http: http),
            CopilotProvider(http: http),
            CodexProvider(http: http),
            CursorProvider(http: http),
        ]
    }
}
