// Save doctor (ModKit/SaveGames.swift): synthetic SE saves in the UESP layout, uncompressed and LZ4.
import Foundation
import Compression

func makeSave(plugins: [String], light: [String], compression: Int, player: String = "Tester") -> Data {
    func u16(_ v: Int) -> Data { Data([UInt8(v & 0xff), UInt8(v >> 8 & 0xff)]) }
    func u32(_ v: Int) -> Data { Data((0..<4).map { UInt8(v >> (8 * $0) & 0xff) }) }
    func ws(_ s: String) -> Data { let b = s.data(using: .utf8)!; return u16(b.count) + b }
    var h = u32(12) + u32(7) + ws(player) + u32(5) + ws("Whiterun") + ws("001.12.27") + ws("NordRace") + u16(0) + Data(count: 8)
    h += u32(0x9E3BE0C0) + u32(0x01DD5EEC)               // FILETIME 2026-10-18 (any valid value)
    h += u32(2) + u32(1) + u16(compression)              // 2×1 screenshot
    var lists = Data([UInt8(plugins.count)]); for p in plugins { lists += ws(p) }
    lists += u16(light.count); for p in light { lists += ws(p) }
    var body = Data([78]) + u32(lists.count) + lists + Data(repeating: 0xAB, count: 4096)   // rest of the save
    let raw = body.count
    if compression == 2 {
        var out = Data(count: raw + 1024)
        let n = out.withUnsafeMutableBytes { d in body.withUnsafeBytes { s in
            compression_encode_buffer(d.bindMemory(to: UInt8.self).baseAddress!, raw + 1024, s.bindMemory(to: UInt8.self).baseAddress!, raw, nil, COMPRESSION_LZ4_RAW) } }
        body = out.prefix(n)
    }
    return "TESV_SAVEGAME".data(using: .ascii)! + u32(h.count) + h + Data(count: 2 * 1 * 4) + u32(raw) + u32(body.count) + body
}

func saveTests() {
    section("save doctor")
    let f = Fixture("saves")
    let k = f.kit
    let dir = k.savesDir
    try? fm.createDirectory(at: dir.appendingPathComponent("Profile B"), withIntermediateDirectories: true)
    let full = ["Skyrim.esm", "Update.esm", "ModA.esp", "Gone.esp", "OffMod.esp"], light = ["Lite.esl", "Off.esl"]
    try! makeSave(plugins: full, light: light, compression: 0).write(to: dir.appendingPathComponent("Save1.ess"))
    try! makeSave(plugins: full, light: light, compression: 2, player: "Lz").write(to: dir.appendingPathComponent("Profile B/Save2.ess"))
    try! Data("junk".utf8).write(to: dir.appendingPathComponent("Broken.ess"))
    let a = try! SaveReader.read(dir.appendingPathComponent("Save1.ess"))
    check(a.player == "Tester" && a.level == 5 && a.location == "Whiterun" && a.race == "NordRace" && a.saveNumber == 7 && a.formVersion == 78, "header fields")
    check(a.plugins == full && a.lightPlugins == light, "plugin lists (\(a.plugins), \(a.lightPlugins))")
    let b = try! SaveReader.read(dir.appendingPathComponent("Profile B/Save2.ess"))
    check(b.player == "Lz" && b.plugins == full && b.lightPlugins == light, "LZ4-compressed save")
    check((try? SaveReader.read(dir.appendingPathComponent("Broken.ess"))) == nil, "broken save refused, no crash")
    check(Set(k.saveFiles().map(\.lastPathComponent)) == ["Save1.ess", "Save2.ess", "Broken.ess"], "saves found, profile subfolders included")

    // the profile: ModA + Lite active; OffMod's mod disabled; Off.esl installed but inactive; Gone.esp nowhere
    _ = f.addMod("Mod A", ["ModA.esp": "a", "Lite.esl": "l", "Off.esl": "o"])
    let off = f.addMod("Off Mod", ["OffMod.esp": "x"])
    var p = try! k.currentProfile()
    p.mods[p.mods.firstIndex { $0.id == off.id }!].enabled = false
    p.loadOrder = [LoadOrderEntry(name: "ModA.esp", active: true), LoadOrderEntry(name: "Lite.esl", active: true), LoadOrderEntry(name: "Off.esl", active: false)]
    try! k.saveProfile(p); try! k.deploy()
    write(f.game.appendingPathComponent("Data/Skyrim.esm"), "TES4"); write(f.game.appendingPathComponent("Data/Update.esm"), "TES4")
    let c = k.checkSave(a)
    check(c.missing == ["Gone.esp"], "missing plugin found (\(c.missing))")
    check(Set(c.fixable.map(\.plugin)) == ["OffMod.esp", "Off.esl"], "installed-but-off plugins are fixable (\(c.fixable.map(\.plugin)))")
    check(c.fixable.contains { $0.fix == .enableMod(id: off.id, plugin: "OffMod.esp") }, "disabled mod providing it is named")
    try! k.fixSave(c)
    let q = try! k.currentProfile()
    check(q.mods.first { $0.id == off.id }!.enabled && q.loadOrder.contains { $0.name == "Off.esl" && $0.active } && q.loadOrder.contains { $0.name == "OffMod.esp" && $0.active },
          "fix turns on the mod and its plugins")
}

func pluginLockTests() {
    section("plugin position locks")
    func e(_ n: String) -> LoadOrderEntry { LoadOrderEntry(name: n, active: true) }
    let before = ["A.esp", "B.esp", "C.esp", "D.esp", "E.esp"].map(e)
    let sorted = ["E.esp", "D.esp", "C.esp", "B.esp", "A.esp"].map(e)
    check(LoadOrder.keepLocked(before: before, sorted: sorted, locked: []).map(\.name) == sorted.map(\.name), "no locks: sorted order")
    let r = LoadOrder.keepLocked(before: before, sorted: sorted, locked: ["b.esp", "e.esp"]).map(\.name)
    check(r == ["D.esp", "B.esp", "C.esp", "A.esp", "E.esp"], "locked plugins stay at their slots, the rest sorted around them (\(r))")
    let f = Fixture("locks")
    try! f.kit.setPluginLocked("Mod.ESP", true)
    check(f.kit.lockedPlugins() == ["mod.esp"], "lock stored in the profile")
    try! f.kit.setPluginLocked("mod.esp", false)
    check(f.kit.lockedPlugins().isEmpty && (try! f.kit.currentProfile()).lockedPlugins == nil, "unlock clears it")
}

func ansiTests() {
    section("engine output cleanup")
    check(ModKit.stripANSI("Downloading (75/116) - 4.2GB remaining\u{1B}[K") == "Downloading (75/116) - 4.2GB remaining", "erase-line code removed")
    check(ModKit.stripANSI("\u{1B}[32mOK\u{1B}[0m done") == "OK done", "colours removed")
    check(ModKit.stripANSI("\u{1B}]0;title\u{07}text") == "text", "window title sequence removed")
    check(ModKit.stripANSI("plain") == "plain", "plain text untouched")
}

func lootRuleTests() {
    section("LOOT rules (userlist)")
    let f = Fixture("lootrules")
    let k = f.kit
    try! k.setLoadAfter("Patch.esp", after: ["Base.esp", "Other's Mod.esp", "Base.esp"])
    try! k.setLoadAfter("Z.esp", after: ["A.esm"])
    check(k.lootRules() == ["Patch.esp": ["Base.esp", "Other's Mod.esp"], "Z.esp": ["A.esm"]], "rules round-trip, duplicates dropped, quotes escaped (\(k.lootRules()))")
    let y = (try? String(contentsOf: k.lootUserlistURL, encoding: .utf8)) ?? ""
    check(y.contains("  - name: 'Patch.esp'\n    after:\n      - 'Base.esp'\n      - 'Other''s Mod.esp'\n"), "LOOT userlist YAML")
    try! k.setLoadAfter("Patch.esp", after: [])
    check(k.lootRules() == ["Z.esp": ["A.esm"]], "rule removed")
    try! k.setLoadAfter("Z.esp", after: [])
    check(k.lootRules().isEmpty && y.hasPrefix("# Written by SkyrimMT"), "empty userlist stays valid")
}

func lightCandidateTests() {
    section("light-plugin (ESL) candidates")
    func record(_ type: String, _ formID: UInt32) -> Data {
        var d = Data(type.utf8); d.append(contentsOf: le32(4)); d.append(contentsOf: le32(0)); d.append(contentsOf: le32(formID)); d.append(Data(count: 8)); d.append(Data(count: 4)); return d
    }
    func group(_ inner: Data) -> Data {
        var d = Data("GRUP".utf8); d.append(contentsOf: le32(UInt32(24 + inner.count))); d.append(Data(count: 16)); d.append(inner); return d
    }
    // pluginBytes ends with a bare "GRUP" marker standing in for "the rest of a plugin" — drop it, real records follow
    func plug(_ masters: [String], _ v: Float) -> Data { Data(pluginBytes(flags: 0, masters: masters, version: v).dropLast(4)) }
    let f = Fixture("light")
    let k = f.kit
    try! pluginBytes(flags: 1, masters: []).write(to: f.game.appendingPathComponent("Data/Skyrim.esm"))
    // own index = 1 (one master): own records are 0x01xxxxxx; overrides of Skyrim.esm are 0x00xxxxxx
    let plugins: [String: Data] = [
        "Good.esp": plug(["Skyrim.esm"], 1.70) + group(record("MISC", 0x0100_0801) + record("WEAP", 0x0100_0FFF) + record("MISC", 0x0001_2345)),
        "LowIDs171.esp": plug(["Skyrim.esm"], 1.71) + group(record("MISC", 0x0100_0010)),
        "LowIDs170.esp": plug(["Skyrim.esm"], 1.70) + group(record("MISC", 0x0100_0010)),
        "NewCell.esp": plug(["Skyrim.esm"], 1.70) + group(record("CELL", 0x0100_0900)),
        "Master.esp": plug(["Skyrim.esm"], 1.70) + group(record("MISC", 0x0100_0900)),
        "Child.esp": plug(["Skyrim.esm", "Master.esp"], 1.70),
    ]
    let tmp = f.home.appendingPathComponent("incoming/light"); try! fm.createDirectory(at: tmp, withIntermediateDirectories: true)
    for (n, d) in plugins { try! d.write(to: tmp.appendingPathComponent(n)) }
    _ = try! k.addMod(name: "Plugins", from: tmp)
    try! k.deploy()
    var p = try! k.currentProfile(); p.loadOrder = plugins.keys.sorted().map { LoadOrderEntry(name: $0, active: true) }; try! k.saveProfile(p); try! k.deploy()
    let c = Dictionary(uniqueKeysWithValues: k.lightCandidates(gameVersion: "1.7.104").map { ($0.plugin, $0) })
    check(c["Good.esp"]?.reason == nil && c["Good.esp"]?.newRecords == 2, "new IDs 0x801–0xFFF: can be light; overrides not counted (\(String(describing: c["Good.esp"])))")
    check(c["LowIDs171.esp"]?.reason == nil, "header 1.71 on 1.6.1130+: IDs from 0x000 allowed")
    check(c["LowIDs170.esp"]?.reason != nil, "header 1.70 with low IDs: no")
    check(k.lightCandidates(gameVersion: "1.5.97").first { $0.plugin == "LowIDs171.esp" }?.reason != nil, "old game: classic range only")
    check(c["NewCell.esp"]?.reason?.contains("cell") == true, "new cell: excluded")
    check(c["Master.esp"]?.reason?.contains("master") == true, "master of another plugin: excluded")
}

func flagLightTests() {
    section("flag plugins light")
    func record(_ type: String, _ formID: UInt32) -> Data {
        var d = Data(type.utf8); d.append(contentsOf: le32(4)); d.append(contentsOf: le32(0)); d.append(contentsOf: le32(formID)); d.append(Data(count: 8)); d.append(Data(count: 4)); return d
    }
    let f = Fixture("flaglight")
    let k = f.kit
    try! pluginBytes(flags: 1, masters: []).write(to: f.game.appendingPathComponent("Data/Skyrim.esm"))
    let good = Data(pluginBytes(flags: 0, masters: ["Skyrim.esm"], version: 1.70).dropLast(4)) + record("MISC", 0x0100_0900)
    let m = f.addMod("Small Mod", [:])
    try! good.write(to: k.stagingFolder(m).appendingPathComponent("Small.esp"))
    try! k.deploy()
    var p = try! k.currentProfile(); p.loadOrder = [LoadOrderEntry(name: "Small.esp", active: true)]; try! k.saveProfile(p); try! k.deploy()
    check(try! k.flagLight(["Small.esp", "Missing.esp"], gameVersion: "1.7.104") == ["Small.esp"], "only qualifying plugins flagged")
    try! k.deploy()
    let h = try! PluginParser.parse(f.game.appendingPathComponent("Data/Small.esp"))
    check(h.isLight && !h.masterFlag, "deployed copy is light (flags \(String(h.flags, radix: 16)))")
    check(!(try! PluginParser.parse(k.stagingFolder(m).appendingPathComponent("Small.esp"))).isLight, "original untouched")
    check(k.staleLightFlagged().isEmpty, "fresh copy not stale")
    var v2 = good; v2.append(record("MISC", 0x0100_0901))
    try! v2.write(to: k.stagingFolder(m).appendingPathComponent("Small.esp"))
    check(k.staleLightFlagged() == ["Small.esp"], "mod updated → copy stale")
    try! k.removeLightFlagged(["Small.esp"]); try! k.deploy()
    check(!(try! PluginParser.parse(f.game.appendingPathComponent("Data/Small.esp"))).isLight, "removing the copy brings the original back")
}

func saveGuardTests() {
    section("save guard: playthroughs that use a mod")
    let f = Fixture("saveguard")
    let k = f.kit
    write(f.game.appendingPathComponent("Data/Update.esm"), "vanilla update")
    let quest = f.addMod("Quest Mod", ["Quest.esp": "q", "scripts/q.pex": "s"])
    let sharedA = f.addMod("Shared A", ["Shared.esp": "a"])
    let sharedB = f.addMod("Shared B", ["Shared.esp": "b"])
    let tex = f.addMod("Textures", ["textures/t.dds": "t"])
    let upd = f.addMod("Update fix", ["Update.esm": "patched"])
    try! k.deploy()
    check(k.pluginsLost(disabling: [quest.id]) == ["Quest.esp"], "a mod's own plugin would be lost")
    check(k.pluginsLost(disabling: [sharedA.id]).isEmpty, "a plugin another enabled mod also provides stays")
    check(k.pluginsLost(disabling: [sharedA.id, sharedB.id]) == ["Shared.esp"], "…unless both go")
    check(k.pluginsLost(disabling: [tex.id]).isEmpty, "mods without plugins: nothing lost")
    check(k.pluginsLost(disabling: [upd.id]).isEmpty, "the game's own copy of an overridden plugin stays")
    let dir = k.activeSavesFolder
    try! fm.createDirectory(at: dir, withIntermediateDirectories: true)
    func save(_ name: String, _ player: String, _ plugins: [String], ago: Double) {
        let u = dir.appendingPathComponent(name)
        try! makeSave(plugins: ["Skyrim.esm"] + plugins, light: [], compression: 2, player: player).write(to: u)
        try! fm.setAttributes([.modificationDate: Date().addingTimeInterval(-ago)], ofItemAtPath: u.path)
    }
    save("Save3.ess", "Ysolda", ["Quest.esp", "Shared.esp"], ago: 60)
    save("Save2.ess", "Ysolda", ["Old.esp"], ago: 3600)            // an older save of the same character
    save("Save1.ess", "Lydia", ["Shared.esp"], ago: 7200)
    try! fm.createDirectory(at: dir.appendingPathComponent("Other profile"), withIntermediateDirectories: true)
    try! makeSave(plugins: ["Quest.esp"], light: [], compression: 0, player: "Elsewhere").write(to: dir.appendingPathComponent("Other profile/Save9.ess"))
    let pts = k.playthroughs()
    check(pts.map(\.player) == ["Ysolda", "Lydia"], "newest save per character, this profile's folder only (\(pts.map(\.player)))")
    check(k.playthroughRisks(plugins: ["Quest.esp"]).map(\.save.player) == ["Ysolda"], "Quest.esp: Ysolda's playthrough at risk")
    check(k.playthroughRisks(plugins: ["shared.esp"]).count == 2, "case-insensitive; both characters use Shared.esp")
    check(k.playthroughRisks(plugins: ["Old.esp"]).isEmpty, "only the newest save counts (the character moved on)")
    check(k.playthroughRisks(plugins: []).isEmpty, "nothing lost → no risk")
}
