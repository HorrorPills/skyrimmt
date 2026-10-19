// Mod updates (ModKit/Updates.swift): Nexus update chains, rate-limit friendly checking, update in place.
import Foundation

func updatesTests() {
    section("mod updates")
    func file(_ id: Int, _ v: String, _ cat: String = "MAIN") -> NexusFileInfo {
        NexusFileInfo(fileID: id, name: "File \(id)", fileName: "file-\(id).7z", version: v, category: cat, sizeBytes: 10, md5: nil, uploadedTimestamp: id)
    }
    let files = [file(1, "1.0", "OLD_VERSION"), file(2, "1.1", "OLD_VERSION"), file(3, "1.2"), file(9, "opt")]
    check(ModKit.latestFile(from: 1, files: files, updates: [(1, 2), (2, 3)])?.fileID == 3, "chain followed to the newest file")
    check(ModKit.latestFile(from: 3, files: files, updates: [(1, 2), (2, 3)]) == nil, "newest file: no update")
    check(ModKit.latestFile(from: 9, files: files, updates: [(1, 2), (2, 3)]) == nil, "unrelated file (optional) not 'updated' by the main file")
    check(ModKit.latestFile(from: 1, files: files, updates: [(1, 2), (2, 1)])?.fileID == 2, "cycle in the chain doesn't hang")

    let f = Fixture("updates")
    let k = f.kit
    func nexusMod(_ name: String, _ nid: Int, _ fid: Int) -> ModRecord {
        let m = f.addMod(name, ["textures/\(nid).dds": name])
        let i = k.mods.firstIndex { $0.id == m.id }!
        var r = k.mods[i]; r.nexus = NexusRef(modID: nid, fileID: fid); r.version = "1.0"; k.replaceMod(at: i, with: r)
        return r
    }
    let a = nexusMod("Alpha", 100, 1), b = nexusMod("Beta", 200, 20), _ = nexusMod("Gamma", 300, 30)
    let remote: [Int: (files: [NexusFileInfo], updates: [(old: Int, new: Int)])] = [
        100: (files, [(1, 2), (2, 3)]), 200: ([file(20, "2.0")], []), 300: ([file(30, "3.0")], [])]
    var calls: [Int] = []
    let ups = runAsync { await k.findUpdates(recentlyChanged: [], fetch: { calls.append($0); return remote[$0]! }) }
    check(ups.map(\.modName) == ["Alpha"] && ups.first?.newVersion == "1.2" && ups.first?.currentVersion == "1.0", "update found (\(ups.map(\.modName)))")
    check(calls.count == 3, "first check covers every Nexus mod (\(calls))")
    calls = []
    _ = runAsync { await k.findUpdates(recentlyChanged: [200], fetch: { calls.append($0); return remote[$0]! }) }
    check(calls == [200], "later checks only ask about recently changed mods (\(calls))")
    calls = []
    _ = runAsync { await k.findUpdates(recentlyChanged: [], budget: 1, maxAge: 0, fetch: { calls.append($0); return remote[$0]! }) }
    check(calls.count == 1, "request budget respected")
    check(k.cachedUpdates().map(\.modRecordID) == [a.id], "cached result survives")

    // update in place: FOMOD choices replayed, position / enabled / notes kept
    let src = freshDir("updates-src")
    makeFomodTree(src.appendingPathComponent("v1"))
    pack(src.appendingPathComponent("v1"), src.appendingPathComponent("v1.zip"), format: "zip")
    let (w, l) = try! k.beginInstall(archive: src.appendingPathComponent("v1.zip"))
    guard case .fomod(_, let cfgURL) = l else { check(false, "fomod layout"); return }
    let inst = FomodInstaller(config: try! FomodParser.load(cfgURL), context: FomodContext(pluginState: { _ in .missing }))
    inst.applyAllDefaults(); inst.selections[0]?[1] = [2]   // Zeta extra only
    let fmod = try! k.finishInstall(work: w, layout: l, name: "Fomod Mod", fomod: inst)
    try! k.setNotes(fmod.id, "keep me")
    var p = try! k.currentProfile()
    let fi = p.mods.firstIndex { $0.id == fmod.id }!
    let pm = p.mods.remove(at: fi); p.mods.insert(pm, at: 1); p.mods[1].enabled = false; try! k.saveProfile(p)
    let before = try! k.currentProfile().mods.map(\.id)
    makeFomodTree(src.appendingPathComponent("v2"))
    write(src.appendingPathComponent("v2/00 Core/textures/core.dds"), "core v2")
    pack(src.appendingPathComponent("v2"), src.appendingPathComponent("v2.zip"), format: "zip")
    try! k.updateMod(fmod.id, archive: src.appendingPathComponent("v2.zip"), nexusFileID: 77, version: "2.0", gameVersion: "1.6.1170")
    let staged = snapshot(k.stagingFolder(k.mod(fmod.id)!))
    check(staged["textures/core.dds"] == "core v2", "new files in place")
    check(staged["textures/extra/zeta.dds"] == "zeta" && staged["textures/extra/alpha.dds"] == nil, "saved installer choices replayed (\(staged.keys.sorted()))")
    let after = try! k.currentProfile()
    check(after.mods.map(\.id) == before && after.mods[1].id == fmod.id && !after.mods[1].enabled, "same position, still disabled")
    let r = k.mod(fmod.id)!
    check(r.version == "2.0" && r.notes == "keep me" && k.mods.filter { $0.name == "Fomod Mod" }.count == 1, "version updated, notes kept, no duplicate entry")
    // a broken archive leaves the old files alone
    write(src.appendingPathComponent("broken.zip"), "not a zip")
    check((try? k.updateMod(fmod.id, archive: src.appendingPathComponent("broken.zip"), nexusFileID: nil, version: "3", gameVersion: "1.6.1170")) == nil
          && read(k.stagingFolder(k.mod(fmod.id)!).appendingPathComponent("textures/core.dds")) == "core v2", "failed update keeps the mod working")
    _ = b
}

func categoryTests() {
    section("categories from Nexus")
    let f = Fixture("categories")
    let k = f.kit
    func nexusMod(_ name: String, _ nid: Int, category: String? = nil) -> ModRecord {
        let m = f.addMod(name, ["textures/\(nid).dds": name])
        let i = k.mods.firstIndex { $0.id == m.id }!
        var r = k.mods[i]; r.nexus = NexusRef(modID: nid); r.category = category; k.replaceMod(at: i, with: r)
        return r
    }
    let a = nexusMod("SkyUI", 12604), b = nexusMod("Mine", 59818, category: "My stuff"), c = nexusMod("Unknown", 1)
    _ = f.addMod("Local", ["x.esp": "x"])
    var asked: [Int] = []
    let n = runAsync { try await k.fillCategories { ids in asked = ids; return [12604: "User Interface", 59818: "Miscellaneous"] } }
    check(asked == [1, 12604], "only mods without a category asked, in one batch (\(asked))")
    check(n == 1 && k.mod(a.id)?.category == "User Interface", "category filled")
    check(k.mod(b.id)?.category == "My stuff", "player's own category kept")
    check(k.mod(c.id)?.category == nil && k.modsMissingCategory.map(\.id) == [c.id], "unknown stays empty")
    k.setCategory([a.id, c.id], "Bulk")
    check(k.mod(a.id)?.category == "Bulk" && k.mod(c.id)?.category == "Bulk", "bulk set category")
}

func existingDownloadTests() {
    section("downloads reused without asking Nexus")
    let dir = freshDir("existing-dl")
    let client = NexusClient(apiKey: "k", appVersion: "t", baseURL: URL(string: "https://api.test/v1/")!, session: stubSession())
    let d = NexusDownloader(client: client, folder: dir)
    write(dir.appendingPathComponent("SkyUI-12604-5-2.7z"), String(repeating: "x", count: 100))
    write(dir.appendingPathComponent("SkyUI-12604-5-2.7z.meta.json"), #"{"modID":12604,"fileID":35407,"modName":"SkyUI","fileName":"SkyUI","version":"5.2","md5":"abc","downloadedAt":"2026-10-18T10:00:00Z"}"#)
    write(dir.appendingPathComponent("Other.7z"), "y")
    write(dir.appendingPathComponent("Other.7z.meta.json"), #"{"modID":1,"fileID":2,"modName":"O","fileName":"O","version":"","md5":null,"downloadedAt":"2026-10-18T10:00:00Z"}"#)
    check(d.existingDownload(modID: 12604, fileID: 35407, md5: "ABC", size: nil)?.lastPathComponent == "SkyUI-12604-5-2.7z", "found by Nexus file + MD5")
    check(d.existingDownload(modID: 12604, fileID: 35407, md5: "other", size: nil) == nil, "different MD5: not reused")
    check(d.existingDownload(modID: 1, fileID: 2, md5: nil, size: 1) != nil && d.existingDownload(modID: 1, fileID: 2, md5: nil, size: 5) == nil, "size checked when no MD5")
    check(d.existingDownload(modID: 12604, fileID: 1, md5: nil, size: nil) == nil, "other file of the same mod: not reused")
    try? fm.removeItem(at: dir.appendingPathComponent("SkyUI-12604-5-2.7z"))
    check(d.existingDownload(modID: 12604, fileID: 35407, md5: nil, size: nil) == nil, "sidecar without its archive ignored")
}

func collectionUpdateTests() {
    section("collection update: new revision in place")
    let f = Fixture("colupdate")
    let k = f.kit
    let src = freshDir("colupdate-src")
    func archive(_ name: String, _ mid: Int, _ fid: Int, _ md5: String) {
        write(src.appendingPathComponent("\(name)/\(name).esp"), "\(name)-\(fid)")
        pack(src.appendingPathComponent(name), k.downloadsDir.appendingPathComponent("\(name)-\(fid).zip"), format: "zip")
        write(k.downloadsDir.appendingPathComponent("\(name)-\(fid).zip.meta.json"),
              #"{"modID":\#(mid),"fileID":\#(fid),"modName":"\#(name)","fileName":"\#(name)","version":"\#(fid)","md5":"\#(md5)","downloadedAt":"2026-10-18T10:00:00Z"}"#)
    }
    try! fm.createDirectory(at: k.downloadsDir, withIntermediateDirectories: true)
    archive("Base", 1, 10, "aa"); archive("Patch", 2, 20, "bb"); archive("Old", 4, 40, "dd")
    archive("Patch", 2, 21, "b2"); archive("New", 5, 50, "ee")
    func manifest(_ mods: [(String, Int, Int, String)]) -> CollectionManifest {
        let m = mods.map { #"{"name":"\#($0.0)","optional":false,"phase":0,"source":{"type":"nexus","modId":\#($0.1),"fileId":\#($0.2),"md5":"\#($0.3)"}}"# }
        let lo = mods.map { #"{"name":"\#($0.0).esp","enabled":true}"# }
        return try! CollectionManifest.parse(Data(#"{"info":{"name":"Test Col"},"mods":[\#(m.joined(separator: ","))],"modRules":[],"loadOrder":[\#(lo.joined(separator: ","))]}"#.utf8))
    }
    func info(_ rev: Int, _ mods: [(String, Int, Int, String)]) -> CollectionInfo {
        CollectionInfo(slug: "tstcol", name: "Test Col", revision: rev, downloadLink: "", gameVersions: [], totalSize: 0,
                       files: mods.map { CollectionFile(modID: $0.1, fileID: $0.2, modName: $0.0, fileName: $0.0, version: "\($0.2)", size: 0, optional: false) })
    }
    let client = NexusClient(apiKey: "k", appVersion: "t", baseURL: URL(string: "https://api.test/v1/")!, session: stubSession())
    let r1 = [("Base", 1, 10, "aa"), ("Patch", 2, 20, "bb"), ("Old", 4, 40, "dd")]
    let m1 = manifest(r1)
    let prof = runAsync { try await k.installCollection(info: info(1, r1), manifest: m1, items: m1.mods, client: client, gameVersion: "1.6.1170", progress: { _, _ in }) }
    check(k.profile(prof)?.mods.count == 3 && k.installedCollections().first?.revision == 1, "revision 1 installed without network (downloads reused)")
    // the player adds a mod of their own to the collection's profile
    let mine = f.addMod("Mine", ["Mine.esp": "mine"])
    var p = try! k.currentProfile(); p.loadOrder.append(LoadOrderEntry(name: "Mine.esp", active: true)); try! k.saveProfile(p)
    let oldPatch = k.mods.first { $0.nexus?.fileID == 20 }!.id, old = k.mods.first { $0.nexus?.modID == 4 }!.id
    let r2 = [("Base", 1, 10, "aa"), ("Patch", 2, 21, "b2"), ("New", 5, 50, "ee")]
    let d = k.collectionDiff(slug: "tstcol", latest: info(2, r2))
    check(d.added == ["New"] && d.changed == ["Patch"] && d.removed == ["Old"], "diff: added / updated / removed (\(d))")
    check(d.summary == "1 new, 1 updated, 1 removed", "plain summary")
    let m2 = manifest(r2)
    let prof2 = runAsync { try await k.installCollection(info: info(2, r2), manifest: m2, items: m2.mods, client: client, gameVersion: "1.6.1170", progress: { _, _ in }) }
    let q = k.profile(prof2)!
    check(prof2 == prof && k.installedCollections().first?.revision == 2, "updated in the same profile")
    let names = q.mods.compactMap { k.mod($0.id)?.name }
    check(names.count == 4 && names.last == "Mine" && names.contains("New"), "new revision's mods + the player's own mod kept last (\(names))")
    check(q.loadOrder.contains { $0.name == "Mine.esp" && $0.active }, "the player's plugin keeps its place")
    check(k.mod(old) == nil && k.mod(oldPatch) == nil, "mods only the old revision used are removed")
    check(k.mod(mine.id) != nil, "the player's mod is not removed")
    check(read(f.game.appendingPathComponent("Data/Patch.esp")) == "Patch-21", "new file version deployed")
}

func versionKeyTests() {
    section("profile game version → version key")
    check(ModKit.versionKey("1.7.104", steamVersion: "1.7.104", installed: ["1.6.1170"]) == "steam", "list made for Steam's current version runs on Steam")
    check(ModKit.versionKey("1.7.104.0", steamVersion: "1.7.104", installed: []) == "steam", "four-part number matches")
    check(ModKit.versionKey("1.6.1170", steamVersion: "1.7.104", installed: ["1.6.1170"]) == "1.6.1170", "pinned copy used")
    check(ModKit.versionKey("1.6.1170.0", steamVersion: "1.7.104", installed: ["1.6.1170"]) == "1.6.1170", "pinned copy found by number")
    check(ModKit.versionKey("1.5.97", steamVersion: "1.7.104", installed: []) == "1.5.97", "missing version reported as is (download offered)")
    check(ModKit.versionKey("steam", steamVersion: "", installed: []) == "steam", "steam stays steam")
}

func duplicateTests() {
    section("duplicate mods")
    let f = Fixture("dups")
    let k = f.kit
    func nexusMod(_ name: String, _ nid: Int, _ fid: Int) -> ModRecord {
        let m = f.addMod(name, ["x\(UUID().uuidString.prefix(4)).txt": name])
        let i = k.mods.firstIndex { $0.id == m.id }!
        var r = k.mods[i]; r.nexus = NexusRef(modID: nid, fileID: fid); k.replaceMod(at: i, with: r); return r
    }
    let a1 = nexusMod("SkyUI", 12604, 1), a2 = nexusMod("SkyUI", 12604, 1), _ = nexusMod("Other", 5, 5)
    var p = try! k.currentProfile(); p.mods.removeAll { $0.id == a2.id }; try! k.saveProfile(p)   // a2 used by no profile
    let d = k.duplicateMods()
    check(d.count == 1 && d[0].mods.count == 2 && d[0].unused == [a2.id], "same Nexus file twice found; the unused copy named (\(d))")
    try! k.removeMod(a2.id)
    check(k.duplicateMods().isEmpty && k.mod(a1.id) != nil, "after removing the extra copy: none left, the used one kept")
}

func mergeDuplicateTests() {
    section("merge identical duplicates")
    let f = Fixture("mergedups")
    let k = f.kit
    func nexusMod(_ name: String, _ files: [String: String], _ fid: Int) -> ModRecord {
        let m = f.addMod(name, files)
        let i = k.mods.firstIndex { $0.id == m.id }!
        var r = k.mods[i]; r.nexus = NexusRef(modID: 7, fileID: fid); k.replaceMod(at: i, with: r); return r
    }
    let a = nexusMod("Mod", ["a.esp": "same", "t/x.dds": "tex"], 70)
    let b = nexusMod("Mod", ["a.esp": "same", "t/x.dds": "tex"], 70)        // identical copy (another profile)
    let c = nexusMod("Mod", ["a.esp": "other choice"], 70)                    // same file, different installer choice
    try! k.createProfile("List")
    var lp = k.profile("List")!; lp.mods = [ProfileMod(id: b.id, enabled: false), ProfileMod(id: c.id, enabled: true)]; try! k.saveProfile(lp)
    let n = try! k.mergeIdenticalDuplicates()
    check(n == 1 && k.mod(b.id) == nil && k.mod(c.id) != nil, "identical copy merged, different copy kept (\(n))")
    let q = k.profile("List")!
    check(q.mods.first?.id == a.id && q.mods.first?.enabled == false && q.mods.last?.id == c.id, "profile now uses the kept copy, same place and state")
}

func perProfileOverwriteTests() {
    section("Overwrite per profile")
    let f = Fixture("owprofile")
    let k = f.kit
    _ = f.addMod("Plugin mod", ["SKSE/Plugins/thing.dll": "dll"])
    try! k.createProfile("List", cloneFrom: k.currentProfileName)
    try! k.deploy()
    write(f.game.appendingPathComponent("Data/SKSE/Plugins/thing.ini"), "written in Default")
    _ = try! k.switchProfile(to: "List")            // captures Default's generated file
    let defOW = ModKit.overwriteID(for: "Default")
    check(k.mod(defOW) != nil && k.profile("Default")!.mods.contains { $0.id == defOW } && !k.profile("List")!.mods.contains { ModKit.isOverwrite($0.id) },
          "the file went to Default's own Overwrite; List doesn't get it")
    check(read(f.game.appendingPathComponent("Data/SKSE/Plugins/thing.ini")) == nil, "not in the game while List is active")
    write(f.game.appendingPathComponent("Data/SKSE/Plugins/thing.ini"), "written in List")
    _ = try! k.switchProfile(to: "Default")
    check(read(k.stagingFolder(k.mod(ModKit.overwriteID(for: "List"))!).appendingPathComponent("SKSE/Plugins/thing.ini")) == "written in List"
          && read(f.game.appendingPathComponent("Data/SKSE/Plugins/thing.ini")) == "written in Default", "each profile keeps its own generated file")
    try! k.renameProfile("List", to: "List 2")
    check(k.mod(ModKit.overwriteID(for: "List 2")) != nil && k.profile("List 2")!.mods.contains { $0.id == ModKit.overwriteID(for: "List 2") }, "rename carries the Overwrite")
    try! k.deleteProfile("List 2", removeUnusedMods: false)
    check(k.mod(ModKit.overwriteID(for: "List 2")) == nil, "deleting a profile removes its Overwrite")
}

func driftTests() {
    section("deployed binaries drift back to the mod's copy")
    let f = Fixture("drift")
    let k = f.kit
    let m = f.addMod("Plugin", ["SKSE/Plugins/p.dll": "original dll", "SKSE/Plugins/p.ini": "a=1"])
    try! k.deploy()
    let dll = f.game.appendingPathComponent("Data/SKSE/Plugins/p.dll"), ini = f.game.appendingPathComponent("Data/SKSE/Plugins/p.ini")
    try! fm.removeItem(at: dll); write(dll, "original dlX")        // runtime state written into the file
    try! fm.removeItem(at: ini); write(ini, "a=2")                 // a plugin saving its settings: legitimate
    check(k.restoreDriftedBinaries() == ["Data/SKSE/Plugins/p.dll"], "only the program file is restored")
    check(read(dll) == "original dll" && read(ini) == "a=2", "DLL back to the mod's copy, the settings file untouched")
    check(read(k.stagingFolder(m).appendingPathComponent("SKSE/Plugins/p.dll")) == "original dll", "mod copy unchanged")
    check((try! k.deployer.verify()).changed == ["Data/SKSE/Plugins/p.ini"], "manifest updated for the restored file")
}

func editedFilesFollowProfileTests() {
    section("edited settings files stay with their profile")
    let f = Fixture("editedini")
    let k = f.kit
    _ = f.addMod("Tweaks", ["SKSE/Plugins/tweaks.ini": "speed=1", "SKSE/Plugins/tweaks.dll": "dll"])
    try! k.createProfile("Other")                  // Tweaks disabled there
    try! k.deploy()
    let ini = f.game.appendingPathComponent("Data/SKSE/Plugins/tweaks.ini")
    try! fm.removeItem(at: ini); write(ini, "speed=5")                  // changed in-game (MCM)
    _ = try! k.switchProfile(to: "Other")
    check(read(ini) == nil, "the edited INI doesn't leak into the other profile")
    _ = try! k.switchProfile(to: "Default")
    check(read(ini) == "speed=5", "back in its profile the player's setting is kept")
    check(read(f.game.appendingPathComponent("Data/SKSE/Plugins/tweaks.dll")) == "dll", "program file deployed normally")
}

func reinstallTests() {
    section("reinstall with new installer options")
    let f = Fixture("reinstall")
    let k = f.kit
    let src = freshDir("reinstall-src")
    makeFomodTree(src.appendingPathComponent("m"))
    let zip = src.appendingPathComponent("m.zip")
    pack(src.appendingPathComponent("m"), zip, format: "zip")
    var (w, l) = try! k.beginInstall(archive: zip)
    guard case .fomod(_, let cfg) = l else { check(false, "fomod"); return }
    let a = FomodInstaller(config: try! FomodParser.load(cfg), context: FomodContext(pluginState: { _ in .missing }))
    a.applyAllDefaults(); a.selections[0]?[1] = [2]                         // Zeta extra
    let m = try! k.finishInstall(work: w, layout: l, name: "Fomod Mod", fomod: a, source: SourceArchive(path: zip.path, md5: nil))
    var p = try! k.currentProfile(); p.mods[p.mods.firstIndex { $0.id == m.id }!].enabled = false; try! k.saveProfile(p)
    check(k.sourceArchive(of: m.id) == zip, "source archive found")
    (w, l) = try! k.beginInstall(archive: zip)
    guard case .fomod(_, let cfg2) = l else { check(false, "fomod again"); return }
    let b = FomodInstaller(config: try! FomodParser.load(cfg2), context: FomodContext(pluginState: { _ in .missing }))
    b.replay(k.mod(m.id)!.installChoices!)
    check(b.selections[0]?[1] == [2], "saved choices preselected")
    b.selections[0]?[1] = [0]                                                 // now Alpha extra
    try! k.reinstallMod(m.id, work: w, layout: l, fomod: b)
    let files = snapshot(k.stagingFolder(k.mod(m.id)!))
    check(files["textures/extra/alpha.dds"] == "alpha" && files["textures/extra/zeta.dds"] == nil, "files follow the new choice (\(files.keys.sorted()))")
    check(k.mod(m.id)?.installChoices?.values.contains { $0.contains("Alpha extra") } == true, "new choices saved")
    check(k.mods.filter { $0.name == "Fomod Mod" }.count == 1 && (try! k.currentProfile()).mods.first { $0.id == m.id }?.enabled == false, "same entry, state kept")
}

func endorseTests() {
    section("Nexus endorse (stubbed)")
    var seen: URLRequest?
    var body = ""
    StubProtocol.handler = { req in
        if req.url!.path.hasSuffix("/endorse.json") {
            seen = req
            if let s = req.httpBodyStream { s.open(); var b = [UInt8](repeating: 0, count: 256); let n = s.read(&b, maxLength: 256); body = String(decoding: b.prefix(max(n, 0)), as: UTF8.self); s.close() }
            else { body = String(decoding: req.httpBody ?? Data(), as: UTF8.self) }
            return (200, [:], json(["message": "Updated endorsement status", "status": "Endorsed"]))
        }
        if req.url!.path.hasSuffix("/user/endorsements.json") {
            return (200, [:], json([["mod_id": 12604, "domain_name": "skyrimspecialedition", "status": "Endorsed"], ["mod_id": 5, "domain_name": "skyrim", "status": "Endorsed"]]))
        }
        return (404, [:], json(["message": "nf"]))
    }
    let c = NexusClient(apiKey: "k", appVersion: "t", baseURL: URL(string: "https://api.test/v1/")!, session: stubSession())
    runAsync { try? await c.endorse(modID: 12604, version: "5.2SE") }
    check(seen?.httpMethod == "POST" && seen?.url?.path == "/v1/games/skyrimspecialedition/mods/12604/endorse.json", "POST to the mod's endorse.json (\(seen?.url?.path ?? "-"))")
    check(body == "version=5.2SE" && seen?.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded", "version sent as form data (\(body))")
    let e = runAsync { try await c.endorsements() }
    check(e == [12604: "Endorsed"], "endorsements of Skyrim SE only (\(e))")
}

func colorTagTests() {
    section("colour tags")
    let f = Fixture("colors")
    let k = f.kit
    let a = f.addMod("A", ["a.txt": "a"]), b = f.addMod("B", ["b.txt": "b"])
    k.setColor([a.id, b.id], "green")
    check(k.mod(a.id)?.color == "green" && k.mod(b.id)?.color == "green", "colour set on several mods")
    k.setColor([a.id], nil)
    check(k.mod(a.id)?.color == nil && k.mod(b.id)?.color == "green", "cleared on one")
}

func skseVersionTests() {
    section("SKSE build vs game version")
    let f = Fixture("sksever")
    check(f.kit.deployedSKSEVersion() == nil, "no SKSE → nil")
    _ = f.addMod("SKSE", ["__root__/skse64_1_6_1170.dll": "dll", "__root__/skse64_loader.exe": "exe", "__root__/skse64_steam_loader.dll": "x"])
    try! f.kit.deploy()
    check(f.kit.deployedSKSEVersion() == "1.6.1170", "skse64_1_6_1170.dll → 1.6.1170 (\(f.kit.deployedSKSEVersion() ?? "nil"))")
}

func parallelPrefetchTests() {
    section("collection install: archives fetched in parallel (Premium)")
    let f = Fixture("prefetch")
    let k = f.kit
    let src = freshDir("prefetch-src")
    var zips: [Int: Data] = [:], md5s: [Int: String] = [:]
    for (n, fid) in [("One", 101), ("Two", 102), ("Three", 103)] {
        write(src.appendingPathComponent("\(n)/\(n).esp"), n)
        let z = src.appendingPathComponent("\(n).zip"); pack(src.appendingPathComponent(n), z, format: "zip")
        zips[fid] = try! Data(contentsOf: z); md5s[fid] = try! md5Hex(of: z)
    }
    StubProtocol.peakInFlight = 0
    StubProtocol.latency = { $0.url!.host == "cdn.test" ? 0.3 : 0 }      // each archive takes 0.3 s to "download"
    defer { StubProtocol.latency = nil }
    StubProtocol.handler = { req in
        let p = req.url!.path
        if let r = p.range(of: #"/files/(\d+)/download_link\.json"#, options: .regularExpression) {
            let fid = String(p[r]).components(separatedBy: "/")[2]
            return (200, [:], json([["name": "CDN", "short_name": "CDN", "URI": "https://cdn.test/\(fid).zip"]]))
        }
        if p.hasPrefix("/"), let fid = Int(p.dropFirst().replacingOccurrences(of: ".zip", with: "")), let z = zips[fid] { return (200, [:], z) }
        return (404, [:], json(["message": "nf"]))
    }
    let client = NexusClient(apiKey: "premium", appVersion: "t", baseURL: URL(string: "https://api.test/v1/")!, session: stubSession())
    let mods = [("One", 1, 101), ("Two", 2, 102), ("Three", 3, 103)]
    let m = mods.map { #"{"name":"\#($0.0)","optional":false,"phase":0,"source":{"type":"nexus","modId":\#($0.1),"fileId":\#($0.2),"md5":"\#(md5s[$0.2]!)"}}"# }
    let man = try! CollectionManifest.parse(Data(#"{"info":{"name":"Fast"},"mods":[\#(m.joined(separator: ","))],"modRules":[],"loadOrder":[]}"#.utf8))
    let info = CollectionInfo(slug: "fastco", name: "Fast", revision: 1, downloadLink: "", gameVersions: [], totalSize: 0,
                              files: mods.map { CollectionFile(modID: $0.1, fileID: $0.2, modName: $0.0, fileName: $0.0, version: "1", size: Int64(zips[$0.2]!.count), optional: false) })
    let t0 = Date()
    let prof = runAsync { try await k.installCollection(info: info, manifest: man, items: man.mods, client: client, gameVersion: "1.6.1170", progress: { _, _ in }) }
    let secs = Date().timeIntervalSince(t0)
    check(k.profile(prof)?.mods.compactMap { k.mod($0.id)?.name } == ["One", "Two", "Three"], "all installed, author's order kept")
    check(StubProtocol.peakInFlight >= 2, "downloads ran in parallel (peak \(StubProtocol.peakInFlight))")
    check(secs < 0.85, String(format: "three 0.3 s downloads took %.2f s (sequential would be ≥ 0.9 s)", secs))
}

func sksePrereqTests() {
    section("SKSE plugins without SKSE / Address Library")
    let f = Fixture("skseprereq")
    let k = f.kit
    _ = f.addMod("Plugin", ["SKSE/Plugins/a.dll": "a", "SKSE/Plugins/b.dll": "b", "SKSE/Plugins/b.ini": "x"])
    var r = k.sksePrerequisites()
    check(r.pluginDLLs == 2 && !r.hasSKSE && !r.hasAddressLibrary, "two SKSE plugins, nothing they need (\(r))")
    _ = f.addMod("SKSE", ["__root__/skse64_loader.exe": "l", "__root__/skse64_1_7_104.dll": "d"])
    _ = f.addMod("Address Library", ["SKSE/Plugins/versionlib-1-6-1170-0.bin": "v"])
    r = k.sksePrerequisites()
    check(r.hasSKSE && r.hasAddressLibrary, "found once installed (\(r))")
}

func trackTests() {
    section("Nexus track (stubbed)")
    var reqs: [URLRequest] = []
    StubProtocol.handler = { req in
        if req.url!.path.hasSuffix("/user/tracked_mods.json") {
            reqs.append(req)
            if req.httpMethod == "GET" { return (200, [:], json([["mod_id": 12604, "domain_name": "skyrimspecialedition"], ["mod_id": 1, "domain_name": "fallout4"]])) }
            return (200, [:], json(["message": "ok"]))
        }
        return (404, [:], json(["message": "nf"]))
    }
    let c = NexusClient(apiKey: "k", appVersion: "t", baseURL: URL(string: "https://api.test/v1/")!, session: stubSession())
    runAsync { try? await c.setTracked(modID: 12604, true) }
    runAsync { try? await c.setTracked(modID: 12604, false) }
    check(reqs.map { $0.httpMethod ?? "" } == ["POST", "DELETE"] && reqs.allSatisfy { $0.url?.query == "domain_name=skyrimspecialedition" }, "POST to track, DELETE to untrack, game in the query")
    let t = runAsync { try await c.trackedMods() }
    check(t == [12604], "tracked Skyrim SE mods only (\(t))")
}

func wabbajackCacheTests() {
    section("Wabbajack download cache")
    let f = Fixture("wjcache")
    let k = f.kit
    write(k.wabbajackDownloadsDir.appendingPathComponent("a.7z"), String(repeating: "x", count: 10_000))
    write(k.wabbajackDownloadsDir.appendingPathComponent("b.zip"), String(repeating: "y", count: 5_000))
    let size = ModKit.folderSize(k.wabbajackDownloadsDir)
    check(size >= 15_000, "cache size measured (\(size))")
    let freed = try! k.clearWabbajackDownloads()
    check(freed == size && ((try? fm.contentsOfDirectory(atPath: k.wabbajackDownloadsDir.path)) ?? ["?"]).isEmpty, "cache emptied, folder kept")
}

func modListMarkdownTests() {
    section("mod list for help requests")
    let f = Fixture("modlistmd")
    let k = f.kit
    let a = f.addMod("SkyUI", ["SkyUI_SE.esp": "p"]), b = f.addMod("Off", ["x.txt": "x"])
    let i = k.mods.firstIndex { $0.id == a.id }!; var r = k.mods[i]; r.nexus = NexusRef(modID: 12604); r.version = "5.2"; k.replaceMod(at: i, with: r)
    var p = try! k.currentProfile(); p.mods[p.mods.firstIndex { $0.id == b.id }!].enabled = false; try! k.saveProfile(p)
    let md = k.modListMarkdown(gameVersion: "1.7.104")
    check(md.contains("Skyrim 1.7.104") && md.contains("- SkyUI 5.2 — https://www.nexusmods.com/skyrimspecialedition/mods/12604"), "mods with versions and links")
    check(md.contains("~~Off~~ (disabled)") && !md.contains(f.home.path), "disabled marked; no local paths")
}

func detectToolsTests() {
    section("tools found in installed mods")
    let f = Fixture("detecttools")
    _ = f.addMod("SSEEdit 4.1.5f", ["SSEEdit.exe": "32", "Optional/SSEEdit64.exe": "64", "Edit Scripts/x.pas": "p"])
    let d = f.kit.detectTools(toolPresets)
    check(d["SSEEdit"]?.lastPathComponent == "SSEEdit.exe", "SSEEdit found (\(d.keys.sorted()))")
    check(f.kit.xeditForCleaning()?.lastPathComponent == "SSEEdit.exe", "cleaning prefers 32-bit xEdit")
}

func updatedFilesReachGameTests() {
    section("mod update/reinstall: changed files reach the game")
    let f = Fixture("swapdeploy")
    let m = f.addMod("Swappy", ["textures/a.dds": "v1", "textures/gone.dds": "old"])
    try! f.kit.deploy()
    let work = freshDir("swapdeploy-work")
    write(work.appendingPathComponent("src/textures/a.dds"), "v2 longer")
    write(work.appendingPathComponent("src/textures/new.dds"), "new")
    try! f.kit.swapModFiles(m.id, work: work, layout: .data(root: work.appendingPathComponent("src")), fomod: nil)
    check(try! f.kit.isDirty(), "updated mod makes the profile need a deploy")
    try! f.kit.deploy()
    check(read(f.game.appendingPathComponent("Data/textures/a.dds")) == "v2 longer", "changed file deployed (\(read(f.game.appendingPathComponent("Data/textures/a.dds")) ?? "nil"))")
    check(read(f.game.appendingPathComponent("Data/textures/new.dds")) == "new" && read(f.game.appendingPathComponent("Data/textures/gone.dds")) == nil, "added/removed files follow")
    check((try! f.kit.deployer.verify()).ok, "manifest matches")
}

func primaryFileTests() {
    section("Nexus: several MAIN files — the author's primary one is installed (CBBE)")
    StubProtocol.handler = { req in
        if req.url!.path.hasSuffix("/mods/198/files.json") {
            return (200, [:], json(["files": [
                ["file_id": 489053, "name": "Caliente's Beautiful Bodies Enhancer CBBE - v2.0.3", "file_name": "cbbe.7z", "version": "2.0.3", "category_name": "MAIN", "is_primary": true, "uploaded_timestamp": 100],
                ["file_id": 489055, "name": "CBBE AE-CC Outfits", "file_name": "cc.7z", "version": "2.0.3", "category_name": "MAIN", "is_primary": false, "uploaded_timestamp": 200],
                ["file_id": 63781, "name": "Normal Map Options", "file_name": "n.7z", "version": "1.4", "category_name": "OPTIONAL", "is_primary": false, "uploaded_timestamp": 300]]]))
        }
        if req.url!.path.hasSuffix("/mods/5/files.json") {
            return (200, [:], json(["files": [
                ["file_id": 1, "name": "Old main", "file_name": "a.7z", "version": "1", "category_name": "MAIN", "uploaded_timestamp": 100],
                ["file_id": 2, "name": "New main", "file_name": "b.7z", "version": "2", "category_name": "MAIN", "uploaded_timestamp": 200]]]))
        }
        return (404, [:], json(["message": "nf"]))
    }
    let c = NexusClient(apiKey: "k", appVersion: "t", baseURL: URL(string: "https://api.test/v1/")!, session: stubSession())
    let sem = DispatchSemaphore(value: 0)
    var a: Int?, b: Int?
    Task { a = try? await c.mainFile(modID: 198)?.fileID; b = try? await c.mainFile(modID: 5)?.fileID; sem.signal() }
    sem.wait()
    check(a == 489053, "CBBE: the body (primary), not the newer outfits file (\(a ?? -1))")
    check(b == 2, "no primary flag: newest MAIN file")
}
