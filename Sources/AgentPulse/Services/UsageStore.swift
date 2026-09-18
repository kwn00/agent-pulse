import Combine
import Foundation

@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var states: [ProviderID: ProviderState] = [:]
    @Published private(set) var lastRefresh: Date?
    @Published private(set) var isRefreshing = false
    /// Bumped every time the panel is presented so cards can replay their entrance.
    @Published private(set) var revealToken = 0
    /// Debug only: ask the panel to open on the settings pane instead of the cards.
    @Published private(set) var presentInSettings = false

    let settings: AppSettings
    private let providers: [ProviderID: any UsageProvider]
    private let cache: SnapshotCache?
    private var cachedSnapshots: [ProviderID: UsageSnapshot]
    private var refreshLoop: Task<Void, Never>?
    private var inFlight: [ProviderID: Task<Void, Never>] = [:]
    private var cancellables = Set<AnyCancellable>()

    init(providers: [any UsageProvider], settings: AppSettings = .shared, cache: SnapshotCache? = .default) {
        self.settings = settings
        self.providers = Dictionary(uniqueKeysWithValues: providers.map { ($0.id, $0) })
        self.cache = cache
        cachedSnapshots = cache?.load() ?? [:]
        // Last known values show immediately (as "loading" since a refresh follows right away).
        for id in ProviderID.allCases {
            states[id] = cachedSnapshots[id].map { .loading(previous: $0) } ?? .idle
        }

        settings.$refreshInterval
            .dropFirst()
            .sink { [weak self] _ in self?.scheduleLoop() }
            .store(in: &cancellables)

        settings.$enabledProviders
            .scan((previous: settings.enabledProviders, current: settings.enabledProviders)) { ($0.current, $1) }
            .dropFirst()
            .sink { [weak self] change in
                guard let self else { return }
                for id in change.current.subtracting(change.previous) { self.refresh(id) }
            }
            .store(in: &cancellables)
    }

    var visibleProviders: [ProviderID] { settings.orderedEnabledProviders }

    func state(for id: ProviderID) -> ProviderState { states[id] ?? .idle }

    func start() {
        refreshAll()
        scheduleLoop()
    }

    func markPresented(startInSettings: Bool = false) {
        presentInSettings = startInSettings
        revealToken &+= 1
        // A stale panel is worse than a slightly chatty one.
        if let lastRefresh, Date().timeIntervalSince(lastRefresh) > 60 {
            refreshAll()
        } else if lastRefresh == nil {
            refreshAll()
        }
    }

    func refreshAll() {
        for id in visibleProviders { refresh(id) }
    }

    func refresh(_ id: ProviderID) {
        guard let provider = providers[id] else { return }
        inFlight[id]?.cancel()
        states[id] = .loading(previous: states[id]?.snapshot)
        updateRefreshingFlag()

        inFlight[id] = Task { [weak self] in
            let result: Result<UsageSnapshot, ProviderFailure>
            do {
                result = .success(try await provider.fetch())
            } catch {
                result = .failure(ProviderFailure.wrap(error))
            }
            guard !Task.isCancelled, let self else { return }
            self.apply(result, to: id)
        }
    }

    private func apply(_ result: Result<UsageSnapshot, ProviderFailure>, to id: ProviderID) {
        let previous = states[id]?.snapshot
        switch result {
        case .success(let snapshot):
            states[id] = .ready(snapshot)
            cachedSnapshots[id] = snapshot
            cache?.save(cachedSnapshots)
        case .failure(let failure):
            states[id] = .failed(failure, previous: previous)
        }
        inFlight[id] = nil
        lastRefresh = Date()
        updateRefreshingFlag()
    }

    private func updateRefreshingFlag() {
        isRefreshing = !inFlight.isEmpty
    }

    private func scheduleLoop() {
        refreshLoop?.cancel()
        let interval = settings.refreshInterval.rawValue
        refreshLoop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled else { return }
                self?.refreshAll()
            }
        }
    }

    // MARK: - Derived summaries

    /// Providers with something worth surfacing: errors first, then the pinned agent if one is
    /// set, otherwise the hottest usage across the board.
    var headline: Headline {
        let visible = visibleProviders
        let failures = visible.filter { state(for: $0).failure != nil && state(for: $0).snapshot == nil }
        if !failures.isEmpty {
            let names = failures.map(\.displayName).joined(separator: ", ")
            return Headline(kind: .attention, text: failures.count == 1 ? "\(names) needs attention" : "\(failures.count) agents need attention")
        }
        if let pinned = settings.effectivePinnedProvider {
            return pinnedHeadline(for: pinned)
        }
        var hottest: (ProviderID, UsageMetric)?
        for id in visible {
            guard let snapshot = state(for: id).liveSnapshot else { continue }
            for metric in snapshot.metrics where metric.isPrimary {
                if let fraction = metric.usedFraction, fraction > (hottest?.1.usedFraction ?? -1) {
                    hottest = (id, metric)
                }
            }
        }
        if let (id, metric) = hottest, let percent = metric.usedPercent {
            let kind: Headline.Kind = percent >= 90 ? .critical : percent >= 75 ? .warm : .calm
            return Headline(kind: kind, text: "\(id.displayName) is highest at \(percent)%")
        }
        if visible.allSatisfy({ state(for: $0).isLoading || state(for: $0) == .idle }) {
            return Headline(kind: .calm, text: "Reading your agents…")
        }
        return Headline(kind: .calm, text: "All agents within limits")
    }

    private func pinnedHeadline(for id: ProviderID) -> Headline {
        let state = state(for: id)
        if let snapshot = state.liveSnapshot {
            let primaries = snapshot.metrics.filter(\.isPrimary)
            let pool = primaries.isEmpty ? snapshot.metrics : primaries
            if let metric = pool.filter({ $0.usedFraction != nil }).max(by: { ($0.usedFraction ?? 0) < ($1.usedFraction ?? 0) }),
               let percent = metric.usedPercent {
                let kind: Headline.Kind = percent >= 90 ? .critical : percent >= 75 ? .warm : .calm
                return Headline(kind: kind, text: "\(id.displayName) · \(metric.label) \(percent)%")
            }
            return Headline(kind: .calm, text: "\(id.displayName) · unlimited")
        }
        if let failure = state.failure {
            return Headline(kind: failure.kind.isSoft ? .calm : .attention, text: "\(id.displayName) · \(failure.shortLabel.lowercased())")
        }
        return Headline(kind: .calm, text: "\(id.displayName) · reading…")
    }

    /// Number for the menu bar: the pinned agent's peak, or the highest across every visible provider.
    /// Cached values behind a failure are deliberately excluded so the number stays "live".
    var menuBarFraction: Double? {
        if let pinned = settings.effectivePinnedProvider {
            return state(for: pinned).liveSnapshot?.headlineFraction
        }
        return visibleProviders.compactMap { state(for: $0).liveSnapshot?.headlineFraction }.max()
    }

    struct Headline: Equatable {
        enum Kind { case calm, warm, critical, attention }
        var kind: Kind
        var text: String
    }
}
