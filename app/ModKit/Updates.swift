// Mod updates (docs/MODMANAGER.md §3A "update in place"): Nexus v1 files.json lists every file plus "file_updates"
// (old_file_id → new_file_id) — the same chain Vortex/MO2 follow. The newest file reachable from the installed one is
// the update. Checking is rate-limit friendly: mods Nexus reports as recently changed first, then the rest a batch per
// check, results cached. Updating replaces the files of the SAME mod entry (position, enabled state, notes, group stay)
// and replays the saved installer (FOMOD) choices.
import Foundation

public struct ModUpdate: Codable, Identifiable, Equatable {
    public var id: String { modRecordID }
    public var modRecordID: String
    public var modName: String
    public var currentVersion: String
    public var newVersion: String
    public var nexusModID: Int
    public var newFileID: Int
    public var newFileName: String
    public var size: Int64?
    public var md5: String?
}

struct ModUpdateState: Codable { var checked: [String: Date] = [:]; var available: [String: ModUpdate] = [:] }

extension NexusClient {
    /// files.json with its update chain.
    public func filesWithUpdates(_ modID: Int) async throws -> (files: [NexusFileInfo], updates: [(old: Int, new: Int)]) {
        guard let j = try await request("games/\(nexusGame)/mods/\(modID)/files.json", cacheable: false) as? [String: Any] else { throw NexusError.badResponse("files") }
        let files = (j["files"] as? [[String: Any]] ?? []).map(Self.fileInfo)
        let ups = (j["file_updates"] as? [[String: Any]] ?? []).compactMap { u -> (Int, Int)? in
            guard let o = u["old_file_id"] as? Int, let n = u["new_file_id"] as? Int else { return nil }
            return (o, n)
        }
        return (files, ups)
    }
}

extension ModKit {
    var updateStateURL: URL { stateDir.appendingPathComponent("updates.json") }

    /// The file that replaces `fileID`: follow old→new links to the end (cycles guarded). nil = no newer file.
    public static func latestFile(from fileID: Int, files: [NexusFileInfo], updates: [(old: Int, new: Int)]) -> NexusFileInfo? {
        var next: [Int: Int] = [:]
        for u in updates { next[u.old] = u.new }
        var cur = fileID, seen = Set<Int>()
        while let n = next[cur], !seen.contains(n) { seen.insert(cur); cur = n }
        guard cur != fileID else { return nil }
        return files.first { $0.fileID == cur }
    }

    public func cachedUpdates() -> [ModUpdate] {
        let st = readJSON(updateStateURL, ModUpdateState.self) ?? ModUpdateState()
        return st.available.values.filter { u in mods.contains { $0.id == u.modRecordID && $0.nexus?.fileID != u.newFileID } }
            .sorted { $0.modName.localizedStandardCompare($1.modName) == .orderedAscending }
    }

    /// Check installed Nexus mods for newer files. `recentlyChanged`: Nexus mod ids changed lately (updated.json) —
    /// always checked; others are checked when never checked or older than `maxAge`, at most `budget` requests.
    public func findUpdates(recentlyChanged: Set<Int>, budget: Int = 120, maxAge: TimeInterval = 7 * 86400,
                            fetch: (Int) async throws -> (files: [NexusFileInfo], updates: [(old: Int, new: Int)])) async -> [ModUpdate] {
        var st = readJSON(updateStateURL, ModUpdateState.self) ?? ModUpdateState()
        let now = Date()
        let candidates = mods.filter { $0.nexus?.fileID != nil && !$0.isSeparator }
        let ordered = candidates.filter { recentlyChanged.contains($0.nexus!.modID) }
            + candidates.filter { !recentlyChanged.contains($0.nexus!.modID) && now.timeIntervalSince(st.checked[$0.id] ?? .distantPast) > maxAge }
        var spent = 0
        var byNexus: [Int: (files: [NexusFileInfo], updates: [(old: Int, new: Int)])] = [:]   // one request per Nexus mod
        for m in ordered {
            guard spent < budget || byNexus[m.nexus!.modID] != nil else { break }
            let nid = m.nexus!.modID
            if byNexus[nid] == nil {
                guard let r = try? await fetch(nid) else { continue }
                byNexus[nid] = r; spent += 1
            }
            let r = byNexus[nid]!
            st.checked[m.id] = now
            if let f = ModKit.latestFile(from: m.nexus!.fileID!, files: r.files, updates: r.updates) {
                st.available[m.id] = ModUpdate(modRecordID: m.id, modName: m.name, currentVersion: m.version, newVersion: f.version,
                                               nexusModID: nid, newFileID: f.fileID, newFileName: f.fileName, size: f.sizeBytes, md5: f.md5)
            } else { st.available[m.id] = nil }
        }
        try? writeJSON(st, to: updateStateURL)
        return cachedUpdates()
    }

    /// Replace a mod's files with a newer archive, keeping the mod entry (id → position, enabled, notes, group).
    /// Update without asking (command line, tests): saved installer choices, defaults for anything new.
    @discardableResult
    public func updateMod(_ id: String, archive: URL, nexusFileID: Int?, version: String, gameVersion: String) throws -> FomodInstaller? {
        let u = try prepareUpdate(id, archive: archive, gameVersion: gameVersion)
        defer { try? FileManager.default.removeItem(at: u.work) }
        if let f = u.fomod { f.applyAllDefaults(); f.makeRosettaSafe() }
        try finishUpdate(id, work: u.work, layout: u.layout, fomod: u.fomod, archive: archive, nexusFileID: nexusFileID, version: version)
        return nil
    }

    /// Unpack an update. A mod with an installer gets it back with the previous choices selected (the app shows it).
    public func prepareUpdate(_ id: String, archive: URL, gameVersion: String) throws -> (work: URL, layout: ModLayout, fomod: FomodInstaller?) {
        guard let m = mod(id) else { throw ModKitError.noSuchMod(id) }
        let (work, layout) = try beginInstall(archive: archive)
        guard case .fomod(_, let cfg) = layout else { return (work, layout, nil) }
        do {
            let inst = FomodInstaller(config: try FomodParser.load(cfg), context: fomodContext(gameVersion: gameVersion))
            if let saved = m.installChoices { inst.replay(saved) }
            if let s = inst.visibleSteps.first, inst.selections[s] == nil { inst.applyDefaults(step: s) }
            return (work, layout, inst)
        } catch { try? FileManager.default.removeItem(at: work); throw error }
    }

    /// Swap in the update's files (same entry: place, state, notes stay) and record version, file and choices.
    public func finishUpdate(_ id: String, work: URL, layout: ModLayout, fomod: FomodInstaller?, archive: URL, nexusFileID: Int?, version: String) throws {
        guard let i = mods.firstIndex(where: { $0.id == id }) else { throw ModKitError.noSuchMod(id) }
        try swapModFiles(id, work: work, layout: layout, fomod: fomod)
        var r = mods[i]
        r.version = version
        if let f = nexusFileID { r.nexus?.fileID = f }
        r.source = SourceArchive(path: archive.path, md5: nil)
        if let f = fomod { r.installChoices = f.choices }
        r.installedAt = Date()
        replaceMod(at: i, with: r)
        var st = readJSON(updateStateURL, ModUpdateState.self) ?? ModUpdateState()
        st.available[id] = nil; try? writeJSON(st, to: updateStateURL)
    }
}

extension ModKit {
    /// Prepare `layout` (with the installer's choices) and swap it in as the files of mod `id`; the old files come back
    /// if anything fails. The mod entry (position, enabled, notes) is untouched.
    public func swapModFiles(_ id: String, work: URL, layout: ModLayout, fomod: FomodInstaller?) throws {
        guard let m = mod(id) else { throw ModKitError.noSuchMod(id) }
        let out = work.appendingPathComponent("out")
        try Installer.prepare(layout, fomod: fomod, into: out)
        let staging = stagingFolder(m)
        let old = staging.deletingLastPathComponent().appendingPathComponent(".old-\(UUID().uuidString)")
        try FileManager.default.moveItem(at: staging, to: old)
        do { try FileManager.default.moveItem(at: out, to: staging) }
        catch { try? FileManager.default.moveItem(at: old, to: staging); throw error }
        try? FileManager.default.removeItem(at: old)
    }

    /// Reinstall with new installer choices (MO2 "Reinstall"): same entry, new files, choices saved.
    public func reinstallMod(_ id: String, work: URL, layout: ModLayout, fomod: FomodInstaller?) throws {
        defer { try? FileManager.default.removeItem(at: work) }
        try swapModFiles(id, work: work, layout: layout, fomod: fomod)
        if let f = fomod, let i = mods.firstIndex(where: { $0.id == id }) { var r = mods[i]; r.installChoices = f.choices; replaceMod(at: i, with: r) }
    }

    /// The archive a mod was installed from, if it is still around (its recorded path, else Downloads by Nexus file).
    public func sourceArchive(of id: String) -> URL? {
        guard let m = mod(id) else { return nil }
        if let p = m.source?.path, FileManager.default.fileExists(atPath: p) { return URL(fileURLWithPath: p) }
        if let n = m.nexus, let f = n.fileID {
            return NexusDownloader(client: NexusClient(apiKey: nil, appVersion: "local"), folder: downloadsDir).existingDownload(modID: n.modID, fileID: f, md5: m.source?.md5, size: nil)
        }
        return nil
    }
}
