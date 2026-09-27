import Foundation
import JavaScriptCore

/// One entry of `project.json` → `general.properties`.
public struct WallpaperProperty: Identifiable {
    public enum Kind: String { case color, slider, bool, combo, textinput, text, other }

    public let key: String
    public var id: String { key }
    public let kind: Kind
    public let label: String
    public let order: Int
    public let defaultValue: Any?
    public let min: Double, max: Double, step: Double
    public let options: [(label: String, value: Any)]
    /// JavaScript expression over other properties (`other.value == 1`) that controls visibility.
    public let condition: String?
}

/// A wallpaper's user-editable properties, plus merging of the user's overrides.
public struct WallpaperProperties {
    public let items: [WallpaperProperty]
    private let raw: [String: [String: Any]]

    public init(json: String) {
        raw = (try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: [String: Any]]) ?? [:]
        items = raw.map { key, p in
            let type = (p["type"] as? String ?? "").lowercased()
            let lo = (p["min"] as? NSNumber)?.doubleValue ?? 0, hi = (p["max"] as? NSNumber)?.doubleValue ?? 100
            let fraction = p["fraction"] as? Bool ?? false
            let step = (p["step"] as? NSNumber)?.doubleValue ?? (fraction ? (hi - lo) / 100 : 1)
            return WallpaperProperty(
                key: key,
                kind: WallpaperProperty.Kind(rawValue: type) ?? .other,
                label: Self.label(p["text"] as? String ?? key, fallback: key),
                order: (p["order"] as? NSNumber)?.intValue ?? 0,
                defaultValue: p["value"],
                min: lo, max: hi, step: step,
                options: (p["options"] as? [[String: Any]] ?? []).compactMap { o in
                    o["value"].map { (Self.label(o["label"] as? String ?? "\($0)", fallback: "\($0)"), $0) }
                },
                condition: (p["condition"] as? String).flatMap { $0.isEmpty ? nil : $0 })
        }.sorted { ($0.order, $0.key) < ($1.order, $1.key) }
    }

    public var hasEditable: Bool { items.contains { ![.text, .other].contains($0.kind) } }

    /// Current value of every property: overrides on top of defaults.
    public func values(_ overrides: [String: Any]) -> [String: Any] {
        var v = raw.compactMapValues { $0["value"] }
        for (k, x) in overrides where raw[k] != nil { v[k] = x }
        return v
    }

    /// Properties whose `condition` holds (conditions are JavaScript, as in Wallpaper Engine).
    public func visible(_ values: [String: Any]) -> [WallpaperProperty] {
        let js = JSContext()!
        for (k, v) in values { js.setObject(["value": v], forKeyedSubscript: k as NSString) }
        return items.filter { p in
            guard let c = p.condition else { return true }
            js.exception = nil
            let r = js.evaluateScript(c)
            return js.exception != nil || r?.toBool() != false
        }
    }

    /// Full properties object with overrides applied (what `applyUserProperties` gets on load).
    public func mergedJSON(_ overrides: [String: Any]) -> String {
        var out = raw
        for (k, v) in overrides where out[k] != nil { out[k]?["value"] = v }
        return Self.encode(out)
    }

    /// Just the changed property, as Wallpaper Engine sends it on edit.
    public func changeJSON(key: String, value: Any) -> String {
        var p = raw[key] ?? [:]
        p["value"] = value
        return Self.encode([key: p])
    }

    // MARK: Helpers

    /// `ui_browse_properties_scheme_color` → "Scheme color"; strips HTML tags.
    static func label(_ text: String, fallback: String) -> String {
        var s = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        for prefix in ["ui_browse_properties_", "ui_editor_properties_", "ui_"] where s.hasPrefix(prefix) {
            s = String(s.dropFirst(prefix.count)).replacingOccurrences(of: "_", with: " ")
            break
        }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? fallback : s.prefix(1).uppercased() + s.dropFirst()
    }

    /// WE colours are "r g b" in 0...1 (older files: 0...255).
    public static func rgb(_ value: Any?) -> [Double] {
        let f = (SceneJSON.floats(value) ?? [1, 1, 1]).map(Double.init)
        let c = f.count >= 3 ? Array(f[0..<3]) : [1, 1, 1]
        return c.contains { $0 > 1 } ? c.map { $0 / 255 } : c
    }

    public static func colorString(_ c: [Double]) -> String {
        c.prefix(3).map { String(format: "%.5f", $0) }.joined(separator: " ")
    }

    private static func encode(_ o: Any) -> String {
        (try? JSONSerialization.data(withJSONObject: o, options: .sortedKeys)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }
}
