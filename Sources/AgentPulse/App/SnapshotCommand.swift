import AppKit
import SwiftUI

/// `AgentPulse --snapshot out.png`: fetch once, render the panel offscreen at 2× and exit.
/// Used to eyeball the design without touching the live menu bar.
@MainActor
enum SnapshotCommand {
    static func run(outputPath: String, settingsPane: Bool, scrolledBy: CGFloat? = nil, tilesOnly: Bool = false) async {
        if tilesOnly {
            write(BrandTileSheet().environment(\.staticRender, true), to: outputPath)
            return
        }

        let store = UsageStore(providers: ProviderRegistry.makeDefault(), cache: nil)
        store.refreshAll()

        // Wait for every provider to settle (bounded so a hung socket can't stall the render).
        let deadline = Date().addingTimeInterval(20)
        while store.isRefreshing, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }

        let layout = PanelLayout()
        if let scrolledBy {
            layout.maxListHeight = 520
            layout.debugScrollOffset = scrolledBy
        } else {
            layout.unconstrained = true
        }

        let view = PulsePanelView(
            store: store,
            settings: .shared,
            layout: layout,
            onSizeChange: { _ in },
            onQuit: {},
            initiallyShowingSettings: settingsPane
        )
        .environment(\.staticRender, true)
        .padding(24)
        .background(Color(hex: 0x05070C))

        write(view, to: outputPath)
    }

    private static func write(_ view: some View, to outputPath: String) {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        renderer.isOpaque = false

        // Wide-gamut app icons push the renderer into an extended working space; bake the result
        // down to plain sRGB so every viewer (and README) shows the same colours.
        guard let rendered = renderer.cgImage,
              let srgb = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil, width: rendered.width, height: rendered.height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            fputs("snapshot: render failed\n", stderr)
            exit(1)
        }
        context.draw(rendered, in: CGRect(x: 0, y: 0, width: rendered.width, height: rendered.height))
        guard let converted = context.makeImage(),
              let png = NSBitmapImageRep(cgImage: converted).representation(using: .png, properties: [:]) else {
            fputs("snapshot: encode failed\n", stderr)
            exit(1)
        }

        do {
            try png.write(to: URL(fileURLWithPath: outputPath))
            print("snapshot: wrote \(outputPath) (\(rendered.width / 2)×\(rendered.height / 2) pt)")
            exit(0)
        } catch {
            fputs("snapshot: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}

/// `--snapshot out.png --tiles`: the four brand tiles at card size and blown up, for icon reviews.
private struct BrandTileSheet: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 30) {
            row("A · badge: disc + installed app icon", style: .badge)
            row("B · bare: installed app icon only", style: .bare)
            row("C · symbol: SF Symbol fallback", style: .symbol)
        }
        .padding(36)
        .background(Color(hex: 0x0B0E17))
    }

    private func row(_ title: String, style: BrandTile.Style) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(Theme.Typography.mono)
                .foregroundStyle(Theme.Palette.textTertiary)
            HStack(spacing: 40) {
                ForEach(ProviderID.allCases) { provider in
                    HStack(spacing: 22) {
                        ZStack {
                            UsageRing(fraction: 0.62, brand: provider.brand, lineWidth: 3, size: 46)
                            BrandTile(provider: provider, size: 30, style: style)
                        }
                        BrandTile(provider: provider, size: 84, style: style)
                    }
                }
            }
        }
    }
}
