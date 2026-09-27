import Foundation
import Testing
@testable import MacWallKit

@Test func parsesVideoProject() throws {
    let json = #"{"title":"Rain","type":"Video","file":"rain.mp4","preview":"preview.gif","workshopid":123,"general":{"properties":{"schemecolor":{"type":"color","value":"0.1 0.2 0.3"}}}}"#
    let p = try WallpaperProject(data: Data(json.utf8))
    #expect(p.title == "Rain")
    #expect(p.kind == .video)
    #expect(p.file == "rain.mp4")
    #expect(p.preview == "preview.gif")
    #expect(p.workshopID == "123")
    let props = try JSONSerialization.jsonObject(with: Data(p.propertiesJSON.utf8)) as! [String: Any]
    #expect((props["schemecolor"] as? [String: Any])?["value"] as? String == "0.1 0.2 0.3")
}

@Test func parsesMinimalProject() throws {
    let p = try WallpaperProject(data: Data(#"{"type":"web"}"#.utf8))
    #expect(p.kind == .web)
    #expect(p.title == "")
    #expect(p.file == nil)
    #expect(p.propertiesJSON == "{}")
    #expect(try WallpaperProject(data: Data(#"{"type":"preset"}"#.utf8)).kind == .unknown)
    #expect(throws: (any Error).self) { try WallpaperProject(data: Data("[]".utf8)) }
}

@Test func parsesWorkshopIDs() {
    #expect(WorkshopID.parse(" 1234567 ") == "1234567")
    #expect(WorkshopID.parse("https://steamcommunity.com/sharedfiles/filedetails/?id=818491532&searchtext=") == "818491532")
    #expect(WorkshopID.parse("steamcommunity.com/workshop/filedetails/?id=42") == "42")
    #expect(WorkshopID.parse("https://steamcommunity.com/app/431960") == nil)
    #expect(WorkshopID.parse("12a") == nil)
    #expect(WorkshopID.parse("") == nil)
}

@Test func steamcmdPromptsWithoutNewline() {
    var p = SteamCMDParser()
    #expect(p.feed("Logging in user 'bob' to Steam Public...\npass") == [])
    #expect(p.feed("word: ") == [.needsPassword])
    #expect(p.feed("\nPlease check your email for the message from Steam, and enter the Steam Guard\n code from that message.\nSteam Guard code:") == [.needsGuardCode])
    #expect(p.feed("Two-factor code:") == [.needsGuardCode])
}

@Test func steamcmdDownloadFlow() {
    var p = SteamCMDParser()
    let out = """
    Logging in user 'bob' [U:1:1] to Steam Public...OK\r
    Downloading item 818491532 ...\r
     Update state (0x61) downloading, progress: 42.50 (100 / 200)
    Success. Downloaded item 818491532 to "/Users/bob/Library/Application Support/Steam/steamapps/workshop/content/431960/818491532" (123 bytes)

    """
    #expect(p.feed(out) == [.loginOK, .progress(0.425),
        .downloaded(path: "/Users/bob/Library/Application Support/Steam/steamapps/workshop/content/431960/818491532")])
}

@Test func steamcmdErrors() {
    var p = SteamCMDParser()
    #expect(p.feed("Logging in user 'bob' to Steam Public...FAILED (Invalid Password)\n") == [.loginFailed("Invalid Password")])
    #expect(p.feed("ERROR! Download item 1 failed (Failure).\n") == [.error("Download item 1 failed (Failure).")])
    #expect(p.feed("Please confirm the login in the Steam Mobile app on your phone.\n") == [.needsMobileConfirm])
}
