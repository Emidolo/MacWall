import Foundation

/// A `macwall://` command. Any app (or web page) can open these URLs, so parsing is strict:
/// unknown commands and malformed parameters yield nil.
public enum ControlCommand: Equatable, Sendable {
    /// `display` is a display UUID; nil means all displays.
    case set(id: String, display: String?)
    case next, previous
    case pause, resume, toggle
    /// 0...1.
    case volume(Float)
    case openLibrary

    public init?(url: URL) {
        guard url.scheme?.lowercased() == "macwall", let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        func value(_ name: String) -> String? {
            parts.queryItems?.first { $0.name == name }?.value.flatMap { $0.isEmpty ? nil : $0 }
        }
        switch parts.host?.lowercased() {
        case "set":
            guard let id = value("id") else { return nil }
            self = .set(id: id, display: value("display"))
        case "next": self = .next
        case "previous": self = .previous
        case "pause": self = .pause
        case "resume": self = .resume
        case "toggle": self = .toggle
        case "volume":
            guard let level = value("value").flatMap(Float.init), level.isFinite else { return nil }
            self = .volume(min(max(level, 0), 1))
        case "open-library": self = .openLibrary
        default: return nil
        }
    }
}
