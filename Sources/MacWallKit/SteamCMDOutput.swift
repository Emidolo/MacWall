import Foundation

public enum SteamCMDEvent: Equatable, Sendable {
    case needsPassword, needsGuardCode, needsMobileConfirm
    case loginOK
    case loginFailed(String)
    case progress(Double)
    case downloaded(path: String)
    case error(String)
}

/// Incremental parser for steamcmd stdout. Prompts arrive without a trailing newline,
/// so the unfinished tail is checked for them too.
public struct SteamCMDParser: Sendable {
    private var partial = ""

    public init() {}

    public mutating func feed(_ chunk: String) -> [SteamCMDEvent] {
        var lines = (partial + chunk).replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
        partial = lines.removeLast()
        var events = lines.compactMap(Self.parse)
        if let prompt = Self.prompt(partial) {
            events.append(prompt)
            partial = ""
        }
        return events
    }

    private static func prompt(_ s: String) -> SteamCMDEvent? {
        let l = s.lowercased()
        if l.hasSuffix("password:") || l.hasSuffix("password: ") { return .needsPassword }
        if l.contains("steam guard code:") || l.contains("two-factor code:") { return .needsGuardCode }
        return nil
    }

    private static func parse(_ line: String) -> SteamCMDEvent? {
        if let p = prompt(line) { return p }
        if line.contains("Steam Mobile app") { return .needsMobileConfirm }
        if line.hasPrefix("Logging in user"), let r = line.range(of: "FAILED") {
            return .loginFailed(line[r.upperBound...].trimmingCharacters(in: CharacterSet(charactersIn: " ()")))
        }
        if line.hasPrefix("Logging in user"), line.hasSuffix("OK") { return .loginOK }
        if line.hasPrefix("Success. Downloaded item"), let a = line.firstIndex(of: "\""), let b = line.lastIndex(of: "\""), a < b {
            return .downloaded(path: String(line[line.index(after: a)..<b]))
        }
        if line.hasPrefix("ERROR!") { return .error(line.dropFirst(6).trimmingCharacters(in: .whitespaces)) }
        if let r = line.range(of: "progress: ") {
            let num = line[r.upperBound...].prefix { $0.isNumber || $0 == "." }
            if let v = Double(num) { return .progress(v / 100) }
        }
        return nil
    }
}
