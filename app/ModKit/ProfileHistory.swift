// Profile history, rename, export/import (docs/MODMANAGER.md §3C). Every save of a profile keeps the previous version
// in profiles/<name>/history/ (a burst of saves inside one action keeps only the state before it), so any change —
// a sort, a collection repair, an accidental purge + switch — can be undone. Exports are shareable JSON: the profile
// plus each mod's name, version and Nexus ids (no files).
import Foundation

public struct ProfileSnapshot: Identifiable, Equatable {
    public var id: String { url.lastPathComponent }
    public let url: URL
    public let date: Date
    public let mods: Int
    public let enabledMods: Int
    public let plugins: Int
    public let activePlugins: Int
    public let gameVersion: String?
}

public struct ProfileExport: Codable {
    public struct Mod: Codable { public var name: String; public var version: String; public var nexus: NexusRef?; public var enabled: Bool }
    public var format = "skyrimmt-profile"
    public var version = 1
    public var name: String
    public var gameVersion: String?
    public var mods: [Mod]
    public var loadOrder: [LoadOrderEntry]
}

extension ModKit {
    static let historyKeep = 300
    static var historyCoalesce: TimeInterval = 3   // tests set 0

    func historyDir(_ name: String) -> URL { profilesDir.appendingPathComponent("\(name)/history") }

    /// Called by saveProfile before the new version is written.
    func snapshotBeforeSave(_ url: URL, newData: Data) {
        let fm = FileManager.default
        guard let old = try? Data(contentsOf: url), old != newData else { return }
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        guard Date().timeIntervalSince(modified) > ModKit.historyCoalesce else { return }   // same action: keep the first state only
        let dir = url.deletingLastPathComponent().appendingPathComponent("history")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let stamp = f.string(from: modified).replacingOccurrences(of: ":", with: "-")
        try? old.write(to: dir.appendingPathComponent("\(stamp).json"))
        let all = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasSuffix(".json") }.sorted()
        for name in all.dropLast(ModKit.historyKeep) { try? fm.removeItem(at: dir.appendingPathComponent(name)) }
    }

    /// Earlier versions of a profile, newest first.
    public func profileHistory(_ name: String) -> [ProfileSnapshot] {
        let dir = historyDir(name)
        let files = Array(((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasSuffix(".json") }.sorted().reversed())
        // up to 300 snapshots of a 2,000-mod profile: decode in parallel
        var out = [ProfileSnapshot?](repeating: nil, count: files.count)
        out.withUnsafeMutableBufferPointer { buf in
            DispatchQueue.concurrentPerform(iterations: files.count) { i in
                let u = dir.appendingPathComponent(files[i])
                guard let p = readJSON(u, Profile.self) else { return }
                let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                let date = f.date(from: ModKit.unstamp(String(files[i].dropLast(5)))) ?? .distantPast
                buf[i] = ProfileSnapshot(url: u, date: date, mods: p.mods.count, enabledMods: p.mods.filter(\.enabled).count,
                                         plugins: p.loadOrder.count, activePlugins: p.loadOrder.filter(\.active).count, gameVersion: p.gameVersion)
            }
        }
        return out.compactMap { $0 }
    }

    /// "2026-10-18T11-02-27.123Z" → "2026-10-18T11:02:27.123Z" (only the time part had its colons replaced)
    static func unstamp(_ s: String) -> String {
        guard let t = s.firstIndex(of: "T") else { return s }
        return String(s[..<t]) + s[t...].replacingOccurrences(of: "-", with: ":")
    }

    /// Put an earlier version back (the current one goes into the history first); deployed if the profile is active.
    public func restoreProfile(_ name: String, from snap: ProfileSnapshot) throws {
        guard var p = readJSON(snap.url, Profile.self) else { throw ModKitError.invalid("snapshot unreadable") }
        p.name = name
        let url = profilesDir.appendingPathComponent("\(name)/profile.json")
        if let cur = try? Data(contentsOf: url) {   // always keep the version being replaced
            let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            try? FileManager.default.createDirectory(at: historyDir(name), withIntermediateDirectories: true)
            try? cur.write(to: historyDir(name).appendingPathComponent(f.string(from: Date()).replacingOccurrences(of: ":", with: "-") + ".json"))
        }
        try writeJSON(p, to: url)
        if name == currentProfileName { try deploy(p) }
    }

    /// Rename a profile (folder, active marker, its generated outputs and collection entry follow).
    public func renameProfile(_ old: String, to newName: String) throws {
        let new = ModKit.sanitize(newName)
        guard new != old else { return }
        guard profile(old) != nil else { throw ModKitError.noSuchProfile(old) }
        guard profile(new) == nil else { throw ModKitError.invalid("a profile named “\(new)” exists") }
        let fm = FileManager.default
        try fm.moveItem(at: profilesDir.appendingPathComponent(old), to: profilesDir.appendingPathComponent(new))
        try renameSlot(old, to: new)
        var p = profile(new)!; p.name = new
        // generated outputs are per profile: their ids carry the name
        for (oldID, newID) in [(ModKit.pandoraOutputID(old), ModKit.pandoraOutputID(new)), (ModKit.bodySlideOutputID(old), ModKit.bodySlideOutputID(new)),
                               (ModKit.overwriteID(for: old), ModKit.overwriteID(for: new))] {
            if let i = mods.firstIndex(where: { $0.id == oldID }) {
                var r = mods[i]; r.id = newID; r.name = r.name.replacingOccurrences(of: "(\(old))", with: "(\(new))"); replaceMod(at: i, with: r)
            }
            if let j = p.mods.firstIndex(where: { $0.id == oldID }) { p.mods[j].id = newID }
        }
        try writeJSON(p, to: profilesDir.appendingPathComponent("\(new)/profile.json"))
        if var st = readJSON(pandoraStateURL, PandoraState.self), let v = st.fingerprints.removeValue(forKey: old) { st.fingerprints[new] = v; try writeJSON(st, to: pandoraStateURL) }
        if var st = readJSON(bodySlideStateURL, BodySlideState.self) {
            if let v = st.fingerprints.removeValue(forKey: old) { st.fingerprints[new] = v }
            if let v = st.settings.removeValue(forKey: old) { st.settings[new] = v }
            try writeJSON(st, to: bodySlideStateURL)
        }
        var cols = installedCollections()
        for i in cols.indices where cols[i].profile == old { cols[i].profile = new }
        for i in cols.indices where cols[i].previousProfile == old { cols[i].previousProfile = new }
        try saveCollections(cols)
        if currentProfileName == old { try atomicWrite(new + "\n", to: currentURL) }
    }

    /// A shareable description of a profile (names, versions, Nexus ids, order, load order — no files).
    public func exportProfile(_ name: String) throws -> Data {
        guard let p = profile(name) else { throw ModKitError.noSuchProfile(name) }
        let mods = p.mods.compactMap { pm -> ProfileExport.Mod? in
            guard let m = mod(pm.id), !ModKit.isPandoraOutput(m.id), !ModKit.isBodySlideOutput(m.id) else { return nil }
            return ProfileExport.Mod(name: m.name, version: m.version, nexus: m.nexus, enabled: pm.enabled)
        }
        let e = ProfileExport(name: p.name, gameVersion: p.gameVersion, mods: mods, loadOrder: p.loadOrder)
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try enc.encode(e)
    }

    /// Create a profile from an export: installed mods are matched by Nexus file, then Nexus mod, then name.
    /// Returns the mods that are not installed (to download).
    @discardableResult
    public func importProfile(_ data: Data, as newName: String? = nil) throws -> [ProfileExport.Mod] {
        let e = try JSONDecoder().decode(ProfileExport.self, from: data)
        guard e.format == "skyrimmt-profile" else { throw ModKitError.invalid("not a SkyrimMT profile export") }
        var name = ModKit.sanitize(newName ?? e.name), n = 2
        while profile(name) != nil { name = ModKit.sanitize("\(newName ?? e.name) \(n)"); n += 1 }
        var p = Profile(name: name); p.gameVersion = e.gameVersion; p.loadOrder = e.loadOrder
        var missing: [ProfileExport.Mod] = []
        for m in e.mods {
            let hit = mods.first { r in m.nexus?.fileID != nil && r.nexus?.fileID == m.nexus?.fileID }
                ?? mods.first { r in m.nexus != nil && r.nexus?.modID == m.nexus?.modID }
                ?? mods.first { $0.name == m.name }
            if let h = hit { p.mods.append(ProfileMod(id: h.id, enabled: m.enabled)) } else { missing.append(m) }
        }
        try saveProfile(p)
        return missing
    }
}
