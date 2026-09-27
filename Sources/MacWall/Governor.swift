import AppKit

/// Decides when playback should pause: sleep, screen lock, Low Power Mode, or a
/// fullscreen window covering a display.
@MainActor
final class Governor {
    var onChange: () -> Void = {}
    private(set) var coveredDisplays = Set<CGDirectDisplayID>()
    private var asleep = false, locked = false
    private var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    private var timer: Timer?

    var pausedEverywhere: Bool { asleep || locked || lowPower }

    init() {
        let ws = NSWorkspace.shared.notificationCenter
        for (name, value) in [(NSWorkspace.willSleepNotification, true), (NSWorkspace.didWakeNotification, false),
                              (NSWorkspace.screensDidSleepNotification, true), (NSWorkspace.screensDidWakeNotification, false)] {
            ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.asleep = value; self?.onChange() }
            }
        }
        let dist = DistributedNotificationCenter.default()
        for (name, value) in [("com.apple.screenIsLocked", true), ("com.apple.screenIsUnlocked", false)] {
            dist.addObserver(forName: .init(name), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.locked = value; self?.onChange() }
            }
        }
        NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
                self?.onChange()
            }
        }
        // ponytail: 2 s poll of the window list; there is no public "fullscreen changed" notification.
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkFullscreen() }
        }
    }

    private func checkFullscreen() {
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let me = ProcessInfo.processInfo.processIdentifier
        let windows: [CGRect] = info.compactMap { w in
            guard w[kCGWindowLayer as String] as? Int == 0,
                  w[kCGWindowOwnerPID as String] as? pid_t != me,
                  let b = w[kCGWindowBounds as String] as! CFDictionary?,
                  let r = CGRect(dictionaryRepresentation: b) else { return nil }
            return r
        }
        var covered = Set<CGDirectDisplayID>()
        for screen in NSScreen.screens {
            let bounds = CGDisplayBounds(screen.displayID)
            let area = bounds.width * bounds.height
            // Covered = one window hides ≥ 95% of the display (fullscreen or zoomed).
            if windows.contains(where: { let i = $0.intersection(bounds); return i.width * i.height >= area * 0.95 }) {
                covered.insert(screen.displayID)
            }
        }
        if covered != coveredDisplays {
            coveredDisplays = covered
            onChange()
        }
    }
}
