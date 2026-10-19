// MO2 import (ModKit/MO2Import.swift) and per-profile INIs (ProfileINIs.swift) on a synthetic Wabbajack-style instance.
import Foundation

func mo2Tests() {
    section("MO2 import")
    let f = Fixture("mo2")
    let k = f.kit
    let inst = f.home.appendingPathComponent("mo2-instance")
    let stock = inst.appendingPathComponent("Stock Game")
    write(inst.appendingPathComponent("ModOrganizer.ini"), """
    [General]
    gameName=Skyrim Special Edition
    gamePath=@ByteArray(Z:\(stock.path.replacingOccurrences(of: "/", with: "\\\\")))
    selected_profile=@ByteArray(Main)
    [Settings]
    """)
    write(inst.appendingPathComponent("mods/A/textures/a.dds"), "A")
    write(inst.appendingPathComponent("mods/A/A.esp"), "a")
    write(inst.appendingPathComponent("mods/B/textures/a.dds"), "B")
    write(inst.appendingPathComponent("mods/B/textures/hidden.dds.mohidden"), "h")
    write(inst.appendingPathComponent("mods/B/Root/enbseries.ini"), "enb")
    write(inst.appendingPathComponent("mods/B/meta.ini"), "[General]\nmodid=123\nversion=1.2\n[installedFiles]\n1\\modid=123\n1\\fileid=456\n")
    write(inst.appendingPathComponent("mods/C/textures/a.dds"), "C")
    write(inst.appendingPathComponent("mods/Visuals_separator/meta.ini"), "")
    write(inst.appendingPathComponent("profiles/Main/modlist.txt"), "# generated\r\n+B\r\n-C\r\n+Visuals_separator\r\n+A\r\n*DLC: Dawnguard\r\n")
    write(inst.appendingPathComponent("profiles/Main/plugins.txt"), "# plugins\r\n*A.esp\r\nB.esp\r\n")
    write(inst.appendingPathComponent("profiles/Main/loadorder.txt"), "Skyrim.esm\r\nA.esp\r\nB.esp\r\n")
    write(inst.appendingPathComponent("profiles/Main/settings.ini"), "[General]\nLocalSettings=true\n")
    write(inst.appendingPathComponent("profiles/Main/Skyrim.ini"), "list ini")
    write(inst.appendingPathComponent("overwrite/SKSE/Plugins/gen.ini"), "generated")
    write(stock.appendingPathComponent("SkyrimSE.exe"), "exe")                  // same as vanilla
    write(stock.appendingPathComponent("skse64_loader.exe"), "loader")          // extra
    write(stock.appendingPathComponent("Data/Skyrim - Textures0.bsa"), "vanilla bsa")
    write(stock.appendingPathComponent("Data/Update.esm"), "cleaned update")   // not in vanilla

    let mo2 = try! MO2Instance.open(inst)
    check(mo2.gameDir?.path == stock.path, "Stock Game found from ModOrganizer.ini (\(mo2.gameDir?.path ?? "nil"))")
    check(mo2.selectedProfile == "Main" && mo2.profiles == ["Main"], "selected profile read")
    check(mo2.modlist("Main").map(\.name) == ["B", "C", "A"], "modlist: highest priority first, separator and DLC left out")
    let lo = mo2.loadOrder("Main")
    check(lo.map(\.name) == ["Skyrim.esm", "A.esp", "B.esp"] && lo[1].active && !lo[2].active, "load order + active flags")

    let r = try! k.importMO2(mo2, profile: "Main", as: "My List", vanillaGame: f.game, gameVersion: "1.6.1170")
    check(r.mods == 3 && r.gameRootFiles == 2 && r.inis == 1 && r.missing.isEmpty, "imported 3 mods, 2 game-root files, 1 INI (\(r.mods)/\(r.gameRootFiles)/\(r.inis))")
    let p = k.profile("My List")!
    let names = p.mods.compactMap { k.mod($0.id)?.name }
    check(names == ["My List – Game Root", "A", "Visuals", "C", "B", "My List – Overwrite"], "priority order, separator before its group (\(names))")
    check(k.mods.first { $0.name == "Visuals" }?.isSeparator == true, "MO2 separator kept as a SkyrimMT separator")
    check(p.mods.first { k.mod($0.id)?.name == "C" }?.enabled == false, "disabled mod stays disabled")
    check(p.gameVersion == "1.6.1170" && p.loadOrder.count == 3, "profile version + load order")
    let b = k.mods.first { $0.name == "B" }!
    check(b.nexus == NexusRef(modID: 123, fileID: 456) && b.version == "1.2", "Nexus ids from meta.ini")
    check(!fm.fileExists(atPath: k.stagingFolder(b).appendingPathComponent("textures/hidden.dds.mohidden").path), "hidden file skipped")
    check(fm.fileExists(atPath: k.stagingFolder(b).appendingPathComponent("__root__/enbseries.ini").path), "Root Builder → __root__")

    _ = try! k.switchProfile(to: "My List")
    check(read(f.game.appendingPathComponent("Data/textures/a.dds")) == "B", "highest-priority mod wins in the game")
    check(read(f.game.appendingPathComponent("enbseries.ini")) == "enb" && read(f.game.appendingPathComponent("skse64_loader.exe")) == "loader", "root files deployed")
    check(read(f.game.appendingPathComponent("Data/Update.esm")) == "cleaned update", "Stock Game extras deployed")

    // a gamePath outside the instance (the real game) is never imported as game-root files
    let inst2 = f.home.appendingPathComponent("mo2-outside")
    write(inst2.appendingPathComponent("ModOrganizer.ini"), "[General]\ngamePath=@ByteArray(Z:\(f.game.path.replacingOccurrences(of: "/", with: "\\\\")))\n")
    write(inst2.appendingPathComponent("profiles/P/modlist.txt"), "")
    check((try! MO2Instance.open(inst2)).gameDir == nil, "real game folder is not a Stock Game")

    // re-import reuses the same mods
    let before = Set(k.mods.map(\.id))
    write(inst.appendingPathComponent("mods/A/textures/new.dds"), "new")
    _ = try! k.importMO2(mo2, profile: "Main", as: "My List", vanillaGame: f.game, gameVersion: "1.6.1170")
    check(Set(k.mods.map(\.id)) == before, "re-import keeps mod ids")
    check(fm.fileExists(atPath: k.stagingFolder(k.mods.first { $0.name == "A" }!).appendingPathComponent("textures/new.dds").path), "re-import refreshes files")
    try? fm.removeItem(at: f.home)
}

func profileINITests() {
    section("per-profile INIs")
    let f = Fixture("profini")
    let k = f.kit
    _ = try! k.currentProfile()   // creates "Default"
    let mg = k.myGamesDir
    write(mg.appendingPathComponent("Skyrim.ini"), "shared skyrim")
    write(mg.appendingPathComponent("SkyrimPrefs.ini"), "shared prefs")
    try! k.createProfile("Listy")
    write(k.profileINIDir("Listy").appendingPathComponent("Skyrim.ini"), "list skyrim")
    _ = try! k.switchProfile(to: "Listy")
    check(read(mg.appendingPathComponent("Skyrim.ini")) == "list skyrim", "profile INI put in place")
    check(read(mg.appendingPathComponent("SkyrimPrefs.ini")) == "shared prefs", "INIs the profile lacks stay")
    write(mg.appendingPathComponent("Skyrim.ini"), "list skyrim (changed in game)")
    _ = try! k.switchProfile(to: "Default")
    check(read(mg.appendingPathComponent("Skyrim.ini")) == "shared skyrim", "shared INIs restored")
    check(read(k.profileINIDir("Listy").appendingPathComponent("Skyrim.ini")) == "list skyrim (changed in game)", "in-game changes kept with the profile")
    try! k.createProfile("Plain")
    write(mg.appendingPathComponent("Skyrim.ini"), "shared v2")
    _ = try! k.switchProfile(to: "Plain")
    check(read(mg.appendingPathComponent("Skyrim.ini")) == "shared v2", "profiles without own INIs touch nothing")
    try? fm.removeItem(at: f.home)
}

func vanillaViewTests() {
    section("vanilla view")
    let f = Fixture("vanillaview")
    let k = f.kit
    _ = f.addMod("Replacer", ["Skyrim - Textures0.bsa": "modded bsa", "textures/new.dds": "new"])
    _ = try! k.deploy()
    check(read(f.game.appendingPathComponent("Data/Skyrim - Textures0.bsa")) == "modded bsa", "mod replaced a vanilla file")
    let v = f.home.appendingPathComponent("vanilla-view")
    let n = try! k.deployer.makeVanillaView(at: v)
    check(read(v.appendingPathComponent("Data/Skyrim - Textures0.bsa")) == "vanilla bsa", "vanilla view has the original (from backup)")
    check(!fm.fileExists(atPath: v.appendingPathComponent("Data/textures/new.dds").path), "mod-only files left out")
    check(read(v.appendingPathComponent("SkyrimSE.exe")) == "exe" && n == 4, "all vanilla files (\(n))")
    try? fm.removeItem(at: f.home)
}

func manualInstallFilesTests() {
    section("MO2 import: list files for manual install")
    let f = Fixture("mo2manual")
    let k = f.kit
    let inst = f.home.appendingPathComponent("adf")
    write(inst.appendingPathComponent("ModOrganizer.ini"), "[General]\ngameName=Skyrim Special Edition\nselected_profile=@ByteArray(Main)\n")
    write(inst.appendingPathComponent("mods/A/A.esp"), "a")
    write(inst.appendingPathComponent("profiles/Main/modlist.txt"), "+A\r\n")
    write(inst.appendingPathComponent("profiles/Main/plugins.txt"), "*A.esp\r\n")
    let man = inst.appendingPathComponent("__Files Requiring Manual Install")
    for (rel, c) in ["skse64_loader.exe": "loader", "skse64_1_7_104.dll": "dll", "skse64_readme.txt": "rm", "Data/Scripts/actor.pex": "pex",
                     "src/skse64-2.3.1.tar.gz": "src"] { write(man.appendingPathComponent(rel), c) }
    write(inst.appendingPathComponent("__Bethini Pie/Bethini.exe"), "tool")      // a tool folder: not imported
    let r = try! k.importMO2(try! MO2Instance.open(inst), profile: "Main", as: "ADF", vanillaGame: f.game, gameVersion: nil) { _, _, _ in }
    let p = k.profile(r.profile)!
    let gf = k.mods.first { $0.name == "ADF – Game Files" }
    check(gf != nil && p.mods.contains { $0.id == gf!.id && $0.enabled }, "manual-install folder imported and enabled")
    if let gf {
        check(snapshot(k.stagingFolder(gf)) == ["__root__/skse64_loader.exe": "loader", "__root__/skse64_1_7_104.dll": "dll", "scripts/actor.pex": "pex"],
              "SKSE laid out: loader + DLL to the game folder, scripts to Data, source/readme left out (\(snapshot(k.stagingFolder(gf)).keys.sorted()))")
    }
    check(r.gameRootFiles == 2, "game-folder files counted (\(r.gameRootFiles))")
    check(!k.mods.contains { $0.name.contains("Bethini") }, "tool folders are not mods")
    _ = try! k.importMO2(try! MO2Instance.open(inst), profile: "Main", as: "ADF", vanillaGame: f.game, gameVersion: nil) { _, _, _ in }
    check(k.mods.filter { $0.name == "ADF – Game Files" }.count == 1, "re-import refreshes, no duplicate")
}

func mo2VariantTests() {
    section("MO2 import: list variants")
    check(ModKit.variantProfileName(list: "A Dragonborn's Fate", mo2Profile: "A Dragonborn's Fate Extended") == "A Dragonborn's Fate – Extended", "variant name trimmed")
    check(ModKit.variantProfileName(list: "List", mo2Profile: "Performance") == "List – Performance", "other variant name kept")
    check(ModKit.variantProfileName(list: "A Dragonborn's Fate", mo2Profile: "A Dragonborn's Fate") == "A Dragonborn's Fate – Standard", "the list-named variant is “Standard”")
    let f = Fixture("mo2variants")
    let k = f.kit
    let inst = f.home.appendingPathComponent("list")
    write(inst.appendingPathComponent("ModOrganizer.ini"), "[General]\ngameName=Skyrim Special Edition\nselected_profile=@ByteArray(Main)\n")
    write(inst.appendingPathComponent("mods/A/A.esp"), "a"); write(inst.appendingPathComponent("mods/B/B.esp"), "b")
    write(inst.appendingPathComponent("profiles/Main/modlist.txt"), "+A\r\n"); write(inst.appendingPathComponent("profiles/Main/plugins.txt"), "*A.esp\r\n")
    write(inst.appendingPathComponent("profiles/Main Extended/modlist.txt"), "+B\r\n+A\r\n"); write(inst.appendingPathComponent("profiles/Main Extended/plugins.txt"), "*A.esp\r\n*B.esp\r\n")
    let mo2 = try! MO2Instance.open(inst)
    _ = try! k.importMO2(mo2, profile: "Main", as: "Main", vanillaGame: f.game, gameVersion: nil) { _, _, _ in }
    _ = try! k.importMO2(mo2, profile: "Main Extended", as: ModKit.variantProfileName(list: "Main", mo2Profile: "Main Extended"), vanillaGame: f.game, gameVersion: nil) { _, _, _ in }
    check(k.profile("Main")?.mods.count == 1 && k.profile("Main – Extended")?.mods.count == 2, "both variants are profiles")
    check(k.mods.filter { $0.name == "A" }.count == 1, "shared mod imported once")
}

func listUpdateTests() {
    section("list update: re-import keeps the player's additions")
    let f = Fixture("listupdate")
    let k = f.kit
    let inst = f.home.appendingPathComponent("list")
    write(inst.appendingPathComponent("ModOrganizer.ini"), "[General]\ngameName=Skyrim Special Edition\nselected_profile=@ByteArray(Main)\n")
    write(inst.appendingPathComponent("mods/A/A.esp"), "a v1")
    write(inst.appendingPathComponent("profiles/Main/modlist.txt"), "+A\r\n"); write(inst.appendingPathComponent("profiles/Main/plugins.txt"), "*A.esp\r\n")
    _ = try! k.importMO2(try! MO2Instance.open(inst), profile: "Main", as: "List", vanillaGame: f.game, gameVersion: nil) { _, _, _ in }
    // the player adds a mod with a plugin to the list's profile
    let mine = f.addMod("My Patch", ["MyPatch.esp": "p"])
    var p = k.profile("List")!; p.mods.append(ProfileMod(id: mine.id, enabled: true)); p.loadOrder.append(LoadOrderEntry(name: "MyPatch.esp", active: true)); try! k.saveProfile(p)
    // new list version: A updated, B added
    write(inst.appendingPathComponent("mods/A/A.esp"), "a v2"); write(inst.appendingPathComponent("mods/B/B.esp"), "b")
    write(inst.appendingPathComponent("profiles/Main/modlist.txt"), "+B\r\n+A\r\n"); write(inst.appendingPathComponent("profiles/Main/plugins.txt"), "*A.esp\r\n*B.esp\r\n")
    _ = try! k.importMO2(try! MO2Instance.open(inst), profile: "Main", as: "List", vanillaGame: f.game, gameVersion: nil) { _, _, _ in }
    let q = k.profile("List")!
    let names = q.mods.compactMap { k.mod($0.id)?.name }
    check(names == ["A", "B", "My Patch"], "list's mods in the new order, the player's mod kept last (\(names))")
    check(q.loadOrder.map(\.name) == ["A.esp", "B.esp", "MyPatch.esp"], "the player's plugin kept (\(q.loadOrder.map(\.name)))")
    check(read(k.stagingFolder(k.mods.first { $0.name == "A" }!).appendingPathComponent("A.esp")) == "a v2" && k.mods.filter { $0.name == "A" }.count == 1, "updated mod refreshed in place")

    section("list update: version check")
    k.recordWabbajackInstall(InstalledWabbajackList(machineURL: "Repo/List", title: "List", version: "13.10.26", profile: "List", installedAt: Date()))
    func entry(_ v: String) -> WabbajackGalleryEntry {
        WabbajackGalleryEntry(title: "List", author: "a", version: v, description: "", nsfw: false, machineURL: "Repo/List", downloadSize: 0, installSize: 0, archives: 0)
    }
    check(k.wabbajackUpdates(gallery: [entry("13.11.2")]).count == 1, "13.11.2 is newer than 13.10.26 (numeric, not text)")
    check(k.wabbajackUpdates(gallery: [entry("13.10.26")]).isEmpty && k.wabbajackUpdates(gallery: [entry("13.9.30")]).isEmpty, "same or older: no update")
}
