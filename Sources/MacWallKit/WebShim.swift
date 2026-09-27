import Foundation

/// Wallpaper Engine's web JavaScript API, injected at document start:
/// `wallpaperRegisterAudioListener`, `wallpaperPropertyListener.applyUserProperties` /
/// `applyGeneralProperties` / `setPaused`, plus an rAF wrapper for FPS limiting and pausing.
/// The host calls `__macwallAudio(bins)` and `__macwallPaused(bool)`.
public enum WebShim {
    public static func script(propertiesJSON: String, fps: Int) -> String {
        """
        (function () {
          var props = \(propertiesJSON), fps = \(fps), audio = [];
          window.wallpaperRegisterAudioListener = function (cb) {
            audio.push(cb);
            window.webkit.messageHandlers.macwall.postMessage('audio');
          };
          window.__macwallAudio = function (bins) {
            for (var i = 0; i < audio.length; i++) { try { audio[i](bins); } catch (e) {} }
          };
          window.addEventListener('load', function () {
            setTimeout(function () {
              var l = window.wallpaperPropertyListener;
              if (!l) return;
              if (l.applyGeneralProperties) l.applyGeneralProperties({ fps: fps || 60 });
              if (l.applyUserProperties) l.applyUserProperties(props);
            }, 0);
          });
          // rAF wrapper: FPS limit (every callback in a frame gets the same verdict) and pausing
          // (callbacks are held so the last frame stays on screen).
          var raf = window.requestAnimationFrame.bind(window), step = fps > 0 ? 1000 / fps : 0;
          var last = -1e9, seen = -1, open = false, paused = false, held = [];
          window.requestAnimationFrame = function (cb) {
            return raf(function tick(ts) {
              if (paused) { held.push(tick); return; }
              if (ts !== seen) { seen = ts; open = ts - last >= step - 1; if (open) last = ts; }
              if (open) cb(ts); else raf(tick);
            });
          };
          window.__macwallPaused = function (p) {
            paused = p;
            var l = window.wallpaperPropertyListener;
            if (l && l.setPaused) l.setPaused(p);
            if (!p) { var h = held; held = []; h.forEach(function (t) { raf(t); }); }
          };
        })();
        """
    }
}
