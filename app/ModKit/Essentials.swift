// ModKit essentials (PLAN §8.9 / M9): the curated base for a modded Skyrim on 1.7.104, as Nexus mod ids. SkyrimMT never
// mirrors these files: the player downloads each through their own Nexus account ("Mod Manager Download" on the
// mod's Files page → nxm link → SkyrimMT downloads and installs). Ids checked on 2026-10-17 (docs/m1-sources.md).
import Foundation

public struct Essential: Identifiable, Equatable {
    public let id: String
    public let name: String
    public let nexusID: Int
    public let why: String
    public let note: String
    /// files (relative to the game folder, case-insensitive glob on the last component) that show it is installed
    public let marker: String
    /// The note for the selected game version: the 1.7.104 facts were checked for 1.7.104 only (docs/m1-sources.md),
    /// other versions get version-neutral advice instead of a wrong build number.
    public func note(for gameVersion: String) -> String {
        if gameVersion.isEmpty || gameVersion.hasPrefix("1.7.") { return note }
        switch id {
        case "skse": return "Choose the build for game \(gameVersion) on Nexus."
        case "addresslib": return "Choose the All in One file on Nexus."
        case "displaytweaks": return "Choose a build that supports \(gameVersion) on Nexus."
        default: return note
        }
    }
    public var filesURL: URL { URL(string: "https://www.nexusmods.com/skyrimspecialedition/mods/\(nexusID)?tab=files")! }
}

public let essentials: [Essential] = [
    Essential(id: "skse", name: "SKSE64 (Anniversary Edition build)", nexusID: 30379, why: "Script Extender. Required by most large mods.",
              note: "SKSE 2.3.x for game 1.7.104.", marker: "skse64_loader.exe"),
    Essential(id: "addresslib", name: "Address Library for SKSE Plugins", nexusID: 32444, why: "Lets SKSE plugins work across game versions.",
              note: "All in One, v13 or newer for 1.7.104.", marker: "Data/SKSE/Plugins/versionlib-*.bin"),
    Essential(id: "enginefixes", name: "SSE Engine Fixes", nexusID: 17230, why: "Fixes engine bugs and crashes.",
              note: "Plugin and preloader; both are installed.", marker: "Data/SKSE/Plugins/EngineFixes.dll"),
    Essential(id: "displaytweaks", name: "SSE Display Tweaks (updated for 1.7.104)", nexusID: 189739, why: "Frame rates above 60 without physics issues, and a frame limiter.",
              note: "Unofficial update for 1.7.99–1.7.104.", marker: "Data/SKSE/Plugins/SSEDisplayTweaks.dll"),
    Essential(id: "crashlogger", name: "Crash Logger SSE AE VR", nexusID: 59818, why: "Writes a crash log that the Crashes page analyzes.",
              note: "Logs go to My Games/Skyrim Special Edition/SKSE.", marker: "Data/SKSE/Plugins/CrashLogger.dll"),
    Essential(id: "skyui", name: "SkyUI", nexusID: 12604, why: "Improved menus and the mod configuration menu (MCM).",
              note: "Needs SKSE.", marker: "Data/SkyUI_SE.esp"),
]

extension ModKit {
    /// The Nexus files to install for an essential on this game version (file names as published, checked through
    /// the public API on 2026-10-19). Empty: no confident choice (other game versions) — the player picks on Nexus.
    public static func essentialFiles(_ e: Essential, from files: [NexusFileInfo], gameVersion: String) -> [NexusFileInfo] {
        guard gameVersion.isEmpty || gameVersion.hasPrefix("1.7.") else { return [] }
        let main = files.filter { $0.category.uppercased() == "MAIN" }.sorted { $0.uploadedTimestamp > $1.uploadedTimestamp }
        func newest(_ needle: String) -> NexusFileInfo? { main.first { $0.name.lowercased().contains(needle.lowercased()) } }
        let v = gameVersion.isEmpty ? "1.7." : gameVersion
        switch e.id {
        case "skse": return newest("Steam").map { [$0] } ?? []                         // the GOG build is listed too
        case "addresslib": return (newest(v) ?? newest("1.7.")).map { [$0] } ?? []      // "All in One (1.7.104.0)"
        case "enginefixes":                                                              // 1.7 build + the SKSE64 preloader
            guard let plugin = newest("1.7"), let pre = newest("Preloader") else { return [] }
            return [plugin, pre]
        default: return (main.first(where: \.isPrimary) ?? main.first).map { [$0] } ?? []
        }
    }

    /// Is the essential present in the game folder (deployed) or installed in SkyrimMT (by Nexus id)?
    public func isInstalled(_ e: Essential) -> Bool {
        if mods.contains(where: { $0.nexus?.modID == e.nexusID }) { return true }
        let parts = e.marker.split(separator: "/").map(String.init)
        let dir = parts.dropLast().reduce(gameDir) { $0.appendingPathComponent($1) }
        let pattern = parts.last!.lowercased()
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).map { $0.lowercased() }
        if pattern.contains("*") {
            let pre = String(pattern.split(separator: "*", omittingEmptySubsequences: false).first ?? ""), suf = String(pattern.split(separator: "*", omittingEmptySubsequences: false).last ?? "")
            return names.contains { $0.hasPrefix(pre) && $0.hasSuffix(suf) }
        }
        return names.contains(pattern)
    }
}
