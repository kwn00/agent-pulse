import SwiftUI

/// Design tokens. Dark, glassy, high-contrast — tuned for a floating menu bar panel.
enum Theme {
    static let panelWidth: CGFloat = 372
    static let panelCornerRadius: CGFloat = 24
    static let cardCornerRadius: CGFloat = 18
    static let maxListHeight: CGFloat = 560

    enum Palette {
        static let backgroundTop = Color(hex: 0x0E1220)
        static let backgroundBottom = Color(hex: 0x080A12)
        static let surface = Color.white.opacity(0.045)
        static let surfaceHover = Color.white.opacity(0.075)
        static let surfaceStroke = Color.white.opacity(0.07)
        static let surfaceStrokeHover = Color.white.opacity(0.14)
        static let track = Color.white.opacity(0.08)
        static let textPrimary = Color.white.opacity(0.95)
        static let textSecondary = Color.white.opacity(0.60)
        static let textTertiary = Color.white.opacity(0.38)
        static let success = Color(hex: 0x4ADE80)
        static let warning = Color(hex: 0xFBBF24)
        static let danger = Color(hex: 0xFB7185)
        static let accent = Color(hex: 0x8B7CFF)
    }

    enum Typography {
        static func display(_ size: CGFloat, weight: Font.Weight = .bold) -> Font {
            .system(size: size, weight: weight, design: .rounded)
        }

        static let title = Font.system(size: 15, weight: .semibold, design: .rounded)
        static let cardTitle = Font.system(size: 13.5, weight: .semibold, design: .rounded)
        static let body = Font.system(size: 12, weight: .medium)
        static let caption = Font.system(size: 11, weight: .medium)
        static let micro = Font.system(size: 10, weight: .semibold)
        static let mono = Font.system(size: 11, weight: .medium, design: .monospaced)
    }

    /// Traffic-light colour for a consumed fraction; calm values stay neutral so only trouble pops.
    static func statusColor(for fraction: Double?, calm: Color = Palette.textSecondary) -> Color {
        guard let fraction else { return Palette.textSecondary }
        if fraction >= 0.9 { return Palette.danger }
        if fraction >= 0.75 { return Palette.warning }
        return calm
    }
}

struct Brand: Sendable {
    var colors: [Color]
    var glow: Color

    var gradient: LinearGradient {
        LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    var barGradient: LinearGradient {
        LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing)
    }

    var angular: AngularGradient {
        AngularGradient(colors: colors + [colors[0]], center: .center, startAngle: .degrees(-90), endAngle: .degrees(270))
    }
}

extension ProviderID {
    var brand: Brand {
        switch self {
        case .antigravity:
            Brand(colors: [Color(hex: 0x8B5CF6), Color(hex: 0xEC4899)], glow: Color(hex: 0xA855F7))
        case .copilot:
            Brand(colors: [Color(hex: 0x38BDF8), Color(hex: 0x6366F1)], glow: Color(hex: 0x60A5FA))
        case .codex:
            Brand(colors: [Color(hex: 0x34D399), Color(hex: 0xA3E635)], glow: Color(hex: 0x4ADE80))
        case .cursor:
            Brand(colors: [Color(hex: 0xFB923C), Color(hex: 0xF43F5E)], glow: Color(hex: 0xFB7185))
        }
    }
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}

enum ResetFormatter {
    /// "Resets in 2h 14m", "Resets tomorrow 09:00", "Resets Oct 1".
    static func text(for date: Date?, now: Date = Date()) -> String? {
        guard let date else { return nil }
        let remaining = date.timeIntervalSince(now)
        if remaining <= 0 { return "Resetting…" }
        if remaining < 60 { return "Resets in under a minute" }
        if remaining < 3600 {
            return "Resets in \(Int(remaining / 60))m"
        }
        if remaining < 86_400 {
            let hours = Int(remaining / 3600)
            let minutes = Int(remaining.truncatingRemainder(dividingBy: 3600) / 60)
            return minutes > 0 ? "Resets in \(hours)h \(minutes)m" : "Resets in \(hours)h"
        }
        if remaining < 7 * 86_400 {
            let days = Int(remaining / 86_400)
            let hours = Int(remaining.truncatingRemainder(dividingBy: 86_400) / 3600)
            return hours > 0 ? "Resets in \(days)d \(hours)h" : "Resets in \(days)d"
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.setLocalizedDateFormatFromTemplate("MMM d")
        return "Resets \(formatter.string(from: date))"
    }

    static func relative(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "never" }
        let seconds = now.timeIntervalSince(date)
        if seconds < 5 { return "just now" }
        if seconds < 60 { return "\(Int(seconds))s ago" }
        if seconds < 3600 { return "\(Int(seconds / 60))m ago" }
        return "\(Int(seconds / 3600))h ago"
    }
}

extension NumberFormatter {
    static let grouped: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter
    }()

    static let currency: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.maximumFractionDigits = 2
        return formatter
    }()
}

extension Double {
    var grouped: String { NumberFormatter.grouped.string(from: NSNumber(value: self)) ?? "\(Int(self))" }
    var usd: String { NumberFormatter.currency.string(from: NSNumber(value: self)) ?? "$\(self)" }
}
