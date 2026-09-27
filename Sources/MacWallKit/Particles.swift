import Foundation

/// A Wallpaper Engine particle system (`particles/*.json`): the common emitters, initializers
/// and operators. Anything else is listed in `unsupported` and ignored.
public struct ParticleDefinition {
    public var material: String?
    public var maxCount: Int
    public var startTime: Float
    public var unsupported: [String] = []
    var emitters: [[String: Any]] = []
    var initializers: [[String: Any]] = []
    var operators: [[String: Any]] = []

    static let knownEmitters: Set = ["boxrandom", "sphererandom"]
    static let knownInitializers: Set = ["lifetimerandom", "sizerandom", "alpharandom", "colorrandom", "velocityrandom",
                                         "rotationrandom", "angularvelocityrandom"]
    static let knownOperators: Set = ["movement", "angularmovement", "alphafade", "sizechange", "alphachange", "colorchange",
                                      "oscillatealpha", "oscillatesize", "oscillateposition"]

    public init(_ d: [String: Any]) {
        material = d["material"] as? String
        maxCount = (d["maxcount"] as? NSNumber)?.intValue ?? 100
        startTime = (d["starttime"] as? NSNumber)?.floatValue ?? 0
        func split(_ key: String, _ known: Set<String>) -> [[String: Any]] {
            (d[key] as? [[String: Any]] ?? []).filter { c in
                let name = c["name"] as? String ?? "?"
                if known.contains(name) { return true }
                unsupported.append("\(key) \(name)")
                return false
            }
        }
        emitters = split("emitter", Self.knownEmitters)
        initializers = split("initializer", Self.knownInitializers)
        operators = split("operator", Self.knownOperators)
        for r in d["renderer"] as? [[String: Any]] ?? [] where r["name"] as? String != "sprite" {
            unsupported.append("renderer \(r["name"] as? String ?? "?")")
        }
        if !(d["children"] as? [Any] ?? []).isEmpty { unsupported.append("child systems") }
    }
}

public final class ParticleSimulation {
    public struct Particle {
        public var position = SIMD3<Float>.zero, velocity = SIMD3<Float>.zero
        public var size: Float = 20, alpha: Float = 1, color = SIMD3<Float>(1, 1, 1)
        public var rotation: Float = 0, angularVelocity: Float = 0
        public var age: Float = 0, lifetime: Float = 1
        var initialSize: Float = 20, initialAlpha: Float = 1, initialColor = SIMD3<Float>(1, 1, 1)
        var osc: [SIMD2<Float>] = []   // per oscillating operator: (frequency, phase)
    }

    public private(set) var particles: [Particle] = []
    private let def: ParticleDefinition
    private let over: [String: [Float]]
    private var rng: SplitMix64
    private var timers: [Float]
    private var elapsed: Float = 0
    private var burstDone = false

    public init(_ def: ParticleDefinition, overrides: [String: [Float]] = [:], seed: UInt64 = .random(in: 0...UInt64.max)) {
        self.def = def
        over = overrides
        rng = SplitMix64(seed)
        timers = Array(repeating: 0, count: def.emitters.count)
        particles.reserveCapacity(capacity)
        // Pre-warm: simulate `starttime` seconds up front.
        for _ in 0..<min(Int(def.startTime * 60), 240) { step(1.0 / 60) }
    }

    private var capacity: Int { max(0, Int((Float(def.maxCount) * o("count")).rounded())) }
    private func o(_ key: String) -> Float { over[key]?.first ?? 1 }

    public func step(_ rawDt: Float) {
        let dt = min(rawDt, 0.1)
        elapsed += dt
        emit(dt)
        for i in particles.indices.reversed() {
            particles[i].age += dt
            if particles[i].age >= particles[i].lifetime { particles.remove(at: i) }
        }
        for i in particles.indices { operate(&particles[i], dt) }
    }

    // MARK: Emission

    private func emit(_ dt: Float) {
        for (e, em) in def.emitters.enumerated() {
            let duration = num(em["duration"], 0)
            if duration > 0, elapsed > duration { continue }
            var n = 0
            let rate = num(em["rate"], 5) * o("rate")
            if rate > 0 {
                timers[e] += dt
                n = Int(timers[e] * rate)
                timers[e] -= Float(n) / rate
            }
            if !burstDone { n += Int(num(em["instantaneous"], 0)) }
            for _ in 0..<n where particles.count < capacity { spawn(em) }
        }
        burstDone = true
    }

    private func spawn(_ em: [String: Any]) {
        var p = Particle()
        let origin = vec(em["origin"], .zero)
        let dirs = vec(em["directions"], SIMD3(1, 1, 0))
        let dmin = vec(em["distancemin"], .zero, splat: true), dmax = vec(em["distancemax"], SIMD3(repeating: 256), splat: true)
        var offset = SIMD3<Float>.zero
        if em["name"] as? String == "sphererandom" {
            let active = (0..<3).filter { dirs[$0] != 0 }
            let dims = Float(max(active.count, 1))
            let r = pow(lerp(pow(dmin.x, dims), pow(dmax.x, dims), rng.unit()), 1 / dims)
            var unit = SIMD3<Float>.zero
            repeat { for a in active { unit[a] = rng.gaussian() } } while simdLength(unit) < 1e-6 && !active.isEmpty
            if !active.isEmpty { unit /= simdLength(unit) }
            offset = r * unit * SIMD3(abs(dirs.x), abs(dirs.y), abs(dirs.z))
            let sign = vec(em["sign"], .zero)
            for a in 0..<3 where sign[a] != 0 { offset[a] = abs(offset[a]) * (sign[a] > 0 ? 1 : -1) }
        } else {
            for a in 0..<3 {
                offset[a] = lerp(dmin[a], dmax[a], rng.unit()) * (rng.unit() < 0.5 ? -1 : 1) * dirs[a]
            }
        }
        p.position = origin + offset
        let speed = lerp(num(em["speedmin"], 0), num(em["speedmax"], 0), rng.unit())
        if speed != 0, simdLength(offset) > 0 { p.velocity += offset / simdLength(offset) * speed }

        for ini in def.initializers { initialize(&p, ini) }
        p.lifetime *= o("lifetime")
        p.initialSize = p.size * o("size")
        p.initialAlpha = p.alpha * o("alpha")
        if let c = over["color"], c.count >= 3 { p.initialColor = p.color * SIMD3(c[0], c[1], c[2]) } else { p.initialColor = p.color }
        p.velocity *= o("speed")
        p.angularVelocity *= o("speed")
        p.osc = def.operators.map { op in
            SIMD2(lerp(num(op["frequencymin"], 0), num(op["frequencymax"], op["name"] as? String == "oscillateposition" ? 5 : 10), rng.unit()),
                  lerp(num(op["phasemin"], 0), num(op["phasemax"], 0) + 2 * .pi, rng.unit()))
        }
        (p.size, p.alpha, p.color) = (p.initialSize, p.initialAlpha, p.initialColor)
        particles.append(p)
    }

    private func initialize(_ p: inout Particle, _ c: [String: Any]) {
        let t = pow(rng.unit(), num(c["exponent"], 1))
        switch c["name"] as? String {
        case "lifetimerandom": p.lifetime = lerp(num(c["min"], 0), num(c["max"], 1), t)
        case "sizerandom": p.size = lerp(num(c["min"], 0), num(c["max"], 20), t)
        case "alpharandom": p.alpha = lerp(num(c["min"], 0.05), num(c["max"], 1), t)
        case "colorrandom":
            p.color = mix(vec(c["min"], .zero), vec(c["max"], SIMD3(repeating: 255)), t) / 255
        case "velocityrandom":
            let lo = vec(c["min"], SIMD3(-32, -32, 0)), hi = vec(c["max"], SIMD3(32, 32, 0))
            p.velocity += SIMD3((0..<3).map { lerp(lo[$0], hi[$0], rng.unit()) })
        case "rotationrandom":
            p.rotation = lerp(vec(c["min"], .zero, splatZ: true).z, vec(c["max"], SIMD3(0, 0, 2 * .pi), splatZ: true).z, t)
        case "angularvelocityrandom":
            p.angularVelocity = lerp(vec(c["min"], SIMD3(0, 0, -5), splatZ: true).z, vec(c["max"], SIMD3(0, 0, 5), splatZ: true).z, t)
        default: break
        }
    }

    // MARK: Operators

    private func operate(_ p: inout Particle, _ dt: Float) {
        let life = min(p.age / max(p.lifetime, 1e-4), 1)
        var size = p.initialSize, alpha = p.initialAlpha, color = p.initialColor
        func ramp(_ c: [String: Any], _ sv: Float, _ ev: Float) -> Float {
            let st = num(c["starttime"], 0), et = num(c["endtime"], 1)
            if life <= st { return sv }
            if life >= et { return ev }
            return lerp(sv, ev, (life - st) / max(et - st, 1e-4))
        }
        for (i, c) in def.operators.enumerated() {
            let osc = i < p.osc.count ? p.osc[i] : .zero
            let wave = (cos(osc.x * p.age + osc.y) + 1) / 2
            switch c["name"] as? String {
            case "movement":
                let drag = num(c["drag"], 0)
                p.velocity += (vec(c["gravity"], .zero) * o("speed") - p.velocity * drag) * dt
                p.position += p.velocity * dt
            case "angularmovement":
                p.angularVelocity += (vec(c["force"], .zero, splatZ: true).z - p.angularVelocity * num(c["drag"], 0)) * dt
                p.rotation += p.angularVelocity * dt
            case "alphafade":
                let fin = num(c["fadeintime"], 0.5), fout = num(c["fadeouttime"], 0.5)
                if life < fin { alpha *= life / fin }
                if life > fout { alpha *= max(0, 1 - (life - fout) / max(1 - fout, 1e-4)) }
            case "sizechange": size *= ramp(c, num(c["startvalue"], 1), num(c["endvalue"], 0))
            case "alphachange": alpha *= ramp(c, num(c["startvalue"], 1), num(c["endvalue"], 0))
            case "colorchange":
                let sv = vec(c["startvalue"], SIMD3(repeating: 1)), ev = vec(c["endvalue"], SIMD3(repeating: 1))
                color *= SIMD3((0..<3).map { ramp(c, sv[$0], ev[$0]) })
            case "oscillatealpha": alpha *= lerp(num(c["scalemin"], 0), num(c["scalemax"], 1), wave)
            case "oscillatesize": size *= lerp(num(c["scalemin"], 0.8), num(c["scalemax"], 1.2), wave)
            case "oscillateposition":
                let scale = lerp(num(c["scalemin"], 0), num(c["scalemax"], 10), 0.5)
                p.position += vec(c["mask"], SIMD3(1, 1, 0)) * (-scale * osc.x * sin(osc.x * p.age + osc.y) * dt)
            default: break
            }
        }
        (p.size, p.alpha, p.color) = (size, alpha, color)
    }

    // MARK: Helpers

    private func num(_ v: Any?, _ def: Float) -> Float { SceneJSON.floats(v)?.first ?? def }

    /// vec3 field; `splat` repeats a lone number on all axes, `splatZ` puts it on z (rotations).
    private func vec(_ v: Any?, _ def: SIMD3<Float>, splat: Bool = false, splatZ: Bool = false) -> SIMD3<Float> {
        guard let f = SceneJSON.floats(v) else { return def }
        if f.count == 1 { return splat ? SIMD3(repeating: f[0]) : splatZ ? SIMD3(0, 0, f[0]) : SIMD3(f[0], def.y, def.z) }
        return SIMD3(f[0], f[1], f.count > 2 ? f[2] : def.z)
    }
}

private func lerp(_ a: Float, _ b: Float, _ t: Float) -> Float { a + (b - a) * t }
private func mix(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ t: Float) -> SIMD3<Float> { a + (b - a) * t }
private func simdLength(_ v: SIMD3<Float>) -> Float { (v * v).sum().squareRoot() }

/// Small, seedable PRNG so simulations are reproducible in tests.
struct SplitMix64 {
    private var state: UInt64
    init(_ seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func unit() -> Float { Float(next() >> 40) / Float(1 << 24) }

    mutating func gaussian() -> Float {
        let u = max(unit(), 1e-7), v = unit()
        return (-2 * log(u)).squareRoot() * cos(2 * .pi * v)
    }
}
