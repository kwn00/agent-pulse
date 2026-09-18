import AppKit
import SwiftUI

/// True when rendering a one-shot image (no animations, final values only).
private struct StaticRenderKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var staticRender: Bool {
        get { self[StaticRenderKey.self] }
        set { self[StaticRenderKey.self] = newValue }
    }
}

struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        view.isEmphasized = true
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

/// Deep glass background with soft brand-colored orbs.
struct PanelBackground: View {
    var accent: Color
    /// Off for the fog copies layered above the content (stacking vibrancy views looks wrong).
    var includesVibrancy = true
    @Environment(\.staticRender) private var staticRender

    var body: some View {
        ZStack {
            // ImageRenderer can't rasterise NSVisualEffectView (it leaves a smudge), so skip it offscreen.
            if includesVibrancy, !staticRender {
                VisualEffectView(material: .hudWindow)
            }
            LinearGradient(
                colors: [Theme.Palette.backgroundTop.opacity(0.94), Theme.Palette.backgroundBottom.opacity(0.97)],
                startPoint: .top,
                endPoint: .bottom
            )
            // Radial fills instead of blurred discs: identical look, deterministic in offscreen renders.
            GeometryReader { proxy in
                let size = proxy.size
                glowOrb(accent.opacity(0.30), diameter: size.width * 1.6)
                    .position(x: size.width * 0.1, y: -size.width * 0.05)
                glowOrb(Theme.Palette.accent.opacity(0.12), diameter: size.width * 1.4)
                    .position(x: size.width * 0.95, y: size.width * 0.35)
            }
            .allowsHitTesting(false)
            // Top-edge highlight sells the "glass" read.
            VStack {
                LinearGradient(colors: [.white.opacity(0.12), .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: 90)
                Spacer(minLength: 0)
            }
            .allowsHitTesting(false)
        }
    }
}

private func glowOrb(_ color: Color, diameter: CGFloat) -> some View {
    Circle()
        .fill(
            RadialGradient(
                colors: [color, color.opacity(0)],
                center: .center,
                startRadius: 0,
                endRadius: diameter / 2
            )
        )
        .frame(width: diameter, height: diameter)
}

struct UsageRing: View {
    var fraction: Double?
    var brand: Brand
    var lineWidth: CGFloat = 3.5
    var size: CGFloat = 48

    @State private var animated: Double = 0
    @Environment(\.staticRender) private var staticRender

    private var shown: Double { staticRender ? (fraction ?? 0) : animated }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Theme.Palette.track, lineWidth: lineWidth)
            if fraction != nil {
                Circle()
                    .trim(from: 0, to: max(0.004, shown))
                    .stroke(brand.angular, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .shadow(color: brand.glow.opacity(0.55), radius: 6)
            } else {
                Circle()
                    .stroke(
                        Theme.Palette.textTertiary.opacity(0.6),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, dash: [2, 5])
                    )
            }
        }
        .frame(width: size, height: size)
        .onAppear { animated = fraction ?? 0 }
        .onChange(of: fraction) { _, newValue in
            withAnimation(.spring(duration: 0.9, bounce: 0.15)) { animated = newValue ?? 0 }
        }
    }
}

struct BrandTile: View {
    enum Style {
        /// Gradient disc with the vendor's real app icon (or the SF Symbol) inside.
        case badge
        /// The vendor's app icon on its own, no disc; falls back to `.badge`.
        case bare
        /// Always the SF Symbol, even when an app icon is available.
        case symbol
    }

    var provider: ProviderID
    var size: CGFloat = 34
    var style: Style = .badge

    var body: some View {
        let icon = style == .symbol ? nil : BrandIcons.shared.image(for: provider)
        if style == .bare, let icon {
            appIcon(icon, side: size)
                .shadow(color: provider.brand.glow.opacity(0.45), radius: 10, y: 4)
        } else {
            ZStack {
                Circle()
                    .fill(provider.brand.gradient)
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [.white.opacity(0.35), .clear],
                            center: .init(x: 0.3, y: 0.2),
                            startRadius: 0,
                            endRadius: size * 0.7
                        )
                    )
                if let icon {
                    appIcon(icon, side: size * 0.64)
                        .shadow(color: .black.opacity(0.35), radius: size * 0.05, y: size * 0.03)
                } else {
                    Image(systemName: provider.symbolName)
                        .font(.system(size: size * 0.42, weight: .semibold))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.25), radius: 1, y: 1)
                }
            }
            .frame(width: size, height: size)
            .shadow(color: provider.brand.glow.opacity(0.45), radius: 10, y: 4)
        }
    }

    /// macOS app icons already carry their squircle; just size and re-round them.
    private func appIcon(_ icon: NSImage, side: CGFloat) -> some View {
        Image(nsImage: icon)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: side, height: side)
            .clipShape(RoundedRectangle(cornerRadius: side * 0.2237, style: .continuous))
    }
}

struct UsageBar: View {
    var fraction: Double?
    var brand: Brand
    var height: CGFloat = 6

    @State private var animated: Double = 0
    @Environment(\.staticRender) private var staticRender

    private var shown: Double { staticRender ? min(1, fraction ?? 0) : animated }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.Palette.track)
                if fraction != nil {
                    Capsule()
                        .fill(brand.barGradient)
                        .frame(width: max(height, proxy.size.width * shown))
                        .shadow(color: brand.glow.opacity(0.5), radius: 5, y: 0)
                }
            }
        }
        .frame(height: height)
        .onAppear { animated = min(1, fraction ?? 0) }
        .onChange(of: fraction) { _, newValue in
            withAnimation(.spring(duration: 0.8, bounce: 0.1)) { animated = min(1, newValue ?? 0) }
        }
    }
}

struct StatusDot: View {
    enum Kind { case ok, warm, critical, error, loading, offline }

    var kind: Kind
    @State private var pulse = false

    private var color: Color {
        switch kind {
        case .ok: Theme.Palette.success
        case .warm: Theme.Palette.warning
        case .critical, .error: Theme.Palette.danger
        case .loading: Theme.Palette.accent
        case .offline: Theme.Palette.textTertiary
        }
    }

    var body: some View {
        ZStack {
            if kind == .loading || kind == .critical {
                Circle()
                    .fill(color.opacity(0.35))
                    .frame(width: 14, height: 14)
                    .scaleEffect(pulse ? 1.4 : 0.6)
                    .opacity(pulse ? 0 : 0.9)
                    .animation(.easeOut(duration: 1.4).repeatForever(autoreverses: false), value: pulse)
            }
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
                .shadow(color: color.opacity(0.8), radius: 3)
        }
        .frame(width: 14, height: 14)
        .onAppear { pulse = true }
    }
}

struct Pill: View {
    var text: String
    var tint: Color = Theme.Palette.textSecondary
    var filled = false

    var body: some View {
        Text(text)
            .font(Theme.Typography.micro)
            .tracking(0.2)
            .foregroundStyle(filled ? Color.black.opacity(0.85) : tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                Capsule().fill(filled ? tint : tint.opacity(0.14))
            )
            .overlay(
                Capsule().strokeBorder(filled ? .clear : tint.opacity(0.25), lineWidth: 0.5)
            )
    }
}

struct GlassIconButton: View {
    var systemName: String
    var help: String
    var isSpinning = false
    var action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            SpinningSymbol(systemName: systemName, isSpinning: isSpinning)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(hovering ? Theme.Palette.textPrimary : Theme.Palette.textSecondary)
                .frame(width: 28, height: 28)
                .background(
                    Circle().fill(hovering ? Theme.Palette.surfaceHover : Theme.Palette.surface)
                )
                .overlay(Circle().strokeBorder(Theme.Palette.surfaceStroke, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
    }
}

/// Clock-driven spin for a 180°-symmetric glyph. Unlike `repeatForever`, stopping doesn't rewind:
/// the symbol eases forward to the next 0°/180° pose, which for a point-symmetric icon looks at rest.
struct SpinningSymbol: View {
    var systemName: String
    var isSpinning: Bool
    var period: TimeInterval = 1.1

    @State private var spinStart: Date?
    @State private var restingAngle: Double = 0

    var body: some View {
        TimelineView(.animation(paused: spinStart == nil)) { context in
            Image(systemName: systemName)
                .rotationEffect(.degrees(angle(at: context.date)))
        }
        .onChange(of: isSpinning, initial: true) { _, spinning in
            if spinning {
                guard spinStart == nil else { return }
                spinStart = Date()
            } else if let start = spinStart {
                let current = liveAngle(at: Date(), since: start).truncatingRemainder(dividingBy: 360)
                let landing = (current / 180).rounded(.up) * 180
                spinStart = nil
                var snap = Transaction()
                snap.disablesAnimations = true
                withTransaction(snap) { restingAngle = current }
                withAnimation(.easeOut(duration: 0.35)) { restingAngle = landing }
            }
        }
    }

    private func angle(at date: Date) -> Double {
        guard let spinStart else { return restingAngle }
        return liveAngle(at: date, since: spinStart)
    }

    private func liveAngle(at date: Date, since start: Date) -> Double {
        max(0, date.timeIntervalSince(start)) / period * 360
    }
}

struct SkeletonBlock: View {
    var width: CGFloat? = nil
    var height: CGFloat = 10

    @State private var phase: CGFloat = -1

    var body: some View {
        RoundedRectangle(cornerRadius: height / 2, style: .continuous)
            .fill(Theme.Palette.track)
            .frame(width: width, height: height)
            .overlay(
                GeometryReader { proxy in
                    LinearGradient(
                        colors: [.clear, .white.opacity(0.14), .clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: proxy.size.width * 0.6)
                    .offset(x: proxy.size.width * phase)
                }
                .clipShape(RoundedRectangle(cornerRadius: height / 2, style: .continuous))
            )
            .onAppear {
                withAnimation(.linear(duration: 1.3).repeatForever(autoreverses: false)) { phase = 1.2 }
            }
    }
}

/// Reports the laid-out size of the modified view.
struct SizeReader: ViewModifier {
    var onChange: (CGSize) -> Void

    func body(content: Content) -> some View {
        content.background(
            GeometryReader { proxy in
                Color.clear
                    .onChange(of: proxy.size, initial: true) { _, newValue in onChange(newValue) }
            }
        )
    }
}

extension View {
    func readSize(_ onChange: @escaping (CGSize) -> Void) -> some View {
        modifier(SizeReader(onChange: onChange))
    }
}
