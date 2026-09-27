import AppKit

enum SceneSupport {
    /// Phase 1: scenes aren't rendered yet; the preview image stands in.
    static func isFullySupported(_ folder: URL) -> Bool { false }
}

final class SceneRenderer: WallpaperRenderer {
    let view = NSView()
    init?(folder: URL, fps: Int, quality: Quality) { return nil }
    func setPaused(_ paused: Bool) {}
    func setVolume(_ volume: Float) {}
    func stop() {}
    func debugSnapshot() -> CGImage? { nil }
    var debugStatus: String { "" }
}
