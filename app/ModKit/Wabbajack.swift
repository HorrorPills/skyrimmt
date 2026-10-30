// ModKit Wabbajack: installs a Wabbajack modlist with the native macOS build of jackify-engine (GPL-3 Wabbajack fork,
// tools/wabbajack: build.sh + macos.patch; texconv/texdiag run through SkyrimMT's Wine in a separate prefix via
// scripts/wabbajack-wine.sh) into $SKYRIM_HOME/wabbajack/lists/<list>, then imports that MO2 instance as a SkyrimMT
// profile (MO2Import.swift). The player's Nexus key is passed to the engine in its environment only.
import Foundation

public struct WabbajackListInfo {
    public var name = ""
    public var author = ""
    public var version = ""
    public var game = ""
    public var gameVersion: String?     // from the list's game-file archives, e.g. "1.6.1170.0"
    public var archives = 0
    public var directives = 0
    public var nexusArchives = 0
}

public struct WabbajackEngine {
    public let engine: URL      // jackify-engine executable
    public let wine: URL        // SkyrimMT's wine binary
    public let shim: URL        // scripts/wabbajack-wine.sh
    public init(engine: URL, wine: URL, shim: URL) { self.engine = engine; self.wine = wine; self.shim = shim }
}

public enum WabbajackError: Error, CustomStringConvertible {
    case notInstalled, needsGame(String), failed(String)
    public var description: String {
        switch self {
        case .notInstalled: return "The Wabbajack engine isn't installed (tools/wabbajack/build.sh)."
        case .needsGame(let v): return "This list needs Skyrim \(v) — get it in the Game tab (Skyrim version), then install again."
        case .failed(let m): return "Wabbajack: \(m)"
        }
    }
}

extension ModKit {
    public var wabbajackDir: URL { home.appendingPathComponent("wabbajack") }

    /// What a .wabbajack file contains (its "modlist" JSON entry).
    public static func wabbajackInfo(_ file: URL) throws -> WabbajackListInfo {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip"); p.arguments = ["-p", file.path, "modlist"]
        let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        guard let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw WabbajackError.failed("not a Wabbajack list: \(file.lastPathComponent)") }
        var i = WabbajackListInfo()
        i.name = j["Name"] as? String ?? file.deletingPathExtension().lastPathComponent
        i.author = j["Author"] as? String ?? ""
        i.version = j["Version"] as? String ?? ""
        i.game = j["GameType"] as? String ?? ""
        let archives = j["Archives"] as? [[String: Any]] ?? []
        i.archives = archives.count
        i.directives = (j["Directives"] as? [Any])?.count ?? 0
        for a in archives {
            let st = a["State"] as? [String: Any] ?? [:]
            let type = st["$type"] as? String ?? ""
            if let v = st["GameVersion"] as? String, !v.isEmpty, i.gameVersion == nil { i.gameVersion = v }
            if type.hasPrefix("NexusDownloader") { i.nexusArchives += 1 }
        }
        return i
    }

    /// Run the engine. `source`: a gallery id ("author/list") or a .wabbajack file. Returns the MO2 instance folder.
    public func runWabbajack(_ e: WabbajackEngine, source: String, listName: String, gameDir: URL, nexusKey: String?,
                             onStart: ((Process) -> Void)? = nil, status: @escaping (String, Double?) -> Void) throws -> URL {
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: e.engine.path) else { throw WabbajackError.notInstalled }
        let out = wabbajackDir.appendingPathComponent("lists/\(ModKit.sanitize(listName))")
        let downloads = wabbajackDir.appendingPathComponent("downloads")
        for d in [out, downloads, wabbajackDir.appendingPathComponent("data")] { try fm.createDirectory(at: d, withIntermediateDirectories: true) }
        let p = Process()
        p.executableURL = e.engine
        p.currentDirectoryURL = e.engine.deletingLastPathComponent()
        let isFile = source.hasSuffix(".wabbajack") || fm.fileExists(atPath: source)
        p.arguments = ["install", isFile ? "-w" : "-m", source, "-o", out.path, "-d", downloads.path]
        var env = ProcessInfo.processInfo.environment
        env["JACKIFY_DATA_DIR"] = wabbajackDir.appendingPathComponent("data").path
        env["SKYRIMMT_WINE"] = e.wine.path
        env["SKYRIMMT_WINE_SHIM"] = e.shim.path
        env["WABBAJACK_GAME_DIR_SKYRIMSPECIALEDITION"] = gameDir.path
        if let k = nexusKey, !k.isEmpty { env["NEXUS_API_KEY"] = k }
        p.environment = env
        let logURL = home.appendingPathComponent("logs/wabbajack-\(ModKit.sanitize(listName)).log")
        try? fm.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        fm.createFile(atPath: logURL.path, contents: nil)
        let log = try FileHandle(forWritingTo: logURL)
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        var lastError: String?
        var pending = ""
        let lock = NSLock()
        pipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            guard !d.isEmpty else { return }
            log.write(d)
            lock.lock(); defer { lock.unlock() }
            // the engine draws progress for a terminal: drop ANSI control sequences (ESC [ … letter, e.g. "\e[K")
            pending += ModKit.stripANSI(String(decoding: d, as: UTF8.self))
            let parts = pending.components(separatedBy: CharacterSet(charactersIn: "\r\n"))
            pending = parts.last ?? ""
            for line in parts.dropLast() where !line.trimmingCharacters(in: .whitespaces).isEmpty {
                if line.hasPrefix("{\"je\""), let j = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] {
                    if (j["level"] as? String) == "error" { lastError = j["message"] as? String }
                    continue
                }
                status(line.trimmingCharacters(in: .whitespaces), ModKit.wabbajackFraction(line))
            }
        }
        try p.run()
        onStart?(p)
        p.waitUntilExit()
        pipe.fileHandleForReading.readabilityHandler = nil
        try? log.close()
        if p.terminationReason == .uncaughtSignal { throw WabbajackError.failed("cancelled") }
        guard p.terminationStatus == 0 else {
            throw WabbajackError.failed((lastError ?? "the engine stopped (code \(p.terminationStatus))") + " — log: logs/\(logURL.lastPathComponent)")
        }
        return out
    }

    /// "Installing files 120/4000 (…)" / "… 45%" → fraction for a progress bar.
    static func wabbajackFraction(_ line: String) -> Double? {
        if let r = line.range(of: #"(\d+)/(\d+)"#, options: .regularExpression) {
            let nums = line[r].split(separator: "/").compactMap { Double($0) }
            if nums.count == 2, nums[1] > 0 { return min(1, nums[0] / nums[1]) }
        }
        if let r = line.range(of: #"(\d+(\.\d+)?)%"#, options: .regularExpression), let v = Double(line[r].dropLast()) { return v / 100 }
        return nil
    }

    /// A ModKit for another game folder of this home (the store's install or a pinned version) — e.g. to build its vanilla view.
    public func kit(forVersionKey key: String) -> ModKit {
        key == "steam" ? ModKit(home: home, gameDir: ModKit.baseGameDir(home), pluginsTxt: pluginsTxt)
                       : ModKit(home: home, gameDir: home.appendingPathComponent("versions/\(key)"), pluginsTxt: pluginsTxt, versionKey: key)
    }

    /// The game folder for a list's Skyrim version: Steam's install or a pinned one (versions/<v>).
    public func gameDirFor(listVersion v: String?, steamGameDir: URL, steamVersion: String) throws -> URL {
        guard let v, !v.isEmpty else { return steamGameDir }
        func short(_ s: String) -> String { s.hasSuffix(".0") && s.split(separator: ".").count == 4 ? String(s.dropLast(2)) : s }
        if short(v) == short(steamVersion) { return steamGameDir }
        let pinned = home.appendingPathComponent("versions/\(short(v))")
        if FileManager.default.fileExists(atPath: pinned.appendingPathComponent(".skyrimmt-version").path) { return pinned }
        throw WabbajackError.needsGame(short(v))
    }

    /// Install a list end to end: engine → MO2 instance → SkyrimMT profile (named after the list).
    @discardableResult
    public func installWabbajackList(_ e: WabbajackEngine, source: String, info: WabbajackListInfo?, gameDir: URL,
                                     nexusKey: String?, onStart: ((Process) -> Void)? = nil,
                                     profileName: String? = nil, status: @escaping (String, Double?) -> Void) throws -> MO2ImportReport {
        let name = info?.name.isEmpty == false ? info!.name : (source as NSString).lastPathComponent.replacingOccurrences(of: ".wabbajack", with: "")
        let instDir = try runWabbajack(e, source: source, listName: name, gameDir: gameDir, nexusKey: nexusKey, onStart: onStart, status: status)
        status("Importing into SkyrimMT…", nil)
        let inst = try MO2Instance.open(instDir)
        guard let prof = inst.selectedProfile.flatMap({ inst.profiles.contains($0) ? $0 : nil }) ?? inst.profiles.first else {
            throw WabbajackError.failed("the installed list has no MO2 profile")
        }
        let gv = info?.gameVersion.map { $0.hasSuffix(".0") && $0.split(separator: ".").count == 4 ? String($0.dropLast(2)) : $0 }
        // an update goes into the profile the list already has
        let primary = profileName ?? (inst.profiles.count > 1 ? ModKit.variantProfileName(list: name, mo2Profile: prof) : name)
        let report = try importMO2(inst, profile: prof, as: primary, vanillaGame: gameDir, gameVersion: gv) { i, n, mod in
            status("Importing \(mod)", n > 0 ? Double(i) / Double(n) : nil)
        }
        // lists with variants ship several MO2 profiles (A Dragonborn's Fate: standard + Extended): each becomes its
        // own SkyrimMT profile; the mods are shared
        for other in inst.profiles where other != prof {
            status("Importing the “\(other)” variant…", nil)
            _ = try? importMO2(inst, profile: other, as: ModKit.variantProfileName(list: name, mo2Profile: other), vanillaGame: gameDir, gameVersion: gv) { _, _, _ in }
        }
        return report
    }

    /// "A Dragonborn's Fate" + MO2 profile "A Dragonborn's Fate Extended" → "A Dragonborn's Fate – Extended".
    public static func variantProfileName(list: String, mo2Profile: String) -> String {
        let rest = mo2Profile.hasPrefix(list) ? String(mo2Profile.dropFirst(list.count)).trimmingCharacters(in: CharacterSet(charactersIn: " -–_()")) : mo2Profile
        return "\(list) – \(rest.isEmpty ? (mo2Profile == list ? "Standard" : mo2Profile) : rest)"
    }
}

extension ModKit {
    /// Remove terminal control sequences (CSI "ESC [ params letter", OSC "ESC ] … BEL") from engine output.
    public static func stripANSI(_ s: String) -> String {
        guard s.contains("\u{1B}") else { return s }
        var out = "", it = s.unicodeScalars.makeIterator()
        while let c = it.next() {
            guard c == "\u{1B}" else { out.unicodeScalars.append(c); continue }
            guard let n = it.next() else { break }
            if n == "[" { while let x = it.next(), !(x.value >= 0x40 && x.value <= 0x7E) {} }
            else if n == "]" { while let x = it.next(), x != "\u{07}" {} }
        }
        return out
    }
}

/// A Wabbajack list SkyrimMT installed (to offer updates).
public struct InstalledWabbajackList: Codable, Equatable {
    public var machineURL: String       // gallery id ("ModdingLinked/ADragonbornsFate"), "" for a file
    public var title: String
    public var version: String
    public var profile: String
    public var installedAt: Date
}

extension ModKit {
    var wabbajackInstallsURL: URL { stateDir.appendingPathComponent("wabbajack-installs.json") }
    /// Lists installed by SkyrimMT whose profile still exists (deleting the profile uninstalls the list).
    public func installedWabbajackLists() -> [InstalledWabbajackList] {
        (readJSON(wabbajackInstallsURL, [InstalledWabbajackList].self) ?? []).filter { profile($0.profile) != nil }
    }
    public func recordWabbajackInstall(_ l: InstalledWabbajackList) {
        var all = installedWabbajackLists().filter { !($0.machineURL == l.machineURL && $0.title == l.title) }
        all.append(l)
        try? writeJSON(all, to: wabbajackInstallsURL)
    }
    /// Gallery entries newer than what is installed (version strings compared numerically, e.g. 13.10.26 < 13.11.2).
    public func wabbajackUpdates(gallery: [WabbajackGalleryEntry]) -> [(installed: InstalledWabbajackList, latest: WabbajackGalleryEntry)] {
        installedWabbajackLists().compactMap { i in
            guard !i.machineURL.isEmpty, let g = gallery.first(where: { $0.machineURL == i.machineURL }),
                  i.version.compare(g.version, options: .numeric) == .orderedAscending else { return nil }
            return (i, g)
        }
    }
}
