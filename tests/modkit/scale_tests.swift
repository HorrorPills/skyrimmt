// Scale suite (docs/MODMANAGER.md §5): a synthetic home the size of the biggest lists (2,000 mods / 500k files, 600
// plugins) and the operations the Mod Manager runs on every refresh, against budgets. Run: run.sh scale
import Foundation

func timed<T>(_ label: String, budget: Double, _ body: () throws -> T) rethrows -> T {
    let t = Date(); let r = try body(); let s = Date().timeIntervalSince(t)
    print(String(format: "  %-38@ %7.3f s  (budget %.2f s)", label as NSString, s, budget))
    check(s < budget, "\(label) under \(budget) s (\(String(format: "%.3f", s)))")
    return r
}

func scaleTests(mods: Int = 2000, filesPerMod: Int = 250) {
    section("scale: \(mods) mods × \(filesPerMod) files")
    let f = Fixture("scale")
    let t0 = Date()
    var ids: [String] = []
    for i in 0..<mods {
        let tmp = f.home.appendingPathComponent("incoming/m\(i)")
        var made = Set<String>()
        for k in 0..<filesPerMod {
            let rel = k % 10 == 0 ? "textures/shared/\(i % 50)/\(k).dds" : "meshes/m\(i)/sub\(k % 20)/\(k).nif"
            let u = tmp.appendingPathComponent(rel)
            let dir = u.deletingLastPathComponent().path
            if made.insert(dir).inserted { try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true) }
            _ = fm.createFile(atPath: u.path, contents: nil)
        }
        if i % 3 == 0 { write(tmp.appendingPathComponent("Mod\(i).esp"), "TES4") }      // ~670 plugins
        let m = try! f.kit.addMod(name: "Scale \(i)", from: tmp)
        ids.append(m.id)
    }
    print(String(format: "  home created in %.0f s", Date().timeIntervalSince(t0)))
    let k = timed("reopen ModKit (mods + profile)", budget: 1.0) { () -> ModKit in
        let k = ModKit(home: f.home, gameDir: f.game, pluginsTxt: fixturePluginsTxt(f.home)); _ = try! k.currentProfile(); return k }
    let p = try! k.currentProfile()
    let plan = timed("plan (all files, conflicts)", budget: 2.5) { try! k.plan(p) }
    check(plan.files.count > mods * filesPerMod * 85 / 100, "plan covers the files (\(plan.files.count))")
    _ = timed("load order (headers of every plugin)", budget: 1.5) { k.loadOrder() }
    _ = timed("per-file conflicts of one mod (app: cached plan)", budget: 0.3) { try! k.fileConflicts(of: ids[mods / 2], plan: plan) }
    _ = timed("dirty check (cached plan)", budget: 0.5) { try! k.isDirty(plan: plan) }
    _ = timed("files of one mod", budget: 0.2) { k.modFiles(ids[mods / 2]) }
    _ = timed("cached updates", budget: 0.2) { k.cachedUpdates() }
    _ = timed("downloads index", budget: 0.5) { k.downloadEntries() }
    var q = p
    timed("toggle + move + save profile", budget: 0.5) { q.mods[5].enabled.toggle(); q.mods.swapAt(7, 9); try! k.saveProfile(q) }
    ModKit.historyCoalesce = 0
    for i in 0..<100 { q.mods[i % 50].enabled.toggle(); try! k.saveProfile(q) }   // 100 versions of a 2,000-mod profile
    ModKit.historyCoalesce = 3
    let h = timed("profile history listing (100 versions)", budget: 1.0) { k.profileHistory(p.name) }
    check(h.count >= 100, "history kept (\(h.count))")
    try? fm.removeItem(at: f.home)
}

func driftCheckSpeedTest() {
    section("drift check at Play is fast on big deploys")
    let f = Fixture("driftspeed")
    var files: [String: String] = ["SKSE/Plugins/p.dll": "dll"]
    for i in 0..<20_000 { files["textures/t/\(i).dds"] = "x" }
    _ = f.addMod("Big", files)
    try! f.kit.deploy()
    let t = Date(); _ = f.kit.restoreDriftedBinaries(); let s = Date().timeIntervalSince(t)
    check(s < 0.15, String(format: "drift check over 20,001 deployed files: %.3f s", s))
}
