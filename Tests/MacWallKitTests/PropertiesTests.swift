import Foundation
import Testing
@testable import MacWallKit

private let json = """
{"schemecolor":{"order":0,"text":"ui_browse_properties_scheme_color","type":"color","value":"0.1 0.2 0.3"},
 "speed":{"order":2,"text":"<b>Speed</b>","type":"slider","min":0,"max":10,"fraction":true,"value":2},
 "count":{"order":3,"text":"Count","type":"slider","min":1,"max":5,"value":3},
 "showclock":{"order":1,"text":"Show clock","type":"bool","value":true},
 "clockstyle":{"order":4,"text":"Clock style","type":"combo","condition":"showclock.value == true",
               "options":[{"label":"Digital","value":"1"},{"label":"Analog","value":"2"}],"value":"1"},
 "title":{"order":5,"text":"Title","type":"textinput","value":"hi"},
 "note":{"order":6,"text":"Just a note","type":"text"},
 "bg":{"order":7,"text":"Background","type":"file"}}
"""

@Test func parsesPropertyTypesInOrder() {
    let p = WallpaperProperties(json: json)
    #expect(p.items.map(\.key) == ["schemecolor", "showclock", "speed", "count", "clockstyle", "title", "note", "bg"])
    #expect(p.items.map(\.kind) == [.color, .bool, .slider, .slider, .combo, .textinput, .text, .other])
    #expect(p.items[0].label == "Scheme color")
    #expect(p.items[2].label == "Speed")
    #expect(p.items[2].step == 0.1)
    #expect(p.items[3].step == 1)
    #expect(p.items[4].options.map(\.label) == ["Digital", "Analog"])
    #expect(p.hasEditable)
    #expect(!WallpaperProperties(json: "{}").hasEditable)
}

@Test func mergesOverridesIntoValues() throws {
    let p = WallpaperProperties(json: json)
    let merged = try JSONSerialization.jsonObject(with: Data(p.mergedJSON(["speed": 7.5, "unknown": 1]).utf8)) as! [String: [String: Any]]
    #expect(merged["speed"]?["value"] as? Double == 7.5)
    #expect(merged["speed"]?["max"] as? Int == 10)
    #expect(merged["count"]?["value"] as? Int == 3)
    #expect(merged["unknown"] == nil)
    let change = try JSONSerialization.jsonObject(with: Data(p.changeJSON(key: "showclock", value: false).utf8)) as! [String: [String: Any]]
    #expect(change.keys.sorted() == ["showclock"])
    #expect(change["showclock"]?["value"] as? Bool == false)
    #expect(change["showclock"]?["type"] as? String == "bool")
}

@Test func evaluatesConditions() {
    let p = WallpaperProperties(json: json)
    #expect(p.visible(p.values([:])).map(\.key).contains("clockstyle"))
    #expect(!p.visible(p.values(["showclock": false])).map(\.key).contains("clockstyle"))
}

@Test func parsesColors() {
    #expect(WallpaperProperties.rgb("0.5 0 1") == [0.5, 0, 1])
    #expect(WallpaperProperties.rgb("255 0 0") == [1, 0, 0])
    #expect(WallpaperProperties.colorString([1, 0.25, 0]) == "1.00000 0.25000 0.00000")
}
