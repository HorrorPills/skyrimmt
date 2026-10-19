// Light-plugin (ESL) candidates (docs/MODMANAGER.md §3B): a regular .esp whose own new records all have object IDs in
// the light range can be flagged light and stop using one of the 254 full slots. Analysis only — conservative:
// new IDs within 0x800–0xFFF, or 0x000–0xFFF for header-1.71 plugins on game 1.6.1130+ (checked against the owner's
// library 2026-10-19: all 9 light plugins with IDs below 0x800 are 1.71, none of 155 at 1.70); no new cells or
// worldspaces (the case light-plugin guides warn about); not a master of other active plugins. Reads record headers
// only (24 bytes each), never record data.
import Foundation

public struct LightCandidate: Equatable {
    public var plugin: String
    public var newRecords: Int
    public var reason: String?          // nil = can be flagged light; else why not
}

extension PluginParser {
    /// Walk the record headers: new records (master index == own index), their highest object ID, new CELL/WRLD.
    public static func scanNewRecords(_ url: URL) throws -> (masters: Int, newRecords: Int, minID: UInt32, maxID: UInt32, newCellsOrWorlds: Int, light: Bool, version: Float) {
        let d = try Data(contentsOf: url, options: .mappedIfSafe)
        let h = try parse(url)
        let own = UInt32(h.masters.count)
        var i = 0, count = 0, cells = 0
        var lo = UInt32.max, hi: UInt32 = 0
        // TES4 record first
        guard d.count >= 24 else { throw PluginError.truncated(url.lastPathComponent) }
        i = 24 + Int(d.u32(4))
        while i + 24 <= d.count {
            let type = d.subdata(in: i..<(i + 4))
            if type == Data("GRUP".utf8) { i += 24; continue }        // groups: their records follow inline
            let size = Int(d.u32(i + 4)), formID = d.u32(i + 12)
            if formID >> 24 == own {
                count += 1
                let obj = formID & 0xFFFFFF
                lo = min(lo, obj); hi = max(hi, obj)
                if type == Data("CELL".utf8) || type == Data("WRLD".utf8) { cells += 1 }
            }
            i += 24 + size
        }
        return (h.masters.count, count, lo == .max ? 0 : lo, hi, cells, h.isLight, h.version)
    }
}

extension ModKit {
    /// Active full-slot .esp plugins that could be flagged light.
    /// `gameVersion`: "1.7.104" etc.; 1.6.1130 and later read header-1.71 light plugins with IDs from 0x000.
    public func lightCandidates(gameVersion: String) -> [LightCandidate] {
        let lo = loadOrder()
        let data = gameDir.appendingPathComponent("Data")
        let extendedGame = gameVersion.compare("1.6.1130", options: .numeric) != .orderedAscending
        let mastersOfOthers = Set(lo.entries.filter(\.active).flatMap { lo.headers[$0.name.lowercased()]?.masters ?? [] }.map { $0.lowercased() })
        var out: [LightCandidate] = []
        for e in lo.entries where e.active && e.name.lowercased().hasSuffix(".esp") {
            guard let h = lo.headers[e.name.lowercased()], !h.isLight, !h.isMaster,
                  let r = try? PluginParser.scanNewRecords(data.appendingPathComponent(e.name)) else { continue }
            var why: String?
            let floor: UInt32 = (extendedGame && r.version >= 1.71) ? 0 : 0x800
            if r.newRecords > Int(0x1000 - floor) { why = "\(r.newRecords) new records — more than a light plugin holds" }
            else if r.newRecords > 0 && (r.minID < floor || r.maxID > 0xFFF) { why = "its record IDs are outside the light range (needs compacting in xEdit)" }
            else if mastersOfOthers.contains(e.name.lowercased()) { why = "other plugins use it as a master" }
            else if r.newCellsOrWorlds > 0 { why = "adds \(r.newCellsOrWorlds) new cell/worldspace record\(r.newCellsOrWorlds == 1 ? "" : "s")" }
            out.append(LightCandidate(plugin: e.name, newRecords: r.newRecords, reason: why))
        }
        return out
    }
}

extension ModKit {
    public static let lightFlaggedModName = "Light-flagged Plugins"
    var lightStateURL: URL { stateDir.appendingPathComponent("light-flagged.json") }
    public var lightFlaggedMod: ModRecord? { mods.first { $0.name == ModKit.lightFlaggedModName } }

    /// Flag qualifying plugins light: a copy of the deployed plugin with TES4 flag 0x200 goes into "Light-flagged
    /// Plugins" (last in the profile). Originals stay untouched; returns the plugins flagged.
    @discardableResult
    public func flagLight(_ plugins: [String], gameVersion: String) throws -> [String] {
        let ok = Set(lightCandidates(gameVersion: gameVersion).filter { $0.reason == nil }.map { $0.plugin.lowercased() })
        let todo = plugins.filter { ok.contains($0.lowercased()) }
        guard !todo.isEmpty else { return [] }
        let fm = FileManager.default
        let mod: ModRecord
        if let m = lightFlaggedMod { mod = m } else {
            let tmp = home.appendingPathComponent("incoming/light-\(UUID().uuidString)")
            try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
            mod = try addMod(name: ModKit.lightFlaggedModName, from: tmp)
        }
        var recs = readJSON(lightStateURL, [String: CleanedRecord].self) ?? [:]
        for name in todo {
            let src = gameDir.appendingPathComponent("Data").appendingPathComponent(name)
            var d = try Data(contentsOf: src)
            guard d.count >= 12, d.prefix(4) == Data("TES4".utf8) else { continue }
            let flags = d.u32(8) | 0x200
            d.replaceSubrange(8..<12, with: withUnsafeBytes(of: flags.littleEndian) { Data($0) })
            let dst = stagingFolder(mod).appendingPathComponent(name)
            try? fm.removeItem(at: dst)
            try d.write(to: dst)
            recs[name.lowercased()] = CleanedRecord(sourceHash: ModKit.fileHash(src) ?? "", cleanedAt: Date())
        }
        try writeJSON(recs, to: lightStateURL)
        var p = try currentProfile()
        p.mods.removeAll { $0.id == mod.id }; p.mods.append(ProfileMod(id: mod.id, enabled: true))
        try saveProfile(p)
        return todo
    }

    /// Light-flagged copies whose original changed since (a mod update) — they would hide the new version.
    public func staleLightFlagged() -> [String] {
        guard let m = lightFlaggedMod, let p = try? currentProfile() else { return [] }
        let recs = readJSON(lightStateURL, [String: CleanedRecord].self) ?? [:]
        var q = p; q.mods.removeAll { $0.id == m.id }
        guard let plan = try? plan(q) else { return [] }
        return ((try? FileManager.default.contentsOfDirectory(atPath: stagingFolder(m).path)) ?? []).filter { f in
            guard let rec = recs[f.lowercased()], let src = plan.files["data/" + f.lowercased()] else { return false }
            return ModKit.fileHash(URL(fileURLWithPath: src.source)) != rec.sourceHash
        }.sorted()
    }

    public func removeLightFlagged(_ plugins: [String]) throws {
        guard let m = lightFlaggedMod else { return }
        var recs = readJSON(lightStateURL, [String: CleanedRecord].self) ?? [:]
        for n in plugins { try? FileManager.default.removeItem(at: stagingFolder(m).appendingPathComponent(n)); recs[n.lowercased()] = nil }
        try writeJSON(recs, to: lightStateURL)
    }
}
