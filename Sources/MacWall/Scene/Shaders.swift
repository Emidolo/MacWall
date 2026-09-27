import Metal
import simd

/// Uniforms shared with the MSL below; layouts must match the structs there.
struct LayerUniforms {
    var mvp: float4x4
    var color: SIMD4<Float>
    var uvScale: SIMD2<Float>
    var pad = SIMD2<Float>.zero
}

struct EffectUniforms {
    var p0 = SIMD4<Float>.zero, p1 = SIMD4<Float>.zero, p2 = SIMD4<Float>.zero
    /// x: time, y: has mask, z: has extra texture, w: unused
    var misc = SIMD4<Float>.zero
}

struct ParticleInstance {
    var positionSize: SIMD4<Float>   // xyz, diameter
    var color: SIMD4<Float>
    var rotation: SIMD4<Float>       // x: z-rotation (radians)
}

/// Native Metal stand-ins for Wallpaper Engine's image, particle and (a few) effect shaders.
/// The effect math is reconstructed from the constants scenes pass in; WE's own shader
/// sources ship only with Wallpaper Engine.
enum SceneShaders {
    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct LayerUniforms { float4x4 mvp; float4 color; float2 uvScale; float2 pad; };
    struct EffectUniforms { float4 p0, p1, p2, misc; };
    struct ParticleInstance { float4 positionSize; float4 color; float4 rotation; };
    struct VOut { float4 pos [[position]]; float2 uv; float4 color; };

    // Unit quad centred on 0 as a 4-vertex triangle strip: TL, TR, BL, BR.
    static float2 corner(uint vid) { return float2((vid & 1) ? 0.5 : -0.5, (vid & 2) ? -0.5 : 0.5); }

    vertex VOut layerVertex(uint vid [[vertex_id]], constant LayerUniforms& u [[buffer(0)]]) {
        float2 c = corner(vid);
        VOut o;
        o.pos = u.mvp * float4(c, 0, 1);
        o.uv = float2(c.x + 0.5, 0.5 - c.y) * u.uvScale;
        o.color = u.color;
        return o;
    }

    fragment float4 layerFragment(VOut in [[stage_in]], texture2d<float> tex [[texture(0)]], sampler s [[sampler(0)]]) {
        float4 c = tex.sample(s, in.uv);
        return float4(c.rgb * in.color.rgb, c.a * in.color.a);
    }

    vertex VOut particleVertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                               constant LayerUniforms& u [[buffer(0)]],
                               const device ParticleInstance* ps [[buffer(1)]]) {
        ParticleInstance p = ps[iid];
        float2 c = corner(vid);
        float r = p.rotation.x;
        float2 offset = float2(c.x * cos(r) - c.y * sin(r), c.x * sin(r) + c.y * cos(r)) * p.positionSize.w;
        VOut o;
        o.pos = u.mvp * float4(p.positionSize.xy + offset, p.positionSize.z, 1);
        o.uv = float2(c.x + 0.5, 0.5 - c.y) * u.uvScale;
        o.color = p.color * u.color;
        return o;
    }

    // Effect passes: a fullscreen triangle over the layer's offscreen target.
    vertex VOut effectVertex(uint vid [[vertex_id]]) {
        float2 p = float2((vid == 1) ? 3.0 : -1.0, (vid == 2) ? 3.0 : -1.0);
        VOut o;
        o.pos = float4(p, 0, 1);
        o.uv = float2((p.x + 1) * 0.5, (1 - p.y) * 0.5);
        o.color = float4(1);
        return o;
    }

    // Crops the power-of-two padding: p0.xy = uv scale.
    fragment float4 fxCopy(VOut in [[stage_in]], constant EffectUniforms& u [[buffer(0)]],
                           texture2d<float> src [[texture(0)]], sampler s [[sampler(0)]]) {
        return src.sample(s, in.uv * u.p0.xy);
    }

    static float maskAt(constant EffectUniforms& u, texture2d<float> mask, sampler s, float2 uv) {
        return u.misc.y > 0.5 ? mask.sample(s, uv).r : 1.0;
    }

    // p0 = (speedx, speedy, repeat.x, repeat.y)
    fragment float4 fxScroll(VOut in [[stage_in]], constant EffectUniforms& u [[buffer(0)]],
                             texture2d<float> src [[texture(0)]], texture2d<float> mask [[texture(1)]],
                             sampler s [[sampler(0)]], sampler wrap [[sampler(1)]]) {
        float2 uv = in.uv * u.p0.zw + u.misc.x * u.p0.xy;
        return mix(src.sample(s, in.uv), src.sample(wrap, uv), maskAt(u, mask, s, in.uv));
    }

    // p0 = (speed, strength, friction.x, friction.y), p1 = (bounds.x, bounds.y)
    fragment float4 fxShake(VOut in [[stage_in]], constant EffectUniforms& u [[buffer(0)]],
                            texture2d<float> src [[texture(0)]], texture2d<float> mask [[texture(1)]],
                            sampler s [[sampler(0)]]) {
        float t = u.misc.x * u.p0.x;
        float2 o = float2(sin(t * u.p0.z), cos(t * u.p0.w));
        float m = smoothstep(u.p1.x, u.p1.y, maskAt(u, mask, s, in.uv));
        return src.sample(s, in.uv + o * u.p0.y * m);
    }

    // p0 = (animationspeed, ratio, ripplestrength, scale), p1 = (scrolldirection, scrollspeed)
    fragment float4 fxWaterRipple(VOut in [[stage_in]], constant EffectUniforms& u [[buffer(0)]],
                                  texture2d<float> src [[texture(0)]], texture2d<float> mask [[texture(1)]],
                                  texture2d<float> normal [[texture(2)]],
                                  sampler s [[sampler(0)]], sampler wrap [[sampler(1)]]) {
        float t = u.misc.x;
        float2 dir = float2(cos(u.p1.x), sin(u.p1.x));
        float2 uvN = in.uv * u.p0.w * float2(u.p0.y, 1) + dir * u.p1.y * t;
        float a = u.p0.x * t;
        float2 n;
        if (u.misc.z > 0.5) {
            n = normal.sample(wrap, uvN + a).xy + normal.sample(wrap, uvN * 0.7 - a).xy - 1.0;
        } else {
            // No WE normal map available: two layers of procedural waves.
            float2 q = uvN * 6.2831853 * 2.0;
            float w = a * 6.2831853 * 4.0;
            n = float2(sin(q.x * 1.3 + w) + sin(q.y * 0.9 - w * 1.2), cos(q.y * 1.1 + w * 0.8) + cos(q.x * 0.7 - w)) * 0.25;
        }
        return src.sample(s, in.uv + n * u.p0.z * maskAt(u, mask, s, in.uv));
    }

    // p0 = (tint.rgb, alpha); tint blended over the layer colour, alpha untouched.
    fragment float4 fxTint(VOut in [[stage_in]], constant EffectUniforms& u [[buffer(0)]],
                           texture2d<float> src [[texture(0)]], texture2d<float> mask [[texture(1)]],
                           sampler s [[sampler(0)]]) {
        float4 c = src.sample(s, in.uv);
        c.rgb = mix(c.rgb, u.p0.rgb, u.p0.a * maskAt(u, mask, s, in.uv));
        return c;
    }
    """
}

/// Compiled pipelines and samplers, built once per device.
final class SceneGPU {
    enum Blend { case opaque, translucent, additive }

    let device: MTLDevice
    let layer: [Blend: MTLRenderPipelineState]
    let particle: [Blend: MTLRenderPipelineState]
    let effects: [String: MTLRenderPipelineState]
    let clampSampler: MTLSamplerState
    let wrapSampler: MTLSamplerState
    static let pixelFormat = MTLPixelFormat.bgra8Unorm

    private static var cache: [ObjectIdentifier: SceneGPU] = [:]

    static func shared(_ device: MTLDevice) throws -> SceneGPU {
        if let gpu = cache[ObjectIdentifier(device)] { return gpu }
        let gpu = try SceneGPU(device)
        cache[ObjectIdentifier(device)] = gpu
        return gpu
    }

    private init(_ device: MTLDevice) throws {
        self.device = device
        let lib = try device.makeLibrary(source: SceneShaders.source, options: nil)
        func pipeline(_ v: String, _ f: String, _ blend: Blend) throws -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = lib.makeFunction(name: v)
            d.fragmentFunction = lib.makeFunction(name: f)
            let a = d.colorAttachments[0]!
            a.pixelFormat = Self.pixelFormat
            if blend != .opaque {
                a.isBlendingEnabled = true
                a.sourceRGBBlendFactor = .sourceAlpha
                a.sourceAlphaBlendFactor = .sourceAlpha
                a.destinationRGBBlendFactor = blend == .additive ? .one : .oneMinusSourceAlpha
                a.destinationAlphaBlendFactor = blend == .additive ? .one : .oneMinusSourceAlpha
            }
            return try device.makeRenderPipelineState(descriptor: d)
        }
        let blends: [Blend] = [.opaque, .translucent, .additive]
        layer = Dictionary(uniqueKeysWithValues: try blends.map { ($0, try pipeline("layerVertex", "layerFragment", $0)) })
        particle = Dictionary(uniqueKeysWithValues: try blends.map { ($0, try pipeline("particleVertex", "layerFragment", $0)) })
        effects = Dictionary(uniqueKeysWithValues: try [("copy", "fxCopy"), ("scroll", "fxScroll"), ("shake", "fxShake"),
                                                         ("waterripple", "fxWaterRipple"), ("tint", "fxTint")]
            .map { ($0.0, try pipeline("effectVertex", $0.1, .opaque)) })

        func sampler(_ mode: MTLSamplerAddressMode) -> MTLSamplerState {
            let d = MTLSamplerDescriptor()
            d.minFilter = .linear
            d.magFilter = .linear
            d.mipFilter = .linear
            d.sAddressMode = mode
            d.tAddressMode = mode
            return device.makeSamplerState(descriptor: d)!
        }
        clampSampler = sampler(.clampToEdge)
        wrapSampler = sampler(.repeat)
    }
}
