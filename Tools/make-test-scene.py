# Writes a synthetic scene wallpaper (scene.pkg + project.json) exercising layers, padding crop,
# rotation, parenting, keyframes, effects and particles. Usage: python3 Tools/make-test-scene.py <out-dir>
import json, struct, os, sys
out = sys.argv[1]; os.makedirs(out, exist_ok=True)

def tex(w, h, iw, ih, pixel):
    d = b"TEXV0005\0TEXI0001\0" + struct.pack("<iIIIIII", 0, 0, w, h, iw, ih, 0)
    d += b"TEXB0003\0" + struct.pack("<Ii", 1, -1) + struct.pack("<I", 1)
    px = bytearray()
    for y in range(h):
        for x in range(w):
            px += bytes(pixel(x, y, iw, ih))
    d += struct.pack("<IIIII", w, h, 0, 0, len(px)) + px
    return d

bg = tex(64, 64, 64, 64, lambda x, y, iw, ih: (x * 4, 40, y * 4, 255))
# 48x48 image in a 64x64 texture; padding is magenta so a wrong UV crop is obvious.
sq = tex(64, 64, 48, 48, lambda x, y, iw, ih: (255, 255, 255, 255) if x < iw and y < ih and (x // 8 + y // 8) % 2 == 0 else ((200, 200, 40, 255) if x < iw and y < ih else (255, 0, 255, 255)))
stripes = tex(64, 64, 64, 64, lambda x, y, iw, ih: (255, 255, 255, 255) if (x // 8) % 2 == 0 else (30, 30, 30, 255))

def model(mat): return json.dumps({"material": mat}).encode()
def material(tex, blend="translucent"): return json.dumps({"passes": [{"shader": "genericimage2", "blending": blend, "textures": [tex]}]}).encode()

scene = {
  "camera": {"center": "0 0 -1", "eye": "0 0 0", "up": "0 1 0"},
  "general": {"orthogonalprojection": {"width": 1920, "height": 1080}, "clearcolor": "0.05 0.05 0.15",
              "cameraparallax": True, "cameraparallaxamount": 0.5, "cameraparallaxdelay": 0.1, "cameraparallaxmouseinfluence": 0.5},
  "objects": [
    {"id": 1, "name": "bg", "image": "models/bg.json", "origin": "960 540 0", "size": "1920 1080", "parallaxDepth": "0.05 0.05"},
    {"id": 2, "name": "square", "image": "models/sq.json", "origin": "400 300 0", "size": "300 300", "angles": "0 0 0.3", "alpha": 0.8, "color": "1.0 0.6 0.6"},
    {"id": 3, "name": "child", "image": "models/sq.json", "parent": 2, "origin": "250 0 0", "size": "100 100",
     "effects": [{"file": "effects/shake/effect.json", "passes": [{"constantshadervalues": {"speed": 3, "strength": 0.05}}]}]},
    {"id": 4, "name": "mover", "image": "models/sq.json", "size": "150 150",
     "origin": {"value": "800 700 0", "animation": {"options": {"fps": 30, "length": 120, "mode": "mirror"},
                "c0": [{"frame": 0, "value": 800}, {"frame": 120, "value": 1700}]}}},
    {"id": 5, "name": "stripes", "image": "models/stripes.json", "origin": "1400 300 0", "size": "600 200",
     "effects": [{"file": "effects/scroll/effect.json", "passes": [{"constantshadervalues": {"speedx": 0.25, "speedy": 0}}]},
                 {"file": "effects/tint/effect.json", "passes": [{"constantshadervalues": {"color": "0 1 0", "alpha": 0.5}}]}]},
    {"id": 6, "name": "sparks", "particle": "particles/sparks.json", "origin": "960 100 0"},
    {"id": 7, "name": "music", "sound": ["sounds/a.mp3"]}
  ]
}
particles = {"material": "materials/particle.json", "maxcount": 300,
  "emitter": [{"name": "boxrandom", "rate": 80, "distancemax": "500 20 0"}],
  "initializer": [{"name": "lifetimerandom", "min": 3, "max": 4}, {"name": "sizerandom", "min": 20, "max": 50},
                  {"name": "velocityrandom", "min": "-20 60 0", "max": "20 160 0"}, {"name": "colorrandom", "min": "255 150 50", "max": "255 220 120"}],
  "operator": [{"name": "movement", "gravity": "0 -10 0"}, {"name": "alphafade", "fadeintime": 0.1, "fadeouttime": 0.7}]}

files = [("scene.json", json.dumps(scene).encode()),
         ("models/bg.json", model("materials/bg.json")), ("materials/bg.json", material("bg", "normal")), ("materials/bg.tex", bg),
         ("models/sq.json", model("materials/sq.json")), ("materials/sq.json", material("sq")), ("materials/sq.tex", sq),
         ("models/stripes.json", model("materials/stripes.json")), ("materials/stripes.json", material("stripes")), ("materials/stripes.tex", stripes),
         ("particles/sparks.json", json.dumps(particles).encode()),
         ("materials/particle.json", json.dumps({"passes": [{"shader": "genericparticle", "blending": "additive", "textures": ["particle/halo"]}]}).encode())]
pkg = struct.pack("<I", 8) + b"PKGV0019" + struct.pack("<I", len(files))
off = 0
for name, body in files:
    pkg += struct.pack("<I", len(name)) + name.encode() + struct.pack("<II", off, len(body)); off += len(body)
pkg += b"".join(b for _, b in files)
open(os.path.join(out, "scene.pkg"), "wb").write(pkg)
json.dump({"title": "Test Scene", "type": "scene", "file": "scene.json", "workshopid": "900003"}, open(os.path.join(out, "project.json"), "w"))
