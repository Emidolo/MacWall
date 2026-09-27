import Foundation
import MacWallKit

/// Drives steamcmd to download Workshop items for Wallpaper Engine (app 431960).
/// steamcmd runs on a pseudo-terminal so its prompts are flushed and it disables echo for the
/// password. Answers typed by the user go straight to the terminal; nothing is stored or logged.
@MainActor
final class SteamCMD: ObservableObject {
    static let shared = SteamCMD()
    static let searchPaths = ["/opt/homebrew/bin/steamcmd", "/usr/local/bin/steamcmd"]

    enum Prompt { case password, guardCode, mobileConfirm }

    @Published private(set) var busy = false
    @Published private(set) var status = ""
    @Published private(set) var progress: Double?
    @Published private(set) var prompt: Prompt?

    private var master: Int32 = -1
    private var process: Process?
    private var parser = SteamCMDParser()
    private var downloadedPath: String?
    private var lastError: String?

    func locate() -> URL? {
        ([AppSettings.shared.steamcmdPath] + Self.searchPaths)
            .first { !$0.isEmpty && FileManager.default.isExecutableFile(atPath: $0) }
            .map(URL.init(fileURLWithPath:))
    }

    func answer(_ text: String) {
        prompt = nil
        guard master >= 0 else { return }
        let bytes = Array((text + "\n").utf8)
        _ = bytes.withUnsafeBytes { write(master, $0.baseAddress, $0.count) }
    }

    func cancel() { process?.terminate() }

    func download(id: String, user: String) async throws -> [Wallpaper] {
        guard let exe = locate() else { throw fail("steamcmd not found. Install it with `brew install steamcmd`.") }
        guard !busy else { throw fail("A download is already running.") }
        busy = true
        progress = nil
        status = "Starting steamcmd (the first run updates itself)…"
        parser = SteamCMDParser()
        downloadedPath = nil
        lastError = nil
        defer { busy = false; prompt = nil; process = nil }

        var mfd: Int32 = -1, sfd: Int32 = -1
        guard openpty(&mfd, &sfd, nil, nil, nil) == 0 else { throw fail("Could not open a terminal for steamcmd.") }
        master = mfd
        defer { close(mfd); master = -1 }

        let p = Process()
        p.executableURL = exe
        p.arguments = ["+login", user, "+workshop_download_item", "431960", id, "+quit"]
        let slave = FileHandle(fileDescriptor: sfd, closeOnDealloc: false)
        p.standardInput = slave
        p.standardOutput = slave
        p.standardError = slave
        process = p
        do {
            try p.run()
        } catch {
            close(sfd)
            throw error
        }
        close(sfd)  // the child has its own copy; closing ours lets reads end when it exits

        let exitCode: Int32 = await withCheckedContinuation { cont in
            Thread.detachNewThread { [weak self] in
                var buf = [UInt8](repeating: 0, count: 4096)
                while true {
                    let n = read(mfd, &buf, buf.count)
                    if n <= 0 { break }  // EOF, or EIO once the child's side is gone
                    let text = String(decoding: buf[0..<n], as: UTF8.self)
                    DispatchQueue.main.async { MainActor.assumeIsolated { self?.consume(text) } }
                }
                p.waitUntilExit()
                // Main queue is FIFO, so every chunk above is handled before we resume.
                DispatchQueue.main.async { cont.resume(returning: p.terminationStatus) }
            }
        }

        guard let path = downloadedPath else {
            throw fail(lastError ?? "steamcmd exited (\(exitCode)) without downloading the item.")
        }
        status = "Importing…"
        let items = try Library.shared.importItem(at: URL(fileURLWithPath: path))
        try? FileManager.default.removeItem(atPath: path)  // the library copy is the one we keep
        status = "Done."
        return items
    }

    private func consume(_ text: String) {
        if let line = text.split(whereSeparator: \.isNewline).last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            status = String(line).trimmingCharacters(in: .whitespaces)
        }
        for event in parser.feed(text) {
            switch event {
            case .needsPassword: prompt = .password; status = "Steam password required."
            case .needsGuardCode: prompt = .guardCode; status = "Steam Guard code required."
            case .needsMobileConfirm: prompt = .mobileConfirm; status = "Approve the sign-in in the Steam Mobile app."
            case .loginOK: prompt = nil; status = "Logged in. Downloading…"
            case .loginFailed(let reason): lastError = "Login failed: \(reason)"
            case .progress(let v): progress = v
            case .downloaded(let path): downloadedPath = path
            case .error(let message): lastError = message
            }
        }
    }

    private func fail(_ message: String) -> Error {
        status = message
        return NSError(domain: "MacWall.SteamCMD", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
