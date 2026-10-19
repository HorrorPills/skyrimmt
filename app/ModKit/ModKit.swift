// ModKit data model + facade (PLAN §8.3, §8.8 profiles). Everything is JSON under $SKYRIM_HOME/config/modkit with
// atomic writes and a version field; staging folders live in $SKYRIM_HOME/mods/<sanitized name>__<short id>/.
// Only the Deployer writes into the game folder; ModKit decides *what* is deployed (profile order + enabled mods).
import Foundation
import Darwin

public struct NexusRef: Codable, Equatable {
    public var modID: Int
    public var fileID: Int?
    public init(modID: Int, fileID: Int? = nil) { self.modID = modID; self.fileID = fileID }
}

public struct SourceArchive: Codable, Equatable {
    public var path: String
    public var sha256: String?
    public var md5: String?
}

public struct ModRecord: Codable, Equatable, Identifiable {
    public var id: String                 // UUID string
    public var name: String
    public var version: String = ""
    public var folder: String             // staging folder name (inside $SKYRIM_HOME/mods)
    public var installedAt: Date = Date()
    public var nexus: NexusRef?
    public var category: String?
    public var source: SourceArchive?
    public var installChoices: [String: [String]]?   // FOMOD: step/group → selected options (replayed on reinstall)
    public var notes: String = ""
    public var separator: Bool? = nil     // a group header in the mod list (MO2 separator); no files
    public var color: String? = nil       // optional tag colour (separators)
    public var isSeparator: Bool { separator == true }
}

public struct ProfileMod: Codable, Equatable {
    public var id: String
    public var enabled: Bool
}

/// A profile = which mods are enabled and in which priority (array order: later wins), plus its load order.
public struct Profile: Codable, Equatable {
    public var name: String
    public var mods: [ProfileMod] = []
    public var loadOrder: [LoadOrderEntry] = []
    public var separateSaves = false
    public var gameVersion: String?      // nil/"steam" = Steam's install; else a pinned version (versions/<v>)
    public var lockedPlugins: [String]?  // plugins whose position sorting never changes (lowercased)
}

struct StoreFile<T: Codable>: Codable { var version: Int; var items: T }

func readJSON<T: Codable>(_ url: URL, _ type: T.Type) -> T? {
    guard let d = try? Data(contentsOf: url) else { return nil }
    let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
    return (try? dec.decode(StoreFile<T>.self, from: d))?.items
}

func writeJSON<T: Codable>(_ value: T, to url: URL) throws {
    let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]; enc.dateEncodingStrategy = .iso8601
    let data = try enc.encode(StoreFile(version: 1, items: value))
    try atomicWrite(String(decoding: data, as: UTF8.self), to: url)
}

public enum ModKitError: Error, CustomStringConvertible {
    case noSuchMod(String), noSuchProfile(String), invalid(String)
    public var description: String {
        switch self { case .noSuchMod(let m): return "no mod \(m)"; case .noSuchProfile(let p): return "no profile \(p)"; case .invalid(let m): return m }
    }
}

/// `mkdir`-based lock shared with the shell scripts (scripts/play.sh waits for run/deploy.lock).
public final class DeployLock {
    let path: String
    public init(runDir: URL) { path = runDir.appendingPathComponent("deploy.lock").path }
    public func acquire(timeout: TimeInterval = 30) throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let end = Date().addingTimeInterval(timeout)
        while mkdir(path, 0o755) != 0 {
            if let p = try? String(contentsOfFile: path + "/pid", encoding: .utf8), let pid = Int32(p.trimmingCharacters(in: .whitespacesAndNewlines)),
               kill(pid, 0) != 0 { try? FileManager.default.removeItem(atPath: path); continue }   // stale
            if Date() > end { throw DeployError.locked("another deploy is running") }
            usleep(200_000)
        }
        try? "\(getpid())".write(toFile: path + "/pid", atomically: true, encoding: .utf8)
    }
    public func release() { try? FileManager.default.removeItem(atPath: path) }
}

public final class ModKit {
    public let home: URL          // SKYRIM_HOME
    public let gameDir: URL
    public let pluginsTxt: URL
    public let deployer: Deployer
    var stateDir: URL { home.appendingPathComponent("config/modkit") }
    public var modsDir: URL { home.appendingPathComponent("mods") }
    var modsURL: URL { stateDir.appendingPathComponent("mods.json") }
    var profilesDir: URL { home.appendingPathComponent("profiles") }
    var currentURL: URL { stateDir.appendingPathComponent("current-profile") }

    public private(set) var mods: [ModRecord] = []
    /// Test hook: throw DeployError.simulatedCrash at this step of a slot swap (Slots.swift).
    public var slotFailAt: Int?

    /// The selected game version ("steam" = Steam's own install) — scripts/versions.sh select.
    public let gameVersionKey: String

    public init(home: URL, gameDir: URL, pluginsTxt: URL, versionKey: String = "steam") {
        self.home = home; self.gameDir = gameDir; self.pluginsTxt = pluginsTxt; self.gameVersionKey = versionKey
        // every game folder has its own deploy state (manifest, vanilla baseline, backups); Steam's keeps the old paths
        let state = versionKey == "steam" ? home.appendingPathComponent("config/modkit") : home.appendingPathComponent("config/modkit/versions/\(versionKey)")
        let backups = versionKey == "steam" ? home.appendingPathComponent("backups/modkit") : home.appendingPathComponent("backups/modkit-\(versionKey)")
        deployer = Deployer(layout: GameLayout(gameDir: gameDir, stateDir: state, backupDir: backups))
        mods = readJSON(modsURL, [ModRecord].self) ?? []
    }

    public static func steamGameDir(_ home: URL) -> URL {
        home.appendingPathComponent("prefix/drive_c/Program Files (x86)/Steam/steamapps/common/Skyrim Special Edition")
    }

    /// Standard SkyrimMT layout for a SKYRIM_HOME, honouring the version switcher's selection.
    public static func standard(home: URL, user: String = NSUserName()) -> ModKit {
        let ptxt = home.appendingPathComponent("prefix/drive_c/users/\(user)/AppData/Local/Skyrim Special Edition/plugins.txt")
        let v = ((try? String(contentsOf: home.appendingPathComponent("config/game-version"), encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let vdir = home.appendingPathComponent("versions/\(v)")
        if !v.isEmpty, FileManager.default.fileExists(atPath: vdir.appendingPathComponent(".skyrimmt-version").path) {
            return ModKit(home: home, gameDir: vdir, pluginsTxt: ptxt, versionKey: v)
        }
        return ModKit(home: home, gameDir: steamGameDir(home), pluginsTxt: ptxt)
    }

    func saveMods() throws { try writeJSON(mods, to: modsURL) }

    // MARK: mods

    public static func sanitize(_ name: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters)
        let s = name.components(separatedBy: bad).joined(separator: "_").trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        return s.isEmpty ? "mod" : String(s.prefix(80))
    }

    /// Adopt an already-prepared folder (installer output, laid out like Data/) as a new mod: it is moved into staging.
    @discardableResult
    public func addMod(name: String, from folder: URL, version: String = "", nexus: NexusRef? = nil) throws -> ModRecord {
        let id = UUID().uuidString
        let dirName = "\(ModKit.sanitize(name))__\(id.prefix(8))"
        let dst = modsDir.appendingPathComponent(dirName)
        try FileManager.default.createDirectory(at: modsDir, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: folder, to: dst)
        let rec = ModRecord(id: id, name: name, version: version, folder: dirName, nexus: nexus)
        mods.append(rec); try saveMods()
        var p = try currentProfile()   // (a brand-new profile already lists every mod)
        if !p.mods.contains(where: { $0.id == id }) { p.mods.append(ProfileMod(id: id, enabled: true)) }
        if let ow = p.mods.firstIndex(where: { ModKit.isOverwrite($0.id) }) { p.mods.append(p.mods.remove(at: ow)) }   // Overwrite stays last
        try saveProfile(p)
        return rec
    }

    public func removeMod(_ id: String) throws {
        guard let i = mods.firstIndex(where: { $0.id == id }) else { throw ModKitError.noSuchMod(id) }
        let folder = modsDir.appendingPathComponent(mods[i].folder)
        for name in profileNames() {
            if var p = profile(name) { p.mods.removeAll { $0.id == id }; try saveProfile(p) }
        }
        mods.remove(at: i); try saveMods()
        Installer.forceRemove(folder)   // deployed clones stay valid until the next deploy removes them
    }

    public func mod(_ id: String) -> ModRecord? { mods.first { $0.id == id } }
    func replaceMod(at i: Int, with r: ModRecord) { mods[i] = r; try? saveMods() }
    /// Several record edits, one write.
    func editMods(_ body: (inout [ModRecord]) -> Void) { body(&mods); try? saveMods() }
    func appendMod(_ r: ModRecord) { mods.append(r); try? saveMods() }
    public func stagingFolder(_ m: ModRecord) -> URL { modsDir.appendingPathComponent(m.folder) }

    // MARK: profiles

    public func profileNames() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: profilesDir.path)) ?? [])
            .filter { fsExists(profilesDir.appendingPathComponent("\($0)/profile.json").path) }.sorted()
    }
    public func profile(_ name: String) -> Profile? { readJSON(profilesDir.appendingPathComponent("\(name)/profile.json"), Profile.self) }
    public func saveProfile(_ p: Profile) throws {
        guard !p.name.isEmpty, p.name == ModKit.sanitize(p.name) else { throw ModKitError.invalid("bad profile name \(p.name)") }
        let url = profilesDir.appendingPathComponent("\(p.name)/profile.json")
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]; enc.dateEncodingStrategy = .iso8601
        snapshotBeforeSave(url, newData: try enc.encode(StoreFile(version: 1, items: p)))   // history (ProfileHistory.swift)
        try writeJSON(p, to: url)
    }
    public var currentProfileName: String {
        ((try? String(contentsOf: currentURL, encoding: .utf8)) ?? "Default").trimmingCharacters(in: .whitespacesAndNewlines)
    }
    public func currentProfile() throws -> Profile {
        if let p = profile(currentProfileName) { return p }
        let p = Profile(name: currentProfileName, mods: mods.map { ProfileMod(id: $0.id, enabled: true) },
                        loadOrder: PluginsTxt.read(pluginsTxt))
        try saveProfile(p)
        return p
    }
    public func createProfile(_ name: String, cloneFrom: String? = nil) throws {
        guard profile(name) == nil else { throw ModKitError.invalid("profile \(name) exists") }
        var p = cloneFrom.flatMap { profile($0) } ?? Profile(name: name, mods: mods.map { ProfileMod(id: $0.id, enabled: false) })
        p.name = name
        try saveProfile(p)
    }
    /// Mods that only profile `name` uses (no other profile lists them; generated outputs not counted).
    public func modsOnlyIn(_ name: String) -> [ModRecord] {
        guard let p = profile(name) else { return [] }
        let others = Set(profileNames().filter { $0 != name }.compactMap { profile($0) }.flatMap { $0.mods.map(\.id) })
        return p.mods.compactMap { mod($0.id) }.filter {
            !others.contains($0.id) && !ModKit.isOverwrite($0.id) && !ModKit.isPandoraOutput($0.id) && !ModKit.isBodySlideOutput($0.id)
        }
    }

    /// Delete a profile that is not active: its folder, its generated outputs (Pandora/BodySlide) and their state, its
    /// collection entry; with `removeUnusedMods` also the mods no other profile uses. Saves are never touched.
    public func deleteProfile(_ name: String, removeUnusedMods: Bool) throws {
        guard profile(name) != nil else { throw ModKitError.noSuchProfile(name) }
        guard name != currentProfileName else { throw ModKitError.invalid("switch to another profile before deleting “\(name)”") }
        let unused = removeUnusedMods ? modsOnlyIn(name) : []
        for id in [ModKit.pandoraOutputID(name), ModKit.bodySlideOutputID(name), ModKit.overwriteID(for: name)] where mod(id) != nil { try removeMod(id) }
        if var st = readJSON(pandoraStateURL, PandoraState.self) { st.fingerprints[name] = nil; try writeJSON(st, to: pandoraStateURL) }
        if var st = readJSON(bodySlideStateURL, BodySlideState.self) { st.fingerprints[name] = nil; st.settings[name] = nil; try writeJSON(st, to: bodySlideStateURL) }
        try FileManager.default.removeItem(at: profilesDir.appendingPathComponent(name))
        try discardSlot(name)
        var cols = installedCollections()
        if cols.contains(where: { $0.profile == name }) { cols.removeAll { $0.profile == name }; try saveCollections(cols) }
        for m in unused { try removeMod(m.id) }   // after the profile is gone, so removeMod only edits the others
    }

    /// Switch profile: the current load order is saved into the old profile, the new one's is written to plugins.txt,
    /// and its mods are deployed.
    public func switchProfile(to name: String) throws -> DeployReport {
        guard var next = profile(name) else { throw ModKitError.noSuchProfile(name) }
        try captureGenerated()        // files the old profile's mods wrote stay with that profile (Overwrite)
        // plugins.txt only reflects the profile while its mods are deployed — after "Remove all mods" (purge) it lists
        // just what is left, and saving that would wipe the profile's real load order (owner report 2026-10-18)
        if try deployer.deployedCount() > 0 {
            var cur = try currentProfile()
            cur.loadOrder = PluginsTxt.read(pluginsTxt); try saveProfile(cur)
        }
        let leaving = currentProfileName
        if instantSwitching {   // park this profile's Data, bring back the next one's (Slots.swift)
            let lock = DeployLock(runDir: home.appendingPathComponent("run"))
            try lock.acquire(); defer { lock.release() }
            try swapSlots(to: name)
        }
        try atomicWrite(name + "\n", to: currentURL)
        try swapINIs(from: leaving, to: name)   // profiles with their own INIs (MO2 / Wabbajack imports)
        try applySavePath(name)                 // separate saves per profile
        let report = try deploy(next)
        if next.loadOrder.isEmpty { next.loadOrder = PluginsTxt.read(pluginsTxt); try saveProfile(next) }
        try syncLoadOrder(next.loadOrder)
        return report
    }

    // MARK: deploy

    public func stagedMods(_ p: Profile) -> [StagedMod] {
        p.mods.filter(\.enabled).compactMap { pm in mod(pm.id).map { StagedMod(id: $0.id, folder: stagingFolder($0)) } }
            + ModKit.builtinMods()
    }

    /// SkyrimMT's own fixes for Wine/macOS (e.g. the Mac Fixes SKSE plugin): folders laid out like Data/ inside
    /// <app>/Contents/Resources/builtin (or $SKYRIMMT_BUILTIN), deployed with every profile, last (own file names).
    public static func builtinMods() -> [StagedMod] {
        let env = ProcessInfo.processInfo.environment["SKYRIMMT_BUILTIN"].map { URL(fileURLWithPath: $0) }
        // the app's own; tools outside the app (CLI) use the installed app's, or a deploy would remove the built-ins
        let installed = URL(fileURLWithPath: "/Applications/SkyrimMT.app/Contents/Resources/builtin")
        let own = Bundle.main.resourceURL?.appendingPathComponent("builtin")
        guard let root = env ?? [own, installed].compactMap({ $0 }).first(where: { FileManager.default.fileExists(atPath: $0.path) }),
              let names = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return [] }
        return names.filter { !$0.hasPrefix(".") }.sorted().map { StagedMod(id: "builtin:\($0)", folder: root.appendingPathComponent($0)) }
    }

    public func plan(_ p: Profile? = nil) throws -> DeployPlan { deployer.plan(stagedMods(try p ?? currentProfile())) }

    @discardableResult
    public func deploy(_ p: Profile? = nil) throws -> DeployReport {
        let profile = try p ?? currentProfile()
        let lock = DeployLock(runDir: home.appendingPathComponent("run"))
        try lock.acquire(); defer { lock.release() }
        try recoverSlotSwapIfNeeded()
        let report = try deployer.deploy(stagedMods(profile))
        let isCollection = installedCollections().contains { $0.profile == profile.name } && !profile.loadOrder.isEmpty
        try syncLoadOrder(profile.loadOrder, newActive: !isCollection)
        return report
    }

    @discardableResult
    public func purge() throws -> DeployReport {
        try captureGenerated()        // mod-written files leave the game folder too (kept in Overwrite)
        let lock = DeployLock(runDir: home.appendingPathComponent("run"))
        try lock.acquire(); defer { lock.release() }
        return try deployer.purge()
    }

    /// Load order after a deploy: the profile's order for plugins that exist, new plugins appended (inactive),
    /// removed ones dropped; written to plugins.txt.
    /// `newActive`: plugins SkyrimMT has never seen start active (normal profiles). In a collection's profile the author's
    /// load order is authoritative, so plugins it doesn't list stay inactive (e.g. Bijin NPCs.esp next to Bijin AIO).
    func syncLoadOrder(_ wanted: [LoadOrderEntry], newActive: Bool = true) throws {
        let known = Set((PluginsTxt.read(pluginsTxt) + wanted).map { $0.name.lowercased() })
        var lo = LoadOrder.load(dataDir: gameDir.appendingPathComponent("Data"), gameDir: gameDir, pluginsTxt: pluginsTxt)
        if !wanted.isEmpty {
            let present = Dictionary(lo.entries.map { ($0.name.lowercased(), $0) }, uniquingKeysWith: { a, _ in a })
            var out: [LoadOrderEntry] = [], used = Set<String>()
            for w in wanted { if let e = present[w.name.lowercased()], used.insert(w.name.lowercased()).inserted { out.append(LoadOrderEntry(name: e.name, active: w.active)) } }
            for e in lo.entries where !used.contains(e.name.lowercased()) { out.append(e) }
            lo.entries = out
        }
        // plugins SkyrimMT has never seen (a newly installed mod) start active, like other mod managers; plugins the
        // player turned off stay off
        let listed = Set(wanted.map { $0.name.lowercased() })
        for i in lo.entries.indices where !listed.contains(lo.entries[i].name.lowercased()) {
            if !newActive { lo.entries[i].active = false }
            else if !known.contains(lo.entries[i].name.lowercased()) { lo.entries[i].active = true }
        }
        try lo.write(to: pluginsTxt)
    }

    public func loadOrder() -> LoadOrder {
        LoadOrder.load(dataDir: gameDir.appendingPathComponent("Data"), gameDir: gameDir, pluginsTxt: pluginsTxt)
    }

    /// Is the deployed state what the current profile wants? (cheap: plan vs manifest keys/sources)
    public func isDirty(plan given: DeployPlan? = nil) throws -> Bool {
        let want = try (given ?? plan()).files
        let m = try Manifest.load(deployer.layout.manifestURL)
        if want.count != m.entries.count { return true }
        for (k, p) in want where m.entries[k]?.source != p.source { return true }
        return !deployer.staleKeys(m, want).isEmpty
    }
}

func fsExists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: path) }

extension ModKit {
    /// Deployed program files (.dll/.exe/.bsa) must equal their mod's copy. Under Wine some SKSE plugins come back with
    /// runtime data written into the file (2026-10-19: ScrambledBugs.dll / VendorRespawnFix.dll /
    /// ScriptEffectArchetypeCrashFix.dll, one .data byte 0 → 2 after a launch) — carried into the next start that state
    /// can change how the plugin behaves. Play calls this first; the mods' own copies are never affected (APFS clones).
    @discardableResult
    public func restoreDriftedBinaries() -> [String] {
        // only program files are checked (a few thousand stats instead of every deployed file: Play stays instant)
        let isBin = { (k: String) in ["dll", "exe", "bsa"].contains((k as NSString).pathExtension.lowercased()) }
        guard let v = try? deployer.verify(only: isBin) else { return [] }
        let bins = v.changed.filter(isBin)
        guard !bins.isEmpty, let done = try? deployer.restore(bins, keepBackup: false) else { return [] }
        let log = home.appendingPathComponent("logs/drift.log")
        let line = ISO8601DateFormatter().string(from: Date()) + "\trestored\t" + done.joined(separator: ", ") + "\n"
        if let h = try? FileHandle(forWritingTo: log) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close() }
        else { try? FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true); try? line.write(to: log, atomically: true, encoding: .utf8) }
        return done
    }
}

extension ModKit {
    /// The game version the deployed SKSE is built for ("skse64_1_7_104.dll" → "1.7.104"); nil without SKSE.
    public func deployedSKSEVersion() -> String? {
        for f in (try? FileManager.default.contentsOfDirectory(atPath: gameDir.path)) ?? [] {
            let l = f.lowercased()
            guard l.hasPrefix("skse64_1_"), l.hasSuffix(".dll"), !l.contains("loader") else { continue }
            return String(l.dropFirst("skse64_".count).dropLast(4)).replacingOccurrences(of: "_", with: ".")
        }
        return nil
    }
}

/// What the profile's SKSE plugins need but is missing (from the deploy plan + the game folder).
public struct SKSEPrerequisites: Equatable {
    public var pluginDLLs: Int = 0          // SKSE/Plugins/*.dll the profile deploys
    public var hasSKSE = false              // skse64_loader.exe (deployed or in the game folder)
    public var hasAddressLibrary = false    // SKSE/Plugins/versionlib-*.bin (AE) or version-*.bin (SE)
}

extension ModKit {
    public func sksePrerequisites(plan given: DeployPlan? = nil) -> SKSEPrerequisites {
        var r = SKSEPrerequisites()
        let plan = given ?? ((try? plan()) ?? DeployPlan())
        for k in plan.files.keys {
            if k.hasPrefix("data/skse/plugins/") {
                let n = String(k.dropFirst("data/skse/plugins/".count))
                if !n.contains("/") && n.hasSuffix(".dll") { r.pluginDLLs += 1 }
                if (n.hasPrefix("versionlib-") || n.hasPrefix("version-")) && n.hasSuffix(".bin") { r.hasAddressLibrary = true }
            }
            if k == "skse64_loader.exe" { r.hasSKSE = true }
        }
        if !r.hasSKSE { r.hasSKSE = FileManager.default.fileExists(atPath: gameDir.appendingPathComponent("skse64_loader.exe").path) }
        if !r.hasAddressLibrary {
            let dir = gameDir.appendingPathComponent("Data/SKSE/Plugins")
            r.hasAddressLibrary = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).contains {
                let l = $0.lowercased(); return (l.hasPrefix("versionlib-") || l.hasPrefix("version-")) && l.hasSuffix(".bin")
            }
        }
        return r
    }
}
