import AppKit
import Combine
import MacWallKit

final class WallpaperWindow: NSWindow {
    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        isReleasedWhenClosed = false
        hasShadow = false
        backgroundColor = .black
        setFrame(screen.frame, display: false)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

extension NSScreen {
    var displayID: CGDirectDisplayID {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0
    }

    /// Stable across reboots and reconnects, unlike the display ID.
    var uuid: String {
        guard let u = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() else { return "\(displayID)" }
        return CFUUIDCreateString(nil, u) as String
    }
}

/// One wallpaper window per display, kept in sync with settings and the screen configuration.
@MainActor
final class WallpaperManager: ObservableObject {
    static let shared = WallpaperManager()

    private struct Slot {
        let window: WallpaperWindow
        let renderer: WallpaperRenderer
        let wallpaperID: String
        let displayID: CGDirectDisplayID
    }

    private var slots: [String: Slot] = [:]
    private var bag = Set<AnyCancellable>()
    private let settings = AppSettings.shared
    @Published var userPaused = false { didSet { applyPause() } }
    let governor = Governor()

    private init() {
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in self?.reload() }.store(in: &bag)
        settings.$assignments.combineLatest(settings.$mirror)
            .debounce(for: .milliseconds(50), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.reload(force: false) }.store(in: &bag)
        settings.$quality.combineLatest(settings.$fpsLimit).dropFirst()
            .debounce(for: .milliseconds(50), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.reload(force: true) }.store(in: &bag)
        settings.$volume.sink { [weak self] v in self?.slots.values.forEach { $0.renderer.setVolume(v) } }.store(in: &bag)
        Library.shared.$items.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.reload() }
        }.store(in: &bag)
        governor.onChange = { [weak self] in self?.applyPause() }
        settings.$lockScreenStill.dropFirst().sink { [weak self] on in
            if on { self?.slots.keys.forEach { self?.captureLockScreenSoon($0) } } else { LockScreen.restore() }
        }.store(in: &bag)
        #if DEBUG
        SelfTest.runIfRequested { [weak self] in self?.slots.map { ($0.key, $0.value.renderer) } ?? [] }
        #endif
    }

    func reload(force: Bool = false) {
        var live = Set<String>()
        for screen in NSScreen.screens {
            let key = screen.uuid
            live.insert(key)
            guard let wp = Library.shared.item(settings.wallpaperID(forDisplay: key)) else {
                remove(key)
                continue
            }
            if let slot = slots[key], slot.wallpaperID == wp.id, !force {
                slot.window.setFrame(screen.frame, display: true)
                continue
            }
            remove(key)
            let window = WallpaperWindow(screen: screen)
            let renderer = makeRenderer(for: wp, settings: settings)
            renderer.view.frame = window.contentLayoutRect
            renderer.view.autoresizingMask = [.width, .height]
            window.contentView = renderer.view
            window.orderBack(nil)
            slots[key] = Slot(window: window, renderer: renderer, wallpaperID: wp.id, displayID: screen.displayID)
            captureLockScreenSoon(key)
        }
        slots.keys.filter { !live.contains($0) }.forEach(remove)
        applyPause()
    }

    /// Stores a property edit and applies it to every window showing that wallpaper.
    func setProperty(_ w: Wallpaper, key: String, value: Any) {
        settings.propertyOverrides[w.id, default: [:]][key] = value
        SceneSupport.invalidate(w.folder)
        let change = WallpaperProperties(json: w.project.propertiesJSON).changeJSON(key: key, value: value)
        let needsRebuild = slots.values.filter { $0.wallpaperID == w.id }.contains { !$0.renderer.applyUserProperties(change) }
        if needsRebuild { rebuildSoon(w.id) }
    }

    func resetProperties(_ w: Wallpaper) {
        settings.propertyOverrides[w.id] = nil
        SceneSupport.invalidate(w.folder)
        rebuildSoon(w.id)
    }

    /// Once the wallpaper has had a moment to load/draw, save a still for the lock screen.
    private func captureLockScreenSoon(_ key: String) {
        guard let renderer = slots[key]?.renderer else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self, weak renderer] in
            guard let self, let renderer, self.slots[key]?.renderer === renderer,
                  let screen = NSScreen.screens.first(where: { $0.uuid == key }) else { return }
            LockScreen.update(screen: screen, from: renderer)
        }
    }

    private var pendingRebuild: DispatchWorkItem?

    /// Debounced so dragging a slider doesn't rebuild a scene on every tick.
    private func rebuildSoon(_ id: String) {
        pendingRebuild?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.slots.filter { $0.value.wallpaperID == id }.keys.forEach(self.remove)
            self.reload()
        }
        pendingRebuild = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private func remove(_ key: String) {
        guard let slot = slots.removeValue(forKey: key) else { return }
        slot.renderer.stop()
        slot.window.orderOut(nil)
    }

    private func applyPause() {
        for slot in slots.values {
            slot.renderer.setPaused(userPaused || governor.pausedEverywhere || governor.coveredDisplays.contains(slot.displayID))
        }
    }
}
