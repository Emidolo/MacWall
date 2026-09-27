import Foundation
import Testing
@testable import MacWallKit

private func json(_ s: String) -> Any { try! JSONSerialization.jsonObject(with: Data(s.utf8), options: .fragmentsAllowed) }
private let noProps = UserProperties(json: "{}")

@Test func parsesValueEncodings() {
    #expect(SceneJSON.floats("1 2.5 -3") == [1, 2.5, -3])
    #expect(SceneJSON.floats("1,2") == [1, 2])
    #expect(SceneJSON.floats(json("[4, 5]")) == [4, 5])
    #expect(SceneJSON.floats(json("7")) == [7])
    #expect(SceneJSON.floats(json("true")) == [1])
    #expect(SceneJSON.floats("#ff8000") == [1, Float(128) / 255, 0])
    #expect(SceneJSON.color("255 0 128") == [1, 0, Float(128) / 255])   // no dot → 0..255
    #expect(SceneJSON.color("1.0 0.5 0") == [1, 0.5, 0])
    #expect(SceneJSON.floats("abc") == nil)
}

@Test func resolvesUserBindings() {
    let props = UserProperties(json: #"{"speed":{"type":"slider","value":3},"mode":{"value":"b"}}"#)
    #expect(SceneJSON.floats(SceneJSON.resolve(json(#"{"user":"speed","value":1}"#), props)) == [3])
    #expect(SceneJSON.floats(SceneJSON.resolve(json(#"{"user":"missing","value":1}"#), props)) == [1])
    #expect(SceneJSON.resolve(json(#"{"user":{"name":"mode","condition":"b"},"value":false}"#), props) as? Bool == true)
    #expect(SceneJSON.resolve(json(#"{"user":{"name":"mode","condition":"c"},"value":true}"#), props) as? Bool == false)
}

@Test func animatedValueDefaultsAndPadding() {
    let v = AnimatedValue(json("\"2\""), noProps, default: [1, 1, 1])
    #expect(v.value(at: 0) == [2, 1, 1])
    #expect(!v.isAnimated)
    #expect(AnimatedValue(nil, noProps, default: [0, 0]).value(at: 5) == [0, 0])
}

@Test func linearKeyframesLoopMirrorSingle() {
    func anim(_ mode: String) -> AnimatedValue {
        AnimatedValue(json("""
        {"value":"0 0 0","animation":{"options":{"fps":10,"length":10,"mode":"\(mode)"},
          "c0":[{"frame":0,"value":0},{"frame":10,"value":100}],
          "c1":[{"frame":0,"value":5},{"frame":5,"value":5,"step":true},{"frame":10,"value":9,"step":true}]}}
        """), noProps, default: [0, 0, 0])
    }
    let loop = anim("loop")
    #expect(loop.isAnimated)
    #expect(loop.value(at: 0.5)[0] == 50)                // frame 5
    #expect(loop.value(at: 1.25)[0] == 25)               // wraps to frame 2.5
    #expect(loop.value(at: 0.9)[1] == 5)                 // step holds until frame 10
    #expect(loop.value(at: 0.5)[2] == 0)                 // missing channel keeps base
    #expect(anim("mirror").value(at: 1.25)[0] == 75)     // frame 12.5 mirrors to 7.5
    #expect(anim("single").value(at: 3)[0] == 100)
}

@Test func relativeAnimationAddsToBase() {
    let v = AnimatedValue(json("""
    {"value":"100 200 0","animation":{"relative":true,"options":{"fps":1,"length":2,"mode":"loop"},
      "c0":[{"frame":0,"value":0},{"frame":2,"value":10}]}}
    """), noProps, default: [0, 0, 0])
    #expect(v.value(at: 1) == [105, 200, 0])
}

@Test func bezierKeyframesMatchReference() {
    // open-wallpaper-engine's reference: keys (0, 0, front (1, 10)) and (100, 0) → 4.438677 at frame 50.
    let v = AnimatedValue(json("""
    {"value":0,"animation":{"options":{"fps":1,"length":100,"mode":"single"},
      "c0":[{"frame":0,"value":0,"front":{"enabled":true,"x":1,"y":10}},{"frame":100,"value":0}]}}
    """), noProps, default: [0])
    #expect(abs(v.value(at: 50)[0] - 4.438677) < 1e-3)
}

@Test func parsesSceneDocument() throws {
    let scene = """
    {"camera":{"center":"0 0 -1","eye":"0 0 0","up":"0 1 0"},
     "general":{"orthogonalprojection":{"width":1920,"height":1080},"clearcolor":"0.1 0.2 0.3",
                "cameraparallax":true,"cameraparallaxamount":0.5,"cameraparallaxdelay":0.1,"cameraparallaxmouseinfluence":{"user":"infl","value":0.3}},
     "objects":[
       {"id":1,"name":"bg","image":"models/bg.json","origin":"960 540 0","scale":"1 1 1","angles":"0 0 0","size":"1920 1080",
        "alpha":1,"color":"1 1 1","visible":true,"parallaxDepth":"0.5 0.5",
        "effects":[{"file":"effects/shake/effect.json","visible":true,"passes":[{"constantshadervalues":{"speed":2,"friction":"1 2"},"textures":[null,"masks/m1"]}]},
                   {"file":"effects/godrays/effect.json","visible":true,"passes":[{}]},
                   {"file":"effects/tint/effect.json","visible":false,"passes":[{}]}]},
       {"id":2,"name":"hidden","image":"models/x.json","visible":{"user":{"name":"showx","condition":"1"},"value":true}},
       {"id":3,"name":"snow","particle":"particles/snow.json","origin":"0 0 0","instanceoverride":{"rate":2,"alpha":0.5}},
       {"id":4,"name":"music","sound":["sounds/a.mp3"]},
       {"id":5,"name":"child","image":"models/c.json","parent":1,"alpha":50}
     ]}
    """
    let doc = try SceneDocument(data: Data(scene.utf8), props: UserProperties(json: #"{"showx":{"value":0},"infl":{"value":0.8}}"#))
    #expect(doc.width == 1920 && doc.height == 1080)
    #expect(doc.clearColor == [0.1, 0.2, 0.3])
    #expect(doc.parallax.enabled && doc.parallax.amount == 0.5 && doc.parallax.mouseInfluence == 0.8)
    #expect(doc.objects.count == 5)
    let bg = doc.objects[0]
    #expect(bg.kind == .image(model: "models/bg.json"))
    #expect(bg.size == [1920, 1080])
    #expect(bg.parallaxDepth == [0.5, 0.5])
    #expect(bg.effects.map(\.name) == ["shake", "godrays"])          // invisible effect dropped
    #expect(bg.effects[0].passes[0].constants["friction"] == [1, 2])
    #expect(bg.effects[0].passes[0].textures == [nil, "masks/m1"])
    #expect(doc.objects[1].visible == false)
    #expect(doc.objects[2].kind == .particle("particles/snow.json"))
    #expect(doc.objects[2].instanceOverride["rate"] == [2])
    #expect(doc.objects[3].kind == .unsupported("sound"))
    #expect(doc.objects[4].parent == 1)
    #expect(doc.objects[4].alpha.value(at: 0) == [0.5])              // legacy 0..100
}

@Test func parsesModelAndMaterial() {
    let model = SceneModel(json(#"{"material":"materials/bg.json","width":800,"height":600,"fullscreen":false}"#) as! [String: Any])
    #expect(model.material == "materials/bg.json")
    #expect(model.size == [800, 600])
    let mat = SceneMaterial(json(#"{"passes":[{"shader":"genericimage2","blending":"additive","textures":["bg",null]}]}"#) as! [String: Any])
    #expect(mat.blending == .additive)
    #expect(mat.textures == ["bg", nil])
    #expect(SceneMaterial([:]).blending == .translucent)
}

@Test func analysesSupport() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    func put(_ path: String, _ s: String) throws {
        let url = dir.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(s.utf8).write(to: url)
    }
    try put("models/a.json", #"{"material":"materials/a.json"}"#)
    try put("materials/a.json", #"{"passes":[{"shader":"genericimage2","textures":["a"]}]}"#)
    try put("materials/a.tex", "x")
    try put("scene.json", #"{"general":{"orthogonalprojection":{"width":10,"height":10}},"objects":[{"image":"models/a.json","effects":[{"file":"effects/shake/effect.json"}]}]}"#)
    #expect(SceneAnalysis.unsupportedFeatures(SceneAssets(folder: dir), props: UserProperties(json: "{}")) == [])

    try put("scene.json", #"{"general":{},"objects":[{"image":"models/a.json","effects":[{"file":"effects/godrays/effect.json"}]},{"sound":["a.mp3"]},{"image":"models/b.json"}]}"#)
    #expect(SceneAnalysis.unsupportedFeatures(SceneAssets(folder: dir), props: UserProperties(json: "{}"))
            == ["godrays effect", "missing models/b.json", "perspective camera", "sound layers"])
}
