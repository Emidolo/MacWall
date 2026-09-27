import AppKit
import SwiftUI

@main
enum Main {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var libraryWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private let manager = WallpaperManager.shared

    func applicationDidFinishLaunching(_ note: Notification) {
        AppSettings.shared.applyDockIcon()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "photo.on.rectangle.angled", accessibilityDescription: "MacWall")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        manager.reload()
        if Library.shared.items.isEmpty { showLibrary() }
        #if DEBUG
        if let dir = ProcessInfo.processInfo.environment["MACWALL_SELFTEST"] {
            showLibrary()
            showSettings()
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [self] in
                SelfTest.capture(libraryWindow, to: URL(fileURLWithPath: dir).appendingPathComponent("library.png"))
                SelfTest.capture(settingsWindow, to: URL(fileURLWithPath: dir).appendingPathComponent("settings.png"))
            }
        }
        #endif
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        showLibrary()
        return true
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(withTitle: "Open Library…", action: #selector(showLibrary), keyEquivalent: "l").target = self
        menu.addItem(withTitle: manager.userPaused ? "Resume" : "Pause", action: #selector(togglePause), keyEquivalent: "p").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",").target = self
        menu.addItem(withTitle: "Quit MacWall", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    @objc func togglePause() { manager.userPaused.toggle() }

    @objc func showLibrary() {
        libraryWindow = present(libraryWindow, title: "MacWall Library", content: LibraryView(), resizable: true)
    }

    @objc func showSettings() {
        settingsWindow = present(settingsWindow, title: "MacWall Settings", content: SettingsView(), resizable: false)
    }

    private func present<V: View>(_ existing: NSWindow?, title: String, content: V, resizable: Bool) -> NSWindow {
        let window = existing ?? {
            let w = NSWindow(contentViewController: NSHostingController(rootView: content))
            w.title = title
            w.styleMask = resizable ? [.titled, .closable, .miniaturizable, .resizable] : [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.center()
            return w
        }()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        return window
    }
}
