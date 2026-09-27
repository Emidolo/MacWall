import Foundation
import MacWallKit

struct Wallpaper: Identifiable, Hashable {
    let id: String
    let folder: URL
    let project: WallpaperProject

    var previewURL: URL? { project.preview.map { folder.appendingPathComponent($0) } }
    var contentURL: URL? { project.file.map { folder.appendingPathComponent($0) } }
    var title: String { project.title.isEmpty ? id : project.title }

    static func == (a: Self, b: Self) -> Bool { a.id == b.id && a.project == b.project }
    func hash(into h: inout Hasher) { h.combine(id) }
}

@MainActor
final class Library: ObservableObject {
    static let shared = Library()
    static let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("MacWall/wallpapers", isDirectory: true)

    @Published private(set) var items: [Wallpaper] = []
    private let fm = FileManager.default

    private init() {
        try? fm.createDirectory(at: Self.root, withIntermediateDirectories: true)
        reload()
    }

    func reload() {
        let dirs = (try? fm.contentsOfDirectory(at: Self.root, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
        items = dirs.compactMap { dir in
            (try? WallpaperProject(url: dir.appendingPathComponent("project.json")))
                .map { Wallpaper(id: dir.lastPathComponent, folder: dir, project: $0) }
        }.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    func item(_ id: String?) -> Wallpaper? { id.flatMap { id in items.first { $0.id == id } } }

    /// Imports a wallpaper folder, a folder of wallpapers, or a .zip of either.
    @discardableResult
    func importItem(at url: URL) throws -> [Wallpaper] {
        if url.pathExtension.lowercased() == "zip" {
            let tmp = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? fm.removeItem(at: tmp) }
            try run("/usr/bin/ditto", ["-x", "-k", url.path, tmp.path])
            return try importItem(at: tmp)
        }
        let folders = projectFolders(in: url)
        guard !folders.isEmpty else {
            throw NSError(domain: "MacWall", code: 1, userInfo: [NSLocalizedDescriptionKey: "No project.json found in \(url.lastPathComponent)."])
        }
        let ids = try folders.map { try copyIntoLibrary($0) }
        reload()
        return ids.compactMap(item)
    }

    func delete(_ w: Wallpaper) {
        try? fm.removeItem(at: w.folder)
        reload()
    }

    private func copyIntoLibrary(_ folder: URL) throws -> String {
        let project = try WallpaperProject(url: folder.appendingPathComponent("project.json"))
        let id = sanitize(project.workshopID ?? folder.lastPathComponent)
        let dest = Self.root.appendingPathComponent(id, isDirectory: true)
        if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
        try fm.copyItem(at: folder, to: dest)
        return id
    }

    /// Folders (up to 3 levels deep) that contain a project.json.
    private func projectFolders(in url: URL) -> [URL] {
        if fm.fileExists(atPath: url.appendingPathComponent("project.json").path) { return [url] }
        guard let e = fm.enumerator(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }
        var found: [URL] = []
        for case let f as URL in e {
            if e.level > 3 { e.skipDescendants(); continue }
            if f.lastPathComponent == "project.json" {
                found.append(f.deletingLastPathComponent())
                e.skipDescendants()
            }
        }
        return found
    }

    private func sanitize(_ s: String) -> String {
        let clean = s.components(separatedBy: CharacterSet(charactersIn: "/:\\")).joined(separator: "_")
        return clean.isEmpty || clean.hasPrefix(".") ? UUID().uuidString : clean
    }
}

func run(_ tool: String, _ args: [String]) throws {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: tool)
    p.arguments = args
    try p.run()
    p.waitUntilExit()
    guard p.terminationStatus == 0 else {
        throw NSError(domain: "MacWall", code: Int(p.terminationStatus),
                      userInfo: [NSLocalizedDescriptionKey: "\(tool) failed (\(p.terminationStatus))"])
    }
}
