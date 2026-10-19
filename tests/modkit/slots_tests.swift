// Instant profile switching (Slots.swift): parked Data folders per profile.
import Foundation

/// Two profiles over shared mods: A = M1 + M2 (M2 replaces a vanilla file, ships an SKSE root file), B = M2 off, M3 on.
private func slotFixture(_ name: String) -> (Fixture, [String: String]) {
    let f = Fixture(name)
    write(f.game.appendingPathComponent("Data/mine/notes.txt"), "player's own file")   // not vanilla, not deployed
    let vanilla = snapshot(f.game)
    let m1 = f.addMod("M1", ["textures/m1.dds": "m1", "textures/shared.dds": "m1 shared"])
    let m2 = f.addMod("M2", ["interface/vanilla.swf": "m2 swf", "textures/shared.dds": "m2 shared", "__root__/skse_loader.exe": "loader"])
    let m3 = f.addMod("M3", ["textures/m3/a.dds": "m3a", "textures/vanilla/rock.dds": "m3 rock"])
    var a = try! f.kit.currentProfile()
    a.name = "A"; a.mods = [ProfileMod(id: m1.id, enabled: true), ProfileMod(id: m2.id, enabled: true), ProfileMod(id: m3.id, enabled: false)]
    try! f.kit.saveProfile(a)
    try! atomicWrite("A\n", to: f.kit.currentURL)
    var b = a; b.name = "B"; b.mods = [ProfileMod(id: m3.id, enabled: true), ProfileMod(id: m2.id, enabled: false), ProfileMod(id: m1.id, enabled: true)]
    try! f.kit.saveProfile(b)
    try! f.kit.deploy()
    return (f, vanilla)
}

private func backupFiles(_ f: Fixture) -> Int {
    let root = f.kit.deployer.layout.backupDir
    guard let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { return 0 }
    var n = 0
    for case let u as URL in en where (try? u.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true { n += 1 }
    return n
}

func slotTests() {
    section("instant profile switching: parked Data folders")
    let (f, vanilla) = slotFixture("slots")
    let k = f.kit
    func want(_ name: String) -> [String: String] { expected(vanilla: vanilla, profile: k.profile(name)!, kit: k) }
    check(!k.instantSwitching, "off by default")
    try! k.setInstantSwitching(true)
    check(snapshot(f.game) == want("A"), "A deployed")
    _ = try! k.switchProfile(to: "B")
    check(snapshot(f.game) == want("B"), "first switch to B: vanilla Data built, B deployed")
    check((try! k.deployer.verify()).ok, "manifest matches the game after the first switch")
    check(k.parkedProfiles() == ["A"], "A parked (\(k.parkedProfiles()))")
    let r = try! k.switchProfile(to: "A")
    check(snapshot(f.game) == want("A"), "back to A from its slot")
    check(r.cloned == 1 && r.removed == 0, "A's Data needed no file work, only its game-root file (+\(r.cloned) −\(r.removed))")
    check(k.parkedProfiles() == ["B"], "B parked now")
    check((try! k.deployer.verify()).ok, "manifest matches after unparking")

    section("instant switching: profile edited while parked")
    var b = k.profile("B")!
    b.mods[0].enabled = false; b.mods[1].enabled = true
    try! k.saveProfile(b)
    let m1 = k.mods.first { $0.name == "M1" }!
    let work = freshDir("slots-update")
    write(work.appendingPathComponent("src/textures/m1.dds"), "m1 version 2")
    write(work.appendingPathComponent("src/textures/shared.dds"), "m1 shared")
    try! k.swapModFiles(m1.id, work: work, layout: .data(root: work.appendingPathComponent("src")), fomod: nil)   // M1 updated in place
    _ = try! k.switchProfile(to: "B")
    check(snapshot(f.game) == want("B"), "parked B picks up its edits and M1's update")
    _ = try! k.switchProfile(to: "A")
    check(snapshot(f.game) == want("A") && read(f.game.appendingPathComponent("Data/textures/m1.dds")) == "m1 version 2", "A shows M1's update too")

    section("instant switching: Steam updates the game")
    _ = try! k.switchProfile(to: "B")
    _ = try! k.switchProfile(to: "A")   // B parked
    write(f.game.appendingPathComponent("SkyrimSE.exe"), "exe build 2")
    write(f.game.appendingPathComponent("Data/Skyrim - Textures0.bsa"), "vanilla bsa build 2")   // Steam writes the live Data only
    var vanilla2 = vanilla; vanilla2["skyrimse.exe"] = "exe build 2"; vanilla2["data/skyrim - textures0.bsa"] = "vanilla bsa build 2"
    _ = try! k.switchProfile(to: "B")
    check(snapshot(f.game) == expected(vanilla: vanilla2, profile: k.profile("B")!, kit: k), "B's old-build slot discarded, rebuilt from the updated game")

    section("instant switching: rename, delete, purge, turn off")
    try! k.renameProfile("A", to: "A2")
    check(k.parkedProfiles() == ["A2"], "slot follows the rename")
    _ = try! k.switchProfile(to: "A2")
    check(snapshot(f.game) == expected(vanilla: vanilla2, profile: k.profile("A2")!, kit: k), "renamed profile unparks")
    try! k.deleteProfile("B", removeUnusedMods: false)
    check(k.parkedProfiles().isEmpty, "deleting a profile discards its slot")
    try! k.createProfile("C", cloneFrom: "A2")
    _ = try! k.switchProfile(to: "C")
    _ = try! k.switchProfile(to: "A2")
    try! k.purge()
    check(snapshot(f.game) == vanilla2, "purge with a parked profile → vanilla + player's file")
    _ = try! k.switchProfile(to: "C")
    _ = try! k.switchProfile(to: "A2")
    try! k.setInstantSwitching(false)
    check(k.parkedProfiles().isEmpty && !fm.fileExists(atPath: k.slotsRoot.appendingPathComponent(".building").path), "turning it off removes every slot")
    _ = try! k.switchProfile(to: "C")
    check(snapshot(f.game) == expected(vanilla: vanilla2, profile: k.profile("C")!, kit: k), "normal switching works after turning it off")
    try! k.purge()
    check(snapshot(f.game) == vanilla2 && backupFiles(f) == 0, "nothing left behind: vanilla game, no orphaned backups (\(backupFiles(f)))")
}

/// A crash at every step of a swap (first switch and from-slot switch) and inside the deploy that follows: a new
/// process recovers, the game ends up exactly as the target profile, and both purge and switching back stay correct.
func slotCrashTests() {
    section("instant switching: crash at every step → recovery")
    for fromSlot in [false, true] {
        for step in 1...8 where fromSlot || step != 7 {   // step 7 = merging the parked manifest
            let (f, vanilla) = slotFixture("slotcrash")
            try! f.kit.setInstantSwitching(true)
            if fromSlot { _ = try! f.kit.switchProfile(to: "B"); _ = try! f.kit.switchProfile(to: "A") }   // B parked
            if step == 8 { f.kit.deployer.failAfterOps = fromSlot ? 0 : 2 } else { f.kit.slotFailAt = step }
            var crashed = false
            do { _ = try f.kit.switchProfile(to: "B") } catch DeployError.simulatedCrash { crashed = true } catch { check(false, "unexpected \(error)") }
            check(crashed, "step \(step) (fromSlot \(fromSlot)): crash simulated")
            let k2 = ModKit(home: f.home, gameDir: f.game, pluginsTxt: fixturePluginsTxt(f.home))   // a new process
            _ = try! k2.switchProfile(to: "B")
            let tag = "step \(step), \(fromSlot ? "parked B" : "first switch")"
            check(snapshot(f.game) == expected(vanilla: vanilla, profile: k2.profile("B")!, kit: k2), "\(tag): B correct after recovery")
            check((try! k2.deployer.verify()).ok && !fm.fileExists(atPath: k2.slotJournalURL.path), "\(tag): manifest matches, journal gone")
            _ = try! k2.switchProfile(to: "A")
            check(snapshot(f.game) == expected(vanilla: vanilla, profile: k2.profile("A")!, kit: k2), "\(tag): back to A")
            try! k2.setInstantSwitching(false)
            try! k2.purge()
            check(snapshot(f.game) == vanilla && backupFiles(f) == 0, "\(tag): purge → vanilla, no orphaned backups (\(backupFiles(f)))")
        }
    }
}

/// Switch time with big profiles: parked vs normal.
func slotBench(mods: Int = 200, filesPerMod: Int = 250) {
    section("instant switching benchmark: 2 profiles × \(mods / 2) mods × \(filesPerMod) files")
    let f = Fixture("slotbench")
    var ids: [String] = []
    for i in 0..<mods {
        let tmp = f.home.appendingPathComponent("incoming/m\(i)")
        for d in 0..<10 { try? fm.createDirectory(at: tmp.appendingPathComponent("textures/m\(i)/d\(d)"), withIntermediateDirectories: true) }
        for j in 0..<filesPerMod { _ = fm.createFile(atPath: tmp.appendingPathComponent("textures/m\(i)/d\(j % 10)/\(j).dds").path, contents: Data("x".utf8)) }
        ids.append(try! f.kit.addMod(name: "Bench \(i)", from: tmp).id)
    }
    var a = try! f.kit.currentProfile(); a.name = "A"
    a.mods = ids.enumerated().map { ProfileMod(id: $1, enabled: $0 % 2 == 0) }
    try! f.kit.saveProfile(a); try! atomicWrite("A\n", to: f.kit.currentURL)
    var b = a; b.name = "B"; b.mods = ids.enumerated().map { ProfileMod(id: $1, enabled: $0 % 2 == 1) }; try! f.kit.saveProfile(b)
    try! f.kit.deploy()
    let n = mods / 2 * filesPerMod
    var t = Date(); _ = try! f.kit.switchProfile(to: "B"); let normal = Date().timeIntervalSince(t)
    try! f.kit.setInstantSwitching(true)
    t = Date(); _ = try! f.kit.switchProfile(to: "A"); let first = Date().timeIntervalSince(t)
    t = Date(); _ = try! f.kit.switchProfile(to: "B"); let parked1 = Date().timeIntervalSince(t)
    t = Date(); _ = try! f.kit.switchProfile(to: "A"); let parked2 = Date().timeIntervalSince(t)
    func time(_ what: String, _ body: () -> Void) { let t = Date(); body(); print(String(format: "    %@: %.3f s", what, Date().timeIntervalSince(t))) }
    time("Manifest.load") { _ = try! Manifest.load(f.kit.deployer.layout.manifestURL) }
    let mm = try! Manifest.load(f.kit.deployer.layout.manifestURL)
    time("Manifest.save") { try! mm.save(f.home.appendingPathComponent("m.tsv")) }
    time("captureGenerated") { _ = try! f.kit.captureGenerated() }
    time("unmanagedFiles") { _ = try! f.kit.deployer.unmanagedFiles() }
    time("verify") { _ = try! f.kit.deployer.verify() }
    time("plan") { _ = try! f.kit.plan() }
    time("deploy (no change)") { _ = try! f.kit.deploy() }
    time("isDirty") { _ = try! f.kit.isDirty() }
    print(String(format: "  %d files per profile: normal switch %.2f s · first parked switch %.2f s · parked switches %.2f s / %.2f s", n, normal, first, parked1, parked2))
    check(parked2 < normal / 3, "parked switch at least 3× faster than a normal one")
    try? fm.removeItem(at: f.home)
}
