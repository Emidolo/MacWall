import Foundation
import ScreenCaptureKit
import Accelerate

/// System audio → Wallpaper Engine style spectrum: 128 floats, 64 left bins then 64 right.
/// Needs Screen Recording permission; without it subscribers just get zeros.
// State is split between the main actor, `queue` and `lock`.
final class AudioCapture: NSObject, SCStreamOutput, @unchecked Sendable {
    @MainActor static let shared = AudioCapture()

    private static let n = 1024, log2n: vDSP_Length = 10
    private let queue = DispatchQueue(label: "macwall.audio")
    private let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
    private let window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: n, isHalfWindow: false)
    private var ring: [[Float]] = [[], []]           // queue-only
    private var latest = [Float](repeating: 0, count: 128)
    private let lock = NSLock()

    @MainActor private var subscribers: [UUID: ([Float]) -> Void] = [:]
    @MainActor private var stream: SCStream?
    @MainActor private var timer: Timer?

    @MainActor
    func subscribe(_ callback: @escaping ([Float]) -> Void) -> UUID {
        let id = UUID()
        subscribers[id] = callback
        if timer == nil { start() }
        return id
    }

    @MainActor
    func unsubscribe(_ id: UUID) {
        subscribers[id] = nil
        if subscribers.isEmpty { stop() }
    }

    @MainActor private func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let bins = self.lock.withLock { self.latest }
                self.subscribers.values.forEach { $0(bins) }
            }
        }
        Task { @MainActor in
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = content.displays.first, timer != nil else { return }
                let cfg = SCStreamConfiguration()
                cfg.capturesAudio = true
                cfg.excludesCurrentProcessAudio = true
                cfg.sampleRate = 48_000
                cfg.channelCount = 2
                // Video is mandatory; make it as cheap as possible.
                cfg.width = 2
                cfg.height = 2
                cfg.minimumFrameInterval = CMTime(value: 1, timescale: 1)
                let s = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: cfg, delegate: nil)
                try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
                try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
                try await s.startCapture()
                stream = s
            } catch {
                NSLog("MacWall: audio capture unavailable (\(error.localizedDescription)); feeding zeros")
            }
        }
    }

    @MainActor private func stop() {
        timer?.invalidate()
        timer = nil
        stream?.stopCapture { _ in }
        stream = nil
        lock.withLock { latest = [Float](repeating: 0, count: 128) }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, let asbd = sb.formatDescription?.audioStreamBasicDescription,
              asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0 else { return }
        let nonInterleaved = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        let channels = Int(asbd.mChannelsPerFrame)
        try? sb.withAudioBufferList { abl, _ in
            for ch in 0..<2 {
                let buf = abl[nonInterleaved ? min(ch, abl.count - 1) : 0]
                guard let data = buf.mData else { continue }
                let all = UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self), count: Int(buf.mDataByteSize) / 4)
                let samples = nonInterleaved ? Array(all) : stride(from: min(ch, channels - 1), to: all.count, by: max(channels, 1)).map { all[$0] }
                ring[ch] = Array((ring[ch] + samples).suffix(Self.n))
            }
        }
        guard ring[0].count == Self.n, ring[1].count == Self.n else { return }
        let bins = spectrum(ring[0]) + spectrum(ring[1])
        lock.withLock { latest = zip(latest, bins).map { max($1, $0 * 0.8) } }  // fast attack, slow decay
    }

    /// 1024 samples → 64 log-spaced bands in 0...1.
    private func spectrum(_ x: [Float]) -> [Float] {
        let half = Self.n / 2
        let windowed = vDSP.multiply(x, window)
        var re = [Float](repeating: 0, count: half), im = re, mags = re
        re.withUnsafeMutableBufferPointer { rp in
            im.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                windowed.withUnsafeBytes { vDSP_ctoz($0.bindMemory(to: DSPComplex.self).baseAddress!, 2, &split, 1, vDSP_Length(half)) }
                vDSP_fft_zrip(setup, &split, 1, Self.log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvabs(&split, 1, &mags, 1, vDSP_Length(half))
            }
        }
        return (0..<64).map { b in
            let lo = Int(pow(Float(half), Float(b) / 64)), hi = max(lo + 1, Int(pow(Float(half), Float(b + 1) / 64)))
            let m = mags[lo..<min(hi, half)].max()! / Float(half)
            return min(1, max(0, (20 * log10(m + 1e-9) + 60) / 60))
        }
    }
}
