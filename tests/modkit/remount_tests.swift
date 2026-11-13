// External drives get a new device number (st_dev) whenever they are mounted again under another disk number: after
// reconnecting, after a restart, or when another drive was attached first. Inodes stay. SkyrimMT recorded the device
// with every deployed file and compared it, so after a remount every deployed file read as "changed outside SkyrimMT":
// deploys left removed mods' files in the game folder ("N file(s) changed outside SkyrimMT were left in place", wrong
// mods in the game), Play re-copied every .dll/.exe/.bsa, and a profile switch or "Remove all mods" moved every deployed
// loose file into the Overwrite mod (GitHub issue #21).
import Foundation
import Darwin

/// Rewrite the manifest as if it was written while the game folder's volume had another device number.
private func ageDeviceNumbers(_ kit: ModKit, by delta: Int64 = 7919) {
    let url = kit.deployer.layout.manifestURL
    let lines = read(url)!.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
        var f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard f.first == "F", f.count >= 8, let dev = Int64(f[4]) else { return String(line) }
        f[4] = String(dev + delta)
        return f.joined(separator: "\t")
    }
    try! lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
}

private func remountFixture(_ f: Fixture) -> (a: ModRecord, b: ModRecord) {
    let a = f.addMod("Base", ["base.esp": "plugin", "Base.bsa": "archive", "SKSE/Plugins/base.dll": "dll", "SKSE/Plugins/base.ini": "setting=1",
                              "Textures/base/rock.dds": "rock", "Meshes/base/rock.nif": "nif", "__root__/skse64_loader.exe": "loader"])
    let b = f.addMod("Extra", ["extra.esp": "plugin2", "Textures/extra/tree.dds": "tree", "Interface/vanilla.swf": "extra swf", "SKSE/Plugins/extra.dll": "dll2"])
    return (a, b)
}

func remountTests() {
    section("external drive mounted again: new device number (issue #21)")
    var f = Fixture("remount")
    let vanilla = snapshot(f.game)
    let (_, b) = remountFixture(f)
    try! f.kit.deploy()
    ageDeviceNumbers(f.kit)
    check(try! f.kit.deployer.verify().ok, "nothing reads as changed (\(try! f.kit.deployer.verify().changed.prefix(3)))")
    check(f.kit.restoreDriftedBinaries().isEmpty, "Play copies nothing again")
    check((try! f.kit.isDirty()) == false, "still deployed")
    check(try! f.kit.captureGenerated().isEmpty, "a profile switch / purge moves nothing into Overwrite")
    check(!f.kit.mods.contains { ModKit.isOverwrite($0.id) && fm.fileExists(atPath: f.kit.stagingFolder($0).appendingPathComponent("base.esp").path) }, "Overwrite holds no copy of the mods")

    // a mod turned off: its files leave the game folder, nothing is reported as changed outside SkyrimMT
    var p = try! f.kit.currentProfile()
    p.mods = p.mods.map { $0.id == b.id ? ProfileMod(id: $0.id, enabled: false) : $0 }
    try! f.kit.saveProfile(p)
    let r = try! f.kit.deploy()
    check(r.keptModified.isEmpty, "no file kept as changed outside SkyrimMT (\(r.keptModified.prefix(3)))")
    check(!fm.fileExists(atPath: f.game.appendingPathComponent("Data/extra.esp").path), "the turned-off mod's plugin is gone")
    check(read(f.game.appendingPathComponent("Data/Interface/vanilla.swf")) == "vanilla swf", "the game's file it replaced is back")
    check(snapshot(f.game) == expected(vanilla: vanilla, profile: try! f.kit.currentProfile(), kit: f.kit), "game folder == profile")
    check((try! f.kit.isDirty()) == false, "clean after the deploy")

    // real changes are still found after a remount
    ageDeviceNumbers(f.kit)
    let ini = f.game.appendingPathComponent("Data/SKSE/Plugins/base.ini")
    try! fm.removeItem(at: ini); write(ini, "setting=2 (written by the plugin)")    // new file: another inode
    let dll = f.game.appendingPathComponent("Data/SKSE/Plugins/base.dll")
    let h = FileHandle(forWritingAtPath: dll.path)!; h.seekToEndOfFile(); h.write(Data("runtime".utf8)); try! h.close()   // same inode, rewritten
    let v = try! f.kit.deployer.verify()
    check(Set(v.changed) == ["Data/SKSE/Plugins/base.ini", "Data/SKSE/Plugins/base.dll"], "a rewritten file and an edited one are changes (\(v.changed))")
    check(f.kit.restoreDriftedBinaries() == ["Data/SKSE/Plugins/base.dll"], "Play puts back only the edited DLL")
    check(read(dll) == "dll", "the mod's DLL is back")

    // purge after a remount gives back the vanilla game
    f = Fixture("remount-purge")
    let vanilla2 = snapshot(f.game)
    _ = remountFixture(f)
    try! f.kit.deploy()
    ageDeviceNumbers(f.kit)
    let pr = try! f.kit.purge()
    check(pr.keptModified.isEmpty, "purge removes every deployed file (\(pr.keptModified.count) kept)")
    check(snapshot(f.game) == vanilla2, "vanilla game folder (\(Set(snapshot(f.game).keys).subtracting(vanilla2.keys).sorted().prefix(4)))")

    // a file at a deployed path that isn't ours (another inode) is never deleted, remount or not
    f = Fixture("remount-foreign")
    _ = remountFixture(f)
    try! f.kit.deploy()
    ageDeviceNumbers(f.kit)
    let tex = f.game.appendingPathComponent("Data/Textures/extra/tree.dds")
    try! fm.removeItem(at: tex); write(tex, "the player's own tree")
    let r2 = try! f.kit.deployer.purge()
    check(r2.keptModified == ["Data/Textures/extra/tree.dds"] && read(tex) == "the player's own tree", "deployer: the player's file stays (\(r2.keptModified), \(read(tex) ?? "gone"))")
    check(r2.removed == 10, "and every file of ours goes (\(r2.removed))")
    // Remove all mods: a rewritten deployed file is kept in Overwrite (as without a remount), and only that one
    f = Fixture("remount-foreign-kit")
    _ = remountFixture(f)
    try! f.kit.deploy()
    ageDeviceNumbers(f.kit)
    let tex2 = f.game.appendingPathComponent("Data/Textures/extra/tree.dds")
    try! fm.removeItem(at: tex2); write(tex2, "the player's own tree")
    try! f.kit.purge()
    let ow = f.kit.mods.first { ModKit.isOverwrite($0.id) }
    let kept = ow.map { snapshot(f.kit.stagingFolder($0)) } ?? [:]
    check(kept == ["textures/extra/tree.dds": "the player's own tree"], "Remove all mods: only the rewritten file goes to Overwrite (\(kept.keys.sorted().prefix(4)))")

    movedHomeTest()
    movedToExfatTest()
    realRemountTest()
}

/// Copied onto an exFAT drive: new inodes, and dates cut to 10 ms.
private func movedToExfatTest() {
    let dir = freshDir("moved-exfat")
    func hdiutil(_ a: [String]) -> Int32 { Installer.run("/usr/bin/hdiutil", a).0 }
    let image = dir.appendingPathComponent("x.dmg"), mnt = dir.appendingPathComponent("m")
    guard hdiutil(["create", "-quiet", "-size", "60m", "-fs", "ExFAT", "-volname", "SKMTMOVED", "-type", "UDIF", "-ov", image.path]) == 0 else { print("  (no exFAT image here: skipped)"); return }
    try! fm.createDirectory(at: mnt, withIntermediateDirectories: true)
    guard hdiutil(["attach", "-quiet", "-nobrowse", "-mountpoint", mnt.path, image.path]) == 0 else { print("  (couldn't attach: skipped)"); return }
    defer { _ = hdiutil(["detach", "-quiet", "-force", mnt.path]); try? fm.removeItem(at: dir) }
    let f = Fixture("moved-exfat-from")
    let (_, b) = remountFixture(f)
    try! f.kit.deploy()
    let to = mnt.appendingPathComponent("SkyrimMT")
    check(Installer.run("/usr/bin/ditto", [f.home.path, to.path]).0 == 0, "copied to exFAT")
    try! fm.removeItem(at: f.home)
    let game = to.appendingPathComponent("game")
    let st = lstatPath(game.appendingPathComponent("Data/base.esp").path)!
    check(st.mtimeNs % 10_000_000 == 0, "exFAT keeps 10 ms dates")
    let kit = ModKit(home: to, gameDir: game, pluginsTxt: fixturePluginsTxt(to))
    check(try! kit.deployer.verify().ok, "exFAT copy: nothing reads as changed (\(try! kit.deployer.verify().changed.prefix(3)))")
    check(try! kit.captureGenerated().isEmpty, "exFAT copy: nothing moves into Overwrite")
    var p = try! kit.currentProfile()
    p.mods = p.mods.map { $0.id == b.id ? ProfileMod(id: $0.id, enabled: false) : $0 }
    try! kit.saveProfile(p)
    let r = try! kit.deploy()
    check(r.keptModified.isEmpty && !fm.fileExists(atPath: game.appendingPathComponent("Data/extra.esp").path), "exFAT copy: a turned-off mod leaves the game (\(r.keptModified.count) kept)")
    check(read(game.appendingPathComponent("Data/Interface/vanilla.swf")) == "vanilla swf", "exFAT copy: the game's file is back")
    check((try! kit.isDirty()) == false && (try! kit.deployer.verify().ok), "exFAT copy: clean afterwards")
}

/// The whole SkyrimMT folder copied to another drive (Finder, ditto): every file has a new inode; sizes and dates stay.
private func movedHomeTest() {
    section("SkyrimMT folder copied to another drive (new inodes)")
    let f = Fixture("moved-from")
    let (_, b) = remountFixture(f)
    try! f.kit.deploy()
    let to = freshDir("moved-to")
    try! fm.removeItem(at: to)
    check(Installer.run("/usr/bin/ditto", [f.home.path, to.path]).0 == 0, "copied")
    try! fm.removeItem(at: f.home)                                   // moved: the old folder is gone
    let game = to.appendingPathComponent("game")
    let kit = ModKit(home: to, gameDir: game, pluginsTxt: fixturePluginsTxt(to))
    check(try! kit.deployer.verify().ok, "nothing reads as changed (\(try! kit.deployer.verify().changed.prefix(3)))")
    check(kit.restoreDriftedBinaries().isEmpty, "Play copies nothing again")
    check(try! kit.captureGenerated().isEmpty, "nothing moves into Overwrite")
    var p = try! kit.currentProfile()
    p.mods = p.mods.map { $0.id == b.id ? ProfileMod(id: $0.id, enabled: false) : $0 }
    try! kit.saveProfile(p)
    let r = try! kit.deploy()
    check(r.keptModified.isEmpty, "first deploy there: nothing kept as changed outside SkyrimMT (\(r.keptModified.count))")
    check(!fm.fileExists(atPath: game.appendingPathComponent("Data/extra.esp").path), "the turned-off mod's plugin is gone")
    check(read(game.appendingPathComponent("Data/Interface/vanilla.swf")) == "vanilla swf", "the game's file it replaced is back")
    check((try! kit.isDirty()) == false && (try! kit.deployer.verify().ok), "clean afterwards")
    // a file the player put there afterwards still counts as theirs
    let tex = game.appendingPathComponent("Data/Textures/base/rock.dds")
    try! fm.removeItem(at: tex); write(tex, "the player's own rock, bigger")
    check(try! kit.deployer.verify().changed == ["Data/Textures/base/rock.dds"], "a replaced file is a change")
}

/// The real thing: an APFS disk image mounted again while another image holds its disk number.
private func realRemountTest() {
    let dir = freshDir("remount-image")
    func hdiutil(_ a: [String]) -> Int32 { Installer.run("/usr/bin/hdiutil", a).0 }
    let image = dir.appendingPathComponent("drive.dmg"), other = dir.appendingPathComponent("other.dmg")
    let mnt = dir.appendingPathComponent("m"), mnt2 = dir.appendingPathComponent("o")
    guard hdiutil(["create", "-quiet", "-size", "60m", "-fs", "APFS", "-volname", "SKMTREMOUNT", "-type", "UDIF", "-ov", image.path]) == 0,
          hdiutil(["create", "-quiet", "-size", "20m", "-fs", "APFS", "-volname", "SKMTOTHER", "-type", "UDIF", "-ov", other.path]) == 0 else {
        print("  (no disk images here: real remount skipped)"); return
    }
    try! fm.createDirectory(at: mnt, withIntermediateDirectories: true); try! fm.createDirectory(at: mnt2, withIntermediateDirectories: true)
    guard hdiutil(["attach", "-quiet", "-nobrowse", "-mountpoint", mnt.path, image.path]) == 0 else { print("  (couldn't attach: skipped)"); return }
    defer { _ = hdiutil(["detach", "-quiet", "-force", mnt.path]); _ = hdiutil(["detach", "-quiet", "-force", mnt2.path]); try? fm.removeItem(at: dir) }

    let home = mnt.appendingPathComponent("SkyrimMT"), game = home.appendingPathComponent("game")
    write(game.appendingPathComponent("SkyrimSE.exe"), "exe")
    write(game.appendingPathComponent("Data/Skyrim - Textures0.bsa"), "bsa")
    write(game.appendingPathComponent("Data/Interface/vanilla.swf"), "vanilla swf")
    let ptxt = home.appendingPathComponent("users/test/AppData/Local/Skyrim Special Edition/plugins.txt")
    try! fm.createDirectory(at: ptxt.deletingLastPathComponent(), withIntermediateDirectories: true)
    var kit = ModKit(home: home, gameDir: game, pluginsTxt: ptxt)
    func add(_ name: String, _ files: [String: String]) -> ModRecord {
        let tmp = home.appendingPathComponent("incoming/\(UUID().uuidString)")
        for (rel, c) in files { write(tmp.appendingPathComponent(rel), c) }
        return try! kit.addMod(name: name, from: tmp)
    }
    _ = add("Base", ["base.esp": "plugin", "Base.bsa": "archive", "SKSE/Plugins/base.dll": "dll"])
    let b = add("Extra", ["extra.esp": "plugin2", "Interface/vanilla.swf": "extra swf"])
    try! kit.deploy()
    let devBefore = lstatPath(game.appendingPathComponent("Data/base.esp").path)!.dev

    // detach, let another volume take the disk number, attach again
    check(hdiutil(["detach", "-quiet", mnt.path]) == 0, "drive ejected")
    check(hdiutil(["attach", "-quiet", "-nobrowse", "-mountpoint", mnt2.path, other.path]) == 0, "another drive attached")
    check(hdiutil(["attach", "-quiet", "-nobrowse", "-mountpoint", mnt.path, image.path]) == 0, "drive attached again")
    kit = ModKit(home: home, gameDir: game, pluginsTxt: ptxt)
    let devAfter = lstatPath(game.appendingPathComponent("Data/base.esp").path)!.dev
    if devAfter == devBefore { print("  (the drive kept its device number this time: the simulated checks above cover it)") }
    else { check(true, "device number changed (\(devBefore) → \(devAfter))") }
    check(try! kit.deployer.verify().ok, "real remount: nothing reads as changed")
    check(kit.restoreDriftedBinaries().isEmpty, "real remount: Play copies nothing again")
    var p = try! kit.currentProfile()
    p.mods = p.mods.map { $0.id == b.id ? ProfileMod(id: $0.id, enabled: false) : $0 }
    try! kit.saveProfile(p)
    let r = try! kit.deploy()
    check(r.keptModified.isEmpty && !fm.fileExists(atPath: game.appendingPathComponent("Data/extra.esp").path), "real remount: a turned-off mod leaves the game")
    check(read(game.appendingPathComponent("Data/Interface/vanilla.swf")) == "vanilla swf", "real remount: the game's file is back")
}
