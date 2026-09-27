#if DEBUG
import AppKit
import AVFoundation
import WebKit

/// `MACWALL_SELFTEST=<dir> build/MacWall.app/Contents/MacOS/MacWall` (debug build) writes a PNG and a
/// status line per wallpaper window, so rendering can be checked without Screen Recording permission.
@MainActor
enum SelfTest {
    static func runIfRequested(renderers: @escaping () -> [(String, WallpaperRenderer)]) {
        guard let dir = ProcessInfo.processInfo.environment["MACWALL_SELFTEST"] else { return }
        let url = URL(fileURLWithPath: dir)
        // Force playback on (the governor may have paused it), let it run, then capture.
        // Occluded web views are suspended by WebKit; opt out so the rAF path is exercised anyway.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            for (_, r) in renderers() {
                (r as? WebRenderer)?.webView.configuration.preferences.inactiveSchedulingPolicy = .none
                r.setPaused(false)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
            for (key, r) in renderers() {
                let base = url.appendingPathComponent(String(key.prefix(8)))
                snapshot(r) { image, status in
                    try? status.write(to: base.appendingPathExtension("txt"), atomically: true, encoding: .utf8)
                    if let image, let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
                        try? data.write(to: base.appendingPathExtension("png"))
                    }
                }
            }
        }
    }

    /// Renders an app window's content view (works without Screen Recording permission).
    static func capture(_ window: NSWindow?, to url: URL) {
        guard let view = window?.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    private static func snapshot(_ r: WallpaperRenderer, done: @escaping (CGImage?, String) -> Void) {
        switch r {
        case let web as WebRenderer:
            web.webView.evaluateJavaScript("document.body.innerText") { text, _ in
                web.webView.takeSnapshot(with: nil) { img, _ in
                    done(img?.cgImage(forProposedRect: nil, context: nil, hints: nil),
                         "web: \(text ?? "nil") occlusionVisible=\(web.webView.window?.occlusionState.contains(.visible) ?? false)")
                }
            }
        case let video as VideoRenderer:
            let p = video.player
            let status = "video: rate=\(p.rate) time=\(p.currentTime().seconds) status=\(p.currentItem?.status.rawValue ?? -1)"
            guard let asset = p.currentItem?.asset else { return done(nil, status) }
            AVAssetImageGenerator(asset: asset).generateCGImageAsynchronously(for: p.currentTime()) { img, _, _ in
                DispatchQueue.main.async { done(img, status) }
            }
        case let scene as SceneRenderer:
            done(scene.debugSnapshot(), "scene: \(scene.debugStatus)")
        default:
            done(nil, "\(type(of: r))")
        }
    }
}
#endif
