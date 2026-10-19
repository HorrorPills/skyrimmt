// Mod list editing beyond install/remove (docs/MODMANAGER.md §3A): separators (groups), rename, notes, bulk removal,
// per-file conflicts and hiding individual files (MO2's ".mohidden" convention, so MO2 setups keep their hidden files).
import Foundation

public struct ModFileConflict: Identifiable, Equatable {
    public var id: String { rel }
    public let rel: String              // relative to the game folder
    public let winner: String           // mod id that provides the deployed file
    public let losers: [String]         // mod ids whose copy is overridden
}

extension ModKit {
    /// Add a separator to the current profile, before `beforeID` (or at the end).
    @discardableResult
    public func addSeparator(_ name: String, before beforeID: String? = nil) throws -> ModRecord {
        let id = UUID().uuidString
        let folder = "__separator__\(ModKit.sanitize(name))__\(id.prefix(8))"
        try FileManager.default.createDirectory(at: modsDir.appendingPathComponent(folder), withIntermediateDirectories: true)
        var r = ModRecord(id: id, name: name, folder: folder); r.separator = true
        appendMod(r)
        var p = try currentProfile()
        p.mods.removeAll { $0.id == id }
        let at = beforeID.flatMap { b in p.mods.firstIndex { $0.id == b } } ?? p.mods.firstIndex { ModKit.isOverwrite($0.id) } ?? p.mods.count
        p.mods.insert(ProfileMod(id: id, enabled: true), at: at)
        try saveProfile(p)
        return r
    }

    public func renameMod(_ id: String, to name: String) throws {
        guard let i = mods.firstIndex(where: { $0.id == id }) else { throw ModKitError.noSuchMod(id) }
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { return }
        var r = mods[i]; r.name = n; replaceMod(at: i, with: r)
    }

    public func setNotes(_ id: String, _ notes: String) throws {
        guard let i = mods.firstIndex(where: { $0.id == id }) else { throw ModKitError.noSuchMod(id) }
        var r = mods[i]; r.notes = notes; replaceMod(at: i, with: r)
    }

    public func setCategory(_ ids: [String], _ category: String?) {
        let set = Set(ids)
        editMods { all in for i in all.indices where set.contains(all[i].id) { all[i].category = category } }
    }

    /// The mods of a separator's group in profile `p`: everything after it up to the next separator.
    public func groupMembers(of separatorID: String, in p: Profile) -> [String] {
        guard let s = p.mods.firstIndex(where: { $0.id == separatorID }) else { return [] }
        var out: [String] = []
        for pm in p.mods[(s + 1)...] { if mod(pm.id)?.isSeparator == true { break }; out.append(pm.id) }
        return out
    }

    /// Move `ids` (a separator brings its whole group) so they sit before `beforeID` (nil = end, before Overwrite).
    public func moveMods(_ ids: [String], before beforeID: String?) throws {
        var p = try currentProfile()
        var moving: [String] = []
        for id in ids where !moving.contains(id) {
            moving.append(id)
            if mod(id)?.isSeparator == true { moving += groupMembers(of: id, in: p).filter { !moving.contains($0) } }
        }
        let set = Set(moving)
        // mods installed but not in this profile join it (off) where they are dropped
        let listed = Set(p.mods.map(\.id))
        let moved = (p.mods.filter { set.contains($0.id) } + moving.filter { !listed.contains($0) && mod($0) != nil }.map { ProfileMod(id: $0, enabled: false) })
            .sorted { a, b in (moving.firstIndex(of: a.id) ?? 0) < (moving.firstIndex(of: b.id) ?? 0) }
        p.mods.removeAll { set.contains($0.id) }
        var at = beforeID.flatMap { b in set.contains(b) ? nil : p.mods.firstIndex { $0.id == b } }
            ?? p.mods.firstIndex { ModKit.isOverwrite($0.id) } ?? p.mods.count
        if beforeID == nil, let ow = p.mods.firstIndex(where: { ModKit.isOverwrite($0.id) }) { at = ow }
        // keep the original order of the moved block (profile order), separators followed by their members
        let ordered = moving.compactMap { id in moved.first { $0.id == id } }
        p.mods.insert(contentsOf: ordered, at: min(at, p.mods.count))
        try saveProfile(p)
    }

    /// Remove several mods (their files leave SkyrimMT; deploy takes them out of the game).
    public func removeMods(_ ids: [String]) throws { for id in ids where mod(id) != nil { try removeMod(id) } }

    /// Files of a mod that win or lose against other enabled mods in the current profile.
    /// `plan`: pass the plan the caller already has (the Mod Manager keeps one per refresh) — rebuilding it costs
    /// seconds at 500k files.
    public func fileConflicts(of id: String, plan given: DeployPlan? = nil) throws -> (wins: [ModFileConflict], loses: [ModFileConflict]) {
        let plan = try given ?? plan()
        var wins: [ModFileConflict] = [], loses: [ModFileConflict] = []
        for (k, losers) in plan.overridden {
            guard let f = plan.files[k] else { continue }
            if f.modID == id { wins.append(ModFileConflict(rel: f.rel, winner: id, losers: losers)) }
            else if losers.contains(id) { loses.append(ModFileConflict(rel: f.rel, winner: f.modID, losers: losers)) }
        }
        return (wins.sorted { $0.rel < $1.rel }, loses.sorted { $0.rel < $1.rel })
    }

    /// All files of a mod (relative to its folder), hidden ones included (with `.mohidden`).
    public func modFiles(_ id: String) -> [String] {
        guard let m = mod(id) else { return [] }
        let root = stagingFolder(m)
        guard let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        var out: [String] = []
        for case let u as URL in en where (try? u.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
            out.append(String(u.path.dropFirst(root.path.count + 1)))
        }
        return out.sorted()
    }

    /// Hide (or show again) one file of a mod: MO2's convention, the file gets ".mohidden" appended.
    public func setFileHidden(_ id: String, _ rel: String, hidden: Bool) throws {
        guard let m = mod(id) else { throw ModKitError.noSuchMod(id) }
        let root = stagingFolder(m)
        let plain = rel.hasSuffix(".mohidden") ? String(rel.dropLast(9)) : rel
        let from = root.appendingPathComponent(hidden ? plain : plain + ".mohidden")
        let to = root.appendingPathComponent(hidden ? plain + ".mohidden" : plain)
        guard FileManager.default.fileExists(atPath: from.path) else { return }
        try? FileManager.default.removeItem(at: to)
        try FileManager.default.moveItem(at: from, to: to)
    }
}

/// The same Nexus file installed more than once (e.g. installed by hand and again by a list).
public struct DuplicateGroup: Identifiable, Equatable {
    public var id: String { "\(modID):\(fileID)" }
    public var modID: Int, fileID: Int
    public var name: String
    public var mods: [String]          // ModRecord ids
    public var unused: [String]        // of those, the copies no profile uses
}

extension ModKit {
    public func duplicateMods() -> [DuplicateGroup] {
        var groups: [String: [ModRecord]] = [:]
        for m in mods where !m.isSeparator { if let n = m.nexus, let f = n.fileID { groups["\(n.modID):\(f)", default: []].append(m) } }
        let used = Set(profileNames().compactMap { profile($0) }.flatMap { $0.mods.map(\.id) })
        return groups.values.filter { $0.count > 1 }.map { g in
            let unused = g.map(\.id).filter { !used.contains($0) }
            return DuplicateGroup(modID: g[0].nexus!.modID, fileID: g[0].nexus!.fileID!, name: g[0].name, mods: g.map(\.id),
                                  unused: unused.count == g.count ? Array(unused.dropFirst()) : unused)   // keep one if none is used
        }.sorted { $0.name < $1.name }
    }
}

extension ModKit {
    /// Two installed copies with byte-identical files (same paths, same content; .mohidden counts)?
    func identicalStaging(_ a: ModRecord, _ b: ModRecord) -> Bool {
        let ra = stagingFolder(a), rb = stagingFolder(b)
        let fa = modFiles(a.id).sorted(), fb = modFiles(b.id).sorted()
        guard fa == fb else { return false }
        let fm = FileManager.default
        for rel in fa {
            let x = ra.appendingPathComponent(rel).path, y = rb.appendingPathComponent(rel).path
            guard let sx = (try? fm.attributesOfItem(atPath: x))?[.size] as? Int64, let sy = (try? fm.attributesOfItem(atPath: y))?[.size] as? Int64, sx == sy else { return false }
            guard fm.contentsEqual(atPath: x, andPath: y) else { return false }
        }
        return true
    }

    /// Merge duplicate copies whose files are identical: every profile uses the kept copy (the first, priority and
    /// enabled state unchanged), the others are removed. Returns how many copies were removed.
    @discardableResult
    public func mergeIdenticalDuplicates() throws -> Int {
        var removed = 0
        for g in duplicateMods() {
            guard let keep = mod(g.mods[0]) else { continue }
            for id in g.mods.dropFirst() {
                guard let other = mod(id), identicalStaging(keep, other) else { continue }
                for name in profileNames() {
                    guard var p = profile(name), p.mods.contains(where: { $0.id == id }) else { continue }
                    if p.mods.contains(where: { $0.id == keep.id }) { p.mods.removeAll { $0.id == id } }
                    else { for i in p.mods.indices where p.mods[i].id == id { p.mods[i].id = keep.id } }
                    try saveProfile(p)
                }
                var cols = installedCollections()
                for i in cols.indices { cols[i].modIDs = cols[i].modIDs.map { $0 == id ? keep.id : $0 } }
                try saveCollections(cols)
                try removeMod(id); removed += 1
            }
        }
        return removed
    }
}

extension ModKit {
    /// Colour tag (red, orange, yellow, green, blue, purple; nil clears) for several mods, one write.
    public func setColor(_ ids: [String], _ color: String?) {
        let set = Set(ids)
        editMods { all in for i in all.indices where set.contains(all[i].id) { all[i].color = color } }
    }
}

extension ModKit {
    /// The profile as Markdown for asking for help (Reddit/Discord): game version, mods in order with versions and
    /// Nexus links (separators as headings), active plugins. No paths, no account details.
    public func modListMarkdown(gameVersion: String) -> String {
        guard let p = try? currentProfile() else { return "" }
        var out = "**SkyrimMT profile “\(p.name)”** — Skyrim \(gameVersion) on macOS (Wine/DXMT)\n\n"
        let enabled = p.mods.filter(\.enabled)
        out += "Mods (\(enabled.count) enabled, lowest priority first):\n"
        for pm in p.mods {
            guard let m = mod(pm.id) else { continue }
            if m.isSeparator { out += "\n**\(m.name)**\n"; continue }
            let link = m.nexus.map { " — https://www.nexusmods.com/skyrimspecialedition/mods/\($0.modID)" } ?? ""
            out += "- \(pm.enabled ? "" : "~~")\(m.name)\(m.version.isEmpty ? "" : " \(m.version)")\(pm.enabled ? "" : "~~ (disabled)")\(link)\n"
        }
        let lo = loadOrder()
        let active = lo.activeOrder
        out += "\nPlugins (\(active.count) active):\n"
        for (i, n) in active.enumerated() { out += "\(i). \(n)\n" }
        return out
    }
}

extension ModKit {
    /// An empty mod (MO2 "Create empty mod"): a folder for the player's own files, enabled, before Overwrite.
    @discardableResult
    public func createEmptyMod(name: String) throws -> ModRecord {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { throw ModKitError.invalid("the mod needs a name") }
        let tmp = home.appendingPathComponent("incoming/empty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return try addMod(name: n, from: tmp)
    }
}

