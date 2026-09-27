import AppKit
import MetalKit
import simd
import MacWallKit

/// Cached per-folder list of scene features we can't render (drives the "Partial" badge).
@MainActor
enum SceneSupport {
    private static var cache: [URL: [String]] = [:]

    static func unsupported(_ folder: URL) -> [String] {
        if let hit = cache[folder] { return hit }
        let props = Library.shared.items.first { $0.folder == folder }.map(AppSettings.shared.propertiesJSON(for:)) ?? "{}"
        let result = SceneAnalysis.unsupportedFeatures(SceneAssets(folder: folder, extraRoots: AppSettings.shared.assetRoots),
                                                       props: UserProperties(json: props))
        cache[folder] = result
        return result
    }

    static func invalidate(_ folder: URL? = nil) {
        if let folder { cache[folder] = nil } else { cache = [:] }
    }
}

/// Renders Wallpaper Engine scenes with Metal: image layers (z-order, transforms, blending),
/// mouse parallax, keyframe animation, a few effects and sprite particle systems.
final class SceneRenderer: NSObject, WallpaperRenderer, MTKViewDelegate {
    private struct Effect {
        let kind: String
        let uniforms: EffectUniforms
        let mask: MTLTexture?
        let extra: MTLTexture?
    }

    private struct Layer {
        let object: SceneObject
        let texture: MTLTexture
        let uvScale: SIMD2<Float>
        let size: SIMD2<Float>
        let fullscreen: Bool
        let blend: SceneGPU.Blend
        let effects: [Effect]
        let targets: [MTLTexture]   // ping-pong pair, only when there are effects
    }

    private struct Particles {
        let object: SceneObject
        let sim: ParticleSimulation
        let texture: MTLTexture
        let uvScale: SIMD2<Float>
        let blend: SceneGPU.Blend
    }

    private enum Item { case layer(Int), particles(Int) }

    private let mtk: MTKView
    var view: NSView { mtk }
    private let gpu: SceneGPU
    private let queue: MTLCommandQueue
    private let doc: SceneDocument
    private let objectsByID: [Int: SceneObject]
    private let renderScale: CGFloat
    private var layers: [Layer] = []
    private var systems: [Particles] = []
    private var items: [Item] = []
    private var textureCache: [String: (MTLTexture, SIMD2<Float>, SIMD2<Float>)?] = [:]
    private var time: Double = 0
    private var lastTick: CFTimeInterval?
    private var pointer = SIMD2<Float>(0.5, 0.5)   // smoothed, (0,0) = top-left
    private(set) var unsupported: [String] = []

    init?(folder: URL, propertiesJSON: String, fps: Int, quality: Quality, assetRoots: [URL]) {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return nil }
        let gpu: SceneGPU
        do { gpu = try SceneGPU.shared(device) } catch {
            NSLog("MacWall: scene shaders failed to compile: \(error)")
            return nil
        }
        let props = UserProperties(json: propertiesJSON)
        let assets = SceneAssets(folder: folder, extraRoots: assetRoots)
        guard let data = assets.data("scene.json"), let doc = try? SceneDocument(data: data, props: props) else { return nil }
        self.gpu = gpu
        self.queue = queue
        self.doc = doc
        objectsByID = Dictionary(doc.objects.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        renderScale = quality.renderScale
        mtk = MTKView(frame: .zero, device: device)
        super.init()

        var missing = Set(SceneAnalysis.unsupportedFeatures(assets, props: props))
        for o in doc.objects {
            switch o.kind {
            case .image(let model):
                if let l = makeLayer(o, model: model, assets, &missing) { items.append(.layer(layers.count)); layers.append(l) }
            case .particle(let path):
                if let p = makeParticles(o, path: path, assets, &missing) { items.append(.particles(systems.count)); systems.append(p) }
            case .group, .unsupported:
                break
            }
        }
        unsupported = missing.sorted()
        guard !items.isEmpty else { return nil }

        mtk.colorPixelFormat = SceneGPU.pixelFormat
        mtk.clearColor = MTLClearColor(red: Double(doc.clearColor[0]), green: Double(doc.clearColor[safe: 1] ?? 0),
                                       blue: Double(doc.clearColor[safe: 2] ?? 0), alpha: 1)
        mtk.preferredFramesPerSecond = fps > 0 ? fps : (NSScreen.main?.maximumFramesPerSecond ?? 60)
        mtk.autoResizeDrawable = false
        (mtk.layer as? CAMetalLayer)?.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        mtk.delegate = self
    }

    // MARK: WallpaperRenderer

    func setPaused(_ paused: Bool) {
        mtk.isPaused = paused
        if paused { lastTick = nil }
    }

    func setVolume(_ volume: Float) {}

    /// Properties feed layout, visibility and effects at load time, so edits rebuild the scene.
    func applyUserProperties(_ changeJSON: String) -> Bool { false }

    func stop() {
        mtk.isPaused = true
        mtk.delegate = nil
    }

    // MARK: Loading

    private func makeLayer(_ o: SceneObject, model modelPath: String, _ assets: SceneAssets, _ missing: inout Set<String>) -> Layer? {
        guard let model = assets.json(modelPath).map(SceneModel.init),
              let mat = model.material.flatMap({ assets.json($0) }).map(SceneMaterial.init),
              let (texture, uvScale, imageSize) = loadTexture(mat.textures.first ?? nil, assets, &missing) else { return nil }
        let size: SIMD2<Float> = model.fullscreen ? SIMD2(doc.width, doc.height)
            : (o.size ?? model.size).map { SIMD2($0[0], $0[1]) } ?? imageSize

        let effects: [Effect] = o.effects.compactMap { e in
            guard SceneAnalysis.supportedEffects.contains(e.name), let pass = e.passes.first else { return nil }
            func c(_ key: String, _ def: [Float]) -> [Float] {
                let v = pass.constants[key] ?? pass.constants["ui_editor_properties_\(key)"] ?? def
                return v.count >= def.count ? v : v + def[v.count...]
            }
            var u = EffectUniforms()
            var extra: MTLTexture?
            switch e.name {
            case "scroll":
                let r = c("repeat", [1, 1])
                u.p0 = SIMD4(c("speedx", [0.1])[0], c("speedy", [0])[0], r[0], r[1])
            case "shake":
                let f = c("friction", [1, 1]), b = c("bounds", [0, 1])
                u.p0 = SIMD4(c("speed", [1])[0], c("strength", [0.05])[0], f[0], f[1])
                u.p1 = SIMD4(b[0], b[1], 0, 0)
            case "waterripple":
                u.p0 = SIMD4(c("animationspeed", [0.15])[0], c("ratio", [1])[0], c("ripplestrength", [0.1])[0], c("scale", [1])[0])
                u.p1 = SIMD4(c("scrolldirection", [0])[0], c("scrollspeed", [0])[0], 0, 0)
                extra = loadTexture((pass.textures[safe: 2] ?? nil) ?? "effects/waterripplenormal", assets, &missing, quiet: true)?.0
            case "tint":
                let col = c("color", [1, 1, 1])
                u.p0 = SIMD4(col[0], col[1], col[2], c("alpha", [1])[0])
            default:
                return nil
            }
            let mask = (pass.textures[safe: 1] ?? nil).flatMap { loadTexture($0, assets, &missing)?.0 }
            u.misc = SIMD4(0, mask == nil ? 0 : 1, extra == nil ? 0 : 1, 0)
            return Effect(kind: e.name, uniforms: u, mask: mask, extra: extra)
        }

        var targets: [MTLTexture] = []
        if !effects.isEmpty {
            let w = min(Int(imageSize.x), 4096), h = min(Int(imageSize.y), 4096)
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: SceneGPU.pixelFormat, width: max(w, 1), height: max(h, 1), mipmapped: false)
            d.usage = [.renderTarget, .shaderRead]
            d.storageMode = .private
            targets = (0..<2).compactMap { _ in gpu.device.makeTexture(descriptor: d) }
        }
        return Layer(object: o, texture: texture, uvScale: uvScale, size: size, fullscreen: model.fullscreen,
                     blend: blend(mat.blending), effects: targets.count == 2 ? effects : [], targets: targets)
    }

    private func makeParticles(_ o: SceneObject, path: String, _ assets: SceneAssets, _ missing: inout Set<String>) -> Particles? {
        guard let json = assets.json(path) else { return nil }
        let def = ParticleDefinition(json)
        let mat = def.material.flatMap { assets.json($0) }.map(SceneMaterial.init)
        let (texture, uvScale) = loadTexture(mat?.textures.first ?? nil, assets, &missing, quiet: true).map { ($0.0, $0.1) }
            ?? (softDot(), SIMD2(1, 1))
        return Particles(object: o, sim: ParticleSimulation(def, overrides: o.instanceOverride), texture: texture,
                         uvScale: uvScale, blend: blend(mat?.blending ?? .additive))
    }

    private func blend(_ b: SceneMaterial.Blending) -> SceneGPU.Blend {
        switch b {
        case .translucent: .translucent
        case .additive: .additive
        case .normal, .disabled: .opaque
        }
    }

    /// Decoded, mipmapped texture plus its UV crop and real image size.
    private func loadTexture(_ name: String?, _ assets: SceneAssets, _ missing: inout Set<String>, quiet: Bool = false)
        -> (MTLTexture, SIMD2<Float>, SIMD2<Float>)? {
        guard let name, !name.hasPrefix("_rt_") else { return nil }
        if let hit = textureCache[name] { return hit }
        var result: (MTLTexture, SIMD2<Float>, SIMD2<Float>)?
        if let data = assets.data(SceneAssets.texturePath(name)) {
            do {
                let tex = try TEXTexture(data: data)
                // ponytail: sprite-sheet/GIF textures would need TEXS frame playback; skipped for now.
                if tex.isAnimated { throw FormatError.unsupported("animated texture") }
                if let t = makeTexture(tex.rgba, width: tex.width, height: tex.height) {
                    let uv = SIMD2(tex.uvScale.0, tex.uvScale.1)
                    result = (t, uv, SIMD2(Float(tex.width), Float(tex.height)) * uv)
                }
            } catch FormatError.unsupported(let what) {
                missing.insert(what + "s")
            } catch {
                missing.insert("unreadable texture \(name)")
            }
        } else if !quiet {
            missing.insert("missing texture \(name)")
        }
        textureCache[name] = result
        return result
    }

    private func makeTexture(_ rgba: Data, width: Int, height: Int) -> MTLTexture? {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: true)
        d.usage = .shaderRead
        guard let t = gpu.device.makeTexture(descriptor: d) else { return nil }
        rgba.withUnsafeBytes {
            t.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: width * 4)
        }
        if let cmd = queue.makeCommandBuffer(), let blit = cmd.makeBlitCommandEncoder() {
            blit.generateMipmaps(for: t)
            blit.endEncoding()
            cmd.commit()
        }
        return t
    }

    /// Fallback particle sprite: a soft white dot.
    private func softDot() -> MTLTexture {
        if let hit = textureCache["\0dot"] ?? nil { return hit.0 }
        let n = 64
        var px = [UInt8](repeating: 255, count: n * n * 4)
        for y in 0..<n {
            for x in 0..<n {
                let dx = (Float(x) + 0.5) / Float(n) * 2 - 1, dy = (Float(y) + 0.5) / Float(n) * 2 - 1
                let a = max(0, 1 - (dx * dx + dy * dy).squareRoot())
                px[(y * n + x) * 4 + 3] = UInt8(a * a * 255)
            }
        }
        let t = makeTexture(Data(px), width: n, height: n)!
        textureCache["\0dot"] = (t, SIMD2(1, 1), SIMD2(Float(n), Float(n)))
        return t
    }

    // MARK: Frame

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        let scale = (view.window?.backingScaleFactor ?? 2) * renderScale
        let want = CGSize(width: (view.bounds.width * scale).rounded(), height: (view.bounds.height * scale).rounded())
        if want.width > 0, want.height > 0, view.drawableSize != want { view.drawableSize = want }

        let now = CACurrentMediaTime()
        let dt = lastTick.map { min(now - $0, 0.1) } ?? 1.0 / 60
        lastTick = now
        time += dt
        updatePointer(Float(dt))
        systems.forEach { $0.sim.step(Float(dt)) }

        guard let cmd = queue.makeCommandBuffer(), let rpd = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable else { return }
        encode(cmd, rpd, size: view.drawableSize)
        cmd.present(drawable)
        cmd.commit()
    }

    private func updatePointer(_ dt: Float) {
        guard doc.parallax.enabled, let frame = mtk.window?.frame, frame.width > 0 else { return }
        let m = NSEvent.mouseLocation
        let target = SIMD2(Float((m.x - frame.minX) / frame.width), Float(1 - (m.y - frame.minY) / frame.height))
            .clamped(lowerBound: .zero, upperBound: SIMD2(1, 1))
        let delay = doc.parallax.delay
        let k = delay <= 0 ? 1 : min(10 * max(1 - delay / 3, 0) * dt, 1)
        pointer += (target - pointer) * k
    }

    private func encode(_ cmd: MTLCommandBuffer, _ rpd: MTLRenderPassDescriptor, size: CGSize) {
        var outputs: [Int: MTLTexture] = [:]
        for (i, l) in layers.enumerated() where !l.effects.isEmpty && l.object.visible {
            outputs[i] = runEffects(l, cmd)
        }

        let c = doc.clearColor
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].clearColor = MTLClearColor(red: Double(c[0]), green: Double(c[safe: 1] ?? 0), blue: Double(c[safe: 2] ?? 0), alpha: 1)
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) else { return }
        let vp = projection(size)
        enc.setFragmentSamplerState(gpu.clampSampler, index: 0)
        for item in items {
            switch item {
            case .layer(let i):
                let l = layers[i]
                guard l.object.visible else { continue }
                var u = LayerUniforms(mvp: vp * parallax(l.object) * world(l.object, fullscreen: l.fullscreen, size: l.size)
                                          * .scale(l.size.x, l.size.y, 1),
                                      color: tint(l.object), uvScale: outputs[i] == nil ? l.uvScale : SIMD2(1, 1))
                enc.setRenderPipelineState(gpu.layer[l.blend]!)
                enc.setVertexBytes(&u, length: MemoryLayout<LayerUniforms>.stride, index: 0)
                enc.setFragmentTexture(outputs[i] ?? l.texture, index: 0)
                enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            case .particles(let i):
                let s = systems[i]
                guard s.object.visible, !s.sim.particles.isEmpty else { continue }
                let instances = s.sim.particles.map {
                    ParticleInstance(positionSize: SIMD4($0.position, $0.size * 0.5), color: SIMD4($0.color, $0.alpha),
                                     rotation: SIMD4($0.rotation, 0, 0, 0))
                }
                // ponytail: a fresh buffer per frame; switch to a ring of buffers if particle counts get large.
                guard let buf = gpu.device.makeBuffer(bytes: instances, length: MemoryLayout<ParticleInstance>.stride * instances.count) else { continue }
                var u = LayerUniforms(mvp: vp * parallax(s.object) * world(s.object, fullscreen: false, size: .zero),
                                      color: tint(s.object), uvScale: s.uvScale)
                enc.setRenderPipelineState(gpu.particle[s.blend]!)
                enc.setVertexBytes(&u, length: MemoryLayout<LayerUniforms>.stride, index: 0)
                enc.setVertexBuffer(buf, offset: 0, index: 1)
                enc.setFragmentTexture(s.texture, index: 0)
                enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: instances.count)
            }
        }
        enc.endEncoding()
    }

    /// Base texture → A, then each effect ping-pongs between the two targets.
    private func runEffects(_ l: Layer, _ cmd: MTLCommandBuffer) -> MTLTexture {
        func pass(_ kind: String, _ u: EffectUniforms, from src: MTLTexture, into dst: MTLTexture, mask: MTLTexture?, extra: MTLTexture?) {
            let rpd = MTLRenderPassDescriptor()
            rpd.colorAttachments[0].texture = dst
            rpd.colorAttachments[0].loadAction = .dontCare
            rpd.colorAttachments[0].storeAction = .store
            guard let enc = cmd.makeRenderCommandEncoder(descriptor: rpd), let pipeline = gpu.effects[kind] else { return }
            var u = u
            enc.setRenderPipelineState(pipeline)
            enc.setFragmentBytes(&u, length: MemoryLayout<EffectUniforms>.stride, index: 0)
            enc.setFragmentTextures([src, mask ?? src, extra ?? src], range: 0..<3)
            enc.setFragmentSamplerStates([gpu.clampSampler, gpu.wrapSampler], range: 0..<2)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            enc.endEncoding()
        }
        var copy = EffectUniforms()
        copy.p0 = SIMD4(l.uvScale.x, l.uvScale.y, 0, 0)
        pass("copy", copy, from: l.texture, into: l.targets[0], mask: nil, extra: nil)
        var cur = 0
        for e in l.effects {
            var u = e.uniforms
            u.misc.x = Float(time)
            pass(e.kind, u, from: l.targets[cur], into: l.targets[1 - cur], mask: e.mask, extra: e.extra)
            cur = 1 - cur
        }
        return l.targets[cur]
    }

    // MARK: Transforms (scene space: pixels, origin bottom-left, +y up)

    /// Aspect-fill: the scene covers the drawable, cropping the overflow evenly.
    private func projection(_ size: CGSize) -> float4x4 {
        let vw = Float(size.width), vh = Float(size.height)
        let s = max(vw / doc.width, vh / doc.height)
        let w = vw / s, h = vh / s
        let x0 = (doc.width - w) / 2, y0 = (doc.height - h) / 2
        return .ortho(left: x0, right: x0 + w, bottom: y0, top: y0 + h)
    }

    private func local(_ o: SceneObject) -> float4x4 {
        let p = o.origin.value(at: time), a = o.angles.value(at: time), s = o.scale.value(at: time)
        return .translate(p[0], p[1], p[2]) * .rotateZ(a[2]) * .rotateY(a[1]) * .rotateX(a[0]) * .scale(s[0], s[1], s[2])
    }

    private func world(_ o: SceneObject, fullscreen: Bool, size: SIMD2<Float>) -> float4x4 {
        if fullscreen { return .translate(doc.width / 2, doc.height / 2, 0) }
        var m = local(o)
        var parent = o.parent, depth = 0
        while let id = parent, let p = objectsByID[id], depth < 32 {
            m = local(p) * m
            parent = p.parent
            depth += 1
        }
        // `alignment` says which edge/corner `origin` refers to (default: centre).
        let s = o.scale.base
        var shift = SIMD2<Float>.zero
        if o.alignment.contains("top") { shift.y -= size.y * s[1] / 2 }
        if o.alignment.contains("bottom") { shift.y += size.y * s[1] / 2 }
        if o.alignment.contains("left") { shift.x += size.x * s[0] / 2 }
        if o.alignment.contains("right") { shift.x -= size.x * s[0] / 2 }
        return .translate(shift.x, shift.y, 0) * m
    }

    /// Layers move opposite to the pointer, scaled by their depth
    /// (open-wallpaper-engine's formula, minus its static off-centre term).
    /// ponytail: amplitude isn't calibrated against real Wallpaper Engine; tune `amount` here if it feels off.
    private func parallax(_ o: SceneObject) -> float4x4 {
        let px = doc.parallax
        guard px.enabled else { return matrix_identity_float4x4 }
        let mouse = SIMD2((0.5 - pointer.x) * doc.width, (pointer.y - 0.5) * doc.height) * px.mouseInfluence
        let offset = mouse * SIMD2(o.parallaxDepth[0], o.parallaxDepth[1]) * px.amount
        return .translate(offset.x, offset.y, 0)
    }

    private func tint(_ o: SceneObject) -> SIMD4<Float> {
        let c = o.color.value(at: time)
        return SIMD4(c[0], c[safe: 1] ?? 1, c[safe: 2] ?? 1, o.alpha.value(at: time)[0])
    }

    // MARK: Debug

    var debugStatus: String {
        "layers=\(layers.count) effects=\(layers.map(\.effects.count).reduce(0, +)) particles=\(systems.map(\.sim.particles.count)) unsupported=\(unsupported)"
    }

    /// Renders one frame offscreen at 960×540 (for the self-test).
    func debugSnapshot() -> CGImage? {
        let w = 960, h = 540
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: SceneGPU.pixelFormat, width: w, height: h, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .managed
        guard let tex = gpu.device.makeTexture(descriptor: d), let cmd = queue.makeCommandBuffer() else { return nil }
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = tex
        rpd.colorAttachments[0].storeAction = .store
        encode(cmd, rpd, size: CGSize(width: w, height: h))
        let blit = cmd.makeBlitCommandEncoder()
        blit?.synchronize(resource: tex)
        blit?.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()
        var px = [UInt8](repeating: 0, count: w * h * 4)
        tex.getBytes(&px, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        return CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                         bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)?.makeImage()
    }
}

// MARK: - Helpers

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

extension float4x4 {
    static func translate(_ x: Float, _ y: Float, _ z: Float) -> float4x4 {
        var m = matrix_identity_float4x4
        m.columns.3 = SIMD4(x, y, z, 1)
        return m
    }

    static func scale(_ x: Float, _ y: Float, _ z: Float) -> float4x4 { float4x4(diagonal: SIMD4(x, y, z, 1)) }

    static func rotateZ(_ a: Float) -> float4x4 {
        float4x4(SIMD4(cos(a), sin(a), 0, 0), SIMD4(-sin(a), cos(a), 0, 0), SIMD4(0, 0, 1, 0), SIMD4(0, 0, 0, 1))
    }

    static func rotateY(_ a: Float) -> float4x4 {
        float4x4(SIMD4(cos(a), 0, -sin(a), 0), SIMD4(0, 1, 0, 0), SIMD4(sin(a), 0, cos(a), 0), SIMD4(0, 0, 0, 1))
    }

    static func rotateX(_ a: Float) -> float4x4 {
        float4x4(SIMD4(1, 0, 0, 0), SIMD4(0, cos(a), sin(a), 0), SIMD4(0, -sin(a), cos(a), 0), SIMD4(0, 0, 0, 1))
    }

    /// Metal clip space (z in 0...1) with a deep z range so particle z never clips.
    static func ortho(left l: Float, right r: Float, bottom b: Float, top t: Float, near n: Float = -10_000, far f: Float = 10_000) -> float4x4 {
        float4x4(SIMD4(2 / (r - l), 0, 0, 0), SIMD4(0, 2 / (t - b), 0, 0), SIMD4(0, 0, 1 / (f - n), 0),
                 SIMD4(-(r + l) / (r - l), -(t + b) / (t - b), -n / (f - n), 1))
    }
}
