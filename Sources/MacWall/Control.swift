import AppKit
import Combine
import MacWallKit

/// Lets other apps drive MacWall: runs `macwall://` commands and announces state changes.
@MainActor
enum Control {
    /// Posted (distributed) whenever the wallpaper, pause state or volume changes. `userInfo` carries
    /// `assignments`, `mirror`, `volume` and `userPaused`, the same keys as MacWall's defaults domain.
    static let stateChanged = Notification.Name("dev.macwall.MacWall.stateChanged")
    private static var bag = Set<AnyCancellable>()

    static func start() {
        let settings = AppSettings.shared, manager = WallpaperManager.shared
        Publishers.MergeMany(settings.$assignments.map { _ in }.eraseToAnyPublisher(),
                             settings.$mirror.map { _ in }.eraseToAnyPublisher(),
                             settings.$volume.map { _ in }.eraseToAnyPublisher(),
                             manager.$userPaused.map { _ in }.eraseToAnyPublisher())
            // @Published fires before the new value is stored; the debounce reads it afterwards
            // (and folds a slider drag into a few posts).
            .debounce(for: .milliseconds(50), scheduler: RunLoop.main)
            .sink {
                // Not otherwise persisted; stored so a controller that starts later can read it.
                UserDefaults.standard.set(manager.userPaused, forKey: "userPaused")
                DistributedNotificationCenter.default().postNotificationName(stateChanged, object: nil, userInfo: [
                    "assignments": settings.assignments, "mirror": settings.mirror,
                    "volume": settings.volume, "userPaused": manager.userPaused,
                ], deliverImmediately: true)
            }
            .store(in: &bag)
    }

    static func handle(_ url: URL) {
        guard let command = ControlCommand(url: url) else { return }
        let settings = AppSettings.shared, manager = WallpaperManager.shared
        switch command {
        case .set(let id, let display):
            guard let wallpaper = Library.shared.item(id), playable(wallpaper),
                  display == nil || NSScreen.screens.contains(where: { $0.uuid == display }) else { return }
            settings.assign(id, display: display)
        case .next: step(1)
        case .previous: step(-1)
        case .pause: manager.userPaused = true
        case .resume: manager.userPaused = false
        case .toggle: manager.userPaused.toggle()
        case .volume(let level): settings.volume = level
        case .openLibrary: (NSApp.delegate as? AppDelegate)?.showLibrary()
        }
    }

    private static func playable(_ wallpaper: Wallpaper) -> Bool {
        [.video, .web, .scene].contains(wallpaper.project.kind)
    }

    /// Cycles through the library in title order. Mirrored: on all displays; otherwise on the primary display.
    private static func step(_ offset: Int) {
        let settings = AppSettings.shared
        let items = Library.shared.items.filter(playable)
        guard !items.isEmpty, let screen = NSScreen.screens.first else { return }
        let current = items.firstIndex { $0.id == settings.wallpaperID(forDisplay: screen.uuid) }
        let next = current.map { ($0 + offset + items.count) % items.count } ?? 0
        settings.assign(items[next].id, display: settings.mirror ? nil : screen.uuid)
    }
}
