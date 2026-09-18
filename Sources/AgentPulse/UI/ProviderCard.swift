import SwiftUI

struct ProviderCard: View {
    let provider: ProviderID
    let state: ProviderState
    let index: Int
    let revealToken: Int
    var now = Date()
    let onRetry: () -> Void

    @State private var hovering = false
    @State private var expanded = false
    @State private var appeared = false
    @Environment(\.staticRender) private var staticRender

    private let collapsedMetricLimit = 4

    private var snapshot: UsageSnapshot? { state.snapshot }

    /// A cached snapshot shown behind a failure: rendered dimmed with a "last read" banner.
    private var isShowingCached: Bool { state.failure != nil && snapshot != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 12)

            if let snapshot {
                metricsSection(snapshot)
                    .opacity(isShowingCached ? 0.55 : 1)
                    .saturation(isShowingCached ? 0.4 : 1)
            } else if state.isLoading {
                skeleton
            } else if let failure = state.failure {
                failureSection(failure)
            }

            if let failure = state.failure, let snapshot, isShowingCached {
                staleBanner(failure, snapshot: snapshot)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: Theme.cardCornerRadius, style: .continuous)
                .fill(hovering ? Theme.Palette.surfaceHover : Theme.Palette.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardCornerRadius, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            (hovering ? Theme.Palette.surfaceStrokeHover : Theme.Palette.surfaceStroke),
                            Theme.Palette.surfaceStroke.opacity(0.4),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        )
        .overlay(alignment: .topLeading) {
            // Faint brand glow bleeding from the tile corner.
            Circle()
                .fill(provider.brand.glow.opacity(hovering ? 0.22 : 0.14))
                .frame(width: 120, height: 120)
                .blur(radius: 40)
                .offset(x: -30, y: -40)
                .allowsHitTesting(false)
                .clipShape(RoundedRectangle(cornerRadius: Theme.cardCornerRadius, style: .continuous))
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.cardCornerRadius, style: .continuous))
        .scaleEffect(hovering ? 1.008 : 1)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.18), value: hovering)
        .opacity(appeared || staticRender ? 1 : 0)
        .offset(y: appeared || staticRender ? 0 : 14)
        .onAppear { reveal() }
        .onChange(of: revealToken) { _, _ in
            appeared = false
            reveal()
        }
    }

    private func reveal() {
        withAnimation(.spring(duration: 0.55, bounce: 0.2).delay(Double(index) * 0.06)) {
            appeared = true
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                UsageRing(fraction: snapshot?.headlineFraction, brand: provider.brand, lineWidth: 3, size: 46)
                BrandTile(provider: provider, size: 30)
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(provider.displayName)
                        .font(Theme.Typography.cardTitle)
                        .foregroundStyle(Theme.Palette.textPrimary)
                    Text(provider.vendor)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.textTertiary)
                    StatusDot(kind: dotKind)
                }
                HStack(spacing: 6) {
                    if let plan = snapshot?.plan {
                        Pill(text: plan.uppercased(), tint: provider.brand.colors[0])
                    }
                    if let account = snapshot?.account {
                        Text(account)
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Palette.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } else if snapshot == nil, state.isLoading {
                        SkeletonBlock(width: 120, height: 9)
                    } else if let failure = state.failure {
                        Text(failure.shortLabel)
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Palette.textSecondary)
                    }
                }
            }

            Spacer(minLength: 8)

            headlineNumber
                .opacity(isShowingCached ? 0.55 : 1)
                .saturation(isShowingCached ? 0.4 : 1)
        }
    }

    private var headlineNumber: some View {
        VStack(alignment: .trailing, spacing: -2) {
            if let snapshot {
                if let fraction = snapshot.headlineFraction {
                    (Text("\(Int((fraction * 100).rounded()))")
                        .font(Theme.Typography.display(26))
                        .foregroundStyle(headlineColor(fraction))
                    + Text("%")
                        .font(Theme.Typography.display(14, weight: .semibold))
                        .foregroundStyle(headlineColor(fraction).opacity(0.7)))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .animation(.spring(duration: 0.6), value: fraction)
                    Text("used")
                        .font(Theme.Typography.micro)
                        .foregroundStyle(Theme.Palette.textTertiary)
                        .tracking(0.6)
                        .textCase(.uppercase)
                } else {
                    Text("∞")
                        .font(Theme.Typography.display(26))
                        .foregroundStyle(Theme.Palette.textPrimary)
                    Text("unlimited")
                        .font(Theme.Typography.micro)
                        .foregroundStyle(Theme.Palette.textTertiary)
                        .tracking(0.6)
                        .textCase(.uppercase)
                }
            } else if state.isLoading {
                SkeletonBlock(width: 44, height: 22)
            } else {
                Image(systemName: state.failure?.kind.symbol ?? "questionmark")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(Theme.Palette.textTertiary)
                    .frame(height: 30)
            }
        }
    }

    private func headlineColor(_ fraction: Double) -> Color {
        fraction >= 0.75 ? Theme.statusColor(for: fraction) : Theme.Palette.textPrimary
    }

    private var dotKind: StatusDot.Kind {
        if state.isLoading { return .loading }
        if let failure = state.failure {
            return failure.kind == .notRunning || failure.kind == .notInstalled ? .offline : .error
        }
        guard let fraction = snapshot?.headlineFraction else { return .ok }
        if fraction >= 0.9 { return .critical }
        if fraction >= 0.75 { return .warm }
        return .ok
    }

    // MARK: Metrics

    @ViewBuilder
    private func metricsSection(_ snapshot: UsageSnapshot) -> some View {
        let measured = snapshot.metrics.filter { !$0.isUnlimited }
        let unlimited = snapshot.metrics.filter(\.isUnlimited)
        let visible = expanded ? measured : Array(measured.prefix(collapsedMetricLimit))
        let hidden = measured.count - visible.count

        if !measured.isEmpty || !unlimited.isEmpty {
            Divider()
                .overlay(Theme.Palette.surfaceStroke)
                .padding(.horizontal, 16)
        }

        VStack(alignment: .leading, spacing: 11) {
            ForEach(visible) { metric in
                MetricRow(metric: metric, brand: provider.brand)
            }

            if hidden > 0 || (expanded && measured.count > collapsedMetricLimit) {
                Button {
                    withAnimation(.spring(duration: 0.4, bounce: 0.1)) { expanded.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        Text(expanded ? "Show less" : "Show \(hidden) more")
                        Image(systemName: "chevron.down")
                            .rotationEffect(.degrees(expanded ? 180 : 0))
                    }
                    .font(Theme.Typography.micro)
                    .foregroundStyle(Theme.Palette.textSecondary)
                }
                .buttonStyle(.plain)
            }

            if !unlimited.isEmpty {
                HStack(spacing: 6) {
                    ForEach(unlimited) { metric in
                        Pill(text: "∞ \(metric.label)", tint: Theme.Palette.textSecondary)
                    }
                    Spacer(minLength: 0)
                }
            }

            if let note = snapshot.note {
                Text(note)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textTertiary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 14)
    }

    private var skeleton: some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider().overlay(Theme.Palette.surfaceStroke)
            HStack { SkeletonBlock(width: 110, height: 9); Spacer(); SkeletonBlock(width: 60, height: 9) }
            SkeletonBlock(height: 6)
            HStack { SkeletonBlock(width: 80, height: 9); Spacer(); SkeletonBlock(width: 40, height: 9) }
            SkeletonBlock(height: 6)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
    }

    private func failureSection(_ failure: ProviderFailure) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider().overlay(Theme.Palette.surfaceStroke)
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: failure.kind.symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(failure.kind.isSoft ? Theme.Palette.textSecondary : Theme.Palette.danger)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 3) {
                    Text(failure.message)
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Palette.textPrimary.opacity(0.9))
                        .fixedSize(horizontal: false, vertical: true)
                    if let hint = failure.hint {
                        Text(hint)
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Palette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
                Button(action: onRetry) {
                    Text("Retry")
                        .font(Theme.Typography.micro)
                        .foregroundStyle(Theme.Palette.textPrimary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(Theme.Palette.surfaceHover))
                        .overlay(Capsule().strokeBorder(Theme.Palette.surfaceStrokeHover, lineWidth: 0.5))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
    }

    /// Soft failures (app closed) read as a calm status line; real errors stay amber.
    private func staleBanner(_ failure: ProviderFailure, snapshot: UsageSnapshot) -> some View {
        let soft = failure.kind.isSoft
        let tint = soft ? Theme.Palette.textSecondary : Theme.Palette.warning.opacity(0.9)
        let lastRead = "last read \(ResetFormatter.relative(snapshot.fetchedAt, now: now))"
        let text = soft ? "\(failure.shortLabel) · \(lastRead)" : "Couldn't refresh · \(lastRead)"

        return HStack(spacing: 6) {
            Image(systemName: soft ? "clock.arrow.circlepath" : "exclamationmark.triangle.fill")
                .font(.system(size: 9, weight: .bold))
            Text(text)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(failure.message + (failure.hint.map { "\n\($0)" } ?? ""))
            Spacer(minLength: 0)
            Button("Retry", action: onRetry)
                .buttonStyle(.plain)
                .underline()
        }
        .font(Theme.Typography.micro)
        .foregroundStyle(tint)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(soft ? Theme.Palette.surface : Theme.Palette.warning.opacity(0.08))
    }
}

struct MetricRow: View {
    let metric: UsageMetric
    let brand: Brand

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(metric.label)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if let detail = metric.detail {
                    Text(detail)
                        .font(Theme.Typography.body)
                        .monospacedDigit()
                        .foregroundStyle(Theme.Palette.textPrimary.opacity(0.85))
                        .lineLimit(1)
                }
                if let percent = metric.usedPercent {
                    Text("\(percent)%")
                        .font(Theme.Typography.body)
                        .monospacedDigit()
                        .foregroundStyle(Theme.statusColor(for: metric.usedFraction))
                        .frame(minWidth: 34, alignment: .trailing)
                        .contentTransition(.numericText())
                }
            }
            UsageBar(fraction: metric.usedFraction, brand: brand, height: 5)
            if let reset = ResetFormatter.text(for: metric.resetsAt) {
                Text(reset)
                    .font(Theme.Typography.micro)
                    .foregroundStyle(Theme.Palette.textTertiary)
            }
        }
    }
}

extension ProviderFailureKind {
    var symbol: String {
        switch self {
        case .notInstalled: "square.dashed"
        case .notSignedIn: "person.crop.circle.badge.questionmark"
        case .notRunning: "power"
        case .unauthorized: "lock.slash"
        case .network: "wifi.exclamationmark"
        case .parsing: "doc.questionmark"
        case .unknown: "exclamationmark.triangle"
        }
    }

    var shortLabel: String {
        switch self {
        case .notInstalled: "Not installed"
        case .notSignedIn: "Signed out"
        case .notRunning: "Not running"
        case .unauthorized: "Token expired"
        case .network: "Offline"
        case .parsing: "Unexpected data"
        case .unknown: "Unavailable"
        }
    }

    /// Soft failures are expected states (app closed), not errors worth red ink.
    var isSoft: Bool {
        self == .notInstalled || self == .notRunning
    }
}
