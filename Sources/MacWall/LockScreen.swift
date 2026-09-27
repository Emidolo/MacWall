import AppKit

/// macOS draws the lock screen itself from the system desktop picture; no app can put a live
/// window there. So MacWall keeps that picture set to a still of the running wallpaper, and
/// remembers the original so it can be put back.
@MainActor
enum LockScreen {
    static let dir = Library.root.deletingLastPathComponent().appendingPathComponent("LockScreen", isDirectory: true)
    private static let fill: [NSWorkspace.DesktopImageOptionKey: Any] = [
        .imageScaling: NSImageScaling.scaleProportionallyUpOrDown.rawValue, .allowClipping: true,
    ]

    static func update(screen: NSScreen, from renderer: WallpaperRenderer) {
        guard AppSettings.shared.lockScreenStill else { return }
        let uuid = screen.uuid
        let size = CGSize(width: screen.frame.width * screen.backingScaleFactor, height: screen.frame.height * screen.backingScaleFactor)
        renderer.snapshot(pixelSize: size) { image in
            guard AppSettings.shared.lockScreenStill, let image,
                  let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]),
                  let screen = NSScreen.screens.first(where: { $0.uuid == uuid }) else { return }
            let fm = FileManager.default
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            // A fresh name every time: macOS caches desktop pictures by URL.
            let url = dir.appendingPathComponent("\(uuid)-\(Int(Date().timeIntervalSince1970)).png")
            guard (try? png.write(to: url)) != nil else { return }
            rememberOriginal(screen)
            do {
                try NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: fill)
            } catch {
                NSLog("MacWall: couldn't set the desktop picture: \(error.localizedDescription)")
            }
            for old in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            where old.lastPathComponent.hasPrefix(uuid) && old.lastPathComponent != url.lastPathComponent {
                try? fm.removeItem(at: old)
            }
        }
    }

    /// Puts back the desktop pictures MacWall replaced.
    static func restore() {
        let settings = AppSettings.shared
        for screen in NSScreen.screens {
            guard let s = settings.originalDesktopImages[screen.uuid], let url = URL(string: s) else { continue }
            try? NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: NSWorkspace.shared.desktopImageOptions(for: screen) ?? [:])
        }
        settings.originalDesktopImages = [:]
        try? FileManager.default.removeItem(at: dir)
    }

    private static func rememberOriginal(_ screen: NSScreen) {
        let settings = AppSettings.shared
        guard settings.originalDesktopImages[screen.uuid] == nil,
              let current = NSWorkspace.shared.desktopImageURL(for: screen),
              !current.path.hasPrefix(dir.path) else { return }
        settings.originalDesktopImages[screen.uuid] = current.absoluteString
    }
}
