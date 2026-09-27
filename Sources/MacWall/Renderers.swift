import AppKit
import AVFoundation
import WebKit
import MacWallKit

@MainActor
protocol WallpaperRenderer: AnyObject {
    var view: NSView { get }
    func setPaused(_ paused: Bool)
    func setVolume(_ volume: Float)
    func stop()
}

@MainActor
func makeRenderer(for w: Wallpaper, settings s: AppSettings) -> WallpaperRenderer {
    switch w.project.kind {
    case .video:
        if let url = w.contentURL { return VideoRenderer(url: url, volume: s.volume, quality: s.quality) }
    case .web:
        if let url = w.contentURL { return WebRenderer(index: url, folder: w.folder, propertiesJSON: w.project.propertiesJSON, fps: s.fpsLimit) }
    case .scene:
        if let r = SceneRenderer(folder: w.folder, fps: s.fpsLimit, quality: s.quality) { return r }
    case .application, .unknown:
        break
    }
    return ImageRenderer(url: w.previewURL)
}

final class VideoRenderer: WallpaperRenderer {
    let view = NSView()
    let player = AVQueuePlayer()
    private var looper: AVPlayerLooper?

    init(url: URL, volume: Float, quality: Quality) {
        let layer = AVPlayerLayer(player: player)
        layer.videoGravity = .resizeAspectFill
        layer.backgroundColor = .black
        view.layer = layer
        view.wantsLayer = true
        let item = AVPlayerItem(url: url)
        item.preferredMaximumResolution = quality.maxVideoSize
        player.preventsDisplaySleepDuringVideoPlayback = false
        looper = AVPlayerLooper(player: player, templateItem: item)
        setVolume(volume)
        player.play()
    }

    func setPaused(_ paused: Bool) { paused ? player.pause() : player.play() }

    func setVolume(_ volume: Float) {
        player.volume = volume
        player.isMuted = volume == 0
    }

    func stop() {
        looper?.disableLooping()
        player.pause()
        player.removeAllItems()
    }
}

/// Hosts a Wallpaper Engine web wallpaper and emulates WE's JavaScript API.
final class WebRenderer: NSObject, WallpaperRenderer, WKScriptMessageHandler {
    let webView: WKWebView
    var view: NSView { webView }
    private var audioToken: UUID?

    init(index: URL, folder: URL, propertiesJSON: String, fps: Int) {
        let config = WKWebViewConfiguration()
        config.mediaTypesRequiringUserActionForPlayback = []
        // Many wallpapers XHR/fetch their own assets over file://.
        config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
        config.userContentController.addUserScript(WKUserScript(
            source: WebShim.script(propertiesJSON: propertiesJSON, fps: fps),
            injectionTime: .atDocumentStart, forMainFrameOnly: true))
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        config.userContentController.add(self, name: "macwall")  // cycle broken in stop()
        webView.loadFileURL(index, allowingReadAccessTo: folder)
    }

    /// The page called `wallpaperRegisterAudioListener`: start feeding it (only now, so
    /// wallpapers without visualizers never trigger the Screen Recording prompt).
    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.body as? String == "audio", audioToken == nil else { return }
        audioToken = AudioCapture.shared.subscribe { [weak self] bins in
            let list = bins.map { String(format: "%.3f", $0) }.joined(separator: ",")
            self?.webView.evaluateJavaScript("__macwallAudio([\(list)])")
        }
    }

    func setPaused(_ paused: Bool) {
        webView.evaluateJavaScript("window.__macwallPaused&&__macwallPaused(\(paused))")
        webView.setAllMediaPlaybackSuspended(paused)
    }

    func setVolume(_ volume: Float) {
        webView.evaluateJavaScript("document.querySelectorAll('video,audio').forEach(function(m){m.volume=\(volume);m.muted=\(volume == 0)})")
    }

    func stop() {
        if let audioToken { AudioCapture.shared.unsubscribe(audioToken) }
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "macwall")
        webView.stopLoading()
        webView.loadHTMLString("", baseURL: nil)
    }
}

/// Fallback: shows the preview image for types we can't render.
final class ImageRenderer: WallpaperRenderer {
    let view = NSView()

    init(url: URL?) {
        let layer = CALayer()
        layer.contents = url.flatMap(NSImage.init(contentsOf:))
        layer.contentsGravity = .resizeAspectFill
        layer.backgroundColor = .black
        view.layer = layer
        view.wantsLayer = true
    }

    func setPaused(_ paused: Bool) {}
    func setVolume(_ volume: Float) {}
    func stop() {}
}
