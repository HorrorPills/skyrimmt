// skyrimmt-cli — ModKit from the command line (autopilot / repair jobs).
//   skyrimmt-cli repair-collection <slug> <order.json> <gameVersion>
//     installs required collection files that are missing, from $SKYRIM_HOME/downloads (by .meta.json mod/file ids),
//     with FOMOD defaults (Rosetta-safe), placed after their nearest installed predecessor in the collection order;
//     then deploys the current profile.
//   skyrimmt-cli install <archive> [name]   install with FOMOD defaults (Rosetta-safe) into the current profile
//   skyrimmt-cli mo2-import <MO2 instance> [--profile P] [--as Name] [--vanilla <game dir>] [--version V]
//   skyrimmt-cli wabbajack info <file.wabbajack> | install <author/list|file.wabbajack>   (env NEXUS_API_KEY, STEAM_GAMEDIR…)
//   skyrimmt-cli bodyslide [scan|--if-needed] [--family auto|3BA|CBBE|…] [--preset name|none]   BodySlide Output mod
//   skyrimmt-cli pandora [--if-needed]   regenerate the profile's Pandora Output mod (animation behaviours)
import Foundation

let home = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SKYRIM_HOME"] ?? NSHomeDirectory() + "/Games/skyrim")
let kit = ModKit.standard(home: home)
let a = Array(CommandLine.arguments.dropFirst())
if a.first == "deploy" {
    let p = try kit.currentProfile()
    let plan = try kit.plan(p)
    for (rel, why) in plan.hidden.sorted(by: { $0.key < $1.key }) { print("hidden: \(rel) — \(why)") }
    let r = try kit.deploy(p)
    print(String(format: "profile %@ → %@: deployed in %.1f s (+%d −%d, unchanged %d)", p.name, kit.gameDir.lastPathComponent, r.seconds, r.cloned + r.linked + r.copied, r.removed, r.unchanged))
    exit(0)
}
if a.first == "switch", a.count == 2 {   // skyrimmt-cli switch <profile> — like the Profiles page (timed)
    let t0 = Date()
    do { let r = try kit.switchProfile(to: a[1]); print(String(format: "switched to %@ in %.2f s (+%d −%d, unchanged %d)", a[1], Date().timeIntervalSince(t0), r.cloned + r.linked + r.copied, r.removed, r.unchanged)); exit(0) }
    catch { print("error: \(error)"); exit(1) }
}
if a.first == "instant", a.count == 2 {   // skyrimmt-cli instant on|off|status — instant profile switching (parked Data folders)
    if a[1] == "status" { print("instant switching \(kit.instantSwitching ? "on" : "off"); parked: \(kit.parkedProfiles())"); exit(0) }
    do { try kit.setInstantSwitching(a[1] == "on"); print("instant switching \(a[1])"); exit(0) } catch { print("error: \(error)"); exit(1) }
}
if a.first == "guard" {   // skyrimmt-cli guard [mod name] — playthroughs; with a mod: what turning it off would risk (read-only)
    for s in kit.playthroughs() { print("\(s.player), level \(s.level), \(s.location) — \(s.saved) — \(s.allPlugins.count) plugins (\(s.url.lastPathComponent))") }
    if a.count >= 2 {
        guard let m = kit.mods.first(where: { $0.name.lowercased() == a[1].lowercased() }) else { print("no mod named \(a[1])"); exit(1) }
        let lost = kit.pluginsLost(disabling: [m.id])
        print("turning off \(m.name): plugins lost \(lost)")
        for r in kit.playthroughRisks(plugins: lost) { print("  at risk: \(r.save.player) (level \(r.save.level)) uses \(r.plugins)") }
    }
    exit(0)
}
if a.first == "snapshot" {   // skyrimmt-cli snapshot [reason] | snapshot list | snapshot restore <id> | snapshot delete <id>
    do {
        if a.count >= 2 && a[1] == "list" { for s in kit.snapshots() { print("\(s.id)  \(s.profile)  \(s.reason)  files: \(s.savedMods.count)") }; exit(0) }
        if a.count >= 3 && (a[1] == "restore" || a[1] == "delete"), let s = kit.snapshots().first(where: { $0.id == a[2] }) {
            if a[1] == "delete" { kit.deleteSnapshot(s); print("deleted"); exit(0) }
            let r = try kit.restoreSnapshot(s); _ = try kit.deploy()
            print("restored \(s.id): files \(r.restoredFiles), missing \(r.missing), undo \(r.undo?.id ?? "-")"); exit(0)
        }
        let s = try kit.takeSnapshot(reason: a.count >= 2 ? a[1...].joined(separator: " ") : "Taken from the command line")
        print("snapshot \(s.id) (\(s.profile), files of \(s.savedMods.count) mods)"); exit(0)
    } catch { print("error: \(error)"); exit(1) }
}
if a.first == "perf-sample", a.count == 2 {   // skyrimmt-cli perf-sample <bench dir> — frames/fps of a bench run (start→end)
    let d = URL(fileURLWithPath: a[1])
    do { let s = try FrameTrace.sample(csv: d.appendingPathComponent("frames.csv"), marks: d.appendingPathComponent("marks.txt"))
         print(String(format: "%d frames, %.1f fps, mean %.2f ms, p99 %.2f ms", s.frames, s.fps, s.meanMs, s.p99Ms)); exit(0) }
    catch { print("error: \(error)"); exit(1) }
}
if a.first == "perf-candidates" {   // skyrimmt-cli perf-candidates — what the Performance page would offer (read-only)
    let save = kit.benchSave().flatMap { try? SaveReader.read($0) }
    print("bench save: \(kit.benchSave()?.path ?? "none") (\(save?.allPlugins.count ?? 0) plugins)")
    for c in (try? kit.perfCandidates(limit: 30, save: save)) ?? [] {
        print(String(format: "%8.0f MB  %@", Double(c.assetBytes) / 1e6, c.name) + (c.together.isEmpty ? "" : "  (+\(c.together.map { kit.mod($0)?.name ?? $0 }.joined(separator: ", ")))"))
    }
    exit(0)
}
if a.first == "dirty" {   // skyrimmt-cli dirty — why the profile needs a deploy (read-only)
    let plan = try! kit.plan(), m = try! Manifest.load(kit.deployer.layout.manifestURL)
    let add = plan.files.keys.filter { m.entries[$0]?.source != plan.files[$0]!.source }, rem = m.entries.keys.filter { plan.files[$0] == nil }
    let stale = kit.deployer.staleKeys(m, plan.files)
    print("to add \(add.count), to remove \(rem.count), changed in staging \(stale.count)")
    for k in (add + rem + stale).sorted().prefix(15) { print("  " + k) }
    exit(0)
}
if a.first == "tool-install", a.count == 3 {   // skyrimmt-cli tool-install <release.conf> <pandora|bodyslide|wabbajack>
    guard let p = ModKit.toolPackages(conf: URL(fileURLWithPath: a[1]))[a[2]] else { print("no package \(a[2])"); exit(1) }
    do { try kit.installToolPackage(p); print("installed \(p.name): \(kit.toolInstalled(p))"); exit(0) } catch { print("error: \(error)"); exit(1) }
}
if a.first == "rename-mod", a.count == 3 {   // skyrimmt-cli rename-mod <id prefix> <new name>
    guard let m = kit.mods.first(where: { $0.id.hasPrefix(a[1]) }) else { print("no mod \(a[1])"); exit(1) }
    do { try kit.renameMod(m.id, to: a[2]); print("renamed \(m.name) → \(a[2])"); exit(0) } catch { print("error: \(error)"); exit(1) }
}
if a.first == "crash" {   // skyrimmt-cli crash [log] — analyse the newest (or given) Crash Logger log
    guard let url = a.count > 1 ? URL(fileURLWithPath: a[1]) : kit.crashLogs().first else { print("no crash logs in \(kit.crashLogDir.path)"); exit(0) }
    guard let r = kit.analyzeCrash(url) else { print("not a Crash Logger log"); exit(1) }
    print("\(url.lastPathComponent) — Skyrim \(r.gameVersion) — \(r.exception)\n\(r.summary)")
    for h in r.hints { print("hint: " + h) }
    print("call stack mods: " + r.stackModules.filter { !CrashLogParser.isSystem($0) }.joined(separator: ", "))
    print("objects: " + r.objects.joined(separator: ", "))
    for s in r.suspects.prefix(8) { print(String(format: "  %5.1f  %@", s.score, s.modName)); for e in s.evidence.prefix(3) { print("         · " + e) } }
    print("signature: \(CrashFix.signature(r)) · profile: \(r.profile ?? "?")")
    print("crash fix would test: " + kit.crashFixCandidates(r).map { kit.mod($0)?.name ?? $0 }.joined(separator: " → "))
    exit(0)
}
if a.first == "save" {   // skyrimmt-cli save [file.ess] — what the newest (or given) save needs vs the profile
    guard let url = a.count > 1 ? URL(fileURLWithPath: a[1]) : kit.saveFiles().first else { print("no saves in \(kit.savesDir.path)"); exit(0) }
    let t0 = Date()
    let s = try SaveReader.read(url)
    print(String(format: "%@ — %@ level %d, %@ (%@), saved %@ — read in %.0f ms", url.lastPathComponent, s.player, s.level, s.location, s.race, s.saved.description, Date().timeIntervalSince(t0) * 1000))
    print("plugins: \(s.plugins.count) full + \(s.lightPlugins.count) light")
    let c = kit.checkSave(s)
    print(c.ok ? "OK for profile \(try kit.currentProfile().name)" : "missing \(c.missing.count), switched off \(c.fixable.count)")
    for m in c.missing.prefix(10) { print("  missing: " + m) }
    for f in c.fixable.prefix(10) { print("  off: \(f.plugin) (\(f.fix))") }
    print("active but not in the save: \(c.added.count)")
    exit(0)
}
if a.first == "collection-diff", a.count >= 2 {   // skyrimmt-cli collection-diff <slug> [revision]
    let ref = CollectionRef(a.count > 2 ? "https://www.nexusmods.com/games/skyrimspecialedition/collections/\(a[1])/revisions/\(a[2])" : a[1])!
    let sem = DispatchSemaphore(value: 0)
    Task {
        do {
            let info = try await NexusClient(apiKey: nil, appVersion: "cli").collection(ref)
            let d = kit.collectionDiff(slug: a[1], latest: info)
            print("rev \(d.fromRevision) → \(d.toRevision): \(d.summary)")
            print("new: \(d.added.prefix(10))\nupdated: \(d.changed.prefix(10))\nremoved: \(d.removed.prefix(10))")
        } catch { print(error) }
        sem.signal()
    }
    sem.wait(); exit(0)
}
if a.first == "clean", a.count >= 3 {   // skyrimmt-cli clean <xEdit.exe> <Plugin> [--test] — Quick Auto Clean into the Cleaned Plugins mod
    let job = try kit.prepareCleaning(plugin: a[2], xedit: URL(fileURLWithPath: a[1]))
    print("workspace \(job.workspace.path)\nargs: \(job.arguments.joined(separator: " "))")
    let root = ProcessInfo.processInfo.environment["SKYRIMMT_ROOT"] ?? FileManager.default.currentDirectoryPath
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/bash")
    p.arguments = [root + "/scripts/run-exe.sh", "--wait", job.xedit.path] + job.arguments
    let t0 = Date(); try p.run(); p.waitUntilExit()
    let r = try kit.finishCleaning(job, keep: !a.contains("--test"))
    print(String(format: "xEdit exited %d after %.0f s — changed: %@, ITMs removed: %d, references undeleted: %d", p.terminationStatus, Date().timeIntervalSince(t0),
                 r.changed ? "yes" : "no", r.removedITMs, r.undeletedRefs))
    print(r.log.components(separatedBy: "\n").suffix(12).joined(separator: "\n"))
    exit(0)
}
if a.first == "loot-sort" {   // skyrimmt-cli loot-sort [--dry-run]
    let helper = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SKYRIMMT_LOOT"] ?? "helpers/loot/target/release/skyrimmt-loot")
    let r = try kit.lootSort(helper: helper, apply: !a.contains("--dry-run"))
    print(String(format: "LOOT sorted %d plugins in %.1f s; %d positions changed%@", r.sorted.count, r.seconds, r.moved, a.contains("--dry-run") ? " (dry run)" : ""))
    let warn = r.plugins.flatMap { p, ms in ms.filter { $0.type != "say" }.map { "\(p): \($0.text)" } }.sorted()
    print("\(warn.count) warnings/errors"); for w in warn.prefix(10) { print("  " + w) }
    for (p, d) in r.dirty.sorted(by: { $0.key < $1.key }) { print("dirty: \(p) — \(d.summary) [\(d.crc)]\(d.autoCleanable ? "" : " (not auto-cleanable)")") }
    exit(0)
}
if a.first == "pandora" {   // skyrimmt-cli pandora [--if-needed]
    if a.contains("--if-needed") && !kit.pandoraNeedsRun() { print("Pandora output is up to date"); exit(0) }
    let inputs = try kit.pandoraInputs()
    let r = try kit.runPandora()
    print(String(format: "Pandora: %d input files → %d output files in %.1f s (%d warnings, %d errors)", inputs.count, r.files, r.seconds, r.warnings, r.errors.count))
    for e in r.errors.prefix(5) { print("  " + e) }
    exit(0)
}
if a.first == "bodyslide" {   // skyrimmt-cli bodyslide [scan|--if-needed] [--family F] [--preset P]
    if a.contains("scan") {
        let s = try kit.bodySlideScan()
        print("outfits \(s.outfits.count), presets \(s.presets.count), RaceMenu \(s.hasRaceMenu), detected family \(s.detectedFamily ?? "none")")
        for (f, n) in s.familyCounts.sorted(by: { $0.key < $1.key }) { print("  \(f): \(n) outfits") }
        let plan = kit.bodySlidePlan(s, family: kit.bodySlideSettings().family ?? s.detectedFamily, profile: try kit.currentProfile())
        print("would build \(plan.outfits.count) outfits, \(plan.choices.count) contested outputs")
        let inp = try kit.bodySlideInputs()
        print("inputs \(inp.count) files, fingerprint \(inp.fingerprint.prefix(12)), stale \(kit.bodySlideNeedsRun())")
        exit(0)
    }
    var st = kit.bodySlideSettings()
    if let i = a.firstIndex(of: "--family"), i + 1 < a.count { st.family = a[i + 1] == "auto" ? nil : a[i + 1] }
    if let i = a.firstIndex(of: "--preset"), i + 1 < a.count { st.preset = a[i + 1] == "none" ? nil : a[i + 1] }
    if st != kit.bodySlideSettings() { try kit.setBodySlideSettings(st) }
    if a.contains("--if-needed") && !kit.bodySlideNeedsRun() { print("BodySlide output is up to date"); exit(0) }
    let r = try kit.runBodySlide()
    print(String(format: "BodySlide (%@): %d outfits → %d files in %.1f s, %d failed", r.family ?? "no family", r.outfits, r.files, r.seconds, r.failed.count))
    for f in r.failed.prefix(10) { print("  failed: " + f) }
    exit(0)
}
if a.first == "install", a.count >= 2 {   // skyrimmt-cli install <archive> [name]: FOMOD defaults (Rosetta-safe), enabled in the current profile
    let archive = URL(fileURLWithPath: a[1])
    let (work, layout) = try kit.beginInstall(archive: archive)
    var fomod: FomodInstaller?
    if case .fomod(_, let cfg) = layout {
        let inst = FomodInstaller(config: try FomodParser.load(cfg), context: kit.fomodContext(gameVersion: kit.gameVersionKey))
        inst.applyAllDefaults(); inst.makeRosettaSafe()
        for p in inst.problems() { print("  fomod: \(p)") }
        fomod = inst
    }
    let name = a.count > 2 ? a[2] : archive.deletingPathExtension().lastPathComponent
    let rec = try kit.finishInstall(work: work, layout: layout, name: name, fomod: fomod)
    print("installed \(rec.name) → \(rec.folder)\(fomod != nil ? " (FOMOD defaults)" : "")")
    exit(0)
}
if a.first == "wabbajack", a.count >= 3 {   // skyrimmt-cli wabbajack info <file> | install <author/list|file.wabbajack>
    let env = ProcessInfo.processInfo.environment
    if a[1] == "gallery" {   // skyrimmt-cli wabbajack gallery <search>
        let sem = DispatchSemaphore(value: 0); var list: [WabbajackGalleryEntry] = []; var err: Error?
        Task { do { list = try await kit.loadWabbajackGallery() } catch { err = error }; sem.signal() }
        sem.wait(); if let err { throw err }
        let q = a[2].lowercased()
        let hits = list.filter { q == "*" || $0.title.lowercased().contains(q) }
        for e in hits.prefix(20) { print("\(e.machineURL) — \(e.title) \(e.version) — \(ByteCountFormatter.string(fromByteCount: e.downloadSize, countStyle: .file)) download\(e.nsfw ? " [NSFW]" : "")") }
        print("\(hits.count) of \(list.count) Skyrim SE lists")
        exit(0)
    }
    if a[1] == "info" {
        let i = try ModKit.wabbajackInfo(URL(fileURLWithPath: a[2]))
        print("\(i.name) \(i.version) by \(i.author) — \(i.game) \(i.gameVersion ?? "(no game files)") — \(i.archives) archives (\(i.nexusArchives) Nexus), \(i.directives) directives")
        exit(0)
    }
    if a[1] == "install" {
        let root = URL(fileURLWithPath: env["SKYRIMMT_ROOT"] ?? FileManager.default.currentDirectoryPath)
        let e = WabbajackEngine(engine: URL(fileURLWithPath: env["SKYRIMMT_WABBAJACK"] ?? home.appendingPathComponent("tools/wabbajack/jackify-engine").path),
                                wine: URL(fileURLWithPath: env["SKYRIMMT_WINE"] ?? home.appendingPathComponent("wine/bin/wine").path),
                                shim: root.appendingPathComponent("scripts/wabbajack-wine.sh"))
        let info = a[2].hasSuffix(".wabbajack") ? try ModKit.wabbajackInfo(URL(fileURLWithPath: a[2])) : nil
        let steam = URL(fileURLWithPath: env["STEAM_GAMEDIR"] ?? "")
        let game = try kit.gameDirFor(listVersion: info?.gameVersion, steamGameDir: steam, steamVersion: env["STEAM_GAME_VERSION"] ?? "")
        var last = ""
        let r = try kit.installWabbajackList(e, source: a[2], info: info, gameDir: game, nexusKey: env["NEXUS_API_KEY"]) { line, _ in
            if line != last { last = line; print(line) }
        }
        print(String(format: "imported as profile “%@”: %d mods (%d files), %d game-root files, %d plugins, %d INIs in %.0f s; missing: %d",
                     r.profile, r.mods, r.files, r.gameRootFiles, r.plugins, r.inis, r.seconds, r.missing.count))
        exit(0)
    }
}
if a.first == "mo2-import", a.count >= 2 {   // skyrimmt-cli mo2-import <instance> [--profile P] [--as Name] [--vanilla <game dir>] [--version V]
    func opt(_ n: String) -> String? { a.firstIndex(of: n).flatMap { $0 + 1 < a.count ? a[$0 + 1] : nil } }
    let inst = try MO2Instance.open(URL(fileURLWithPath: a[1]))
    let prof = opt("--profile") ?? inst.selectedProfile ?? inst.profiles.first ?? "Default"
    print("instance: game \(inst.gameDir?.path ?? "none"), profiles \(inst.profiles), using \(prof): \(inst.modlist(prof).count) mods, \(inst.loadOrder(prof).count) plugins")
    let r = try kit.importMO2(inst, profile: prof, as: opt("--as") ?? URL(fileURLWithPath: a[1]).lastPathComponent,
                              vanillaGame: opt("--vanilla").map { URL(fileURLWithPath: $0) } ?? kit.gameDir, gameVersion: opt("--version"))
    print(String(format: "profile “%@”: %d mods (%d files), %d game-root files, %d plugins, %d INIs in %.1f s; missing %d",
                 r.profile, r.mods, r.files, r.gameRootFiles, r.plugins, r.inis, r.seconds, r.missing.count))
    exit(0)
}
if a.first == "restore-since", a.count == 2, let since = Double(a[1]) {   // deployed files modified after <epoch>
    let v = try kit.deployer.verify()
    let rels = v.changed.filter { rel in
        ((try? FileManager.default.attributesOfItem(atPath: kit.gameDir.path + "/" + rel)[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0) >= since
    }
    let done = try kit.deployer.restore(rels)
    print("restored \(done.count) of \(v.changed.count) changed files"); for r in done { print("  " + r) }
    exit(0)
}
if a.first == "validate" {
    let lo = kit.loadOrder()
    var full = 0, light = 0
    for n in lo.activeOrder { if lo.headers[n.lowercased()]?.isLight == true { light += 1 } else { full += 1 } }
    let issues = lo.validate()
    print("active \(lo.activeOrder.count): full \(full), light \(light); issues \(issues.count)")
    for i in issues.prefix(20) { print("  \(i.kind.rawValue): \(i.plugin) — \(i.detail)") }
    exit(issues.isEmpty ? 0 : 1)
}
guard a.first == "repair-collection", a.count == 4 else { print("usage: skyrimmt-cli deploy | validate | repair-collection <slug> <order.json> <gameVersion>"); exit(2) }
let slug = a[1], gv = a[3]
let order = (try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: a[2]))) as! [String: Any])["files"] as! [[String: Any]]
// archives by (mod, file)
var archives: [String: URL] = [:]
let dl = home.appendingPathComponent("downloads")
for f in (try? FileManager.default.contentsOfDirectory(at: dl, includingPropertiesForKeys: nil)) ?? [] where f.pathExtension == "json" && f.lastPathComponent.hasSuffix(".meta.json") {
    if let j = try? JSONSerialization.jsonObject(with: Data(contentsOf: f)) as? [String: Any], let m = j["modID"] as? Int, let fi = j["fileID"] as? Int {
        archives["\(m)/\(fi)"] = URL(fileURLWithPath: String(f.path.dropLast(".meta.json".count)))
    }
}
var p = try kit.currentProfile()
print("profile: \(p.name), game folder: \(kit.gameDir.lastPathComponent), mods: \(p.mods.count)")
func installedID(_ m: Int, _ f: Int) -> String? { kit.mods.first { $0.nexus?.modID == m && $0.nexus?.fileID == f }?.id }
var added: [String] = []
for pass in 0..<2 {
    for (idx, e) in order.enumerated() {
        let m = e["modID"] as! Int, f = e["fileID"] as! Int, name = e["name"] as! String
        if e["optional"] as? Bool == true || installedID(m, f) != nil { continue }
        guard let arc = archives["\(m)/\(f)"] else { if pass == 1 { print("NO ARCHIVE \(name) \(m)/\(f)") }; continue }
        do {
            let (work, layout) = try kit.beginInstall(archive: arc)
            var fom: FomodInstaller?
            if case .fomod(_, let cfg) = layout {
                let i = FomodInstaller(config: try FomodParser.load(cfg), context: kit.fomodContext(gameVersion: gv, stagedProfileMods: p.mods.map(\.id)))
                i.applyAllDefaults()
                let r = i.makeRosettaSafe(); if !r.isEmpty { print("  rosetta-safe: \(r)") }
                if pass == 0 && !i.problems().isEmpty { try? FileManager.default.removeItem(at: work); continue }   // retry after the others
                fom = i
            }
            let rec = try kit.finishInstall(work: work, layout: layout, name: name, fomod: fom,
                                            source: SourceArchive(path: arc.path), nexus: NexusRef(modID: m, fileID: f))
            p = try kit.currentProfile()
            p.mods.removeAll { $0.id == rec.id }
            // after the nearest installed predecessor in the collection's order
            var pos = 0
            for prev in order[..<idx].reversed() {
                if let pid = installedID(prev["modID"] as! Int, prev["fileID"] as! Int), let at = p.mods.firstIndex(where: { $0.id == pid }) { pos = at + 1; break }
            }
            p.mods.insert(ProfileMod(id: rec.id, enabled: true), at: min(pos, p.mods.count))
            try kit.saveProfile(p)
            added.append(rec.id)
            print("OK \(name) → priority \(pos + 1)")
        } catch { print("FAIL \(name): \(error)") }
    }
}
var cols = kit.installedCollections()
if let i = cols.firstIndex(where: { $0.slug == slug }) { cols[i].modIDs += added; try kit.saveCollections(cols) }
let r = try kit.deploy(p)
print(String(format: "deployed in %.1f s (+%d −%d, kept modified %d)", r.seconds, r.cloned + r.linked + r.copied, r.removed, r.keptModified.count))
