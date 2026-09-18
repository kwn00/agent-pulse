import AppKit
import Foundation

/// Resolves a real brand image per provider without shipping any vendor artwork:
/// 1. a user-supplied file in `~/Library/Application Support/Agent Pulse/Icons/<provider>.png`
/// 2. the icon of the vendor's installed app, via the same API Finder and the Dock use
/// Anything else falls back to the SF Symbol on the tile.
@MainActor
final class BrandIcons {
    static let shared = BrandIcons()

    private var cache: [ProviderID: NSImage?] = [:]

    static var overrideDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Agent Pulse/Icons")
    }

    func image(for provider: ProviderID) -> NSImage? {
        if let cached = cache[provider] { return cached }
        let resolved = userOverride(for: provider) ?? installedAppIcon(for: provider)
        // App icons carry many representations; a large nominal size makes SwiftUI pick a sharp one.
        resolved?.size = NSSize(width: 512, height: 512)
        cache[provider] = resolved
        return resolved
    }

    func invalidate() { cache.removeAll() }

    private func userOverride(for provider: ProviderID) -> NSImage? {
        for ext in ["png", "pdf", "icns", "tiff", "jpg"] {
            let url = Self.overrideDirectory.appendingPathComponent("\(provider.rawValue).\(ext)")
            if let image = NSImage(contentsOf: url) { return image }
        }
        return nil
    }

    private func installedAppIcon(for provider: ProviderID) -> NSImage? {
        let workspace = NSWorkspace.shared
        for bundleID in provider.appBundleIdentifiers {
            if let url = workspace.urlForApplication(withBundleIdentifier: bundleID) {
                return bundledIcon(in: url, for: provider) ?? workspace.icon(forFile: url.path)
            }
        }
        let roots = ["/Applications", Paths.home.appendingPathComponent("Applications").path]
        for name in provider.appNames {
            for root in roots {
                let url = URL(fileURLWithPath: "\(root)/\(name).app")
                if FileManager.default.fileExists(atPath: url.path) {
                    return bundledIcon(in: url, for: provider) ?? workspace.icon(forFile: url.path)
                }
            }
        }
        return nil
    }

    /// Some bundles carry a product-specific icon besides the one Finder shows — the ChatGPT app
    /// (bundle id `com.openai.codex`) ships Codex's own mark as `app.icns`. Prefer those.
    private func bundledIcon(in appURL: URL, for provider: ProviderID) -> NSImage? {
        let resources = appURL.appendingPathComponent("Contents/Resources")
        for name in provider.preferredIconResources {
            if let image = NSImage(contentsOf: resources.appendingPathComponent(name)) { return image }
        }
        return nil
    }
}

extension ProviderID {
    /// Known bundle identifiers of the vendor's desktop apps, most specific first.
    var appBundleIdentifiers: [String] {
        switch self {
        case .antigravity: ["com.google.antigravity", "com.google.antigravity-ide"]
        case .copilot: ["com.github.copilot", "com.github.githubapp"]
        case .codex: ["com.openai.codex", "com.openai.chat"]
        case .cursor: ["com.todesktop.230313mzl4w4u92"]
        }
    }

    var appNames: [String] {
        switch self {
        case .antigravity: ["Antigravity", "Antigravity IDE"]
        case .copilot: ["GitHub Copilot"]
        case .codex: ["Codex", "ChatGPT"]
        case .cursor: ["Cursor"]
        }
    }

    /// Icon files inside the app bundle that represent this product better than the bundle icon.
    var preferredIconResources: [String] {
        switch self {
        case .codex: ["Codex.icns", "codex.icns", "app.icns"]
        case .copilot: ["Copilot.icns", "copilot.icns"]
        case .antigravity, .cursor: []
        }
    }
}
