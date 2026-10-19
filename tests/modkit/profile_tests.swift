// Profile history / undo, rename, export & import (ModKit/ProfileHistory.swift).
import Foundation

func profileHistoryTests() {
    section("profile history, rename, export")
    ModKit.historyCoalesce = 0
    defer { ModKit.historyCoalesce = 3 }
    let f = Fixture("profhist")
    let k = f.kit
    let a = f.addMod("Alpha", ["textures/a.dds": "a"])
    let b = f.addMod("Beta", ["textures/b.dds": "b"])
    var p = try! k.currentProfile()
    p.loadOrder = [LoadOrderEntry(name: "A.esp", active: true), LoadOrderEntry(name: "B.esp", active: true)]; try! k.saveProfile(p)
    let good = k.profile(p.name)!
    Thread.sleep(forTimeInterval: 0.01)
    p.loadOrder = [LoadOrderEntry(name: "A.esp", active: true)]; try! k.saveProfile(p)          // the "accident"
    let hist = k.profileHistory(p.name)
    check(!hist.isEmpty && hist.first!.activePlugins == 2, "previous version kept (\(hist.map(\.activePlugins)))")
    try! k.restoreProfile(p.name, from: hist.first!)
    check(k.profile(p.name)!.loadOrder == good.loadOrder, "restore brings the load order back")
    check(k.profileHistory(p.name).first?.activePlugins == 1, "the replaced version is kept too (undo the undo)")

    // coalescing: saves inside one action keep one snapshot
    ModKit.historyCoalesce = 60
    let before = k.profileHistory(p.name).count
    var q = k.profile(p.name)!; q.mods.swapAt(0, 1); try! k.saveProfile(q)
    q.mods.swapAt(0, 1); try! k.saveProfile(q)
    check(k.profileHistory(p.name).count == before, "a burst of saves doesn't flood the history")
    ModKit.historyCoalesce = 0

    // rename keeps everything attached
    k.appendMod(ModRecord(id: ModKit.pandoraOutputID(p.name), name: "Pandora Output (\(p.name))", folder: "PO"))
    var r = k.profile(p.name)!; r.mods.append(ProfileMod(id: ModKit.pandoraOutputID(p.name), enabled: true)); try! k.saveProfile(r)
    let oldName = p.name
    try! k.renameProfile(oldName, to: "Renamed")
    check(k.profile(oldName) == nil && k.profile("Renamed") != nil && k.currentProfileName == "Renamed", "renamed and still active")
    check(k.mod(ModKit.pandoraOutputID("Renamed")) != nil && k.profile("Renamed")!.mods.contains { $0.id == ModKit.pandoraOutputID("Renamed") },
          "generated output follows the rename")
    check(!k.profileHistory("Renamed").isEmpty, "history follows the rename")

    // export → import into a fresh profile, with one mod missing
    let data = try! k.exportProfile("Renamed")
    try! k.removeMod(b.id)
    let missing = try! k.importProfile(data, as: "Shared")
    check(k.profile("Shared")?.mods.map(\.id) == [a.id] && missing.map(\.name) == ["Beta"], "import matches installed mods, reports missing ones")
    check(k.profile("Shared")?.loadOrder.count == 2, "import brings the load order")
    try? fm.removeItem(at: f.home)
}

func separateSavesTests() {
    section("separate saves")
    let f = Fixture("saves")
    let k = f.kit
    _ = try! k.currentProfile()
    let custom = k.myGamesDir.appendingPathComponent("SkyrimCustom.ini")
    write(custom, "[Display]\r\nbLockFrameRate=0\r\n")
    try! k.createProfile("List")
    try! k.setSeparateSaves("List", true)
    _ = try! k.switchProfile(to: "List")
    let ini = read(custom) ?? ""
    check(ini.contains("[General]\r\nSLocalSavePath=Saves\\SkyrimMT\\List\\") && ini.contains("bLockFrameRate=0"), "save path set, other settings kept (\(ini.debugDescription))")
    check(fm.fileExists(atPath: k.profileSavesFolder("List").path), "save folder created")
    _ = try! k.switchProfile(to: "Default")
    check(!(read(custom) ?? "").contains("SLocalSavePath") && (read(custom) ?? "").contains("bLockFrameRate=0"), "shared saves again for profiles without")
    try? fm.removeItem(at: f.home)
}

func modEditingTests() {
    section("mod editing: separators, bulk, per-file conflicts, hidden files")
    let f = Fixture("modedit")
    let k = f.kit
    let a = f.addMod("A", ["textures/x.dds": "a", "textures/onlya.dds": "a"])
    let b = f.addMod("B", ["textures/x.dds": "b"])
    let c = f.addMod("C", ["meshes/c.nif": "c"])
    let sep = try! k.addSeparator("Visuals", before: b.id)
    var order = try! k.currentProfile().mods.map(\.id)
    check(order == [a.id, sep.id, b.id, c.id], "separator inserted before B")
    check(k.groupMembers(of: sep.id, in: try! k.currentProfile()) == [b.id, c.id], "group = mods up to the next separator")
    try! k.moveMods([sep.id], before: a.id)                      // move the whole group to the top
    order = try! k.currentProfile().mods.map(\.id)
    check(order == [sep.id, b.id, c.id, a.id], "separator moves with its group (\(order.map { k.mod($0)!.name }))")
    _ = try! k.deploy()
    check(read(f.game.appendingPathComponent("Data/textures/x.dds")) == "a", "A now wins x.dds (later in the list)")
    let fc = try! k.fileConflicts(of: a.id)
    check(fc.wins.map(\.rel) == ["Data/textures/x.dds"] && fc.wins.first?.losers == [b.id] && fc.loses.isEmpty, "per-file: A wins x.dds over B")
    check((try! k.fileConflicts(of: b.id)).loses.first?.winner == a.id, "per-file: B loses x.dds to A")
    try! k.setFileHidden(a.id, "textures/x.dds", hidden: true)
    _ = try! k.deploy()
    check(read(f.game.appendingPathComponent("Data/textures/x.dds")) == "b", "hidden file left out — B's copy deployed")
    check(k.modFiles(a.id).contains("textures/x.dds.mohidden"), "hidden file listed with .mohidden")
    try! k.setFileHidden(a.id, "textures/x.dds.mohidden", hidden: false)
    _ = try! k.deploy()
    check(read(f.game.appendingPathComponent("Data/textures/x.dds")) == "a", "shown again")
    try! k.renameMod(c.id, to: "  C renamed ")
    try! k.setNotes(c.id, "check this")
    check(k.mod(c.id)?.name == "C renamed" && k.mod(c.id)?.notes == "check this", "rename + notes")
    try! k.removeMods([b.id, c.id])
    check(k.mod(b.id) == nil && k.mod(c.id) == nil && k.mod(a.id) != nil, "bulk remove")
    try? fm.removeItem(at: f.home)
}

func requirementsTests() {
    section("requirements")
    let f = Fixture("reqs")
    let k = f.kit
    func nexusMod(_ name: String, _ id: Int, enabled: Bool = true) -> ModRecord {
        let m = f.addMod(name, ["textures/\(id).dds": name])
        let i = k.mods.firstIndex { $0.id == m.id }!
        var r = k.mods[i]; r.nexus = NexusRef(modID: id); k.replaceMod(at: i, with: r)
        if !enabled { var p = try! k.currentProfile(); p.mods[p.mods.firstIndex { $0.id == m.id }!].enabled = false; try! k.saveProfile(p) }
        return r
    }
    _ = nexusMod("3BA", 30174)
    _ = nexusMod("CBBE", 198)
    let xp = nexusMod("XPMSSE", 1988, enabled: false)
    let reqs: [Int: [ModRequirement]] = [
        30174: [ModRequirement(modID: 198, name: "CBBE", notes: "", external: false, url: ""),
                ModRequirement(modID: 1988, name: "XPMSSE", notes: "Required 4.61 or higher", external: false, url: ""),
                ModRequirement(modID: 57339, name: "FSMP", notes: "If you choose option related SMP, this is required", external: false, url: ""),
                ModRequirement(modID: 13048, name: "PapyrusUtil", notes: "", external: false, url: ""),
                ModRequirement(modID: 0, name: "SKSE", notes: "", external: true, url: "https://skse.silverlock.org")],
        198: [ModRequirement(modID: 13048, name: "PapyrusUtil", notes: "", external: false, url: "")],
    ]
    var calls = 0
    let issues = runAsync { try await k.checkRequirements { id in calls += 1; return reqs[id] ?? [] } }
    let byID = Dictionary(uniqueKeysWithValues: issues.map { ($0.requirement.modID, $0) })
    check(byID[198] == nil, "installed + enabled requirement is fine")
    check(byID[1988]?.state == .disabled(xp.id), "installed but disabled requirement reported as disabled")
    check(byID[13048]?.state == .missing && Set(byID[13048]!.requiredBy) == ["3BA", "CBBE"], "missing requirement lists every mod needing it")
    check(byID[57339]?.requirement.conditional == true && issues.last?.requirement.modID == 57339, "conditional requirement flagged and listed last")
    check(!issues.contains { $0.requirement.external }, "external requirements (links) are not reported as missing mods")
    check(calls == 2, "one request per enabled Nexus mod (\(calls))")
    _ = runAsync { try await k.checkRequirements { _ in calls += 1; return [] } }
    check(calls == 2, "cached for the next check")
    // not applicable on SE/AE: VR-only, credit-only, LE-only
    let na = [ModRequirement(modID: 1, name: "Skyrim Script Extender for VR (SKSEVR)", notes: "", external: false, url: ""),
              ModRequirement(modID: 2, name: "VR Address Library for SKSEVR", notes: "FOR VR: 0.198.0 and above", external: false, url: ""),
              ModRequirement(modID: 3, name: "Crash Logger", notes: "For info and credit; no files needed", external: false, url: ""),
              ModRequirement(modID: 4, name: "SkyUI", notes: "for LE only", external: false, url: "")]
    check(na.allSatisfy(\.notApplicable), "VR / credit / LE-only requirements are not applicable")
    let real = [ModRequirement(modID: 5, name: "SkyPatcher", notes: "", external: false, url: ""),
                ModRequirement(modID: 6, name: "Address Library for SKSE Plugins", notes: "Required", external: false, url: ""),
                ModRequirement(modID: 7, name: "Vivid Weathers", notes: "", external: false, url: "")]
    check(!real.contains(where: \.notApplicable), "real requirements stay (no false VR match on words like 'Vivid')")
    check(ModRequirement(modID: 8, name: "MergeMapper", notes: "optional, recommended for VR users", external: false, url: "").conditional, "'optional' is a suggestion")
    try? fm.removeItem(at: f.home)
}

/// Run an async throwing block from synchronous test code.
func runAsync<T>(_ body: @escaping () async throws -> T) -> T {
    let sem = DispatchSemaphore(value: 0)
    var out: Result<T, Error>!
    Task { do { out = .success(try await body()) } catch { out = .failure(error) }; sem.signal() }
    sem.wait()
    return try! out.get()
}

func downloadsTests() {
    section("downloads index")
    let f = Fixture("dl")
    let k = f.kit
    let dl = k.downloadsDir
    write(dl.appendingPathComponent("SkyUI_5_2-12604-5-2.7z"), String(repeating: "x", count: 100))
    write(dl.appendingPathComponent("SkyUI_5_2-12604-5-2.7z.meta.json"), #"{"modID":12604,"fileID":35407,"modName":"SkyUI","fileName":"SkyUI","version":"5.2","md5":null,"downloadedAt":"2026-10-18T10:00:00Z"}"#)
    write(dl.appendingPathComponent("loose.zip"), "zz")
    write(dl.appendingPathComponent("notes.txt"), "not an archive")
    let m = f.addMod("SkyUI", ["SkyUI_SE.esp": "p"])
    let i = k.mods.firstIndex { $0.id == m.id }!
    var r = k.mods[i]; r.nexus = NexusRef(modID: 12604, fileID: 35407); k.replaceMod(at: i, with: r)
    let e = k.downloadEntries()
    check(e.map(\.name) == ["loose", "SkyUI"], "archives only, names from metadata (\(e.map(\.name)))")
    check(e.first { $0.name == "SkyUI" }?.installedModID == m.id && e.first { $0.name == "loose" }?.installedModID == nil, "installed archive linked by Nexus file")
    check(e.first { $0.name == "SkyUI" }?.version == "5.2" && e.first { $0.name == "SkyUI" }?.size == 100, "version + size")
    let freed = k.deleteDownloads([dl.appendingPathComponent("SkyUI_5_2-12604-5-2.7z"), f.home.appendingPathComponent("elsewhere.7z")])
    check(freed == 100 && !fm.fileExists(atPath: dl.appendingPathComponent("SkyUI_5_2-12604-5-2.7z.meta.json").path), "deleted with its sidecar")
    check(k.downloadEntries().map(\.name) == ["loose"], "only files inside the downloads folder can be deleted")
    try? fm.removeItem(at: f.home)
}

func saveFolderNameTests() {
    section("separate saves: folder names Skyrim can read")
    check(ModKit.asciiFolderName("A Dragonborn's Fate – Standard") == "A Dragonborn's Fate - Standard", "en dash → hyphen")
    check(ModKit.asciiFolderName("Skyrim Ågård’s “Best”") == "Skyrim Agard's Best", "accents and curly quotes (\(ModKit.asciiFolderName("Skyrim Ågård’s “Best”")))")
    check(ModKit.asciiFolderName("Wildlander: Hard?") == "Wildlander_ Hard_", "characters Windows forbids replaced")
    let f = Fixture("savenames")
    let k = f.kit
    let name = "List – Extended"
    try! k.createProfile(name)
    _ = try! k.switchProfile(to: name)
    // saves written under the old folder names: the exact UTF-8 name and Skyrim's Windows-1252 misreading of it
    let base = k.myGamesDir.appendingPathComponent("Saves/SkyrimMT")
    try? fm.removeItem(at: base)                       // start clean
    let mojibake = String(data: Data(name.utf8), encoding: .windowsCP1252)!
    write(base.appendingPathComponent("\(mojibake)/Save1.ess"), "save one")
    write(base.appendingPathComponent("\(name)/Save2.ess"), "save two")
    try! k.setSeparateSaves(name, true)
    let folder = k.profileSavesFolder(name)
    check(folder.lastPathComponent == "List - Extended", "ASCII folder")
    check(read(folder.appendingPathComponent("Save1.ess")) == "save one" && read(folder.appendingPathComponent("Save2.ess")) == "save two", "saves from both old folders moved in")
    check(!fm.fileExists(atPath: base.appendingPathComponent(mojibake).path) && !fm.fileExists(atPath: base.appendingPathComponent(name).path), "empty old folders removed")
    check((read(k.myGamesDir.appendingPathComponent("SkyrimCustom.ini")) ?? "").contains("SLocalSavePath=Saves\\SkyrimMT\\List - Extended\\"), "INI points at the ASCII folder")
}

func saveBackupTests() {
    section("save backups before updates")
    let f = Fixture("savebackups")
    let k = f.kit
    try? fm.removeItem(at: k.savesDir); try? fm.removeItem(at: k.saveBackupsDir)
    check(k.backupSaves(reason: "nothing") == nil, "no saves → no backup")
    write(k.savesDir.appendingPathComponent("Save1.ess"), "one"); write(k.savesDir.appendingPathComponent("Save1.skse"), "co")
    let b = k.backupSaves(reason: "before updating Test Col")!
    check(b.count == 1 && b.reason == "before updating Test Col", "backup taken (\(b))")
    write(k.savesDir.appendingPathComponent("Save1.ess"), "broken by update"); write(k.savesDir.appendingPathComponent("Save2.ess"), "made later")
    check(try! k.restoreSaves(b) == 0 && read(k.savesDir.appendingPathComponent("Save1.ess")) == "broken by update", "restore never overwrites unless asked")
    check(try! k.restoreSaves(b, replace: true) == 2 && read(k.savesDir.appendingPathComponent("Save1.ess")) == "one"
          && read(k.savesDir.appendingPathComponent("Save2.ess")) == "made later", "replace brings the old save back, later saves stay")
}

func iniEditorTests() {
    section("game settings editor: the right file, the right encoding")
    let f = Fixture("inieditor")
    let k = f.kit
    try? fm.removeItem(at: k.myGamesDir)
    try! k.createProfile("Own"); try! k.createProfile("Shared")
    write(k.profileINIDir("Own").appendingPathComponent("SkyrimCustom.ini"), "[Display]\nown=1\n")
    check(k.iniURL(profile: k.currentProfileName, file: "Skyrim.ini") == k.myGamesDir.appendingPathComponent("Skyrim.ini"), "active profile → live file")
    check(k.iniURL(profile: "Own", file: "SkyrimCustom.ini") == k.profileINIDir("Own").appendingPathComponent("SkyrimCustom.ini"), "profile with own INIs → its copy")
    check(k.iniURL(profile: "Shared", file: "Skyrim.ini") == k.myGamesDir.appendingPathComponent("Skyrim.ini"), "shared-INI profile while a shared one is active → live")
    try! k.writeINI(profile: k.currentProfileName, file: "SkyrimCustom.ini", text: "[General]\nsName=Café – test\n")
    let raw = try! Data(contentsOf: k.myGamesDir.appendingPathComponent("SkyrimCustom.ini"))
    check(raw == "[General]\r\nsName=Café – test\r\n".data(using: .windowsCP1252)!, "written as Windows-1252 with CRLF (\(raw.count) bytes)")
    check(k.readINI(profile: k.currentProfileName, file: "SkyrimCustom.ini").contains("Café – test"), "read back")
}

func snapshotTests() {
    section("snapshots: the whole setup back in one step")
    let f = Fixture("snapshots")
    let k = f.kit
    let vanilla = snapshot(f.game)
    let a = f.addMod("Alpha", ["textures/a.dds": "a v1", "Alpha.esp": "p"])
    let b = f.addMod("Beta", ["textures/b.dds": "b"])
    try! k.deploy()
    let ini = k.iniURL(profile: k.currentProfileName, file: "Skyrim.ini")
    try! fm.createDirectory(at: ini.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! "[General]\r\nx=1\r\n".write(to: ini, atomically: true, encoding: .utf8)
    let before = try! k.currentProfile()
    let s1 = try! k.takeSnapshot(reason: "Before updating Alpha", mods: [a.id, b.id])
    check(k.snapshots().map(\.id) == [s1.id] && s1.savedMods.contains(a.id) && s1.savedMods.contains(b.id), "snapshot listed with the mods it keeps")
    // a bad evening: Alpha updated, Beta removed, a new mod, reordered, settings changed
    let work = freshDir("snapshots-update")
    write(work.appendingPathComponent("src/textures/a.dds"), "a v2")
    try! k.swapModFiles(a.id, work: work, layout: .data(root: work.appendingPathComponent("src")), fomod: nil)
    try! k.removeMod(b.id)
    let c = f.addMod("Gamma", ["textures/c.dds": "c"])
    var p = try! k.currentProfile(); p.mods.reverse(); try! k.saveProfile(p)
    try! "[General]\r\nx=2\r\n".write(to: ini, atomically: true, encoding: .utf8)
    try! k.deploy()
    let after = try! k.currentProfile()
    let r = try! k.restoreSnapshot(s1)
    try! k.deploy()
    check(Set(r.restoredFiles).isSuperset(of: ["Alpha", "Beta"]) && r.missing.isEmpty, "Alpha's old files and the removed Beta came back (\(r.restoredFiles))")
    check(try! k.currentProfile() == before, "profile exactly as it was (mods, order, load order)")
    check(read(ini) == "[General]\r\nx=1\r\n", "game settings as they were")
    var want = expected(vanilla: vanilla, profile: before, kit: k)
    check(snapshot(f.game) == want && read(f.game.appendingPathComponent("Data/textures/a.dds")) == "a v1", "game folder = the old setup")
    check(k.mod(c.id) != nil, "a mod installed later stays installed")
    // the restore itself is undoable
    let undo = r.undo!
    check(k.snapshots().first?.id == undo.id, "undo snapshot taken first")
    let r2 = try! k.restoreSnapshot(undo)
    try! k.deploy()
    var afterNoBeta = after; afterNoBeta.mods.removeAll { $0.id == b.id }
    check(try! k.currentProfile() == after, "undo: the evening's profile is back")
    check(read(ini) == "[General]\r\nx=2\r\n" && read(f.game.appendingPathComponent("Data/textures/a.dds")) == "a v2", "undo: Alpha v2 and x=2 again (\(read(ini) ?? "nil") / \(read(f.game.appendingPathComponent("Data/textures/a.dds")) ?? "nil") / staging \(read(k.stagingFolder(k.mod(a.id)!).appendingPathComponent("textures/a.dds")) ?? "nil"))")
    want = expected(vanilla: vanilla, profile: try! k.currentProfile(), kit: k)
    check(snapshot(f.game) == want, "undo: game folder matches")
    check(r2.undo != nil, "every restore leaves its own undo")

    section("snapshots: limits and safety")
    let d = f.addMod("Delta", ["textures/d.dds": "d"])
    let s2 = try! k.takeSnapshot(reason: "Without Delta's files")
    try! k.removeMod(d.id)
    let r3 = try! k.restoreSnapshot(s2)
    check(r3.missing == ["Delta"] && !(try! k.currentProfile()).mods.contains { $0.id == d.id }, "a removed mod whose files weren't kept is reported, not listed")
    try! fm.createDirectory(at: k.snapshotsDir.appendingPathComponent(".tmp-crashed"), withIntermediateDirectories: true)
    for i in 0..<(ModKit.snapshotsKept + 3) { _ = try! k.takeSnapshot(reason: "n\(i)") }
    check(k.snapshots().count == ModKit.snapshotsKept, "only the newest \(ModKit.snapshotsKept) are kept")
    check(!fm.fileExists(atPath: k.snapshotsDir.appendingPathComponent(".tmp-crashed").path), "half-written snapshot from a crash cleaned up")
    try! k.createProfile("Other")
    _ = try! k.switchProfile(to: "Other")
    check((try? k.restoreSnapshot(k.snapshots().first!)) == nil, "restoring another profile's snapshot asks to switch first")
}

func perfTests() {
    section("FPS cost per mod: frame trace math")
    let d = freshDir("perf-trace")
    // 200 frames: first 50 = menu (40 ms), then 150 frames of 10 ms with one 30 ms hitch
    var csv = "frame,t_us,dt_us,present_us,sync\n", t: Int64 = 0
    for i in 0..<200 { let dt: Int64 = i < 50 ? 40000 : (i == 120 ? 30000 : 10000); t += dt; csv += "\(i),\(t),\(dt),500,1\n" }
    try! csv.write(to: d.appendingPathComponent("frames.csv"), atomically: true, encoding: .utf8)
    try! "menu 10 0\nstart 52 0\nend 201 0\n".write(to: d.appendingPathComponent("marks.txt"), atomically: true, encoding: .utf8)
    let s = try! FrameTrace.sample(csv: d.appendingPathComponent("frames.csv"), marks: d.appendingPathComponent("marks.txt"))
    check(s.frames == 149 && abs(s.meanMs - 1500.0 / 148) < 0.01 && s.p99Ms == 10, "segment start→end only, mean, p99 (one hitch in 149 frames is under 1%) (\(s.frames) \(s.meanMs) \(s.p99Ms))")
    try! csv.replacingOccurrences(of: "\n", with: "\r\n").write(to: d.appendingPathComponent("crlf.csv"), atomically: true, encoding: .utf8)
    check((try? FrameTrace.sample(csv: d.appendingPathComponent("crlf.csv"), marks: d.appendingPathComponent("marks.txt")))?.frames == 149, "Windows line endings (the frametrace DLL writes CRLF)")
    try! "start 5 0\n".write(to: d.appendingPathComponent("m2.txt"), atomically: true, encoding: .utf8)
    check((try? FrameTrace.sample(csv: d.appendingPathComponent("frames.csv"), marks: d.appendingPathComponent("m2.txt"))) == nil, "missing marks → error, no number")
    let real = URL(fileURLWithPath: NSHomeDirectory() + "/Code/skyrimmt/bench/warm-high-3989")
    if let r = try? FrameTrace.sample(csv: real.appendingPathComponent("frames.csv"), marks: real.appendingPathComponent("marks.txt")) {
        check(r.frames == 11521 - 6401 && r.fps > 20 && r.fps < 200, "a real bench run parses (\(r.frames) frames, \(String(format: "%.1f", r.fps)) fps)")
    }

    section("FPS cost per mod: candidates, dependents, measurement, restore")
    let f = Fixture("perf")
    let k = f.kit
    try! pluginBytes(flags: 1, masters: []).write(to: f.game.appendingPathComponent("Data/Skyrim.esm"))
    let big = f.addMod("Big Textures", ["textures/big.dds": String(repeating: "x", count: 5000)])
    let fw = f.addMod("Framework", ["textures/fw.dds": "x"])
    let dir = f.home.appendingPathComponent("incoming/plug"); try! fm.createDirectory(at: dir, withIntermediateDirectories: true)
    try! pluginBytes(flags: 1, masters: ["Skyrim.esm"]).write(to: dir.appendingPathComponent("Base.esm"))
    write(dir.appendingPathComponent("meshes/base.nif"), "m")
    let base = try! k.addMod(name: "Base Master", from: dir)
    let dir2 = f.home.appendingPathComponent("incoming/plug2"); try! fm.createDirectory(at: dir2, withIntermediateDirectories: true)
    try! pluginBytes(flags: 0, masters: ["Skyrim.esm", "Base.esm"]).write(to: dir2.appendingPathComponent("Addon.esp"))
    let addon = try! k.addMod(name: "Addon", from: dir2)
    let dir3 = f.home.appendingPathComponent("incoming/plug3"); try! fm.createDirectory(at: dir3, withIntermediateDirectories: true)
    try! pluginBytes(flags: 0, masters: ["Addon.esp"]).write(to: dir3.appendingPathComponent("AddonPatch.esp"))
    let patch = try! k.addMod(name: "Addon Patch", from: dir3)
    _ = f.addMod("Scripts only", ["scripts/s.pex": "s"])
    try! k.deploy()
    let p0 = try! k.currentProfile()
    check(k.perfDependents(of: base.id, in: p0) == [addon.id, patch.id], "turning off a master takes everything that needs it (directly or not)")
    check(k.perfDependents(of: big.id, in: p0).isEmpty, "a texture mod stands alone")
    let cands = try! k.perfCandidates()
    check(cands.first?.modID == big.id && cands.contains { $0.modID == base.id && $0.together == [addon.id, patch.id] } && !cands.contains { $0.name == "Scripts only" },
          "candidates: biggest assets first, with their dependents; mods without assets left out")
    let modded = SaveInfo(url: f.home, saveNumber: 1, player: "P", level: 1, location: "", race: "", saved: Date(), plugins: ["Skyrim.esm", "Addon.esp"], lightPlugins: [])
    let safe = try! k.perfCandidates(save: modded)
    check(safe.contains { $0.modID == big.id } && !safe.contains { $0.modID == base.id }, "a mod the bench save needs (here through its dependent Addon.esp) isn't offered")
    // a fake benchmark: 10 ms + 3 ms if the big texture is in the game + 1 ms for the base mesh, ±0.05 ms noise
    var runs: [String] = []
    let report = try! k.runPerfTest(cands) { label in
        runs.append(label)
        var ms = 10.0 + (label == "full-2" ? 0.05 : 0)
        if fm.fileExists(atPath: f.game.appendingPathComponent("Data/textures/big.dds").path) { ms += 3 }
        if fm.fileExists(atPath: f.game.appendingPathComponent("Data/meshes/base.nif").path) { ms += 1 }
        return PerfSample(frames: 1000, seconds: 10, meanMs: ms, p99Ms: ms * 2)
    }
    check(runs.first == "full-1" && runs.last == "full-2" && runs.count == cands.count + 2, "full run, one per candidate, full run again (\(runs))")
    check(abs(report.results.first!.costMs - 3.025) < 0.001 && report.results.first!.candidate.modID == big.id, "Big Textures costs ~3 ms per frame, ranked first")
    check(abs((report.results.first { $0.candidate.modID == base.id }!.costMs) - 1.025) < 0.001, "Base Master (+ its dependents) ~1 ms")
    check(abs(report.noiseMs - 0.05) < 0.001, "noise from the two full runs")
    check(try! k.currentProfile() == p0 && (try! k.isDirty()) == false && !fm.fileExists(atPath: k.perfRestoreURL.path), "profile restored and deployed after the test")
    check(k.perfReport().map { ($0.results, $0.baseline, $0.profile) } ?? ([], report.baseline, "") == (report.results, report.baseline, report.profile), "report saved for the page")
    // a failing benchmark mid-way: profile still restored, error reported
    var n = 0
    do { _ = try k.runPerfTest(cands) { _ in n += 1; if n == 2 { throw PerfError.measurement("game exited while loading") }; return PerfSample(frames: 100, seconds: 1, meanMs: 10, p99Ms: 12) }; check(false, "error expected") }
    catch { check("\(error)".contains("loading"), "benchmark error passed on") }
    check(try! k.currentProfile() == p0 && (try! k.isDirty()) == false, "profile restored after a failed run")
    // crash mid-test (the app died): the restore file brings the profile back at the next start
    try! writeJSON(p0, to: k.perfRestoreURL)
    var broken = p0; for i in broken.mods.indices { broken.mods[i].enabled = false }; try! k.saveProfile(broken); try! k.deploy()
    try! k.finishPerfRestore()
    check(try! k.currentProfile() == p0 && (try! k.isDirty()) == false && !fm.fileExists(atPath: k.perfRestoreURL.path), "after a crash: profile restored at start-up")
}

func essentialFilesTests() {
    section("essentials: the right Nexus file per mod (real file lists, 2026-10-19)")
    func f(_ id: Int, _ name: String, _ cat: String = "MAIN", _ t: Int) -> NexusFileInfo {
        NexusFileInfo(fileID: id, name: name, fileName: "\(id).7z", version: "", category: cat, sizeBytes: nil, md5: nil, uploadedTimestamp: t)
    }
    let e = Dictionary(uniqueKeysWithValues: essentials.map { ($0.id, $0) })
    let skse = [f(470991, "Skyrim Script Extender (SKSE64) GOG", "MAIN", 2), f(795992, "Skyrim Script Extender (SKSE64) Steam", "MAIN", 1)]
    check(ModKit.essentialFiles(e["skse"]!, from: skse, gameVersion: "1.7.104").map(\.fileID) == [795992], "SKSE: the Steam build, not GOG")
    let addr = [f(795954, "Address Library All in One (1.7.104.0) v13", "MAIN", 5), f(470707, "All in one (1.6.X)", "OLD_VERSION", 1)]
    check(ModKit.essentialFiles(e["addresslib"]!, from: addr, gameVersion: "1.7.104").map(\.fileID) == [795954], "Address Library: the game version's file")
    let ef = [f(669325, "Engine Fixes (All-In-One) for 1.5.97", "OPTIONAL", 9), f(669326, "Engine Fixes (All-In-One) for 1.6.1170 and newer", "OPTIONAL", 9),
              f(725261, "Engine Fixes - SKSE64 Preloader", "MAIN", 3), f(725753, "Engine Fixes - Main File", "MAIN", 4),
              f(794484, "Engine Fixes 7.0.21 beta for Skyrim AE 1.7.99", "MAIN", 5)]
    check(ModKit.essentialFiles(e["enginefixes"]!, from: ef, gameVersion: "1.7.104").map(\.fileID) == [794484, 725261], "Engine Fixes: 1.7 build + preloader")
    let ui = [f(734848, "SkyUI SDK", "OPTIONAL", 9), f(749043, "SkyUI", "MAIN", 1)]
    check(ModKit.essentialFiles(e["skyui"]!, from: ui, gameVersion: "1.7.104").map(\.fileID) == [749043], "SkyUI: main file, not the SDK")
    check(ModKit.essentialFiles(e["skse"]!, from: skse, gameVersion: "1.6.640").isEmpty, "other game versions: no automatic choice")
    check(ModKit.essentialFiles(e["enginefixes"]!, from: [f(725261, "Engine Fixes - SKSE64 Preloader", "MAIN", 3)], gameVersion: "1.7.104").isEmpty, "incomplete set → none (no half installs)")
}

func toolPackageTests() {
    section("prebuilt tools: download, verify, unpack")
    let f = Fixture("toolpkg")
    let src = freshDir("toolpkg-src")
    write(src.appendingPathComponent("pandora/Pandora Behaviour Engine+"), "#!/bin/sh\necho ok\n")
    chmod(src.appendingPathComponent("pandora/Pandora Behaviour Engine+").path, 0o755)
    write(src.appendingPathComponent("pandora/Data/x.txt"), "data")
    let tar = src.appendingPathComponent("pandora-macos-arm64.tar.xz")
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/tar"); p.arguments = ["-cJf", tar.path, "-C", src.path, "pandora"]; try! p.run(); p.waitUntilExit()
    let sum = try! ModKit.sha256(of: tar)
    let conf = src.appendingPathComponent("release.conf")
    try! "# test\nRUNTIME_VERSION=\"1\"\nPANDORA_URL=\"\(tar.absoluteString)\"\nPANDORA_SHA256=\"\(sum)\"\nBODYSLIDE_URL=\"\(tar.absoluteString)\"\nBODYSLIDE_SHA256=\"\"\n"
        .write(to: conf, atomically: true, encoding: .utf8)
    let pk = ModKit.toolPackages(conf: conf)
    check(pk.keys.sorted() == ["pandora"], "packages with URL and checksum only (\(pk.keys.sorted()))")
    let pan = pk["pandora"]!
    check(!f.kit.toolInstalled(pan), "not installed at first")
    try! f.kit.installToolPackage(pan)
    check(f.kit.toolInstalled(pan) && read(f.home.appendingPathComponent("tools/pandora/Data/x.txt")) == "data", "installed into tools/pandora")
    check(f.kit.pandoraInstalled, "Pandora reports installed")
    check((try? fm.contentsOfDirectory(atPath: f.home.appendingPathComponent("tools").path))?.filter { $0.hasPrefix(".") }.isEmpty == true, "no leftovers")
    let bad = ToolPackage(name: "BodySlide", folder: "bodyslide", executable: "BodySlide", url: tar, sha256: String(repeating: "0", count: 64))
    var threw = false
    do { try f.kit.installToolPackage(bad) } catch { threw = "\(error)".contains("checksum") }
    check(threw && !fm.fileExists(atPath: f.home.appendingPathComponent("tools/bodyslide").path), "damaged download refused, nothing installed")
    let missing = ToolPackage(name: "Wabbajack engine", folder: "wabbajack", executable: "jackify-engine", url: URL(fileURLWithPath: "/nonexistent/x.tar.xz"), sha256: sum)
    check((try? f.kit.installToolPackage(missing)) == nil && !f.kit.toolInstalled(missing), "unreachable download → error")
    let real = ModKit.toolPackages(conf: URL(fileURLWithPath: NSHomeDirectory() + "/Code/skyrimmt/config/release.conf"))
    check(real.values.allSatisfy { $0.url.absoluteString.hasPrefix("https://github.com/") && $0.sha256.count == 64 }, "release.conf packages point at GitHub with SHA-256 (\(real.count))")
}

func modsOutsideProfileTests() {
    section("mods installed for other profiles can join this one")
    let f = Fixture("outside")
    let a = f.addMod("A", ["a.txt": "a"]), b = f.addMod("B", ["b.txt": "b"])
    var p = try! f.kit.currentProfile(); p.mods.removeAll { $0.id == b.id }; try! f.kit.saveProfile(p)   // B belongs to another setup
    try! f.kit.moveMods([b.id], before: a.id)
    let q = try! f.kit.currentProfile()
    check(q.mods.map(\.id) == [b.id, a.id] && q.mods[0].enabled == false, "dragging it in adds it (off) where it was dropped")
}

func dataTreeTests() {
    section("Data view: origin per file, conflicts per folder")
    let f = Fixture("datatree")
    let a = f.addMod("Armor", ["Textures/Armor/plate.dds": "a", "Textures/shared.dds": "a", "Interface/vanilla.swf": "a swf"])
    let b = f.addMod("Better", ["textures/shared.dds": "b", "meshes/b.nif": "b"])
    try! f.kit.deploy()
    let t = try! f.kit.dataTree()
    func node(_ path: String) -> DataNode? {
        var n: DataNode? = t
        for part in path.lowercased().split(separator: "/") { n = n?.children?.first { $0.id.split(separator: "/").last.map(String.init) == String(part) } }
        return n
    }
    check(node("textures/shared.dds")?.winner == b.id && node("textures/shared.dds")?.losers == [a.id], "later mod wins, the other is listed as overridden")
    check(node("interface/vanilla.swf")?.winner == a.id && node("interface/vanilla.swf")?.losers == [ModKit.vanillaOrigin], "a mod replacing a game file overrides vanilla")
    check(node("textures/vanilla/rock.dds")?.winner == ModKit.vanillaOrigin, "game files listed as the game's own")
    check(node("textures")?.conflicts == 1 && node("textures")?.mods[a.id] == 2 && node("textures")?.mods[b.id] == 1, "folder: conflicts and files per mod")
    check(node("textures/armor")?.conflicts == 0 && node("meshes")?.conflicts == 0, "folders without shared files are not conflicts")
    check(node("Textures/Armor/plate.dds")?.name == "plate.dds" && node("textures")?.children?.first?.isFolder == true, "spelling kept, folders listed first")
    check(t.files == 6, "every file once (\(t.files))")
}
