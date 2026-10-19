// Snapshots ("it worked yesterday" → one click): before risky changes SkyrimMT records the whole setup of a profile —
// its mod list and load order, the mod records, its game INIs, and APFS clones of the files of the mods the change
// touches (a removed or updated mod can come back exactly as it was; clones share blocks with the original until it
// changes). Restoring takes a snapshot of the present first, so a restore is undoable too. Saves are not part of a
// snapshot (they are progress; SaveBackup keeps those). The game folder isn't either: it is derived — deploy after.
//   <home>/snapshots/<id>/ snapshot.json · profile.json · mods.json · ini/<file> · mods/<staging folder>/
import Foundation

public struct Snapshot: Codable, Identifiable, Equatable {
    public var id: String                 // folder name: sortable time + short uuid
    public var date: Date
    public var reason: String
    public var profile: String
    public var savedMods: [String]        // mod ids whose files are kept (cloned)
    public var modCount: Int              // enabled mods in the profile at that time
}

public struct SnapshotRestore: Equatable {
    public var restoredFiles: [String] = []   // mod names whose files came back
    public var missing: [String] = []         // mods the profile needs that are gone and weren't saved
    public var undo: Snapshot?                 // the snapshot of the state before the restore
}

extension ModKit {
    public var snapshotsDir: URL { home.appendingPathComponent("snapshots") }
    public static let snapshotsKept = 30

    /// Record the current profile. `mods`: ids whose files the coming change may alter or remove (cloned).
    @discardableResult
    public func takeSnapshot(reason: String, mods ids: [String] = []) throws -> Snapshot {
        let fm = FileManager.default
        let p = try currentProfile()
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss.SSS"; f.locale = Locale(identifier: "en_US_POSIX")
        let id = f.string(from: Date()) + "-" + UUID().uuidString.prefix(6)
        let dir = snapshotsDir.appendingPathComponent(id)
        let tmp = snapshotsDir.appendingPathComponent(".tmp-" + id)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        do {
            try writeJSON(p, to: tmp.appendingPathComponent("profile.json"))
            try writeJSON(mods, to: tmp.appendingPathComponent("mods.json"))
            for n in ModKit.iniNames {
                let u = iniURL(profile: p.name, file: n)
                if fm.fileExists(atPath: u.path) {
                    try fm.createDirectory(at: tmp.appendingPathComponent("ini"), withIntermediateDirectories: true)
                    try cloneOrCopy(u, tmp.appendingPathComponent("ini/" + n))
                }
            }
            // the mods the change touches + this profile's Overwrite (generated files: cheap, often what changed)
            var saved: [String] = []
            for mid in Array(Set(ids + [currentOverwriteID()])).sorted() {
                guard let m = mod(mid), !m.isSeparator, fm.fileExists(atPath: stagingFolder(m).path) else { continue }
                try fm.createDirectory(at: tmp.appendingPathComponent("mods"), withIntermediateDirectories: true)
                try cloneOrCopy(stagingFolder(m), tmp.appendingPathComponent("mods/" + m.folder))
                saved.append(mid)
            }
            let s = Snapshot(id: id, date: Date(), reason: reason, profile: p.name, savedMods: saved, modCount: p.mods.filter(\.enabled).count)
            try writeJSON(s, to: tmp.appendingPathComponent("snapshot.json"))
            try fm.moveItem(at: tmp, to: dir)   // complete or not there at all
            pruneSnapshots()
            return s
        } catch { Installer.forceRemove(tmp); throw error }
    }

    /// Newest first.
    public func snapshots() -> [Snapshot] {
        ((try? FileManager.default.contentsOfDirectory(atPath: snapshotsDir.path)) ?? [])
            .filter { !$0.hasPrefix(".") }
            .compactMap { readJSON(snapshotsDir.appendingPathComponent("\($0)/snapshot.json"), Snapshot.self) }
            .sorted { $0.id > $1.id }   // ids start with the time in ms (dates are stored to the second)
    }

    public func deleteSnapshot(_ s: Snapshot) { Installer.forceRemove(snapshotsDir.appendingPathComponent(s.id)) }

    func pruneSnapshots() {
        for s in snapshots().dropFirst(ModKit.snapshotsKept) { deleteSnapshot(s) }
        for n in (try? FileManager.default.contentsOfDirectory(atPath: snapshotsDir.path)) ?? [] where n.hasPrefix(".tmp-") {
            Installer.forceRemove(snapshotsDir.appendingPathComponent(n))   // left by a crash mid-snapshot
        }
    }

    /// Put a snapshot back: the saved mods' files and records, the profile (mods, order, load order), its INIs. Mods
    /// installed later stay installed (just not in the restored list). The caller deploys if it is the active profile.
    @discardableResult
    public func restoreSnapshot(_ s: Snapshot) throws -> SnapshotRestore {
        let fm = FileManager.default
        let dir = snapshotsDir.appendingPathComponent(s.id)
        guard let savedProfile = readJSON(dir.appendingPathComponent("profile.json"), Profile.self),
              let savedRecords = readJSON(dir.appendingPathComponent("mods.json"), [ModRecord].self) else { throw ModKitError.invalid("snapshot \(s.id) is incomplete") }
        guard s.profile == currentProfileName else { throw ModKitError.invalid("switch to profile “\(s.profile)” to restore this snapshot") }
        var r = SnapshotRestore()
        // undo point: the present, with the files of every mod this restore replaces
        r.undo = try takeSnapshot(reason: "Before restoring “\(s.reason)”", mods: s.savedMods)
        let byID = Dictionary(savedRecords.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for id in s.savedMods {
            guard let rec = byID[id] else { continue }
            let src = dir.appendingPathComponent("mods/" + rec.folder)
            guard fm.fileExists(atPath: src.path) else { continue }
            let dst = modsDir.appendingPathComponent(rec.folder)
            let tmp = modsDir.appendingPathComponent(".restore-\(UUID().uuidString)")
            try cloneOrCopy(src, tmp)                       // the snapshot stays usable
            let old = modsDir.appendingPathComponent(".old-\(UUID().uuidString)")
            if let cur = mod(id), fm.fileExists(atPath: stagingFolder(cur).path) { try fm.moveItem(at: stagingFolder(cur), to: old) }
            if fm.fileExists(atPath: dst.path) { try fm.moveItem(at: dst, to: modsDir.appendingPathComponent(".old-\(UUID().uuidString)-2")) }
            try fm.moveItem(at: tmp, to: dst)
            editMods { list in if let i = list.firstIndex(where: { $0.id == id }) { list[i] = rec } else { list.append(rec) } }
            r.restoredFiles.append(rec.name)
        }
        for n in (try? fm.contentsOfDirectory(atPath: modsDir.path)) ?? [] where n.hasPrefix(".old-") { Installer.forceRemove(modsDir.appendingPathComponent(n)) }
        // records of mods the snapshot lists that still exist but whose files weren't saved: keep the present files
        r.missing = savedProfile.mods.compactMap { pm in mod(pm.id) == nil ? (byID[pm.id]?.name ?? pm.id) : nil }
        var p = savedProfile
        p.mods.removeAll { mod($0.id) == nil }                   // can't list what isn't installed
        try saveProfile(p)
        for n in ModKit.iniNames {
            let u = dir.appendingPathComponent("ini/" + n)
            guard fm.fileExists(atPath: u.path) else { continue }
            let dst = iniURL(profile: p.name, file: n)
            try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.removeItem(at: dst)
            try cloneOrCopy(u, dst)
        }
        return r
    }
}
