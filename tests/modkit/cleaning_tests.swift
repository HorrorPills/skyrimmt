// Plugin cleaning (ModKit/Cleaning.swift): workspace, xEdit arguments/settings/log, Cleaned Plugins mod, stale copies.
import Foundation

func cleaningTests() {
    section("plugin cleaning (xEdit Quick Auto Clean)")
    check(ModKit.xeditAppName(URL(fileURLWithPath: "/x/SSEEdit64.exe")) == "SSEEdit" && ModKit.xeditAppName(URL(fileURLWithPath: "/x/SSEEditQuickAutoClean.exe")) == "SSEEdit"
          && ModKit.xeditAppName(URL(fileURLWithPath: "/x/SSEEdit.exe")) == "SSEEdit", "log/settings name from any xEdit exe")
    let log = """
    [Undeleting and Disabling References done]  Processed Records: 699, Undeleted Records: 4, Elapsed Time: 00:00
    Removing: MGRJzargoFlameCloak "J'zargo's Flame Cloak" [SPEL:00097EDF]
    [Removing "Identical to Master" records done]  Processed Records: 699, Removed Records: 3, Elapsed Time: 00:00
    [Undeleting and Disabling References done]  Processed Records: 698, Undeleted Records: 0, Elapsed Time: 00:00
    [Removing "Identical to Master" records done]  Processed Records: 698, Removed Records: 0, Elapsed Time: 00:00
    """
    let c = ModKit.cleaningCounts(log)
    check(c.itm == 3 && c.udr == 4, "counts summed over passes (\(c))")
    let two = "SSEEdit (Quick Auto Clean) starting session 1\n[x]  Processed Records: 9, Removed Records: 5, E\nSSEEdit starting session 2\n" + log
    check(ModKit.cleaningCounts(two) == (3, 4), "only the last session of an appended log counts")
    check(ModKit.winPath(URL(fileURLWithPath: "/Users/a/Data"), dir: true) == "Z:\\Users\\a\\Data\\", "Wine path")

    let f = Fixture("cleaning")
    let k = f.kit
    try! pluginBytes(flags: 1, masters: []).write(to: f.game.appendingPathComponent("Data/Skyrim.esm"))
    _ = f.addMod("Dirty Mod", ["Dirty.esp": "dirty v1", "textures/d.dds": "d"])
    try! k.deploy()
    let xedit = f.home.appendingPathComponent("tools/SSEEdit.exe"); write(xedit, "exe")
    let job = try! k.prepareCleaning(plugin: "Dirty.esp", xedit: xedit)
    check(read(job.workspace.appendingPathComponent("Data/Dirty.esp")) == "dirty v1", "workspace = clone of the game's Data")
    check(job.arguments.prefix(4) == ["-qac", "-autoexit", "-autoload", "-IKnowWhatImDoing"] && job.arguments.last == "Dirty.esp"
          && job.arguments.contains { $0.hasPrefix("-D:Z:") && $0.hasSuffix("\\Data\\") }, "xEdit arguments (\(job.arguments))")
    let settings = read(f.home.appendingPathComponent("cache/xedit/plugins.sseviewsettings")) ?? ""
    check(settings.contains("First64Start=0") && settings.contains("[DeveloperMessage]") && settings.contains("LastShownOn="), "first-run questions pre-answered")
    // "xEdit" cleans the copy
    write(job.workspace.appendingPathComponent("Data/Dirty.esp"), "clean v1")
    write(xedit.deletingLastPathComponent().appendingPathComponent("SSEEdit_log.txt"), log)
    let r = try! k.finishCleaning(job)
    check(r.changed && r.removedITMs == 3 && r.undeletedRefs == 4, "result read back (\(r))")
    check(!fm.fileExists(atPath: job.workspace.path), "workspace removed")
    check(!fm.fileExists(atPath: xedit.deletingLastPathComponent().appendingPathComponent("SSEEdit_log.txt").path)
          && fm.fileExists(atPath: f.home.appendingPathComponent("logs/xedit/SSEEdit_log.txt").path), "xEdit's log moved out of its folder (no stray mod files)")
    check(read(f.game.appendingPathComponent("Data/Dirty.esp")) == "dirty v1", "game folder untouched by cleaning")
    let cm = k.cleanedMod
    check(cm != nil && read(k.stagingFolder(cm!).appendingPathComponent("Dirty.esp")) == "clean v1", "cleaned copy in the Cleaned Plugins mod")
    check(try! k.currentProfile().mods.last?.id == cm?.id, "Cleaned Plugins wins (highest priority)")
    try! k.deploy()
    check(read(f.game.appendingPathComponent("Data/Dirty.esp")) == "clean v1", "deploy uses the cleaned copy")
    check(k.staleCleanedPlugins().isEmpty, "fresh copy is not stale")
    // the mod updates its plugin → the cleaned copy would hide the new version
    let dm = k.mods.first { $0.name == "Dirty Mod" }!
    write(k.stagingFolder(dm).appendingPathComponent("Dirty.esp"), "dirty v2")
    check(k.staleCleanedPlugins() == ["Dirty.esp"], "stale after the original changed (\(k.staleCleanedPlugins()))")
    try! k.removeCleaned(["Dirty.esp"]); try! k.deploy()
    check(read(f.game.appendingPathComponent("Data/Dirty.esp")) == "dirty v2", "removing the stale copy brings the new version back")
    // unchanged result → nothing kept
    let job2 = try! k.prepareCleaning(plugin: "Dirty.esp", xedit: xedit)
    check(!(try! k.finishCleaning(job2)).changed, "already clean: nothing changed")
}
