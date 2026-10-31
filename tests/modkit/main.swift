// ModKit test runner (no XCTest with Command Line Tools): tests/modkit/run.sh builds ModKit + this file and runs it.
// Everything happens in throwaway folders under $MODKIT_TEST_DIR (default: build/modkit-test) on the same APFS volume.
//   modkit-tests [all|unit|property|crash|bench]   (bench: 500 mods × 400 files = 200k files)
import Foundation
import Darwin

setvbuf(stdout, nil, _IONBF, 0)
var failures = 0, passes = 0
func check(_ cond: @autoclosure () -> Bool, _ what: String, file: String = #file, line: Int = #line) {
    if cond() { passes += 1 } else { failures += 1; print("  FAIL \(what) (line \(line))") }
}
func section(_ name: String) { print("== \(name)") }

let fm = FileManager.default
let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["MODKIT_TEST_DIR"] ?? fm.currentDirectoryPath + "/build/modkit-test")
func freshDir(_ name: String) -> URL {
    let d = root.appendingPathComponent(name)
    try? fm.removeItem(at: d); try! fm.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}
func write(_ url: URL, _ text: String) {
    try! fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! text.write(to: url, atomically: false, encoding: .utf8)
}
func read(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }

/// Every regular file under dir: lowercased relative path → contents.
func snapshot(_ dir: URL) -> [String: String] {
    var out: [String: String] = [:]
    if let en = fm.enumerator(atPath: dir.path) {
        while let rel = en.nextObject() as? String {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: dir.path + "/" + rel, isDirectory: &isDir), !isDir.boolValue {
                out[rel.lowercased()] = read(dir.appendingPathComponent(rel)) ?? "<unreadable>"
            }
        }
    }
    return out
}

/// plugins.txt where Wine keeps it (users/<u>/AppData/Local/Skyrim Special Edition): ModKit derives My Games from it,
/// so test saves/INIs/crash logs stay inside the fixture (they used to land in the repo's own Documents folder).
func fixturePluginsTxt(_ home: URL) -> URL { home.appendingPathComponent("users/test/AppData/Local/Skyrim Special Edition/plugins.txt") }

struct Fixture {
    let home: URL, game: URL, kit: ModKit
    init(_ name: String) {
        home = freshDir(name)
        game = home.appendingPathComponent("game")
        // vanilla game: exe, a few Data files, plugins
        write(game.appendingPathComponent("SkyrimSE.exe"), "exe")
        write(game.appendingPathComponent("Data/Skyrim - Textures0.bsa"), "vanilla bsa")
        write(game.appendingPathComponent("Data/Textures/Vanilla/rock.dds"), "vanilla rock")
        write(game.appendingPathComponent("Data/Interface/vanilla.swf"), "vanilla swf")
        try? FileManager.default.createDirectory(at: fixturePluginsTxt(home).deletingLastPathComponent(), withIntermediateDirectories: true)
        kit = ModKit(home: home, gameDir: game, pluginsTxt: fixturePluginsTxt(home))
    }
    /// A prepared mod folder (as installer output) with the given files (rel → content).
    func addMod(_ name: String, _ files: [String: String]) -> ModRecord {
        let tmp = home.appendingPathComponent("incoming/\(UUID().uuidString)")
        for (rel, c) in files { write(tmp.appendingPathComponent(rel), c) }
        try! fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        return try! kit.addMod(name: name, from: tmp)
    }
}

/// Expected game folder: vanilla files, overridden by enabled mods in priority order (case-insensitive).
func expected(vanilla: [String: String], profile: Profile, kit: ModKit) -> [String: String] {
    var out = vanilla
    for pm in profile.mods where pm.enabled {
        guard let m = kit.mod(pm.id) else { continue }
        for (rel, c) in snapshot(kit.stagingFolder(m)) {
            let target = rel.hasPrefix("__root__/") ? String(rel.dropFirst(9)) : "data/" + rel
            out[target] = c
        }
    }
    return out
}

// MARK: - synthetic plugins

func pluginBytes(flags: UInt32, masters: [String], author: String = "", version: Float = 1.71, bigField: Bool = false) -> Data {
    var fields = Data()
    func field(_ type: String, _ data: Data) {
        if data.count > 0xFFFF {
            fields.append(contentsOf: Array("XXXX".utf8)); fields.append(contentsOf: le16(4)); fields.append(contentsOf: le32(UInt32(data.count)))
            fields.append(contentsOf: Array(type.utf8)); fields.append(contentsOf: le16(0))
        } else {
            fields.append(contentsOf: Array(type.utf8)); fields.append(contentsOf: le16(UInt16(data.count)))
        }
        fields.append(data)
    }
    var hedr = Data(); hedr.append(contentsOf: le32(version.bitPattern)); hedr.append(contentsOf: le32(10)); hedr.append(contentsOf: le32(0x800))
    field("HEDR", hedr)
    if !author.isEmpty { field("CNAM", Data(author.utf8) + Data([0])) }
    if bigField { field("SNAM", Data(repeating: 0x41, count: 70000) + Data([0])) }
    for m in masters { field("MAST", Data(m.utf8) + Data([0])); field("DATA", Data(count: 8)) }
    var d = Data(Array("TES4".utf8)); d.append(contentsOf: le32(UInt32(fields.count))); d.append(contentsOf: le32(flags))
    d.append(Data(count: 12)); d.append(fields)
    d.append(Data(Array("GRUP".utf8)))   // rest of a real plugin
    return d
}
func le16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xff), UInt8(v >> 8)] }
func le32(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8((v >> (8 * UInt32($0))) & 0xff) } }

// MARK: - unit tests

func unitTests() {
    section("deploy basics")
    let f = Fixture("unit")
    let vanilla = snapshot(f.game)
    let a = f.addMod("Mod A", ["Textures/A/a.dds": "a1", "textures/shared.dds": "fromA", "Interface/vanilla.swf": "A overrides vanilla"])
    let b = f.addMod("Mod B", ["Textures/Shared.dds": "fromB", "Meshes/b.nif": "b1"])
    let skse = f.addMod("SKSE", ["__root__/skse64_loader.exe": "loader", "Scripts/skse.pex": "pex"])
    var r = try! f.kit.deploy()
    var p = try! f.kit.currentProfile()
    check(snapshot(f.game) == expected(vanilla: vanilla, profile: p, kit: f.kit), "deployed == expected")
    check(read(f.game.appendingPathComponent("skse64_loader.exe")) == "loader", "root mod goes to the game folder")
    check(read(f.game.appendingPathComponent("Data/textures/shared.dds")) == "fromB", "later mod wins, case-insensitive")
    check(r.cloned == 6, "all files placed as APFS clones (\(r.cloned))")
    check(r.backedUp == 1, "vanilla file moved aside (\(r.backedUp))")
    let plan = try! f.kit.plan()
    check(plan.conflicts[b.id]?[a.id] == 1, "conflict B over A counted")
    // clone = independent file: editing the deployed copy never changes the staging copy
    let st1 = lstatPath(f.game.path + "/Data/Meshes/b.nif"), st2 = lstatPath(f.kit.stagingFolder(b).path + "/Meshes/b.nif")
    check(st1?.ino != st2?.ino && st1?.mtimeNs == st2?.mtimeNs, "deployed file is a clone (own inode, same mtime)")
    // no-op redeploy
    r = try! f.kit.deploy()
    check(r.cloned == 0 && r.removed == 0 && r.unchanged == 6, "redeploy without changes does nothing (\(r.unchanged))")
    // reorder: A after B
    p.mods = [p.mods[1], p.mods[0], p.mods[2]]; try! f.kit.saveProfile(p)
    r = try! f.kit.deploy()
    check(read(f.game.appendingPathComponent("Data/textures/shared.dds")) == "fromA", "priority change redeploys the winner")
    check(snapshot(f.game) == expected(vanilla: vanilla, profile: p, kit: f.kit), "after reorder == expected")
    // disable A: vanilla swf comes back
    p.mods[1].enabled = false; try! f.kit.saveProfile(p)
    r = try! f.kit.deploy()
    check(read(f.game.appendingPathComponent("Data/Interface/vanilla.swf")) == "vanilla swf", "vanilla file restored when its mod is disabled")
    check(snapshot(f.game) == expected(vanilla: vanilla, profile: p, kit: f.kit), "after disable == expected")
    // user file + drift
    write(f.game.appendingPathComponent("Data/userfile.txt"), "mine")
    check((try! f.kit.deployer.unmanagedFiles()) == ["Data/userfile.txt"], "user file listed as unmanaged")
    check((try! f.kit.deployer.verify()).ok, "verify ok")
    try! fm.removeItem(at: f.game.appendingPathComponent("Data/Meshes/b.nif"))
    var v = try! f.kit.deployer.verify()
    check(v.missing == ["Data/Meshes/b.nif"], "verify reports a deleted file")
    r = try! f.kit.deploy()   // plan unchanged → no fix (verify only reports); a forced redeploy happens when the source changes
    // edited in place outside SkyrimMT (replaced file, new inode): purge must keep it
    try! fm.removeItem(at: f.game.appendingPathComponent("Data/Scripts/skse.pex"))
    write(f.game.appendingPathComponent("Data/Scripts/skse.pex"), "edited by a tool")
    v = try! f.kit.deployer.verify()
    check(v.changed.contains("Data/Scripts/skse.pex"), "verify reports a replaced file")
    r = try! f.kit.purge()
    let after = snapshot(f.game)
    // the edited file is the profile's now: kept in its Overwrite (managed, comes back on the next deploy), and the
    // game folder really is vanilla after "Remove all mods"
    var want = vanilla; want["data/userfile.txt"] = "mine"
    check(after == want, "purge → vanilla + the player's own file")
    check(read(f.kit.stagingFolder(f.kit.mod(f.kit.currentOverwriteID())!).appendingPathComponent("Scripts/skse.pex")) == "edited by a tool", "externally edited file kept in the profile's Overwrite")
    check(r.keptModified.isEmpty, "nothing left behind in the game folder")
    check(!fm.fileExists(atPath: f.game.path + "/Data/Meshes"), "purge removes folders it created")
    check(fm.fileExists(atPath: f.game.path + "/Data/Textures/Vanilla"), "purge keeps vanilla folders")
    _ = skse

    section("plugins")
    let pf = Fixture("plugins")
    let data = pf.game.appendingPathComponent("Data")
    for (n, fl, ms) in [("Skyrim.esm", UInt32(1), [String]()), ("Update.esm", 1, ["Skyrim.esm"]), ("Dawnguard.esm", 1, ["Skyrim.esm", "Update.esm"]),
                        ("ccQDRSSE001-SurvivalMode.esl", 0x201, ["Skyrim.esm"]), ("Big.esm", 1, ["Skyrim.esm"]), ("Light.esp", 0x200, ["Skyrim.esm"]),
                        ("Patch.esp", 0, ["Skyrim.esm", "Big.esm"]), ("NeedsMissing.esp", 0, ["Skyrim.esm", "Gone.esm"])] {
        try! pluginBytes(flags: fl, masters: ms, author: "tester").write(to: data.appendingPathComponent(n))
    }
    try! pluginBytes(flags: 0, masters: [], bigField: true).write(to: data.appendingPathComponent("Huge.esp"))
    try! Data("not a plugin".utf8).write(to: data.appendingPathComponent("Broken.esp"))
    write(pf.game.appendingPathComponent("Skyrim.ccc"), "ccQDRSSE001-SurvivalMode.esl\r\nccNotInstalled.esm\r\n")
    let h = try! PluginParser.parse(data.appendingPathComponent("Patch.esp"))
    check(h.masters == ["Skyrim.esm", "Big.esm"] && h.author == "tester" && abs(h.version - 1.71) < 0.001, "TES4 header: masters, author, version")
    check(try! PluginParser.parse(data.appendingPathComponent("Light.esp")).isLight, "ESL-flagged .esp is light")
    check(!(try! PluginParser.parse(data.appendingPathComponent("Light.esp")).isMaster), "ESL-flagged .esp is not a master")
    check(try! PluginParser.parse(data.appendingPathComponent("Huge.esp")).description.count == 70000, "XXXX large field")
    // plugins.txt: Patch before Big (wrong), NeedsMissing active, Light active; Huge not listed
    let ptxt = fixturePluginsTxt(pf.home)
    try! "# comment\r\n*Patch.esp\r\n*Big.esm\r\n*NeedsMissing.esp\r\n*Light.esp\r\n*Gone.esp\r\n*Big.esm\r\n".data(using: .windowsCP1252)!.write(to: ptxt)
    var lo = LoadOrder.load(dataDir: data, gameDir: pf.game, pluginsTxt: ptxt)
    check(lo.implicit == ["Skyrim.esm", "Update.esm", "Dawnguard.esm", "ccQDRSSE001-SurvivalMode.esl"], "implicit: base masters present + Skyrim.ccc entries present (\(lo.implicit))")
    check(lo.entries.map(\.name) == ["Patch.esp", "Big.esm", "NeedsMissing.esp", "Light.esp", "Broken.esp", "Huge.esp"], "order from plugins.txt, gone/duplicates dropped, new appended (\(lo.entries.map(\.name)))")
    let kinds = Set(lo.validate().map(\.kind))
    check(kinds.contains(.missingMaster), "missing master detected")
    check(kinds.contains(.nonMasterBeforeMaster), "ESP before ESM detected")
    check(kinds.contains(.masterAfterDependent), "master after dependent detected")
    check(kinds.contains(.unreadable), "broken plugin reported")
    lo.basicSort()
    check(lo.entries.map(\.name).firstIndex(of: "Big.esm")! < lo.entries.map(\.name).firstIndex(of: "Patch.esp")!, "basic sort: master first")
    check(!Set(lo.validate().map(\.kind)).contains(.masterAfterDependent), "basic sort fixes order")
    try! lo.write(to: ptxt)
    let back = PluginsTxt.read(ptxt)
    check(back.first?.name == "Big.esm" && back.first?.active == true, "plugins.txt round-trip")
    check(!back.contains { $0.name == "Skyrim.esm" || $0.name.hasPrefix("cc") }, "implicit plugins not written")
    let raw = try! Data(contentsOf: ptxt)
    check(String(data: raw, encoding: .windowsCP1252)!.contains("\r\n"), "CRLF line endings")

    section("new plugins start active")
    let np = Fixture("newplugins")
    try! pluginBytes(flags: 1, masters: []).write(to: np.game.appendingPathComponent("Data/Skyrim.esm"))
    let tmpP = np.home.appendingPathComponent("incoming/p"); try! fm.createDirectory(at: tmpP, withIntermediateDirectories: true)
    try! pluginBytes(flags: 0, masters: ["Skyrim.esm"]).write(to: tmpP.appendingPathComponent("NewMod.esp"))
    _ = try! np.kit.addMod(name: "NewMod", from: tmpP)
    try! np.kit.deploy()
    check(PluginsTxt.read(np.kit.pluginsTxt) == [LoadOrderEntry(name: "NewMod.esp", active: true)], "new mod's plugin active after deploy")
    var lo2 = np.kit.loadOrder(); lo2.entries[0].active = false; try! lo2.write(to: np.kit.pluginsTxt)
    var pp = try! np.kit.currentProfile(); pp.loadOrder = lo2.entries; try! np.kit.saveProfile(pp)
    try! np.kit.deploy()
    check(PluginsTxt.read(np.kit.pluginsTxt).first?.active == false, "a plugin the player turned off stays off")

    section("tools → Overwrite capture")
    let tf = Fixture("tools")
    let tv = snapshot(tf.game)
    _ = tf.addMod("Body", ["meshes/body.nif": "body v1", "textures/body.dds": "tex"])
    try! tf.kit.deploy()
    write(tf.game.appendingPathComponent("Data/mine.txt"), "player's own file")   // before the tool: stays unmanaged
    let snap = try! tf.kit.beginToolRun()
    // the "tool" writes new output and rebuilds a deployed mesh (replacing the file)
    write(tf.game.appendingPathComponent("Data/meshes/out/outfit.nif"), "built outfit")
    try! fm.removeItem(at: tf.game.appendingPathComponent("Data/meshes/body.nif"))
    write(tf.game.appendingPathComponent("Data/meshes/body.nif"), "body rebuilt")
    let captured = try! tf.kit.finishToolRun(snap)
    check(captured == ["Data/meshes/body.nif", "Data/meshes/out/outfit.nif"], "captured new + changed files (\(captured))")
    let ow = tf.kit.mod(tf.kit.currentOverwriteID())!
    check(snapshot(tf.kit.stagingFolder(ow)) == ["meshes/out/outfit.nif": "built outfit", "meshes/body.nif": "body rebuilt"], "Overwrite staging holds the tool output")
    check(read(tf.game.appendingPathComponent("Data/meshes/body.nif")) == "body rebuilt" && read(tf.game.appendingPathComponent("Data/meshes/out/outfit.nif")) == "built outfit",
          "game folder shows the tool output")
    check((try! tf.kit.deployer.verify()).ok, "everything managed again after capture")
    check((try! tf.kit.deployer.unmanagedFiles()) == ["Data/mine.txt"], "player's own file not captured")
    check(try! tf.kit.currentProfile().mods.last?.id == tf.kit.currentOverwriteID(), "Overwrite is last (wins)")
    _ = tf.addMod("Later mod", ["meshes/body.nif": "later"])
    check(try! tf.kit.currentProfile().mods.last?.id == tf.kit.currentOverwriteID(), "Overwrite stays last after installing another mod")
    try! tf.kit.deploy()
    check(read(tf.game.appendingPathComponent("Data/meshes/body.nif")) == "body rebuilt", "Overwrite still wins")
    try! tf.kit.purge()
    var tvWant = tv; tvWant["data/mine.txt"] = "player's own file"
    check(snapshot(tf.game) == tvWant, "purge → vanilla + player's file")

    section("tool output folder → output mod (TexGen / DynDOLOD / xLODGen)")
    let lf = Fixture("tooloutput")
    _ = lf.addMod("Trees", ["textures/tree.dds": "tree"])
    try! lf.kit.deploy()
    let te = ToolEntry(name: "TexGen", exe: "/x/TexGenx64.exe", arguments: "-sse", outputMod: "TexGen Output")
    let (s1, a1) = try! lf.kit.beginToolRun(te)
    check(a1.count == 2 && a1[0] == "-sse" && a1[1].hasPrefix("-o:Z:\\") && a1[1].hasSuffix("\\"), "arguments: game mode + -o: output folder (\(a1))")
    write(s1.outputDir!.appendingPathComponent("textures/lod/tree_lod.dds"), "lod v1")
    let r1 = try! lf.kit.finishToolRunCounting(s1)
    check(r1.output == 1 && r1.captured.isEmpty, "output folder became the output mod, nothing in Overwrite (\(r1))")
    check(read(lf.game.appendingPathComponent("Data/textures/lod/tree_lod.dds")) == "lod v1", "output deployed")
    check((try! lf.kit.deployer.verify()).ok, "game folder managed after the run")
    let outMod = lf.kit.mods.first { $0.name == "TexGen Output" }!
    var olp = try! lf.kit.currentProfile()
    olp.mods[olp.mods.firstIndex { $0.id == outMod.id }!].enabled = false; try! lf.kit.saveProfile(olp)
    let (s2, _) = try! lf.kit.beginToolRun(te)
    write(s2.outputDir!.appendingPathComponent("textures/lod/other.dds"), "lod v2")
    let r2 = try! lf.kit.finishToolRunCounting(s2)
    let again = lf.kit.mods.filter { $0.name == "TexGen Output" }
    check(r2.output == 1 && again.count == 1 && again[0].id == outMod.id, "re-run replaces the same mod")
    check(snapshot(lf.kit.stagingFolder(again[0])) == ["textures/lod/other.dds": "lod v2"], "old generation's files gone")
    check(try! lf.kit.currentProfile().mods.first { $0.id == outMod.id }?.enabled == false, "player's on/off choice kept")
    let (s3, _) = try! lf.kit.beginToolRun(te)
    let r3 = try! lf.kit.finishToolRunCounting(s3)
    check(r3.output == 0 && snapshot(lf.kit.stagingFolder(again[0])).count == 1 && !fm.fileExists(atPath: s3.outputDir!.path),
          "a run that wrote nothing keeps the last output")
    let (s4, a4) = try! lf.kit.beginToolRun(ToolEntry(name: "SSEEdit", exe: "/x/SSEEdit.exe"))
    check(a4.isEmpty && s4.outputDir == nil, "tools without an output mod get no -o:")
    let dynMod = lf.addMod("DynDOLOD Standalone", ["DynDOLOD/DynDOLODx64.exe": "exe", "DynDOLOD/TexGenx64.exe": "exe2", "DynDOLOD/Edit Scripts/a.pas": "s"])
    let dynExe = lf.kit.stagingFolder(dynMod).appendingPathComponent("DynDOLOD/TexGenx64.exe")
    let ent = try! lf.kit.toolEntry(preset: toolPresets.first { $0.name == "TexGen" }, exe: dynExe)
    check(ent.exe.hasPrefix(lf.home.appendingPathComponent("tools").path) && read(URL(fileURLWithPath: ent.exe)) == "exe2"
          && read(URL(fileURLWithPath: ent.exe).deletingLastPathComponent().appendingPathComponent("Edit Scripts/a.pas")) == "s",
          "LOD tool runs from a clone outside the mods folder (\(ent.exe))")
    write(URL(fileURLWithPath: ent.exe).deletingLastPathComponent().appendingPathComponent("cache.txt"), "tool cache")
    let ent2 = try! lf.kit.toolEntry(preset: toolPresets.first { $0.name == "DynDOLOD" }, exe: lf.kit.stagingFolder(dynMod).appendingPathComponent("DynDOLOD/DynDOLODx64.exe"))
    check(read(URL(fileURLWithPath: ent2.exe).deletingLastPathComponent().appendingPathComponent("cache.txt")) == "tool cache"
          && ent2.outputMod == "DynDOLOD Output" && ent2.arguments == "-sse", "second tool from the same folder reuses the clone")
    check(read(lf.kit.stagingFolder(dynMod).appendingPathComponent("DynDOLOD/cache.txt")) == nil, "mod's own folder untouched")
    let xe = try! lf.kit.toolEntry(preset: toolPresets.first { $0.name == "SSEEdit" }, exe: dynExe)
    check(xe.exe == dynExe.path, "other tools run where they are")

    section("files mods write while playing")
    let gf = Fixture("generated")
    let gv = snapshot(gf.game)
    _ = gf.addMod("Plugin mod", ["SKSE/Plugins/thing.dll": "dll"])
    try! gf.kit.deploy()
    write(gf.game.appendingPathComponent("Data/SKSE/Plugins/thing.ini"), "written by the plugin")   // inside a folder we created
    write(gf.game.appendingPathComponent("Data/player.txt"), "the player's own file")                // elsewhere
    // a mod file that lost its deploy record (2026-10-18 incident): old archive date → not "generated"
    let orphan = gf.game.appendingPathComponent("Data/SKSE/Plugins/orphan.dll"); write(orphan, "old mod file")
    try! fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_600_000_000)], ofItemAtPath: orphan.path)
    write(gf.game.appendingPathComponent("Data/ShaderCache/Lighting/abc.bin"), "compiled")             // Community Shaders cache
    check((try! gf.kit.generatedFiles()) == ["Data/SKSE/Plugins/thing.ini", "Data/ShaderCache/Lighting/abc.bin"].sorted() || (try! gf.kit.generatedFiles()).sorted() == ["Data/SKSE/Plugins/thing.ini", "Data/ShaderCache/Lighting/abc.bin"].sorted(),
          "generated files found (incl. the shader cache); player's file and an orphaned old mod file not (\((try? gf.kit.generatedFiles()) ?? []))")
    try! fm.removeItem(at: gf.game.appendingPathComponent("Data/ShaderCache"))
    try! fm.removeItem(at: orphan)
    try! gf.kit.purge()
    var gwant = gv; gwant["data/player.txt"] = "the player's own file"
    check(snapshot(gf.game) == gwant, "purge removes generated files from the game, keeps the player's")
    check(read(gf.kit.stagingFolder(gf.kit.mod(gf.kit.currentOverwriteID())!).appendingPathComponent("SKSE/Plugins/thing.ini")) == "written by the plugin", "generated file kept in Overwrite")
    try! gf.kit.deploy()
    check(read(gf.game.appendingPathComponent("Data/SKSE/Plugins/thing.ini")) == "written by the plugin", "redeploy brings it back")

    section("macOS compatibility: fake cubemaps")
    func dds(cube: Bool, dx10: Bool) -> Data {
        var d = Data("DDS ".utf8); d.append(Data(count: 144))
        func put(_ v: UInt32, _ at: Int) { for i in 0..<4 { d[at + i] = UInt8((v >> (8 * UInt32(i))) & 0xff) } }
        put(124, 4); put(32, 12); put(128, 16)
        if dx10 { d.replaceSubrange(84..<88, with: Data("DX10".utf8)); put(98, 128); put(3, 132); put(cube ? 4 : 0, 136); put(1, 140) }
        else if cube { put(0xFE00, 112) }
        return d
    }
    let cmf = Fixture("cubemaps")
    let cm = cmf.home.appendingPathComponent("incoming/cm")
    for (n, d) in [("textures/cubemaps/eyecubemap.dds", dds(cube: false, dx10: true)), ("textures/cubemaps/real.dds", dds(cube: true, dx10: true)),
                   ("textures/cubemaps/legacy.dds", dds(cube: true, dx10: false)), ("textures/other/flat.dds", dds(cube: false, dx10: true))] {
        try! fm.createDirectory(at: cm.appendingPathComponent(n).deletingLastPathComponent(), withIntermediateDirectories: true)
        try! d.write(to: cm.appendingPathComponent(n))
    }
    _ = try! cmf.kit.addMod(name: "Eyes", from: cm)
    let cplan = try! cmf.kit.plan()
    check(cplan.hidden.keys.sorted() == ["Data/textures/cubemaps/eyecubemap.dds"], "2D texture in cubemaps/ hidden (\(cplan.hidden.keys.sorted()))")
    check(cplan.files["data/textures/cubemaps/real.dds"] != nil && cplan.files["data/textures/cubemaps/legacy.dds"] != nil && cplan.files["data/textures/other/flat.dds"] != nil,
          "real cubemaps (DX10 + legacy) and 2D textures elsewhere still deploy")

    section("profiles")
    let pr = Fixture("profiles")
    let pv = snapshot(pr.game)
    _ = pr.addMod("One", ["one.txt": "1"])
    _ = pr.addMod("Two", ["two.txt": "2"])
    try! pr.kit.deploy()
    try! pr.kit.createProfile("Light")
    _ = try! pr.kit.switchProfile(to: "Light")
    check(snapshot(pr.game) == pv, "switch to an empty profile → vanilla")
    var lp = pr.kit.profile("Light")!; lp.mods[1].enabled = true; try! pr.kit.saveProfile(lp)
    try! pr.kit.deploy()
    check(read(pr.game.appendingPathComponent("Data/two.txt")) == "2" && read(pr.game.appendingPathComponent("Data/one.txt")) == nil, "profile mods deployed")
    _ = try! pr.kit.switchProfile(to: "Default")
    check(read(pr.game.appendingPathComponent("Data/one.txt")) == "1", "back to Default")
    check(try! !pr.kit.isDirty(), "not dirty after deploy")
    var dp = try! pr.kit.currentProfile(); dp.mods[0].enabled = false; try! pr.kit.saveProfile(dp)
    check(try! pr.kit.isDirty(), "dirty after a change")
}

// MARK: - property tests (random mod sets)

struct RNG { var s: UInt64; mutating func next() -> UInt64 { s ^= s << 13; s ^= s >> 7; s ^= s << 17; return s }
    mutating func int(_ n: Int) -> Int { Int(next() % UInt64(n)) } }

func propertyTests(rounds: Int = 25, seed: UInt64 = 0x5EED) {
    section("property: random mods / priorities / toggles (\(rounds) rounds)")
    var rng = RNG(s: seed)
    let f = Fixture("property")
    let vanilla = snapshot(f.game)
    let pool = (0..<40).map { "Textures/T\($0 % 7)/f\($0).dds" } + ["Interface/vanilla.swf", "Textures/Vanilla/rock.dds", "Meshes/m.nif", "__root__/root.dll"]
    for i in 0..<8 {
        var files: [String: String] = [:]
        for _ in 0..<(3 + rng.int(10)) {
            var p = pool[rng.int(pool.count)]
            if rng.int(3) == 0 { p = p.uppercased().replacingOccurrences(of: "__ROOT__", with: "__root__") }   // case variants
            files[p] = "mod\(i):\(p)"
        }
        _ = f.addMod("Mod \(i)", files)
    }
    for round in 0..<rounds {
        var p = try! f.kit.currentProfile()
        for _ in 0..<3 { let a = rng.int(p.mods.count), b = rng.int(p.mods.count); p.mods.swapAt(a, b) }
        for j in p.mods.indices where rng.int(4) == 0 { p.mods[j].enabled.toggle() }
        try! f.kit.saveProfile(p)
        try! f.kit.deploy()
        check(snapshot(f.game) == expected(vanilla: vanilla, profile: p, kit: f.kit), "round \(round): game folder == winners")
        check((try! f.kit.deployer.verify()).ok, "round \(round): verify ok")
    }
    try! f.kit.purge()
    check(snapshot(f.game) == vanilla, "purge after random rounds → vanilla")
}

// MARK: - crash recovery

func crashTests(trials: Int = 30, seed: UInt64 = 0xC0FFEE) {
    section("crash mid-deploy → recovery (\(trials) trials)")
    var rng = RNG(s: seed)
    for t in 0..<trials {
        let f = Fixture("crash")
        let vanilla = snapshot(f.game)
        for i in 0..<4 {
            var files: [String: String] = [:]
            for k in 0..<6 { files["Textures/C\(k % 3)/\(i)-\(k).dds"] = "m\(i)k\(k)"; files["Textures/C\(k % 3)/shared\(k).dds"] = "m\(i)" }
            files["Interface/vanilla.swf"] = "m\(i) swf"
            _ = f.addMod("M\(i)", files)
        }
        var p = try! f.kit.currentProfile()
        p.mods[0].enabled = false; try! f.kit.saveProfile(p)
        try! f.kit.deploy()
        // change, then crash after k ops
        p.mods[0].enabled = true; p.mods[2].enabled = false; p.mods.swapAt(1, 3); try! f.kit.saveProfile(p)
        f.kit.deployer.failAfterOps = 1 + rng.int(25)
        var crashed = false
        do { try f.kit.deploy() } catch DeployError.simulatedCrash { crashed = true } catch { check(false, "unexpected \(error)") }
        f.kit.deployer.failAfterOps = nil
        // a new process starts: recovery, then the same deploy
        let kit2 = ModKit(home: f.home, gameDir: f.game, pluginsTxt: fixturePluginsTxt(f.home))
        check(!crashed || kit2.deployer.needsRecovery, "trial \(t): journal left behind after crash")
        try! kit2.deploy()
        check(!kit2.deployer.needsRecovery, "trial \(t): journal cleared")
        check(snapshot(f.game) == expected(vanilla: vanilla, profile: p, kit: kit2), "trial \(t): state correct after recovery")
        try! kit2.purge()
        check(snapshot(f.game) == vanilla, "trial \(t): purge → vanilla")
        // crash during purge
        try! kit2.deploy()
        kit2.deployer.failAfterOps = 1 + rng.int(20)
        _ = try? kit2.purge()
        kit2.deployer.failAfterOps = nil
        let kit3 = ModKit(home: f.home, gameDir: f.game, pluginsTxt: fixturePluginsTxt(f.home))
        try! kit3.purge()
        check(snapshot(f.game) == vanilla, "trial \(t): purge after crashed purge → vanilla")
    }
}

// MARK: - benchmark

func bench(mods: Int = 500, filesPerMod: Int = 400) {
    section("benchmark: \(mods) mods × \(filesPerMod) files")
    let f = Fixture("bench")
    let t0 = Date()
    for i in 0..<mods {
        let tmp = f.home.appendingPathComponent("incoming/m\(i)")
        var made = Set<String>()
        for k in 0..<filesPerMod {
            // 10% of paths shared between neighbouring mods (conflicts)
            let rel = k % 10 == 0 ? "textures/shared/\(i % 50)/\(k).dds" : "textures/m\(i)/sub\(k % 20)/\(k).dds"
            let u = tmp.appendingPathComponent(rel)
            let dir = u.deletingLastPathComponent().path
            if made.insert(dir).inserted { try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true) }
            check(fm.createFile(atPath: u.path, contents: Data("x".utf8)), "bench file created")
        }
        _ = try! f.kit.addMod(name: "Bench \(i)", from: tmp)
    }
    print(String(format: "  staging created in %.1f s", Date().timeIntervalSince(t0)))
    let p1 = Date(); let plan = try! f.kit.plan(); print(String(format: "  plan: %d files, %.2f s", plan.files.count, Date().timeIntervalSince(p1)))
    let r1 = try! f.kit.deploy(); print(String(format: "  first deploy: %.2f s (cloned %d, linked %d)", r1.seconds, r1.cloned, r1.linked))
    let r2 = try! f.kit.deploy(); print(String(format: "  no-change deploy: %.2f s (unchanged %d)", r2.seconds, r2.unchanged))
    let v0 = Date(); let v = try! f.kit.deployer.verify(); print(String(format: "  verify: %.2f s (ok=%@)", Date().timeIntervalSince(v0), v.ok ? "yes" : "no"))
    var p = try! f.kit.currentProfile(); p.mods[10].enabled = false; p.mods.swapAt(20, 30); try! f.kit.saveProfile(p)
    let r3 = try! f.kit.deploy(); print(String(format: "  small change deploy: %.2f s (+%d −%d)", r3.seconds, r3.cloned, r3.removed))
    let r4 = try! f.kit.purge(); print(String(format: "  purge: %.2f s (removed %d)", r4.seconds, r4.removed))
    check(plan.files.count > mods * filesPerMod * 85 / 100, "benchmark plans ~\(mods * filesPerMod) files (\(plan.files.count))")
    // PLAN §8.8 hoped for < 10 s; measured APFS cost per new file (~67 µs with 8 threads for clonefile, ~260 µs for
    // link) makes ~180k files filesystem-bound at ~18 s on the M1 Max (docs/m3-m4-report.md). Guard against regressions:
    check(r1.seconds < 40, "first deploy of \(plan.files.count) files under 40 s (\(Int(r1.seconds)) s)")
    check(r2.seconds < 5, "no-change deploy under 5 s")
    try? fm.removeItem(at: f.home)
}

let mode = CommandLine.arguments.dropFirst().first ?? "all"
// tests never see an installed SkyrimMT's built-in mods (ModKit falls back to /Applications for CLI tools)
let noBuiltins = freshDir("no-builtins")
setenv("SKYRIMMT_BUILTIN", noBuiltins.path, 1)
if mode == "all" || mode == "unit" { unitTests() }
if mode == "all" || mode == "property" { propertyTests() }
if mode == "all" || mode == "crash" { crashTests() }
if mode == "all" || mode == "slots" { slotTests(); slotCrashTests() }
if mode == "slotbench" { slotBench() }
if mode == "all" || mode == "install" { installTests(); readOnlyArchiveTests() }
if mode == "all" || mode == "nexus" { nexusTests() }
if mode == "all" || mode == "pandora" { pandoraTests() }
if mode == "all" || mode == "vortex" { vortexBridgeTests() }
if mode == "all" || mode == "bodyslide" { bodySlideTests(); bodySlideConfigTests(); builtinTests(); deleteProfileTests(); purgeKeepsLoadOrderTests() }
if mode == "all" || mode == "mo2" { mo2Tests(); manualInstallFilesTests(); mo2VariantTests(); listUpdateTests(); profileINITests(); vanillaViewTests() }
if mode == "all" || mode == "profiles" { profileHistoryTests(); snapshotTests(); perfTests(); essentialFilesTests(); toolPackageTests(); modsOutsideProfileTests(); dataTreeTests(); separateSavesTests(); saveFolderNameTests(); saveBackupTests(); iniEditorTests(); modEditingTests(); requirementsTests(); downloadsTests(); updatesTests(); crashLogTests(); crashLog125Tests(); crashFixTests(); crashProfileTests(); saveTests(); saveGuardTests(); lootRuleTests(); lightCandidateTests(); flagLightTests(); pluginLockTests(); categoryTests(); existingDownloadTests(); collectionUpdateTests(); ansiTests(); cleaningTests(); versionKeyTests(); duplicateTests(); mergeDuplicateTests(); perProfileOverwriteTests(); driftTests(); editedFilesFollowProfileTests(); reinstallTests(); updatedFilesReachGameTests(); primaryFileTests(); endorseTests(); colorTagTests(); skseVersionTests(); parallelPrefetchTests(); sksePrereqTests(); driftCheckSpeedTest(); trackTests(); wabbajackCacheTests(); modListMarkdownTests(); detectToolsTests(); gogLayoutTests() }
if mode == "bench" { bench() }
if mode == "scale" { let e = ProcessInfo.processInfo.environment; scaleTests(mods: Int(e["SCALE_MODS"] ?? "") ?? 2000, filesPerMod: Int(e["SCALE_FILES"] ?? "") ?? 250) }
print("\(passes) passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)
