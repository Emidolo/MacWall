import AppKit
import ServiceManagement
import Security
import MacWallKit

enum Quality: String, CaseIterable, Identifiable {
    case low, medium, high
    var id: String { rawValue }
    /// Max decode size for video; `.zero` means native.
    var maxVideoSize: CGSize {
        switch self {
        case .low: CGSize(width: 1280, height: 720)
        case .medium: CGSize(width: 1920, height: 1080)
        case .high: .zero
        }
    }
    /// Render scale for scene wallpapers (fraction of the backing resolution).
    var renderScale: CGFloat {
        switch self { case .low: 0.5; case .medium: 0.75; case .high: 1 }
    }
}

/// Key under which the mirrored ("all displays") wallpaper is stored.
let allDisplaysKey = "*"

@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let d = UserDefaults.standard

    /// Display UUID (or `allDisplaysKey`) → wallpaper id.
    @Published var assignments: [String: String] { didSet { d.set(assignments, forKey: "assignments") } }
    @Published var mirror: Bool { didSet { d.set(mirror, forKey: "mirror") } }
    @Published var volume: Float { didSet { d.set(volume, forKey: "volume") } }
    /// 0 = unlimited.
    @Published var fpsLimit: Int { didSet { d.set(fpsLimit, forKey: "fpsLimit") } }
    @Published var quality: Quality { didSet { d.set(quality.rawValue, forKey: "quality") } }
    @Published var showDockIcon: Bool {
        didSet { d.set(showDockIcon, forKey: "showDockIcon"); applyDockIcon() }
    }
    @Published var steamcmdPath: String { didSet { d.set(steamcmdPath, forKey: "steamcmdPath") } }
    /// Optional copy of Wallpaper Engine's `assets` folder, for textures scenes share with WE.
    @Published var weAssetsPath: String { didSet { d.set(weAssetsPath, forKey: "weAssetsPath") } }
    var assetRoots: [URL] { weAssetsPath.isEmpty ? [] : [URL(fileURLWithPath: (weAssetsPath as NSString).expandingTildeInPath)] }
    @Published var steamUsername: String { didSet { Keychain.username = steamUsername } }
    /// Keep the macOS desktop picture (which the lock screen shows) set to a still of the wallpaper.
    @Published var lockScreenStill: Bool { didSet { d.set(lockScreenStill, forKey: "lockScreenStill") } }
    /// Display UUID → the desktop picture it had before MacWall replaced it.
    @Published var originalDesktopImages: [String: String] { didSet { d.set(originalDesktopImages, forKey: "originalDesktopImages") } }
    /// Wallpaper id → property key → the user's value (project.json keeps the defaults).
    @Published var propertyOverrides: [String: [String: Any]] { didSet { d.set(propertyOverrides, forKey: "propertyOverrides") } }

    private init() {
        assignments = d.dictionary(forKey: "assignments") as? [String: String] ?? [:]
        mirror = d.object(forKey: "mirror") as? Bool ?? true
        volume = d.object(forKey: "volume") as? Float ?? 0
        fpsLimit = d.integer(forKey: "fpsLimit")
        quality = Quality(rawValue: d.string(forKey: "quality") ?? "") ?? .high
        showDockIcon = d.bool(forKey: "showDockIcon")
        steamcmdPath = d.string(forKey: "steamcmdPath") ?? ""
        weAssetsPath = d.string(forKey: "weAssetsPath") ?? ""
        steamUsername = Keychain.username ?? ""
        lockScreenStill = d.object(forKey: "lockScreenStill") as? Bool ?? true
        originalDesktopImages = d.dictionary(forKey: "originalDesktopImages") as? [String: String] ?? [:]
        propertyOverrides = d.dictionary(forKey: "propertyOverrides") as? [String: [String: Any]] ?? [:]
    }

    func wallpaperID(forDisplay uuid: String) -> String? {
        mirror ? assignments[allDisplaysKey] : (assignments[uuid] ?? assignments[allDisplaysKey])
    }

    func assign(_ id: String, display uuid: String?) {
        if let uuid {
            mirror = false
            assignments[uuid] = id
        } else {
            mirror = true
            assignments[allDisplaysKey] = id
        }
    }

    /// `general.properties` with the user's edits applied.
    func propertiesJSON(for w: Wallpaper) -> String {
        WallpaperProperties(json: w.project.propertiesJSON).mergedJSON(propertyOverrides[w.id] ?? [:])
    }

    func applyDockIcon() {
        NSApp.setActivationPolicy(showDockIcon ? .regular : .accessory)
    }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            objectWillChange.send()
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                NSAlert(error: error).runModal()
            }
        }
    }
}

/// Stores only the Steam username; steamcmd keeps its own cached session.
/// The username is the item's account *attribute* with no secret data, so reading it never
/// decrypts anything and never triggers a Keychain prompt (ad-hoc signed rebuilds would otherwise
/// ask every time and block launch).
enum Keychain {
    private static let base: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "dev.macwall.steam-username",
    ]

    static var username: String? {
        get {
            var q = base
            q[kSecReturnAttributes as String] = true
            var out: AnyObject?
            guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return nil }
            return (out as? [String: Any])?[kSecAttrAccount as String] as? String
        }
        set {
            SecItemDelete(base as CFDictionary)
            guard let newValue, !newValue.isEmpty else { return }
            var q = base
            q[kSecAttrAccount as String] = newValue
            SecItemAdd(q as CFDictionary, nil)
        }
    }
}
