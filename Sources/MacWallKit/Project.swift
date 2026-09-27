import Foundation

/// The parts of a Wallpaper Engine `project.json` MacWall uses.
public struct WallpaperProject: Equatable, Sendable {
    public enum Kind: String, Sendable, CaseIterable { case video, web, scene, application, unknown }

    public var title: String
    public var kind: Kind
    public var file: String?
    public var preview: String?
    public var workshopID: String?
    /// `general.properties` re-serialized as a JSON object, ready for `applyUserProperties`.
    public var propertiesJSON: String

    public init(data: Data) throws {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.propertyListReadCorrupt)
        }
        title = root["title"] as? String ?? ""
        kind = Kind(rawValue: (root["type"] as? String ?? "").lowercased()) ?? .unknown
        file = root["file"] as? String
        preview = root["preview"] as? String
        workshopID = (root["workshopid"]).map { "\($0)" }
        let props = (root["general"] as? [String: Any])?["properties"] as? [String: Any] ?? [:]
        propertiesJSON = String(decoding: try JSONSerialization.data(withJSONObject: props, options: .sortedKeys), as: UTF8.self)
    }

    public init(url: URL) throws { try self.init(data: Data(contentsOf: url)) }
}

public enum WorkshopID {
    /// Accepts a bare numeric ID or any Workshop URL carrying `?id=`.
    public static func parse(_ input: String) -> String? {
        let s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if isDigits(s) { return s }
        let id = URLComponents(string: s)?.queryItems?.first { $0.name == "id" }?.value
        return id.flatMap { isDigits($0) ? $0 : nil }
    }

    private static func isDigits(_ s: String) -> Bool {
        !s.isEmpty && s.allSatisfy { $0.isASCII && $0.isNumber }
    }
}
