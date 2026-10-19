// Instant profile switching (docs/MODMANAGER.md §6). Each profile keeps its own complete Data folder ("slot"): when
// you leave a profile its Data folder is renamed into slots/<version>/<profile>/Data together with its part of the
// deploy manifest; the next profile's parked folder is renamed back into the game. Renames are O(1), so switching
// between two 2,000-mod setups takes as long as a no-change deploy instead of removing and placing every file.
// Disk: parked files are APFS clones of the mods' staging files and the game's own files — shared blocks, only
// metadata is extra.
//
// Every slot is self-contained: its Data folder + the manifest part + the backups that manifest names (vanilla files
// its mods replaced). A profile without a slot gets a fresh vanilla Data built (clones) from the parked one, then a
// normal deploy. Steam updates only reach the live Data: a parked slot made with another SkyrimSE.exe is discarded.
//
// Crash safety: slot-journal.tsv ("from\tto") is written first; finishSwap() looks at what exists on disk and
// completes the remaining steps, so it is idempotent and runs again after a crash at any point.
import Foundation
import Darwin

struct SlotMeta: Codable { var profile: String; var gameFingerprint: String; var parkedAt: Date }
struct SlotSettings: Codable { var enabled = false }

extension Manifest {
    /// Entries/backups/created folders inside Data (they travel with a slot) and the rest (game root: SKSE etc.).
    func splitData() -> (data: Manifest, rest: Manifest) {
        var d = Manifest(), r = Manifest()
        for (k, e) in entries { if k.hasPrefix("data/") { d.entries[k] = e } else { r.entries[k] = e } }
        for (k, b) in backups { if k.hasPrefix("data/") { d.backups[k] = b } else { r.backups[k] = b } }
        for c in createdDirs { if c.lowercased().hasPrefix("data/") { d.createdDirs.insert(c) } else { r.createdDirs.insert(c) } }
        return (d, r)
    }
    func merged(with o: Manifest) -> Manifest {
        var m = self
        m.entries.merge(o.entries) { $1 }; m.backups.merge(o.backups) { $1 }; m.createdDirs.formUnion(o.createdDirs)
        return m
    }
}

extension ModKit {
    var slotSettingsURL: URL { stateDir.appendingPathComponent("slots.json") }
    /// Parked Data folders live next to the game (same volume: renames, clones) and per game folder.
    public var slotsRoot: URL { home.appendingPathComponent("slots/\(gameVersionKey)") }
    var slotJournalURL: URL { deployer.layout.stateDir.appendingPathComponent("slot-journal.tsv") }
    var liveData: URL { gameDir.appendingPathComponent("Data") }
    /// Whose Data folder is in the game right now (normally the current profile; differs only after a crash between
    /// the swap and the end of switchProfile). Slots are named after the owner of their content.
    var liveOwnerURL: URL { deployer.layout.stateDir.appendingPathComponent("slot-live") }
    var liveOwner: String {
        ((try? String(contentsOf: liveOwnerURL, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 } ?? currentProfileName
    }
    func slotDir(_ profile: String) -> URL { slotsRoot.appendingPathComponent(profile) }

    public var instantSwitching: Bool { (readJSON(slotSettingsURL, SlotSettings.self) ?? SlotSettings()).enabled }

    /// Turning it off discards every parked slot (their Data folders and the backups they own).
    public func setInstantSwitching(_ on: Bool) throws {
        try writeJSON(SlotSettings(enabled: on), to: slotSettingsURL)
        if !on { try discardAllSlots(); try? FileManager.default.removeItem(at: liveOwnerURL) }
    }

    /// Profiles with a parked Data folder.
    public func parkedProfiles() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: slotsRoot.path)) ?? [])
            .filter { !$0.hasPrefix(".") && FileManager.default.fileExists(atPath: slotDir($0).appendingPathComponent("Data").path) }.sorted()
    }

    /// The game build a slot was made for: SkyrimSE.exe's size + mtime (its vanilla copy if a mod replaced it).
    func gameFingerprint() -> String {
        let m = try? Manifest.load(deployer.layout.manifestURL)
        let exe = m?.backups["skyrimse.exe"].map { deployer.layout.backupDir.appendingPathComponent($0) } ?? gameDir.appendingPathComponent("SkyrimSE.exe")
        guard let st = lstatPath(exe.path) else { return "none" }
        return "\(st.size)-\(st.mtimeNs / 1_000_000_000)"
    }

    func slotUsable(_ profile: String) -> Bool {
        let d = slotDir(profile)
        guard FileManager.default.fileExists(atPath: d.appendingPathComponent("Data").path),
              FileManager.default.fileExists(atPath: d.appendingPathComponent("manifest.tsv").path),
              let meta = readJSON(d.appendingPathComponent("slot.json"), SlotMeta.self) else { return false }
        return meta.gameFingerprint == gameFingerprint()
    }

    /// Remove a parked slot: its Data folder (clones only) and the vanilla backups its manifest owns.
    public func discardSlot(_ profile: String) throws {
        let d = slotDir(profile)
        guard FileManager.default.fileExists(atPath: d.path) else { return }
        // only a complete slot owns its backups (mid-park, the manifest copy still names the live game's backups)
        if fsExists(d.appendingPathComponent("Data").path), let m = try? Manifest.load(d.appendingPathComponent("manifest.tsv")) {
            for b in m.backups.values { try? FileManager.default.removeItem(at: deployer.layout.backupDir.appendingPathComponent(b)) }
        }
        Installer.forceRemove(d)
    }

    public func discardAllSlots() throws {
        for n in (try? FileManager.default.contentsOfDirectory(atPath: slotsRoot.path)) ?? [] where !n.hasPrefix(".") { try discardSlot(n) }
        Installer.forceRemove(slotsRoot.appendingPathComponent(".building"))
    }

    /// A profile was renamed: its parked slot follows.
    func renameSlot(_ old: String, to new: String) throws {
        let a = slotDir(old), b = slotDir(new)
        if liveOwner == old { try atomicWrite(new + "\n", to: liveOwnerURL) }
        guard FileManager.default.fileExists(atPath: a.path) else { return }
        try? discardSlot(new)
        try FileManager.default.moveItem(at: a, to: b)
    }

    /// Finish a swap a crash interrupted (called before every deploy/switch).
    public func recoverSlotSwapIfNeeded() throws {
        guard let j = try? String(contentsOf: slotJournalURL, encoding: .utf8) else { return }
        let f = j.trimmingCharacters(in: .newlines).split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard f.count == 2 else { try? FileManager.default.removeItem(at: slotJournalURL); return }
        _ = try finishSwap(from: f[0], to: f[1])
    }

    /// Park the live Data folder as `from`'s slot and put `to`'s in place (parked, or a fresh vanilla one). Returns
    /// true when `to` came from its parked slot. The caller deploys `to` afterwards (a no-change deploy when parked).
    @discardableResult
    func swapSlots(to: String) throws -> Bool {
        try deployer.recoverIfNeeded()
        try recoverSlotSwapIfNeeded()
        let from = liveOwner
        guard from != to else { return false }
        try deployer.ensureBaseline()   // vanilla list, taken while the live Data is complete
        try FileManager.default.createDirectory(at: slotsRoot, withIntermediateDirectories: true)
        // a leftover slot of the live profile (e.g. switched before a crash) is out of date: the live Data is newer
        if FileManager.default.fileExists(atPath: slotDir(from).path) { try discardSlot(from) }
        try atomicWrite("\(from)\t\(to)\n", to: slotJournalURL)
        try slotStep(1)
        return try finishSwap(from: from, to: to)
    }

    private func finishSwap(from a: String, to b: String) throws -> Bool {
        let fm = FileManager.default
        let mURL = deployer.layout.manifestURL
        let aDir = slotDir(a), bDir = slotDir(b)
        let aData = aDir.appendingPathComponent("Data"), bData = bDir.appendingPathComponent("Data")
        var fromSlot = false
        // 1. park the live Data as a's slot (manifest part first: a crash leaves both copies consistent)
        if fsExists(liveData.path) && !fsExists(aData.path) {
            let (d, _) = try Manifest.load(mURL).splitData()
            try fm.createDirectory(at: aDir, withIntermediateDirectories: true)
            try d.save(aDir.appendingPathComponent("manifest.tsv"))
            try writeJSON(SlotMeta(profile: a, gameFingerprint: gameFingerprint(), parkedAt: Date()), to: aDir.appendingPathComponent("slot.json"))
            try slotStep(2)
            guard rename(liveData.path, aData.path) == 0 else { throw DeployError.io("park Data: \(String(cString: strerror(errno)))") }
            try slotStep(3)
        }
        // 2. live manifest = game-root part only; then b's Data into the game
        if !fsExists(liveData.path) {
            let (_, rest) = try Manifest.load(mURL).splitData()
            try rest.save(mURL)
            try slotStep(4)
            if slotUsable(b) {
                guard rename(bData.path, liveData.path) == 0 else { throw DeployError.io("unpark Data: \(String(cString: strerror(errno)))") }
                fromSlot = true
            } else {
                try discardSlot(b)   // stale (other game build) or incomplete
                let building = slotsRoot.appendingPathComponent(".building")
                Installer.forceRemove(building)
                try buildVanillaData(from: aDir, into: building)
                try slotStep(5)
                guard rename(building.path, liveData.path) == 0 else { throw DeployError.io("place Data: \(String(cString: strerror(errno)))") }
            }
            try slotStep(6)
        }
        // 3. b's manifest part joins the live manifest (idempotent: replaces the Data part), then its slot folder goes
        let bManifest = bDir.appendingPathComponent("manifest.tsv")
        if fsExists(bManifest.path) && !fsExists(bData.path) {
            let (_, rest) = try Manifest.load(mURL).splitData()
            try rest.merged(with: try Manifest.load(bManifest)).save(mURL)
            try slotStep(7)
            Installer.forceRemove(bDir)
            fromSlot = true
        }
        try atomicWrite(b + "\n", to: liveOwnerURL)
        try? fm.removeItem(at: slotJournalURL)
        return fromSlot
    }

    /// The game's own Data files (baseline), taken from a parked slot: the slot's file where no mod replaced it, else
    /// the vanilla original from the backup that slot owns; plus files the player put in Data themselves. APFS clones.
    private func buildVanillaData(from slot: URL, into dst: URL) throws {
        let fm = FileManager.default
        let m = try Manifest.load(slot.appendingPathComponent("manifest.tsv"))
        let parked = slot.appendingPathComponent("Data")
        try fm.createDirectory(at: dst, withIntermediateDirectories: true)
        let baseline = ((try? String(contentsOf: deployer.layout.baselineURL, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        var vanillaKeys = Set<String>()
        func put(_ src: URL, _ relInData: String) throws {
            let d = dst.appendingPathComponent(relInData)
            try fm.createDirectory(at: d.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.removeItem(at: d)
            try cloneOrCopy(src, d)
        }
        for rel in baseline where rel.lowercased().hasPrefix("data/") {
            let k = rel.lowercased(), inData = String(rel.dropFirst(5))
            vanillaKeys.insert(k)
            if let b = m.backups[k] {
                let u = deployer.layout.backupDir.appendingPathComponent(b)
                if fsExists(u.path) { try put(u, inData) }
            } else if m.entries[k] == nil, fsExists(parked.appendingPathComponent(inData).path) {
                try put(parked.appendingPathComponent(inData), inData)
            }
        }
        // the player's own files (not deployed, not vanilla) stay visible in every profile
        if let en = fm.enumerator(atPath: parked.path) {
            while let r = en.nextObject() as? String {
                let k = "data/" + r.lowercased()
                guard m.entries[k] == nil, !vanillaKeys.contains(k), let st = lstatPath(parked.path + "/" + r), !st.isDir else { continue }
                try put(parked.appendingPathComponent(r), r)
            }
        }
    }

    private func slotStep(_ n: Int) throws { if let f = slotFailAt, n >= f { throw DeployError.simulatedCrash } }
}
