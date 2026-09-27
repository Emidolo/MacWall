import JavaScriptCore
import Testing
@testable import MacWallKit

/// Runs the shim in JavaScriptCore with a fake rAF clock and page lifecycle.
private func page(fps: Int) -> JSContext {
    let js = JSContext()!
    js.evaluateScript("""
        var window = this, frameQueue = [], now = 0, loadHandlers = [], posted = [];
        window.requestAnimationFrame = function (cb) { frameQueue.push(cb); return frameQueue.length; };
        window.addEventListener = function (t, cb) { if (t === 'load') loadHandlers.push(cb); };
        window.setTimeout = function (cb) { cb(); };
        window.webkit = { messageHandlers: { macwall: { postMessage: function (m) { posted.push(m); } } } };
        function frame() { now += 1000 / 60; var q = frameQueue; frameQueue = []; q.forEach(function (cb) { cb(now); }); }
        var frames = 0, captured = null;
        var document = { addEventListener: function (t, cb, capture) { if (t === 'play' && capture) captured = cb; },
                         querySelectorAll: function () { return media; } };
        var media = [{ volume: 1, muted: false }];
        """)
    js.evaluateScript(WebShim.script(propertiesJSON: #"{"speed":{"type":"slider","value":3}}"#, fps: fps, volume: 0))
    js.evaluateScript("(function loop() { frames++; requestAnimationFrame(loop); })();")
    return js
}

private func run(_ js: JSContext, frames n: Int) -> Int32 {
    js.evaluateScript("frames = 0; for (var i = 0; i < \(n); i++) frame();")
    return js.evaluateScript("frames").toInt32()
}

@Test func unlimitedFpsRunsEveryFrame() {
    #expect(run(page(fps: 0), frames: 60) == 60)
}

@Test func fpsLimitThrottles() {
    #expect(run(page(fps: 30), frames: 60) == 30)
    #expect(run(page(fps: 15), frames: 60) == 15)
}

@Test func pauseHoldsFramesAndResumeContinues() {
    let js = page(fps: 0)
    js.evaluateScript("__macwallPaused(true)")
    #expect(run(js, frames: 30) == 0)
    js.evaluateScript("__macwallPaused(false)")
    #expect(run(js, frames: 30) == 30)
}

@Test func appliesPropertiesAndAudio() {
    let js = page(fps: 0)
    js.evaluateScript("""
        var got = null, paused = null, bins = null;
        window.wallpaperPropertyListener = {
          applyUserProperties: function (p) { got = p.speed.value; },
          setPaused: function (p) { paused = p; }
        };
        loadHandlers.forEach(function (h) { h(); });
        wallpaperRegisterAudioListener(function (b) { bins = b.length; });
        __macwallAudio(new Array(128).fill(0.5));
        __macwallPaused(true);
        """)
    #expect(js.evaluateScript("got").toInt32() == 3)
    #expect(js.evaluateScript("bins").toInt32() == 128)
    #expect(js.evaluateScript("paused").toBool())
    #expect(js.evaluateScript("posted[0]").toString() == "audio")
}

@Test func mediaStartsMutedAndFollowsVolume() {
    let js = page(fps: 0)
    js.evaluateScript("captured({ target: media[0] })")
    #expect(js.evaluateScript("media[0].muted").toBool())
    js.evaluateScript("__macwallVolume(0.4)")
    #expect(js.evaluateScript("media[0].volume").toDouble() == 0.4)
    #expect(!js.evaluateScript("media[0].muted").toBool())
}
