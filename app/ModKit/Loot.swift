// ModKit LOOT: runs the separate GPL-3 helper `skyrimmt-loot` (helpers/loot, libloot) and applies its order to the
// load order, keeping the player's active/inactive choices. The masterlist + prelude come from LOOT's GitHub repos
// (branch matching libloot 0.29), cached in $SKYRIM_HOME/cache/loot and refreshed weekly.
import Foundation

public struct LootMessage: Equatable { public let type: String; public let text: String }
public struct LootResult {
    public var sorted: [String] = []
    public var plugins: [String: [LootMessage]] = [:]
    public var general: [LootMessage] = []
    public var seconds = 0.0
    public var moved = 0
    public var dirty: [String: DirtyPlugin] = [:]   // plugin → LOOT's cleaning data for this exact file
}

/// LOOT masterlist cleaning data (ITMs = identical-to-master records, UDRs = deleted references, deleted navmeshes).
public struct DirtyPlugin: Codable, Equatable {
    public var crc: String, itm: Int, udr: Int, nav: Int, utility: String
    /// Quick Auto Clean fixes ITMs and UDRs; deleted navmeshes need manual work (LOOT says so too).
    public var autoCleanable: Bool { (itm > 0 || udr > 0) && nav == 0 }
    public var summary: String {
        var p: [String] = []
        if itm > 0 { p.append("\(itm) identical-to-master record\(itm == 1 ? "" : "s")") }
        if udr > 0 { p.append("\(udr) deleted reference\(udr == 1 ? "" : "s")") }
        if nav > 0 { p.append("\(nav) deleted navmesh\(nav == 1 ? "" : "es") (needs manual fixing)") }
        return p.joined(separator: ", ")
    }
}

public enum LootError: Error, CustomStringConvertible {
    case helperMissing, failed(String)
    public var description: String {
        switch self { case .helperMissing: return "The LOOT helper isn't part of this build."; case .failed(let m): return "LOOT: \(m)" }
    }
}

extension ModKit {
    static let lootBranch = "v0.29"   // libloot 0.29.x reads this masterlist format

    var lootCache: URL { home.appendingPathComponent("cache/loot") }

    /// Download (or refresh after 7 days) the Skyrim SE masterlist and the shared prelude.
    public func updateMasterlist(force: Bool = false) throws {
        try FileManager.default.createDirectory(at: lootCache, withIntermediateDirectories: true)
        for (file, repo) in [("masterlist.yaml", "skyrimse"), ("prelude.yaml", "prelude")] {
            let dst = lootCache.appendingPathComponent(file)
            if !force, let d = try? dst.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
               Date().timeIntervalSince(d) < 7 * 86400 { continue }
            let url = URL(string: "https://raw.githubusercontent.com/loot/\(repo)/\(ModKit.lootBranch)/\(file)")!
            guard let data = try? Data(contentsOf: url), data.count > 1000 else {
                if FileManager.default.fileExists(atPath: dst.path) { continue }   // offline: keep the cached one
                throw LootError.failed("couldn't download the LOOT \(file)")
            }
            try data.write(to: dst, options: .atomic)
        }
    }

    /// Sort with LOOT and apply the order (plugins.txt + the profile's load order). `helper` = path to skyrimmt-loot.
    @discardableResult
    public func lootSort(helper: URL, apply: Bool = true) throws -> LootResult {
        guard FileManager.default.isExecutableFile(atPath: helper.path) else { throw LootError.helperMissing }
        try updateMasterlist()
        let p = Process(); p.executableURL = helper
        var args = ["sort", "--game", gameDir.path, "--local", pluginsTxt.deletingLastPathComponent().path,
                    "--masterlist", lootCache.appendingPathComponent("masterlist.yaml").path,
                    "--prelude", lootCache.appendingPathComponent("prelude.yaml").path]
        let user = home.appendingPathComponent("config/modkit/loot-userlist.yaml")
        if FileManager.default.fileExists(atPath: user.path) { args += ["--userlist", user.path] }
        p.arguments = args
        let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        guard let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw LootError.failed("no answer from the helper") }
        if let e = j["error"] as? String { throw LootError.failed(e) }
        func msgs(_ v: Any?) -> [LootMessage] { (v as? [[String: Any]] ?? []).map { LootMessage(type: $0["type"] as? String ?? "say", text: $0["text"] as? String ?? "") } }
        var r = LootResult()
        r.sorted = j["sorted"] as? [String] ?? []
        r.general = msgs(j["general"])
        r.seconds = j["seconds"] as? Double ?? 0
        for (k, v) in j["plugins"] as? [String: Any] ?? [:] { r.plugins[k] = msgs(v) }
        for (k, v) in j["dirty"] as? [String: [String: Any]] ?? [:] {
            r.dirty[k] = DirtyPlugin(crc: v["crc"] as? String ?? "", itm: v["itm"] as? Int ?? 0, udr: v["udr"] as? Int ?? 0,
                                     nav: v["nav"] as? Int ?? 0, utility: v["utility"] as? String ?? "SSEEdit")
        }
        guard apply else { return r }
        var lo = loadOrder()
        let pos = Dictionary(r.sorted.enumerated().map { ($1.lowercased(), $0) }, uniquingKeysWith: { a, _ in a })
        let before = lo.entries.map(\.name), beforeEntries = lo.entries
        lo.entries.sort { (pos[$0.name.lowercased()] ?? Int.max) < (pos[$1.name.lowercased()] ?? Int.max) }
        lo.entries = LoadOrder.keepLocked(before: beforeEntries, sorted: lo.entries, locked: Set((try? currentProfile())?.lockedPlugins ?? []))
        r.moved = zip(before, lo.entries.map(\.name)).filter { $0 != $1 }.count
        try lo.write(to: pluginsTxt)
        var prof = try currentProfile(); prof.loadOrder = lo.entries; try saveProfile(prof)
        return r
    }
}
