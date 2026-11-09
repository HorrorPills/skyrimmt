// Volumes without native extended attributes, and deploys that must survive failing halfway (GitHub issue #16).
// On exFAT every attribute lives in a visible "._name" file: they were deployed as mod files, raced the copies that
// create them ("exists: …/._x.dll"), and SKSE then tried to load them. A failed deploy also left a journal naming the old
// mod folder, so after a reinstall every later deploy and purge failed ("missing staging file").
import Foundation
import Darwin

private func setAttr(_ u: URL) { _ = u.path.withCString { setxattr($0, "com.example.skyrimmt-test", "1", 1, 0, 0) } }
private func metadataFiles(_ dir: URL) -> [String] { fastFileList(dir.path).filter { MacMetadata.inPath($0) } }

func macMetadataTests() {
    section("macOS metadata files are never mod files")
    check(MacMetadata.isFile("._x.dll") && MacMetadata.isFile(".DS_Store") && !MacMetadata.isFile(".hidden.esp") && !MacMetadata.isFile("_x.dll"), "names")
    check(MacMetadata.inPath("Data/__MACOSX/a.txt") && MacMetadata.inPath("data/skse/plugins/._a.dll") && !MacMetadata.inPath("Data/SKSE/Plugins/a.dll"), "paths")
    check(MacMetadata.inPath("data/__macosx/a.txt") && MacMetadata.inPath("data/.ds_store") && !MacMetadata.inPath("data/_mods/.hidden/_a.esp"), "manifest keys (lowercased), and lookalikes stay")

    let f = Fixture("macmeta")
    let m = f.addMod("Plugin", ["SKSE/Plugins/a.dll": "real", "SKSE/Plugins/._a.dll": "sidecar", "a.esp": "x", "._a.esp": "sidecar",
                                "__MACOSX/SKSE/._a.dll": "zip junk", "__root__/b.dll": "root", "__root__/._b.dll": "sidecar", "Textures/.DS_Store": "finder"])
    let keys = Set(try! f.kit.plan().files.keys)
    check(keys == ["data/skse/plugins/a.dll", "data/a.esp", "b.dll"], "only the real files are planned (\(keys.sorted()))")
    try! f.kit.deploy()
    check(metadataFiles(f.game).isEmpty, "nothing of the kind reaches the game folder")
    check(read(f.game.appendingPathComponent("Data/SKSE/Plugins/a.dll")) == "real", "the real file does")

    // deployed by an older version: gone at the next deploy, without a report of files "changed outside SkyrimMT"
    let old = f.kit.stagingFolder(m).appendingPathComponent("SKSE/Plugins/._a.dll").path
    let oldDst = f.game.appendingPathComponent("Data/SKSE/Plugins/._a.dll")
    var legacy = try! f.kit.plan().files
    legacy["data/skse/plugins/._a.dll"] = PlannedFile(rel: "Data/SKSE/Plugins/._a.dll", source: old, modID: m.id)
    _ = try! f.kit.deployer.apply(legacy)
    check(fm.fileExists(atPath: oldDst.path), "older deploy state set up")
    check((try! f.kit.isDirty()) == true, "an older deploy shows as not deployed")
    check(try! f.kit.deployer.verify().ok, "its metadata entries aren't reported as drift")
    // (the folder was copied since: the sidecar's inode no longer matches the manifest)
    let copied = try! Data(contentsOf: oldDst); try! fm.removeItem(at: oldDst); fm.createFile(atPath: oldDst.path + ".tmp", contents: copied); try! fm.moveItem(atPath: oldDst.path + ".tmp", toPath: oldDst.path)
    let r = try! f.kit.deploy()
    check(!fm.fileExists(atPath: oldDst.path) && r.keptModified.isEmpty, "removed by the next deploy")
    check((try! f.kit.isDirty()) == false, "and the state is clean")

    // load order: a "._" plugin in Data is not a plugin (it used to land in plugins.txt)
    write(f.game.appendingPathComponent("Data/._c.esp"), "sidecar")
    let lo = f.kit.loadOrder()
    check(!lo.entries.contains { $0.name.hasPrefix("._") } && !lo.unreadable.contains { $0.hasPrefix("._") }, "plugin scan skips them")
    check(try! !f.kit.deployer.unmanagedFiles().contains { MacMetadata.inPath($0) }, "not unmanaged files either")
    try? fm.removeItem(at: f.game.appendingPathComponent("Data/._c.esp"))

    // downloads
    write(f.kit.downloadsDir.appendingPathComponent("Mod.7z"), "archive")
    write(f.kit.downloadsDir.appendingPathComponent("._Mod.7z"), "sidecar")
    check(f.kit.downloadEntries().map(\.url.lastPathComponent) == ["Mod.7z"], "downloads list skips them")

    // archive layout: a sidecar next to the wrapper folder must not hide the mod inside it
    let x = freshDir("macmeta-layout")
    write(x.appendingPathComponent("My Mod/a.esp"), "x")
    write(x.appendingPathComponent("My Mod/._a.esp"), "sidecar")
    write(x.appendingPathComponent("._My Mod"), "sidecar")
    write(x.appendingPathComponent("__MACOSX/My Mod/._a.esp"), "zip junk")
    if case .data(let r) = Installer.detect(x) { check(r.lastPathComponent == "My Mod", "layout looks inside the wrapper") } else { check(false, "layout looks inside the wrapper") }
    let out = x.appendingPathComponent("out")
    try! Installer.prepare(Installer.detect(x), into: out)
    check(metadataFiles(out).isEmpty && fm.fileExists(atPath: out.appendingPathComponent("a.esp").path), "installed mods are clean")

    // a copy leaves attributes behind (they are what creates the sidecars) and keeps the date
    let c = freshDir("macmeta-copy"), a = c.appendingPathComponent("a"), b = c.appendingPathComponent("b")
    write(a, "data"); setAttr(a)
    try! fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_500_000_000)], ofItemAtPath: a.path)
    try! copyContents(a.path, to: b.path)
    check(read(b) == "data" && listxattr(b.path, nil, 0, 0) == 0, "copied without attributes")
    check((try! fm.attributesOfItem(atPath: b.path)[.modificationDate] as! Date).timeIntervalSince1970 == 1_500_000_000, "date kept")
    check((try? copyContents(a.path, to: b.path)) == nil, "never over an existing file")
}

func staleJournalTests() {
    section("a failed deploy never blocks later ones")
    // failed halfway, mod reinstalled (new folder) before the next try
    var f = Fixture("journal-reinstall")
    let vanilla = snapshot(f.game)
    let m1 = f.addMod("Addr", (0..<30).reduce(into: [:]) { $0["SKSE/Plugins/v\($1).bin"] = "old" })
    f.kit.deployer.failAfterOps = 5
    check((try? f.kit.deploy()) == nil && f.kit.deployer.needsRecovery, "deploy fails halfway, journal stays")
    f.kit.deployer.failAfterOps = nil
    let oldFolder = f.kit.stagingFolder(m1).lastPathComponent
    try! f.kit.removeMod(m1.id)
    let m2 = f.addMod("Addr", (0..<30).reduce(into: [:]) { $0["SKSE/Plugins/v\($1).bin"] = "new" })
    check(f.kit.stagingFolder(m2).lastPathComponent != oldFolder, "reinstall gets a new folder")
    do { try f.kit.deploy(); check(true, "next deploy works") } catch { check(false, "next deploy works: \(error)") }
    check(!f.kit.deployer.needsRecovery, "journal finished")
    check((0..<30).allSatisfy { read(f.game.appendingPathComponent("Data/SKSE/Plugins/v\($0).bin")) == "new" }, "the new files are in place")
    check((try! f.kit.isDirty()) == false, "state clean")
    try! f.kit.purge()
    check(snapshot(f.game) == vanilla, "purge gives back the vanilla game (\(snapshot(f.game).keys.sorted().prefix(4)))")
    check(!fm.fileExists(atPath: f.game.appendingPathComponent("Data/SKSE").path), "and removes the folders the failed deploy created")

    // failed right after moving the game's file aside, then the mod is removed: the game's file comes back
    f = Fixture("journal-backup")
    let vanilla2 = snapshot(f.game)
    let m3 = f.addMod("Rock", ["Textures/Vanilla/rock.dds": "mod rock", "z.txt": "x"])
    f.kit.deployer.failAfterOps = 1
    check((try? f.kit.deploy()) == nil, "fails after one step")
    f.kit.deployer.failAfterOps = nil
    try! f.kit.removeMod(m3.id)
    do { try f.kit.deploy(); check(true, "deploy after removal works") } catch { check(false, "deploy after removal works: \(error)") }
    check(snapshot(f.game) == vanilla2, "game folder is vanilla again (\(read(f.game.appendingPathComponent("Data/Textures/Vanilla/rock.dds")) ?? "gone"))")

    // purge while the journal is stale
    f = Fixture("journal-purge")
    let vanilla3 = snapshot(f.game)
    let m4 = f.addMod("P", (0..<10).reduce(into: [:]) { $0["p\($1).txt"] = "x" })
    f.kit.deployer.failAfterOps = 3
    _ = try? f.kit.deploy()
    f.kit.deployer.failAfterOps = nil
    try! f.kit.removeMod(m4.id)
    do { try f.kit.purge(); check(true, "purge works") } catch { check(false, "purge works: \(error)") }
    check(snapshot(f.game) == vanilla3, "vanilla game, nothing of the removed mod left (\(snapshot(f.game).keys.sorted().prefix(4)))")
    let aside = f.home.appendingPathComponent("backups/modkit/failed-deploy")
    check(fm.enumerator(atPath: aside.path)?.allObjects.isEmpty == false, "its placed files are kept in backups")

    // the player's file stays when it is in the baseline and was never moved
    f = Fixture("journal-keep-vanilla")
    let vanilla4 = snapshot(f.game)
    let m5 = f.addMod("Rock", ["Textures/Vanilla/rock.dds": "mod rock"])
    try! f.kit.deployer.ensureBaseline()
    try! FileManager.default.createDirectory(at: f.kit.deployer.layout.stateDir, withIntermediateDirectories: true)
    try! "# SkyrimMT deploy journal v1\nA\tData/Textures/Vanilla/rock.dds\t\(m5.id)\t/gone/rock.dds\n".write(to: f.kit.deployer.layout.journalURL, atomically: true, encoding: .utf8)
    try! f.kit.removeMod(m5.id)
    do { try f.kit.deploy(); check(snapshot(f.game) == vanilla4, "a file of the game itself is never moved") } catch { check(false, "deploy: \(error)") }

    // a copy cut short leaves nothing behind, under any name
    let c = freshDir("journal-copy")
    check((try? copyContents(c.appendingPathComponent("missing").path, to: c.appendingPathComponent("dst").path)) == nil, "failed copy reports it")
    check(((try? fm.contentsOfDirectory(atPath: c.path)) ?? []).isEmpty, "and leaves nothing")
}

/// The real thing: a throwaway exFAT disk image (no admin needed).
func exfatTests() {
    section("exFAT volume (issue #16)")
    let dir = freshDir("exfat-image"), image = dir.appendingPathComponent("x.dmg"), mnt = dir.appendingPathComponent("m")
    func hdiutil(_ a: [String]) -> Int32 { Installer.run("/usr/bin/hdiutil", a).0 }
    guard hdiutil(["create", "-quiet", "-size", "200m", "-fs", "ExFAT", "-volname", "SKMTTEST", "-type", "UDIF", "-ov", image.path]) == 0 else { print("  (no exFAT image here: skipped)"); return }
    try! fm.createDirectory(at: mnt, withIntermediateDirectories: true)
    guard hdiutil(["attach", "-quiet", "-nobrowse", "-mountpoint", mnt.path, image.path]) == 0 else { print("  (couldn't attach: skipped)"); return }
    defer { _ = hdiutil(["detach", "-quiet", "-force", mnt.path]); try? fm.removeItem(at: dir) }
    check(!MacMetadata.nativeAttributes(mnt.path), "volume recognised as non-native")
    check(MacMetadata.nativeAttributes(dir.path) || dir.path.contains("exfat"), "the test folder's volume is native")

    let home = mnt.appendingPathComponent("SkyrimMT"), game = home.appendingPathComponent("game")
    write(game.appendingPathComponent("SkyrimSE.exe"), "exe")
    write(game.appendingPathComponent("Data/Skyrim - Textures0.bsa"), "bsa")
    write(game.appendingPathComponent("Data/Textures/rock.dds"), "vanilla rock")
    let ptxt = fixturePluginsTxt(home)
    try! fm.createDirectory(at: ptxt.deletingLastPathComponent(), withIntermediateDirectories: true)
    let kit = ModKit(home: home, gameDir: game, pluginsTxt: ptxt)
    func add(_ name: String, _ files: [String]) -> ModRecord {
        let t = home.appendingPathComponent("incoming/\(UUID().uuidString)")
        for rel in files { let u = t.appendingPathComponent(rel); write(u, name + rel); setAttr(u) }
        return try! kit.addMod(name: name, from: t)
    }
    // well past one parallel chunk (64): the race with the sidecars that copies create needs real concurrency
    let plugins = add("Plugins", (0..<300).map { "SKSE/Plugins/p\($0).dll" })
    _ = add("Addr", ["SKSE/Plugins/versionlib-1-6-1130-0.bin"])
    _ = add("Start", ["alternate start.bsa", "alternate start.esp", "Textures/rock.dds"])
    check(fm.fileExists(atPath: kit.stagingFolder(plugins).appendingPathComponent("SKSE/Plugins/._p0.dll").path), "sidecars exist in staging (the bug's precondition)")
    check(try! kit.plan().files.count == 304, "plan holds the real files only")

    do {
        let r = try kit.deploy()
        check(r.copied == 304, "first deploy places everything as copies (\(r.copied))")
        check(metadataFiles(game).isEmpty, "no sidecars in the game folder (\(metadataFiles(game).prefix(3)))")
        check(read(game.appendingPathComponent("Data/SKSE/Plugins/p7.dll")) == "PluginsSKSE/Plugins/p7.dll", "content is right")
        check(read(game.appendingPathComponent("Data/Textures/rock.dds")) == "StartTextures/rock.dds", "a game file is overridden")
    } catch { check(false, "first deploy works: \(error)") }
    check(!kit.deployer.needsRecovery, "no journal left")
    check((try? kit.isDirty()) == false, "state clean")
    check((try? kit.deployer.verify().ok) == true, "verify clean")
    check((try? kit.deploy().copied) == 0, "second deploy has nothing to do")
    check(!PluginsTxt.read(ptxt).contains { $0.name.hasPrefix("._") }, "plugins.txt is clean")

    // a tool or Steam adds sidecars: the next deploy sweeps them, the files stay
    setAttr(game.appendingPathComponent("Data/SKSE/Plugins/p0.dll"))
    check(!metadataFiles(game).isEmpty, "sidecar appears")
    check(kit.deployer.sweepMetadata() >= 1 && metadataFiles(game).isEmpty, "swept")
    check((try? kit.deployer.verify().ok) == true, "sweeping changes no deployed file")

    // unplug and plug back in
    check(hdiutil(["detach", "-quiet", mnt.path]) == 0 && hdiutil(["attach", "-quiet", "-nobrowse", "-mountpoint", mnt.path, image.path]) == 0, "remount")
    check((try? kit.isDirty()) == false, "still clean after a remount")
    check((try? kit.deployer.verify().ok) == true, "verify clean after a remount")

    // reinstall, drift repair, purge
    let n = add("Plugins", (0..<300).map { "SKSE/Plugins/p\($0).dll" })
    try! kit.removeMod(plugins.id)
    do { try kit.deploy() } catch { check(false, "deploy after reinstall: \(error)") }
    check(read(game.appendingPathComponent("Data/SKSE/Plugins/p7.dll")) == "PluginsSKSE/Plugins/p7.dll" && kit.mod(n.id) != nil, "reinstalled")
    write(game.appendingPathComponent("Data/SKSE/Plugins/p1.dll"), "changed by Wine")
    check(kit.restoreDriftedBinaries().count == 1, "a changed DLL goes back to the mod's copy")
    check(read(game.appendingPathComponent("Data/SKSE/Plugins/p1.dll")) == "PluginsSKSE/Plugins/p1.dll", "with the right content")
    do { try kit.purge() } catch { check(false, "purge: \(error)") }
    check(!fm.fileExists(atPath: game.appendingPathComponent("Data/SKSE").path), "purge removes the folders it created")
    check(read(game.appendingPathComponent("Data/Textures/rock.dds")) == "vanilla rock", "and restores the game's file")
    check(metadataFiles(game).isEmpty, "no sidecars after a purge")

    // the launch-time sweep in scripts/_env.sh: same result, only on such a volume
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path
    func sweep(_ g: URL, _ fn: String = "sweep_mac_metadata", native: Bool = false) -> Int32 {
        let script = ". \"\(root)/scripts/_env.sh\"; \(native ? "native_attributes" : fn)"
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/bash"); p.arguments = ["-c", script]
        var e = ProcessInfo.processInfo.environment; e["SKYRIM_HOME"] = home.path; e["GAMEDIR"] = g.path; e["SKYRIMMT_NO_SYNC_CHECK"] = "1"
        p.environment = e; p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try! p.run(); p.waitUntilExit(); return p.terminationStatus
    }
    write(game.appendingPathComponent("Data/SKSE2/._x.dll"), "sidecar")
    check(sweep(game) == 0 && !fm.fileExists(atPath: game.appendingPathComponent("Data/SKSE2/._x.dll").path), "launch sweep removes them on exFAT")
    // while the game runs (session-helper.sh): a save's sidecar would show in Skyrim's Load menu as "$SAVE OBSOLETE"
    let saves = home.appendingPathComponent("prefix/drive_c/users/\(NSUserName())/Documents/My Games/Skyrim Special Edition/Saves")
    write(saves.appendingPathComponent("real.ess"), "save")
    write(saves.appendingPathComponent("._real.ess"), "sidecar"); write(saves.appendingPathComponent("._real.skse"), "sidecar")
    check(sweep(game, "sweep_save_metadata") == 0 && read(saves.appendingPathComponent("real.ess")) == "save", "in-session sweep keeps the save")
    check(!fm.fileExists(atPath: saves.appendingPathComponent("._real.ess").path) && !fm.fileExists(atPath: saves.appendingPathComponent("._real.skse").path), "and removes its sidecars")
    check(sweep(game, native: true) != 0, "exFAT is seen as non-native by the session helper")
    check(!MacMetadata.nativeAttributes(mnt.path), "the image stayed mounted for the whole test")
    let apfs = freshDir("exfat-apfs-game")
    write(apfs.appendingPathComponent("._kept"), "not ours to touch on APFS")
    write(apfs.appendingPathComponent("Data/SKSE/Plugins/._copied.dll"), "came along from an external drive")
    write(apfs.appendingPathComponent("Data/SKSE/Plugins/real.dll"), "plugin")
    check(sweep(apfs) == 0 && fm.fileExists(atPath: apfs.appendingPathComponent("._kept").path), "and leaves APFS alone")
    check(sweep(apfs, native: true) == 0, "APFS is native: nothing extra runs during play")
    check(!fm.fileExists(atPath: apfs.appendingPathComponent("Data/SKSE/Plugins/._copied.dll").path) && fm.fileExists(atPath: apfs.appendingPathComponent("Data/SKSE/Plugins/real.dll").path), "except SKSE's plugin folder, where one stops the game")
    try? fm.removeItem(at: apfs)
}
