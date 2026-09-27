import AppKit
import ServiceManagement
import Security

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
    @Published var steamUsername: String { didSet { Keychain.username = steamUsername } }

    private init() {
        assignments = d.dictionary(forKey: "assignments") as? [String: String] ?? [:]
        mirror = d.object(forKey: "mirror") as? Bool ?? true
        volume = d.object(forKey: "volume") as? Float ?? 0
        fpsLimit = d.integer(forKey: "fpsLimit")
        quality = Quality(rawValue: d.string(forKey: "quality") ?? "") ?? .high
        showDockIcon = d.bool(forKey: "showDockIcon")
        steamcmdPath = d.string(forKey: "steamcmdPath") ?? ""
        steamUsername = Keychain.username ?? ""
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
enum Keychain {
    private static let base: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "dev.macwall.steam",
        kSecAttrAccount as String: "username",
    ]

    static var username: String? {
        get {
            var q = base
            q[kSecReturnData as String] = true
            var out: AnyObject?
            guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        }
        set {
            SecItemDelete(base as CFDictionary)
            guard let newValue, !newValue.isEmpty else { return }
            var q = base
            q[kSecValueData as String] = Data(newValue.utf8)
            SecItemAdd(q as CFDictionary, nil)
        }
    }
}
