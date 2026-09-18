import Foundation
import ServiceManagement

enum RefreshInterval: Int, CaseIterable, Identifiable, Sendable {
    case oneMinute = 60
    case fiveMinutes = 300
    case fifteenMinutes = 900
    case thirtyMinutes = 1800

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .oneMinute: "1 min"
        case .fiveMinutes: "5 min"
        case .fifteenMinutes: "15 min"
        case .thirtyMinutes: "30 min"
        }
    }
}

enum MenuBarStyle: String, CaseIterable, Identifiable, Sendable {
    case iconOnly
    case highestUsage
    case pinned

    var id: String { rawValue }

    var label: String {
        switch self {
        case .iconOnly: "Icon only"
        case .highestUsage: "Peak %"
        case .pinned: "One agent"
        }
    }
}

@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private let defaults: UserDefaults

    @Published var refreshInterval: RefreshInterval {
        didSet { defaults.set(refreshInterval.rawValue, forKey: Keys.refreshInterval) }
    }

    @Published var menuBarStyle: MenuBarStyle {
        didSet { defaults.set(menuBarStyle.rawValue, forKey: Keys.menuBarStyle) }
    }

    /// Agent shown in the menu bar (and described by the headline) when `menuBarStyle == .pinned`.
    @Published var pinnedProvider: ProviderID? {
        didSet { defaults.set(pinnedProvider?.rawValue, forKey: Keys.pinnedProvider) }
    }

    @Published var enabledProviders: Set<ProviderID> {
        didSet { defaults.set(enabledProviders.map(\.rawValue).sorted(), forKey: Keys.enabledProviders) }
    }

    /// Display order of the cards; every known provider appears exactly once.
    @Published var providerOrder: [ProviderID] {
        didSet { defaults.set(providerOrder.map(\.rawValue), forKey: Keys.providerOrder) }
    }

    @Published var launchAtLogin: Bool {
        didSet { applyLaunchAtLogin() }
    }

    private enum Keys {
        static let refreshInterval = "refreshInterval"
        static let menuBarStyle = "menuBarStyle"
        static let enabledProviders = "enabledProviders"
        static let providerOrder = "providerOrder"
        static let pinnedProvider = "pinnedProvider"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        refreshInterval = RefreshInterval(rawValue: defaults.integer(forKey: Keys.refreshInterval)) ?? .fiveMinutes
        menuBarStyle = MenuBarStyle(rawValue: defaults.string(forKey: Keys.menuBarStyle) ?? "") ?? .highestUsage
        pinnedProvider = defaults.string(forKey: Keys.pinnedProvider).flatMap(ProviderID.init(rawValue:))
        if let stored = defaults.stringArray(forKey: Keys.enabledProviders) {
            enabledProviders = Set(stored.compactMap(ProviderID.init(rawValue:)))
        } else {
            enabledProviders = Set(ProviderID.allCases)
        }
        providerOrder = Self.normalizedOrder(defaults.stringArray(forKey: Keys.providerOrder)?.compactMap(ProviderID.init(rawValue:)) ?? [])
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    var orderedEnabledProviders: [ProviderID] {
        providerOrder.filter { enabledProviders.contains($0) }
    }

    /// The pinned agent, falling back to the first enabled one if the pin is unset or disabled.
    var effectivePinnedProvider: ProviderID? {
        guard menuBarStyle == .pinned else { return nil }
        if let pinnedProvider, enabledProviders.contains(pinnedProvider) { return pinnedProvider }
        return orderedEnabledProviders.first
    }

    func move(_ provider: ProviderID, to index: Int) {
        guard let from = providerOrder.firstIndex(of: provider) else { return }
        var order = providerOrder
        order.remove(at: from)
        order.insert(provider, at: min(max(index, 0), order.count))
        providerOrder = order
    }

    /// Drops unknown ids and appends any provider missing from a stored (possibly older) list.
    static func normalizedOrder(_ stored: [ProviderID]) -> [ProviderID] {
        var seen = Set<ProviderID>()
        var order = stored.filter { seen.insert($0).inserted }
        order += ProviderID.allCases.filter { !seen.contains($0) }
        return order
    }

    func toggle(_ provider: ProviderID) {
        if enabledProviders.contains(provider) {
            if enabledProviders.count > 1 { enabledProviders.remove(provider) }
        } else {
            enabledProviders.insert(provider)
        }
    }

    private func applyLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            if launchAtLogin, service.status != .enabled {
                try service.register()
            } else if !launchAtLogin, service.status == .enabled {
                try service.unregister()
            }
        } catch {
            // Registration only works from a real .app bundle; reflect the real state instead of lying.
            let actual = service.status == .enabled
            if actual != launchAtLogin { launchAtLogin = actual }
        }
    }
}
