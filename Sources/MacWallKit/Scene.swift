import Foundation

// MARK: - Values

/// `project.json` → `general.properties.<key>.value`, for resolving `{"user": ...}` bindings.
public struct UserProperties {
    public let values: [String: Any]

    public init(json: String) {
        let props = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
        values = props.compactMapValues { ($0 as? [String: Any])?["value"] }
    }
}

public enum SceneJSON {
    /// Numbers, bools, `"x y z"` / `"x,y,z"` strings, arrays and `#rrggbb`.
    public static func floats(_ v: Any?) -> [Float]? {
        switch v {
        case let n as NSNumber:
            return [n.floatValue]
        case let s as String:
            if s.hasPrefix("#"), s.count == 7, let x = UInt32(s.dropFirst(), radix: 16) {
                return [Float(x >> 16 & 255) / 255, Float(x >> 8 & 255) / 255, Float(x & 255) / 255]
            }
            let parts = s.split { $0 == " " || $0 == "," }
            let f = parts.compactMap { Float($0) }
            return f.isEmpty || f.count != parts.count ? nil : f
        case let a as [Any]:
            let f = a.compactMap { ($0 as? NSNumber)?.floatValue }
            return f.isEmpty || f.count != a.count ? nil : f
        default:
            return nil
        }
    }

    /// Colour strings without a decimal point are 0...255.
    public static func color(_ v: Any?) -> [Float]? {
        guard let f = floats(v) else { return nil }
        if let s = v as? String, !s.hasPrefix("#"), !s.contains(".") { return f.map { $0 / 255 } }
        return f
    }

    /// Unwraps `{"user": key, "value": default}`, conditional `{"user": {"name","condition"}}`,
    /// and `{"value": v, "animation"/"script": …}` wrappers to a plain value.
    public static func resolve(_ raw: Any?, _ props: UserProperties) -> Any? {
        guard let d = raw as? [String: Any] else { return raw }
        if let key = d["user"] as? String, let v = props.values[key] { return v }
        if let cond = d["user"] as? [String: Any], let name = cond["name"] as? String, let v = props.values[name] {
            return "\(v)" == "\(cond["condition"] ?? "")"
        }
        return d["value"]
    }

    static func bool(_ raw: Any?, _ props: UserProperties, default def: Bool) -> Bool {
        floats(resolve(raw, props)).map { $0[0] != 0 } ?? def
    }

    static func number(_ raw: Any?, _ props: UserProperties, default def: Float) -> Float {
        floats(resolve(raw, props))?.first ?? def
    }
}

// MARK: - Keyframe animation

/// A (possibly keyframed) vector field. Keyframes follow open-wallpaper-engine's reading of the
/// format: channels c0/c1/c2, cubic Bézier segments with handle x scaled by half the segment.
public struct AnimatedValue {
    public let base: [Float]
    let track: Track?

    public var isAnimated: Bool { track != nil }

    public init(_ raw: Any?, _ props: UserProperties, default def: [Float]) {
        var b = SceneJSON.floats(SceneJSON.resolve(raw, props)) ?? def
        if b.count < def.count { b += def[b.count...] }
        base = b
        track = ((raw as? [String: Any])?["animation"] as? [String: Any]).flatMap(Track.init)
    }

    public init(constant: [Float]) {
        base = constant
        track = nil
    }

    public func value(at seconds: Double) -> [Float] {
        guard let track else { return base }
        let frame = track.frame(at: seconds)
        return base.indices.map { i in
            guard i < track.channels.count, !track.channels[i].isEmpty else { return base[i] }
            let v = Float(Track.eval(track.channels[i], frame))
            return track.relative ? base[i] + v : v
        }
    }

    struct Track {
        struct Key {
            var frame: Double, value: Double, step: Bool
            var front: (x: Double, y: Double), back: (x: Double, y: Double)
        }

        let channels: [[Key]]
        let fps: Double, end: Double, mode: String, relative: Bool

        init?(_ d: [String: Any]) {
            func handle(_ h: Any?) -> (Double, Double) {
                guard let h = h as? [String: Any], (h["enabled"] as? Bool) ?? true else { return (0, 0) }
                return ((h["x"] as? NSNumber)?.doubleValue ?? 0, (h["y"] as? NSNumber)?.doubleValue ?? 0)
            }
            channels = ["c0", "c1", "c2", "c3"].map { c in
                ((d[c] as? [[String: Any]]) ?? []).compactMap { k -> Key? in
                    guard let f = (k["frame"] as? NSNumber)?.doubleValue, let v = (k["value"] as? NSNumber)?.doubleValue else { return nil }
                    return Key(frame: f, value: v, step: k["step"] as? Bool ?? false, front: handle(k["front"]), back: handle(k["back"]))
                }.sorted { $0.frame < $1.frame }
            }
            guard channels.contains(where: { !$0.isEmpty }) else { return nil }
            let options = d["options"] as? [String: Any] ?? [:]
            fps = max((options["fps"] as? NSNumber)?.doubleValue ?? 30, 1)
            let lastKey = channels.compactMap { $0.last?.frame }.max() ?? 0
            end = max(lastKey, (options["length"] as? NSNumber)?.doubleValue ?? 0)
            mode = (options["mode"] as? String ?? "loop").lowercased()
            relative = d["relative"] as? Bool ?? false
        }

        func frame(at seconds: Double) -> Double {
            let f = seconds * fps
            guard end > 0 else { return 0 }
            switch mode {
            case "loop", "repeat":
                return f.truncatingRemainder(dividingBy: end)
            case "mirror":
                let m = f.truncatingRemainder(dividingBy: 2 * end)
                return m <= end ? m : 2 * end - m
            default:
                return min(max(f, 0), end)
            }
        }

        static func eval(_ keys: [Key], _ frame: Double) -> Double {
            guard let first = keys.first, let last = keys.last else { return 0 }
            if frame <= first.frame { return first.value }
            if frame >= last.frame { return last.value }
            let i = keys.lastIndex { $0.frame <= frame }!
            return segment(keys[i], keys[i + 1], frame)
        }

        static func segment(_ a: Key, _ b: Key, _ frame: Double) -> Double {
            if b.step { return a.value }
            let dt = b.frame - a.frame
            guard dt > 0 else { return b.value }
            let p1x = a.frame + a.front.x * dt * 0.5, p1y = a.value + a.front.y
            let p2x = b.frame + b.back.x * dt * 0.5, p2y = b.value + b.back.y
            let linear = a.value + (b.value - a.value) * (frame - a.frame) / dt
            let hasHandles = a.front != (0, 0) || b.back != (0, 0)
            guard hasHandles, a.frame <= p1x, p1x <= p2x, p2x <= b.frame else { return linear }
            func bez(_ p0: Double, _ p1: Double, _ p2: Double, _ p3: Double, _ t: Double) -> Double {
                let u = 1 - t
                return u * u * u * p0 + 3 * u * u * t * p1 + 3 * u * t * t * p2 + t * t * t * p3
            }
            var lo = 0.0, hi = 1.0, t = 0.5
            for _ in 0..<32 {
                t = (lo + hi) / 2
                let x = bez(a.frame, p1x, p2x, b.frame, t)
                if abs(x - frame) < 1e-6 { break }
                if x < frame { lo = t } else { hi = t }
            }
            return bez(a.value, p1y, p2y, b.value, t)
        }
    }
}

// MARK: - scene.json

public struct SceneEffect: Equatable {
    public struct Pass: Equatable {
        public var constants: [String: [Float]]
        public var textures: [String?]
    }

    /// Folder name under `effects/`, e.g. "shake".
    public var name: String
    public var passes: [Pass]
}

public struct SceneObject {
    public enum Kind: Equatable {
        case image(model: String)
        case particle(String)
        case group
        case unsupported(String)
    }

    public var id: Int
    public var name: String
    public var kind: Kind
    public var parent: Int?
    public var origin, scale, angles, alpha, color: AnimatedValue
    public var size: [Float]?
    public var visible: Bool
    public var parallaxDepth: [Float]
    public var alignment: String
    public var effects: [SceneEffect]
    public var instanceOverride: [String: [Float]]
}

public struct SceneDocument {
    public struct Parallax {
        public var enabled = false
        public var amount: Float = 0.5, delay: Float = 0.1, mouseInfluence: Float = 0
    }

    public var width: Float, height: Float
    /// False when the scene had no explicit orthographic size (perspective or "auto").
    public var hasExplicitSize: Bool
    public var clearColor: [Float]
    public var parallax = Parallax()
    public var objects: [SceneObject]

    public init(data: Data, props: UserProperties) throws {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FormatError.badMagic("scene.json")
        }
        let general = root["general"] as? [String: Any] ?? [:]
        let ortho = general["orthogonalprojection"] as? [String: Any]
        let w = SceneJSON.number(ortho?["width"], props, default: 0), h = SceneJSON.number(ortho?["height"], props, default: 0)
        clearColor = SceneJSON.color(SceneJSON.resolve(general["clearcolor"], props)) ?? [0, 0, 0]
        parallax.enabled = SceneJSON.bool(general["cameraparallax"], props, default: false)
        parallax.amount = SceneJSON.number(general["cameraparallaxamount"], props, default: 0.5)
        parallax.delay = SceneJSON.number(general["cameraparallaxdelay"], props, default: 0.1)
        parallax.mouseInfluence = SceneJSON.number(general["cameraparallaxmouseinfluence"], props, default: 0)

        objects = (root["objects"] as? [[String: Any]] ?? []).enumerated().map { i, o in Self.object(o, index: i, props) }

        hasExplicitSize = w > 0 && h > 0
        if hasExplicitSize {
            (width, height) = (w, h)
        } else {
            // "auto": the smallest centred box that holds every image layer.
            var aw: Float = 0, ah: Float = 0
            for o in objects {
                guard case .image = o.kind, let size = o.size else { continue }
                let p = o.origin.base
                aw = max(aw, 2 * (abs(p[0]) + size[0] / 2))
                ah = max(ah, 2 * (abs(p[1]) + size[1] / 2))
            }
            (width, height) = aw > 0 && ah > 0 ? (aw, ah) : (1920, 1080)
        }
    }

    private static func object(_ o: [String: Any], index: Int, _ props: UserProperties) -> SceneObject {
        let kind: SceneObject.Kind
        if let image = o["image"] as? String {
            kind = .image(model: image)
        } else if let particle = o["particle"] as? String {
            kind = .particle(particle)
        } else if let other = ["sound", "text", "light", "shape", "model"].first(where: { o[$0] != nil }) {
            kind = .unsupported(other)
        } else {
            kind = .group
        }

        var alpha = AnimatedValue(o["alpha"], props, default: [1])
        if !alpha.isAnimated, alpha.base[0] > 1 { alpha = AnimatedValue(constant: [alpha.base[0] / 100]) }

        let effects: [SceneEffect] = (o["effects"] as? [[String: Any]] ?? []).compactMap { e in
            guard SceneJSON.bool(e["visible"], props, default: true), let file = e["file"] as? String else { return nil }
            let parts = file.split(separator: "/")
            let name = parts.count >= 2 ? String(parts[parts.count - 2]) : file
            let passes = (e["passes"] as? [[String: Any]] ?? []).map { p in
                SceneEffect.Pass(
                    constants: (p["constantshadervalues"] as? [String: Any] ?? [:]).compactMapValues { SceneJSON.floats(SceneJSON.resolve($0, props)) },
                    textures: (p["textures"] as? [Any] ?? []).map { ($0 as? String).flatMap { $0.isEmpty ? nil : $0 } })
            }
            return SceneEffect(name: name, passes: passes)
        }

        let io = o["instanceoverride"] as? [String: Any] ?? [:]
        return SceneObject(
            id: (o["id"] as? NSNumber)?.intValue ?? -(index + 1),
            name: o["name"] as? String ?? "",
            kind: kind,
            parent: (o["parent"] as? NSNumber)?.intValue,
            origin: AnimatedValue(o["origin"], props, default: [0, 0, 0]),
            scale: AnimatedValue(o["scale"], props, default: [1, 1, 1]),
            angles: AnimatedValue(o["angles"], props, default: [0, 0, 0]),
            alpha: alpha,
            color: AnimatedValue(o["color"], props, default: [1, 1, 1]),
            size: SceneJSON.floats(SceneJSON.resolve(o["size"], props)).flatMap { $0.count >= 2 && $0[0] > 0 && $0[1] > 0 ? Array($0[0..<2]) : nil },
            visible: SceneJSON.bool(o["visible"], props, default: true),
            parallaxDepth: SceneJSON.floats(SceneJSON.resolve(o["parallaxDepth"], props)).map { $0.count >= 2 ? Array($0[0..<2]) : [$0[0], $0[0]] } ?? [1, 1],
            alignment: (SceneJSON.resolve(o["alignment"], props) as? String ?? "center").lowercased(),
            effects: effects,
            instanceOverride: (io["enabled"] as? Bool ?? true) ? io.compactMapValues { SceneJSON.floats(SceneJSON.resolve($0, props)) } : [:])
    }
}

// MARK: - Models and materials

public struct SceneModel {
    public var material: String?
    public var size: [Float]?
    public var fullscreen: Bool
    public var noPadding: Bool
    public var puppet: String?

    public init(_ d: [String: Any]) {
        material = d["material"] as? String
        let w = (d["width"] as? NSNumber)?.floatValue ?? 0, h = (d["height"] as? NSNumber)?.floatValue ?? 0
        size = w > 0 && h > 0 ? [w, h] : nil
        fullscreen = d["fullscreen"] as? Bool ?? false
        noPadding = d["nopadding"] as? Bool ?? false
        puppet = d["puppet"] as? String
    }
}

public struct SceneMaterial {
    public enum Blending: String { case normal, translucent, additive, disabled }

    public var shader: String
    public var blending: Blending
    public var textures: [String?]

    public init(_ d: [String: Any]) {
        let pass = (d["passes"] as? [[String: Any]])?.first ?? [:]
        shader = pass["shader"] as? String ?? "genericimage2"
        blending = Blending(rawValue: (pass["blending"] as? String ?? "").lowercased()) ?? .translucent
        textures = (pass["textures"] as? [Any] ?? []).map { ($0 as? String).flatMap { $0.isEmpty ? nil : $0 } }
    }
}

// MARK: - Asset lookup

/// Resolves scene asset paths: the wallpaper's `scene.pkg` first, then its folder, then any extra
/// roots (e.g. a copy of Wallpaper Engine's own `assets` folder).
public struct SceneAssets {
    public let pkg: PKGArchive?
    public let folder: URL
    public let extraRoots: [URL]

    public init(folder: URL, extraRoots: [URL] = []) {
        self.folder = folder
        self.extraRoots = extraRoots
        pkg = try? PKGArchive(url: folder.appendingPathComponent("scene.pkg"))
    }

    public func data(_ path: String) -> Data? {
        if let d = pkg?[path] { return d }
        for root in [folder] + extraRoots {
            if let d = try? Data(contentsOf: root.appendingPathComponent(path)) { return d }
        }
        return nil
    }

    public func exists(_ path: String) -> Bool {
        pkg?[path] != nil || ([folder] + extraRoots).contains { FileManager.default.fileExists(atPath: $0.appendingPathComponent(path).path) }
    }

    public func json(_ path: String) -> [String: Any]? {
        data(path).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    /// Material texture names map to `materials/<name>.tex`.
    public static func texturePath(_ name: String) -> String { "materials/\(name).tex" }
}

// MARK: - Support analysis

public enum SceneAnalysis {
    public static let supportedEffects: Set = ["shake", "waterripple", "scroll", "tint"]

    /// Human-readable list of the scene's features MacWall can't render (empty = fully supported).
    /// Cheap: parses JSON and checks files exist, but decodes no textures.
    public static func unsupportedFeatures(_ assets: SceneAssets, props: UserProperties) -> [String] {
        guard let data = assets.data("scene.json"), let doc = try? SceneDocument(data: data, props: props) else {
            return ["unreadable scene.json"]
        }
        var out = Set<String>()
        if !doc.hasExplicitSize { out.insert("perspective camera") }
        for o in doc.objects {
            switch o.kind {
            case .unsupported(let kind):
                out.insert("\(kind) layers")
            case .group:
                break
            case .particle(let path):
                guard let json = assets.json(path) else { out.insert("missing \(path)"); continue }
                ParticleDefinition(json).unsupported.forEach { out.insert("particle \($0)") }
            case .image(let modelPath):
                o.effects.map(\.name).filter { !supportedEffects.contains($0) }.forEach { out.insert("\($0) effect") }
                guard let model = assets.json(modelPath).map(SceneModel.init) else { out.insert("missing \(modelPath)"); continue }
                if model.puppet != nil { out.insert("puppet animation") }
                guard let matPath = model.material, let mat = assets.json(matPath).map(SceneMaterial.init) else {
                    out.insert("missing material"); continue
                }
                if !mat.shader.hasPrefix("genericimage") { out.insert("\(mat.shader) shader") }
                if let tex = mat.textures.first ?? nil, !tex.hasPrefix("_rt_"), !assets.exists(SceneAssets.texturePath(tex)) {
                    out.insert("missing texture \(tex)")
                }
            }
        }
        return out.sorted()
    }
}
