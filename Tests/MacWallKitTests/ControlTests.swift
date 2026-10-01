import Foundation
import Testing
@testable import MacWallKit

private func command(_ url: String) -> ControlCommand? { ControlCommand(url: URL(string: url)!) }

@Test func parsesControlCommands() {
    #expect(command("macwall://set?id=123") == .set(id: "123", display: nil))
    #expect(command("macwall://set?id=123&display=37D8832A-2D66") == .set(id: "123", display: "37D8832A-2D66"))
    #expect(command("macwall://next") == .next)
    #expect(command("macwall://previous") == .previous)
    #expect(command("macwall://pause") == .pause)
    #expect(command("macwall://resume") == .resume)
    #expect(command("macwall://toggle") == .toggle)
    #expect(command("MACWALL://Toggle") == .toggle)
    #expect(command("macwall://volume?value=0.25") == .volume(0.25))
    #expect(command("macwall://open-library") == .openLibrary)
}

@Test func rejectsMalformedControlCommands() {
    #expect(command("macwall://set") == nil)
    #expect(command("macwall://set?id=") == nil)
    #expect(command("macwall://volume") == nil)
    #expect(command("macwall://volume?value=loud") == nil)
    #expect(command("macwall://volume?value=nan") == nil)
    #expect(command("macwall://quit") == nil)
    #expect(command("https://next") == nil)
    #expect(command("macwall:next") == nil)
}

@Test func clampsVolume() {
    #expect(command("macwall://volume?value=7") == .volume(1))
    #expect(command("macwall://volume?value=-1") == .volume(0))
}
