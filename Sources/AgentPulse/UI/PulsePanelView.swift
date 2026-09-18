import SwiftUI

/// Screen-dependent limits the controller feeds into the view.
@MainActor
final class PanelLayout: ObservableObject {
    @Published var maxListHeight: CGFloat = Theme.maxListHeight
    /// Skip the scroll container entirely (used for offscreen renders).
    @Published var unconstrained = false
    /// Offscreen renders only: fake a scrolled list so the edge fog can be inspected.
    @Published var debugScrollOffset: CGFloat?
}

struct PulsePanelView: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var settings: AppSettings
    @ObservedObject var layout: PanelLayout
    var onSizeChange: (CGSize) -> Void
    var onQuit: () -> Void

    @State private var showingSettings: Bool
    /// Turned off for one render pass so the "back to home" reset on open doesn't slide in view.
    @State private var paneTransitionsEnabled = true
    @State private var listHeight: CGFloat = 0
    @State private var scrollOffset: CGFloat = 0
    /// Card list frame in panel coordinates; the edge fog is drawn at the panel level so it can
    /// reuse the real background layers instead of guessing a colour.
    @State private var scrollFrame: CGRect = .zero
    @State private var now = Date()

    init(
        store: UsageStore,
        settings: AppSettings,
        layout: PanelLayout,
        onSizeChange: @escaping (CGSize) -> Void,
        onQuit: @escaping () -> Void,
        initiallyShowingSettings: Bool = false
    ) {
        self.store = store
        self.settings = settings
        self.layout = layout
        self.onSizeChange = onSizeChange
        self.onQuit = onQuit
        _showingSettings = State(initialValue: initiallyShowingSettings)
    }

    private let clock = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        // Pinned to the top of the hosting view: while the window is mid-resize the content must
        // not float to the vertical centre, or every label appears to jump.
        panel
            .frame(maxHeight: .infinity, alignment: .top)
    }

    private var panel: some View {
        VStack(spacing: 0) {
            PanelHeader(
                store: store,
                headline: store.headline,
                showingSettings: $showingSettings,
                now: now
            )
            .padding(.horizontal, 18)
            .padding(.top, 18)
            .padding(.bottom, 8)

            ZStack(alignment: .top) {
                if showingSettings {
                    SettingsPane(settings: settings, store: store)
                        .transition(.asymmetric(
                            insertion: .move(edge: .trailing).combined(with: .opacity),
                            removal: .move(edge: .trailing).combined(with: .opacity)
                        ))
                } else {
                    cardList
                        .transition(.asymmetric(
                            insertion: .move(edge: .leading).combined(with: .opacity),
                            removal: .move(edge: .leading).combined(with: .opacity)
                        ))
                }
            }
            .animation(paneTransitionsEnabled ? .spring(duration: 0.42, bounce: 0.12) : nil, value: showingSettings)

            PanelFooter(settings: settings, store: store, now: now, onQuit: onQuit)
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
        }
        .frame(width: Theme.panelWidth)
        .coordinateSpace(name: "panel")
        .background(PanelBackground(accent: accentColor))
        .overlay(edgeFog)
        .clipShape(RoundedRectangle(cornerRadius: Theme.panelCornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.panelCornerRadius, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(0.22), .white.opacity(0.06), .white.opacity(0.10)],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 1
                )
        )
        .readSize(onSizeChange)
        .onReceive(clock) { now = $0 }
        .onChange(of: store.revealToken) { _, _ in
            // Every open starts on the cards; settings is a detour, not a place to resume.
            let target = store.presentInSettings
            guard showingSettings != target else { return }
            paneTransitionsEnabled = false
            showingSettings = target
            DispatchQueue.main.async { paneTransitionsEnabled = true }
        }
        .preferredColorScheme(.dark)
        .environment(\.colorScheme, .dark)
    }

    private var accentColor: Color {
        switch store.headline.kind {
        case .calm: Theme.Palette.accent
        case .warm: Theme.Palette.warning
        case .critical, .attention: Theme.Palette.danger
        }
    }

    @ViewBuilder
    private var cardList: some View {
        if layout.unconstrained {
            cards.padding(.bottom, 6)
        } else if let fakeOffset = layout.debugScrollOffset {
            // Static stand-in for a scrolled ScrollView (ImageRenderer can't scroll).
            cards
                .padding(.bottom, 24)
                .readSize { listHeight = $0.height }
                .offset(y: -fakeOffset)
                .frame(height: visibleHeight, alignment: .top)
                .clipped()
                .background(
                    GeometryReader { proxy in
                        Color.clear.onChange(of: proxy.frame(in: .named("panel")), initial: true) { _, frame in
                            scrollFrame = frame
                        }
                    }
                )
        } else {
            ScrollView(.vertical, showsIndicators: false) {
                cards
                    .padding(.bottom, overflows ? 24 : 6)
                    .readSize { listHeight = $0.height }
                    .background(
                        GeometryReader { proxy in
                            Color.clear.onChange(of: proxy.frame(in: .named("cardScroll")).minY, initial: true) { _, minY in
                                scrollOffset = -minY
                            }
                        }
                    )
            }
            .coordinateSpace(name: "cardScroll")
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: visibleHeight)
            .background(
                GeometryReader { proxy in
                    Color.clear.onChange(of: proxy.frame(in: .named("panel")), initial: true) { _, frame in
                        scrollFrame = frame
                    }
                }
            )
        }
    }

    // MARK: Edge fog

    private var visibleHeight: CGFloat { min(max(listHeight, 120), layout.maxListHeight) }
    private var overflows: Bool { !layout.unconstrained && listHeight > layout.maxListHeight + 1 }
    private var effectiveScrollOffset: CGFloat { layout.debugScrollOffset ?? scrollOffset }

    /// 0…1 strength per edge; fades in over the first 28pt of hidden content.
    private var topFog: Double { overflows ? min(1, max(0, effectiveScrollOffset) / 28) : 0 }
    private var bottomFog: Double { overflows ? min(1, max(0, listHeight - visibleHeight - effectiveScrollOffset) / 28) : 0 }

    /// A copy of the panel background masked to thin bands at the list's edges, so the fog is
    /// exactly the colour that sits behind it (violet-tinted up top, near-black at the bottom).
    private var edgeFog: some View {
        let bandHeight: CGFloat = 40
        return PanelBackground(accent: accentColor, includesVibrancy: false)
            .mask(alignment: .top) {
                ZStack(alignment: .top) {
                    LinearGradient(colors: [.black.opacity(0.94), .clear], startPoint: .top, endPoint: .bottom)
                        .frame(height: bandHeight)
                        .offset(y: scrollFrame.minY)
                        .opacity(topFog)
                    LinearGradient(colors: [.clear, .black.opacity(0.94)], startPoint: .top, endPoint: .bottom)
                        .frame(height: bandHeight)
                        .offset(y: scrollFrame.maxY - bandHeight)
                        .opacity(bottomFog)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .allowsHitTesting(false)
            .animation(.easeOut(duration: 0.15), value: topFog == 0)
            .animation(.easeOut(duration: 0.15), value: bottomFog == 0)
    }

    /// Cards grow ~1% on hover; the extra top/bottom padding keeps the scaled edges inside the
    /// scroll view's clip instead of shaving off the first card's top edge.
    private var cards: some View {
        VStack(spacing: 10) {
            ForEach(Array(store.visibleProviders.enumerated()), id: \.element) { index, provider in
                ProviderCard(
                    provider: provider,
                    state: store.state(for: provider),
                    index: index,
                    revealToken: store.revealToken,
                    now: now,
                    onRetry: { store.refresh(provider) }
                )
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .animation(.spring(duration: 0.4, bounce: 0.1), value: settings.providerOrder)
    }
}

// MARK: - Header

private struct PanelHeader: View {
    @ObservedObject var store: UsageStore
    /// Passed by value: it depends on settings too, which this view doesn't observe directly.
    var headline: UsageStore.Headline
    @Binding var showingSettings: Bool
    var now: Date

    @State private var displayedHeadline = ""

    var body: some View {
        HStack(spacing: 12) {
            AppMark(size: 34)

            VStack(alignment: .leading, spacing: 2) {
                Text(showingSettings ? "Settings" : "Agent Pulse")
                    .font(Theme.Typography.title)
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .contentTransition(.opacity)

                HStack(spacing: 5) {
                    if !showingSettings {
                        Circle()
                            .fill(headlineColor)
                            .frame(width: 5, height: 5)
                            .shadow(color: headlineColor.opacity(0.8), radius: 3)
                    }
                    // No `.animation(value:)` here on purpose: when `headline` changes inside an
                    // animated transaction, that modifier makes SwiftUI interpolate this label's
                    // frame from the VStack origin, so it visibly drops in from the title line.
                    // The cross-fade is driven by an explicit `withAnimation` in `onChange` instead.
                    Text(showingSettings ? "Tune what Pulse watches" : displayedHeadline)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .contentTransition(.opacity)
                        .onChange(of: headline.text) { _, newText in
                            if showingSettings {
                                displayedHeadline = newText
                            } else {
                                withAnimation(.easeInOut(duration: 0.25)) { displayedHeadline = newText }
                            }
                        }
                        .onAppear { displayedHeadline = headline.text }
                }
            }

            Spacer(minLength: 8)

            if showingSettings {
                GlassIconButton(systemName: "chevron.left", help: "Back") {
                    showingSettings = false
                }
            } else {
                GlassIconButton(
                    systemName: "arrow.triangle.2.circlepath",
                    help: "Refresh now (⌘R)",
                    isSpinning: store.isRefreshing
                ) {
                    store.refreshAll()
                }
                .keyboardShortcut("r", modifiers: .command)

                GlassIconButton(systemName: "slider.horizontal.3", help: "Settings (⌘,)") {
                    showingSettings = true
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
    }

    private var headlineColor: Color {
        switch headline.kind {
        case .calm: Theme.Palette.success
        case .warm: Theme.Palette.warning
        case .critical, .attention: Theme.Palette.danger
        }
    }
}

/// The app's own mark: a heartbeat on a gradient orb.
struct AppMark: View {
    var size: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [Color(hex: 0x8B7CFF), Color(hex: 0xEC4899), Color(hex: 0xFB923C)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            Circle()
                .fill(
                    RadialGradient(
                        colors: [.white.opacity(0.4), .clear],
                        center: .init(x: 0.3, y: 0.2),
                        startRadius: 0,
                        endRadius: size * 0.75
                    )
                )
            PulseGlyph()
                .stroke(.white, style: StrokeStyle(lineWidth: size * 0.075, lineCap: .round, lineJoin: .round))
                .padding(size * 0.22)
                .shadow(color: .black.opacity(0.2), radius: 1, y: 1)
        }
        .frame(width: size, height: size)
        .shadow(color: Color(hex: 0xA855F7).opacity(0.45), radius: 10, y: 4)
    }
}

/// ECG-style heartbeat line, normalised to the unit rect.
struct PulseGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width, h = rect.height
        let midY = rect.minY + h * 0.55
        path.move(to: CGPoint(x: rect.minX, y: midY))
        path.addLine(to: CGPoint(x: rect.minX + w * 0.22, y: midY))
        path.addLine(to: CGPoint(x: rect.minX + w * 0.34, y: rect.minY + h * 0.78))
        path.addLine(to: CGPoint(x: rect.minX + w * 0.50, y: rect.minY + h * 0.12))
        path.addLine(to: CGPoint(x: rect.minX + w * 0.64, y: rect.minY + h * 0.92))
        path.addLine(to: CGPoint(x: rect.minX + w * 0.74, y: midY))
        path.addLine(to: CGPoint(x: rect.maxX, y: midY))
        return path
    }
}

// MARK: - Footer

private struct PanelFooter: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var store: UsageStore
    var now: Date
    var onQuit: () -> Void

    @State private var hoveringQuit = false

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 5) {
                Image(systemName: "clock.arrow.2.circlepath")
                    .font(.system(size: 10, weight: .semibold))
                Text("Every \(settings.refreshInterval.label) · updated \(ResetFormatter.relative(store.lastRefresh, now: now))")
                    .contentTransition(.numericText())
            }
            .font(Theme.Typography.micro)
            .foregroundStyle(Theme.Palette.textTertiary)

            Spacer(minLength: 0)

            Button(action: onQuit) {
                HStack(spacing: 4) {
                    Text("Quit")
                    Text("⌘Q")
                        .foregroundStyle(Theme.Palette.textTertiary)
                }
                .font(Theme.Typography.micro)
                .foregroundStyle(hoveringQuit ? Theme.Palette.textPrimary : Theme.Palette.textSecondary)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(Capsule().fill(hoveringQuit ? Theme.Palette.surfaceHover : .clear))
            }
            .buttonStyle(.plain)
            .keyboardShortcut("q", modifiers: .command)
            .onHover { hoveringQuit = $0 }
            .animation(.easeOut(duration: 0.15), value: hoveringQuit)
        }
    }
}
