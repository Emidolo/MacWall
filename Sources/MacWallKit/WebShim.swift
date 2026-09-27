import Foundation

/// Wallpaper Engine's web JavaScript API, injected at document start:
/// `wallpaperRegisterAudioListener`, `wallpaperPropertyListener.applyUserProperties` /
/// `applyGeneralProperties` / `setPaused`, plus an rAF wrapper for FPS limiting and pausing.
/// The host calls `__macwallAudio(bins)`, `__macwallPaused(bool)` and `__macwallVolume(0...1)`.
public enum WebShim {
    public static func script(propertiesJSON: String, fps: Int, volume: Float) -> String {
        """
        (function () {
          var props = \(propertiesJSON), fps = \(fps), volume = \(volume), audio = [];
          // Media volume follows the app's slider (muted at 0); 'play' doesn't bubble, so capture it.
          function level(m) { m.volume = volume; m.muted = volume === 0; }
          document.addEventListener('play', function (e) { if (e.target && 'volume' in e.target) level(e.target); }, true);
          window.__macwallVolume = function (v) { volume = v; document.querySelectorAll('video,audio').forEach(level); };
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
