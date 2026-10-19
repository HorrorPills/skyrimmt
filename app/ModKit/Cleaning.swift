// Plugin cleaning (docs/MODMANAGER.md §3B): LOOT's masterlist says which plugins are dirty (ITMs / deleted references,
// for the exact file CRC); xEdit's Quick Auto Clean fixes them. xEdit always saves into its Data folder (original renamed
// into its backup folder; xEdit source xeInit.pas / xeMainForm.pas), so it runs against a WORKSPACE: an APFS clone of the
// game's Data, its own plugins.txt, backup and cache folders. The cleaned file goes into the "Cleaned Plugins" mod at the
// highest priority — game files and mod files stay untouched, removing the mod undoes everything. A cleaned copy whose
// original changed later (mod update, game update) is stale: found by the original's hash and taken out.
//   SSEEdit.exe -qac -autoexit -autoload -IKnowWhatImDoing -D:<Data\> -P:<plugins.txt> -B:<backup\> -C:<cache\> <Plugin>
import Foundation
import CryptoKit

public struct CleaningJob {
    public let plugin: String
    public let workspace: URL
    public let xedit: URL
    public let arguments: [String]
    var dataDir: URL { workspace.appendingPathComponent("Data") }
}

public struct CleaningResult: Equatable {
    public var plugin: String
    public var changed: Bool
    public var removedITMs = 0, undeletedRefs = 0
    public var log = ""
}

struct CleanedRecord: Codable, Equatable { var sourceHash: String; var cleanedAt: Date }

extension ModKit {
    public static let cleanedModName = "Cleaned Plugins"
    var cleaningStateURL: URL { stateDir.appendingPathComponent("cleaned-plugins.json") }
    func cleanedRecords() -> [String: CleanedRecord] { readJSON(cleaningStateURL, [String: CleanedRecord].self) ?? [:] }

    /// Z:\… path for Wine (drive Z: is the Mac's root).
    static func winPath(_ u: URL, dir: Bool = false) -> String { "Z:" + u.path.replacingOccurrences(of: "/", with: "\\") + (dir ? "\\" : "") }

    static func fileHash(_ u: URL) -> String? {
        guard let d = try? Data(contentsOf: u, options: .mappedIfSafe) else { return nil }
        return SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined()
    }

    /// "SSEEdit64.exe" / "SSEEditQuickAutoClean.exe" → "SSEEdit" (xEdit names its log and settings after the app).
    static func xeditAppName(_ exe: URL) -> String {
        var n = exe.deletingPathExtension().lastPathComponent
        for suffix in ["QuickAutoClean", "64"] where n.hasSuffix(suffix) { n = String(n.dropLast(suffix.count)) }
        return n
    }

    /// Sums of xEdit's summary lines over its cleaning passes:
    /// "[Removing "Identical to Master" records done]  Processed Records: 699, Removed Records: 1, …"
    /// "[Undeleting and Disabling References done]  Processed Records: 699, Undeleted Records: 0, …"
    static func cleaningCounts(_ log: String) -> (itm: Int, udr: Int) {
        // xEdit appends sessions to its log: only the last one is this run
        let session = log.range(of: "starting session", options: .backwards).map { String(log[$0.upperBound...]) } ?? log
        func sum(_ key: String) -> Int {
            session.components(separatedBy: "\n").reduce(0) { acc, line in
                guard let r = line.range(of: key + ": ") else { return acc }
                return acc + (Int(line[r.upperBound...].prefix { $0.isNumber }) ?? 0)
            }
        }
        return (sum("Removed Records"), sum("Undeleted Records"))
    }

    /// Pre-answer xEdit's interactive first-run questions in its settings file (TMemIniFile).
    static func seedXEditSettings(_ url: URL) throws {
        if !FileManager.default.fileExists(atPath: url.path) { try "".write(to: url, atomically: true, encoding: .utf8) }
        // Delphi TDate serial: days since 1899-12-30
        let epoch = DateComponents(calendar: Calendar(identifier: .gregorian), timeZone: TimeZone(identifier: "UTC"), year: 1899, month: 12, day: 30).date!
        let today = Int(Date().timeIntervalSince(epoch) / 86400)
        try IniEdit.set(url, section: "Init", key: "First64Start", value: "0")
        try IniEdit.set(url, section: "DeveloperMessage", key: "Version", value: "99999999")   // compared with xEdit's version (4.1.5f = 4010506)
        try IniEdit.set(url, section: "DeveloperMessage", key: "LastShownOn", value: String(today))
    }

    /// The xEdit to use for cleaning: 32-bit SSEEdit.exe first (no first-start question), 64-bit as fallback.
    public func xeditForCleaning() -> URL? {
        let d = detectTools([ToolPreset(name: "32", exe: "SSEEdit.exe", arguments: "", note: ""), ToolPreset(name: "64", exe: "SSEEdit64.exe", arguments: "", note: "")])
        return d["32"] ?? d["64"] ?? findTool("SSEEdit.exe")   // last resort: the game folder / deeper layouts
    }

    public var cleanedMod: ModRecord? { mods.first { $0.name == ModKit.cleanedModName } }

    /// Set up the workspace for one plugin (game must be deployed: the clone is what the game would load).
    public func prepareCleaning(plugin: String, xedit: URL) throws -> CleaningJob {
        let fm = FileManager.default
        let data = gameDir.appendingPathComponent("Data")
        guard fm.fileExists(atPath: data.appendingPathComponent(plugin).path) else { throw ModKitError.invalid("\(plugin) is not in the game's Data folder (deploy first)") }
        let ws = home.appendingPathComponent("cache/cleaning/\(UUID().uuidString)")
        try fm.createDirectory(at: ws, withIntermediateDirectories: true)
        // one clonefile call copies the whole tree copy-on-write (seconds, no extra space)
        guard clonefile(data.path, ws.appendingPathComponent("Data").path, 0) == 0 else {
            try? fm.removeItem(at: ws); throw ModKitError.invalid("couldn't clone the Data folder: \(String(cString: strerror(errno)))")
        }
        for d in ["Backup", "Cache"] { try fm.createDirectory(at: ws.appendingPathComponent(d), withIntermediateDirectories: true) }
        let lo = loadOrder()
        let txt = "# SkyrimMT cleaning workspace\r\n" + lo.entries.map { ($0.active ? "*" : "") + $0.name }.joined(separator: "\r\n") + "\r\n"
        // xEdit keeps its settings next to the -P plugins file (when no SSEEdit.ini sits next to the exe): a persistent
        // folder, so first-run questions are answered once — and pre-answered here, because nobody is there to click
        // (64-bit "are you sure", the developer's message every 14 days). SkyrimMT credits xEdit on the Tools page.
        let cfg = home.appendingPathComponent("cache/xedit")
        try fm.createDirectory(at: cfg, withIntermediateDirectories: true)
        let pl = cfg.appendingPathComponent("plugins.txt")
        try txt.write(to: pl, atomically: true, encoding: .utf8)
        try ModKit.seedXEditSettings(cfg.appendingPathComponent("plugins.sseviewsettings"))
        let args = ["-qac", "-autoexit", "-autoload", "-IKnowWhatImDoing",
                    "-D:" + ModKit.winPath(ws.appendingPathComponent("Data"), dir: true), "-P:" + ModKit.winPath(pl),
                    "-B:" + ModKit.winPath(ws.appendingPathComponent("Backup"), dir: true), "-C:" + ModKit.winPath(ws.appendingPathComponent("Cache"), dir: true),
                    plugin]
        return CleaningJob(plugin: plugin, workspace: ws, xedit: xedit, arguments: args)
    }

    /// After xEdit exited: keep the cleaned file (if it changed) in the Cleaned Plugins mod; remove the workspace.
    @discardableResult
    /// `keep: false` only reports (tests on a real setup without changing any profile).
    public func finishCleaning(_ job: CleaningJob, keep: Bool = true) throws -> CleaningResult {
        let fm = FileManager.default
        defer { try? fm.removeItem(at: job.workspace) }
        let original = gameDir.appendingPathComponent("Data").appendingPathComponent(job.plugin)
        let cleaned = job.dataDir.appendingPathComponent(job.plugin)
        var r = CleaningResult(plugin: job.plugin, changed: false)
        // xEdit's log next to the exe, named after the app (SSEEdit_log.txt for SSEEdit64.exe / SSEEditQuickAutoClean.exe too)
        let logURL = job.xedit.deletingLastPathComponent().appendingPathComponent(ModKit.xeditAppName(job.xedit) + "_log.txt")
        if let log = (try? String(contentsOf: logURL, encoding: .utf8)) ?? (try? String(contentsOf: logURL, encoding: .windowsCP1252)) {
            let c = ModKit.cleaningCounts(log)
            r.removedITMs = c.itm; r.undeletedRefs = c.udr
            r.log = log.components(separatedBy: "\n").suffix(30).joined(separator: "\n")
        }
        // xEdit usually lives inside a mod: its log must not become a mod file (it would deploy into Data)
        if fm.fileExists(atPath: logURL.path) {
            let keep = home.appendingPathComponent("logs/xedit/\(ModKit.xeditAppName(job.xedit))_log.txt")
            try? fm.createDirectory(at: keep.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.removeItem(at: keep)
            try? fm.moveItem(at: logURL, to: keep)
        }
        guard let before = ModKit.fileHash(original), let after = ModKit.fileHash(cleaned), before != after else { return r }
        r.changed = true
        guard keep else { return r }
        // into the Cleaned Plugins mod (created on first use), highest priority in the current profile
        let mod: ModRecord
        if let m = cleanedMod { mod = m } else {
            let tmp = home.appendingPathComponent("incoming/cleaned-\(UUID().uuidString)")
            try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
            mod = try addMod(name: ModKit.cleanedModName, from: tmp)
        }
        let dst = stagingFolder(mod).appendingPathComponent(job.plugin)
        try? fm.removeItem(at: dst)
        try fm.copyItem(at: cleaned, to: dst)
        var p = try currentProfile()
        p.mods.removeAll { $0.id == mod.id }
        p.mods.append(ProfileMod(id: mod.id, enabled: true))
        try saveProfile(p)
        var recs = cleanedRecords()
        recs[job.plugin.lowercased()] = CleanedRecord(sourceHash: before, cleanedAt: Date())
        try writeJSON(recs, to: cleaningStateURL)
        return r
    }

    /// Cleaned copies whose original changed since cleaning (the copy would hide the new version).
    public func staleCleanedPlugins() -> [String] {
        guard let m = cleanedMod, let p = try? currentProfile() else { return [] }
        let recs = cleanedRecords()
        // the original = what the plan would deploy without the Cleaned Plugins mod
        var q = p; q.mods.removeAll { $0.id == m.id }
        guard let plan = try? plan(q) else { return [] }
        let base = gameDir.appendingPathComponent("Data")
        var out: [String] = []
        for f in (try? FileManager.default.contentsOfDirectory(atPath: stagingFolder(m).path)) ?? [] {
            guard let rec = recs[f.lowercased()] else { continue }
            let src = plan.files["data/" + f.lowercased()].map { URL(fileURLWithPath: $0.source) } ?? baseline(f, base)
            if let h = src.flatMap(ModKit.fileHash), h != rec.sourceHash { out.append(f) }
        }
        return out.sorted()
    }

    /// The game's own copy of a plugin (vanilla: the backup SkyrimMT made when a mod replaced it, else Data).
    private func baseline(_ name: String, _ data: URL) -> URL? {
        let backup = deployer.layout.backupDir.appendingPathComponent("Data").appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: backup.path) { return backup }
        let u = data.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    /// Remove cleaned copies (stale ones, or on request).
    public func removeCleaned(_ plugins: [String]) throws {
        guard let m = cleanedMod else { return }
        var recs = cleanedRecords()
        for n in plugins {
            try? FileManager.default.removeItem(at: stagingFolder(m).appendingPathComponent(n))
            recs[n.lowercased()] = nil
        }
        try writeJSON(recs, to: cleaningStateURL)
    }
}
