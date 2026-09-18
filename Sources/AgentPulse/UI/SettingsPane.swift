import SwiftUI

struct SettingsPane: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var store: UsageStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsSection(title: "Agents", hint: "Drag ☰ to reorder") {
                ReorderableAgentList(settings: settings)
            }

            SettingsSection(title: "Menu bar", hint: menuBarHint) {
                VStack(spacing: 10) {
                    SegmentedRow(
                        label: "Show",
                        options: MenuBarStyle.allCases,
                        selection: $settings.menuBarStyle,
                        title: \.label
                    )
                    if settings.menuBarStyle == .pinned {
                        PinnedAgentRow(settings: settings)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                    Divider().overlay(Theme.Palette.surfaceStroke)
                    SegmentedRow(
                        label: "Refresh",
                        options: RefreshInterval.allCases,
                        selection: $settings.refreshInterval,
                        title: \.label
                    )
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .animation(.spring(duration: 0.3, bounce: 0.1), value: settings.menuBarStyle)
            }

            SettingsSection(title: "General") {
                ToggleRow(title: "Launch at login", subtitle: "Start Pulse when you sign in", isOn: $settings.launchAtLogin)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
            }

            Text("Pulse only reads the credentials your agents already keep on this Mac. Nothing leaves your machine except the same usage calls the official tools make.")
                .font(Theme.Typography.micro)
                .foregroundStyle(Theme.Palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 4)
    }

    private var menuBarHint: String {
        switch settings.menuBarStyle {
        case .iconOnly: "Headline shows the peak"
        case .highestUsage: "Highest usage across agents"
        case .pinned: "Headline follows the pin"
        }
    }
}

/// Chip picker for the agent the menu bar number (and headline) should track.
private struct PinnedAgentRow: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        HStack(spacing: 10) {
            Text("Agent")
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Palette.textPrimary)
            Spacer(minLength: 6)
            HStack(spacing: 4) {
                ForEach(settings.orderedEnabledProviders) { provider in
                    let selected = settings.effectivePinnedProvider == provider
                    Button {
                        withAnimation(.spring(duration: 0.3, bounce: 0.15)) { settings.pinnedProvider = provider }
                    } label: {
                        HStack(spacing: 5) {
                            BrandTile(provider: provider, size: 14)
                                .saturation(selected ? 1 : 0)
                                .opacity(selected ? 1 : 0.6)
                            if selected {
                                Text(provider.displayName)
                                    .font(Theme.Typography.micro)
                                    .foregroundStyle(Theme.Palette.textPrimary)
                                    .lineLimit(1)
                                    .fixedSize()
                                    .transition(.opacity.combined(with: .scale(scale: 0.8, anchor: .leading)))
                            }
                        }
                        .padding(.horizontal, selected ? 9 : 6)
                        .padding(.vertical, 4)
                        .background(
                            Capsule().fill(selected ? provider.brand.colors[0].opacity(0.22) : .clear)
                        )
                        .overlay(
                            Capsule().strokeBorder(selected ? provider.brand.colors[0].opacity(0.55) : .clear, lineWidth: 1)
                        )
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help(provider.displayName)
                }
            }
            .padding(2)
            .background(Capsule().fill(Theme.Palette.track))
            .layoutPriority(1)
        }
    }
}

private struct SettingsSection<Content: View>: View {
    var title: String
    var hint: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title.uppercased())
                    .tracking(0.8)
                Spacer()
                if let hint {
                    Text(hint)
                }
            }
            .font(Theme.Typography.micro)
            .foregroundStyle(Theme.Palette.textTertiary)
            .padding(.horizontal, 6)
            content
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Theme.Palette.surface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Theme.Palette.surfaceStroke, lineWidth: 1)
                )
        }
    }
}

/// Agent rows with a ☰ grip: drag it vertically to reorder, click the rest of the row to toggle.
private struct ReorderableAgentList: View {
    @ObservedObject var settings: AppSettings

    @State private var dragging: ProviderID?
    @State private var dragOffset: CGFloat = 0

    private let rowHeight: CGFloat = 46

    var body: some View {
        let order = settings.providerOrder
        VStack(spacing: 0) {
            ForEach(Array(order.enumerated()), id: \.element) { index, provider in
                ProviderToggleRow(
                    provider: provider,
                    isOn: settings.enabledProviders.contains(provider),
                    showsDivider: index < order.count - 1 && dragging == nil,
                    isDragging: dragging == provider,
                    dragInProgress: dragging != nil,
                    height: rowHeight,
                    toggle: { settings.toggle(provider) },
                    dragGesture: dragGesture(for: provider, in: order)
                )
                .offset(y: offset(for: provider, at: index, in: order))
                .zIndex(dragging == provider ? 1 : 0)
                .animation(dragging == provider ? nil : .spring(duration: 0.28, bounce: 0.1), value: dragOffset)
            }
        }
        // The gesture measures against this fixed space. Measuring in the grip's own (moving)
        // coordinate space feeds the row's offset back into the translation and makes it shake.
        .coordinateSpace(name: "agentList")
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func dragGesture(for provider: ProviderID, in order: [ProviderID]) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named("agentList"))
            .onChanged { value in
                if dragging == nil { dragging = provider }
                guard dragging == provider else { return }
                dragOffset = value.translation.height
            }
            .onEnded { _ in
                guard dragging == provider, let from = order.firstIndex(of: provider) else { return }
                let to = targetIndex(from: from, count: order.count)
                withAnimation(.spring(duration: 0.32, bounce: 0.15)) {
                    if to != from { settings.move(provider, to: to) }
                    dragging = nil
                    dragOffset = 0
                }
            }
    }

    private func targetIndex(from: Int, count: Int) -> Int {
        let shift = Int((dragOffset / rowHeight).rounded())
        return min(max(from + shift, 0), count - 1)
    }

    /// The dragged row follows the pointer; rows it has passed slide one slot to make room.
    private func offset(for provider: ProviderID, at index: Int, in order: [ProviderID]) -> CGFloat {
        guard let dragging, let from = order.firstIndex(of: dragging) else { return 0 }
        if provider == dragging { return dragOffset }
        let to = targetIndex(from: from, count: order.count)
        if from < to, index > from, index <= to { return -rowHeight }
        if from > to, index >= to, index < from { return rowHeight }
        return 0
    }
}

private struct ProviderToggleRow<Drag: Gesture>: View {
    var provider: ProviderID
    var isOn: Bool
    var showsDivider: Bool
    var isDragging: Bool
    /// Suppresses hover highlights on the rows the dragged one passes over.
    var dragInProgress: Bool
    var height: CGFloat
    var toggle: () -> Void
    var dragGesture: Drag

    @State private var hovering = false
    @State private var gripHovering = false

    var body: some View {
        HStack(spacing: 0) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(gripHovering || isDragging ? Theme.Palette.textSecondary : Theme.Palette.textTertiary.opacity(0.7))
                .frame(width: 26, height: height)
                .contentShape(Rectangle())
                .onHover { inside in
                    gripHovering = inside
                    (inside ? NSCursor.openHand : NSCursor.arrow).set()
                }
                .gesture(dragGesture)

            Button(action: toggle) {
                HStack(spacing: 10) {
                    BrandTile(provider: provider, size: 22)
                        .saturation(isOn ? 1 : 0)
                        .opacity(isOn ? 1 : 0.45)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(provider.displayName)
                            .font(Theme.Typography.body)
                            .foregroundStyle(Theme.Palette.textPrimary)
                        Text(provider.vendor)
                            .font(Theme.Typography.micro)
                            .foregroundStyle(Theme.Palette.textTertiary)
                    }
                    Spacer()
                    GlassSwitch(isOn: isOn, tint: provider.brand.colors[0])
                }
                .padding(.trailing, 12)
                .frame(height: height)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 4)
        .background(
            RoundedRectangle(cornerRadius: isDragging ? 10 : 0, style: .continuous)
                .fill(isDragging || (hovering && !dragInProgress) ? Theme.Palette.surfaceHover : .clear)
        )
        .overlay(alignment: .bottom) {
            if showsDivider {
                Divider().overlay(Theme.Palette.surfaceStroke).padding(.leading, 62)
            }
        }
        .scaleEffect(isDragging ? 1.02 : 1)
        .shadow(color: .black.opacity(isDragging ? 0.35 : 0), radius: 10, y: 4)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .animation(.spring(duration: 0.3), value: isOn)
        .animation(.spring(duration: 0.25), value: isDragging)
    }
}

private struct ToggleRow: View {
    var title: String
    var subtitle: String
    @Binding var isOn: Bool

    var body: some View {
        Button { isOn.toggle() } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Palette.textPrimary)
                    Text(subtitle)
                        .font(Theme.Typography.micro)
                        .foregroundStyle(Theme.Palette.textTertiary)
                }
                Spacer()
                GlassSwitch(isOn: isOn, tint: Theme.Palette.accent)
            }
        }
        .buttonStyle(.plain)
        .animation(.spring(duration: 0.3), value: isOn)
    }
}

private struct GlassSwitch: View {
    var isOn: Bool
    var tint: Color

    var body: some View {
        ZStack(alignment: isOn ? .trailing : .leading) {
            Capsule()
                .fill(isOn ? tint : Theme.Palette.track)
                .overlay(Capsule().strokeBorder(.white.opacity(isOn ? 0.2 : 0.08), lineWidth: 0.5))
            Circle()
                .fill(.white)
                .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                .padding(2)
        }
        .frame(width: 34, height: 20)
        .shadow(color: isOn ? tint.opacity(0.45) : .clear, radius: 6)
    }
}

private struct SegmentedRow<Option: Identifiable & Hashable>: View {
    var label: String
    var options: [Option]
    @Binding var selection: Option
    var title: KeyPath<Option, String>

    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 10) {
            Text(label)
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Palette.textPrimary)
            Spacer(minLength: 6)
            HStack(spacing: 2) {
                ForEach(options) { option in
                    let selected = option == selection
                    Button {
                        withAnimation(.spring(duration: 0.35, bounce: 0.15)) { selection = option }
                    } label: {
                        Text(option[keyPath: title])
                            .font(Theme.Typography.micro)
                            .foregroundStyle(selected ? Color.black.opacity(0.85) : Theme.Palette.textSecondary)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background {
                                if selected {
                                    Capsule()
                                        .fill(Theme.Palette.textPrimary)
                                        .matchedGeometryEffect(id: "segment", in: namespace)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(2)
            .background(Capsule().fill(Theme.Palette.track))
        }
    }
}
