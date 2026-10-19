// ModKit MO2 import: turns a Mod Organizer 2 instance (what Wabbajack lists install, or a player's own MO2 setup)
// into SkyrimMT mods + a profile. MO2 facts (modorganizer src/profile.cpp, doWriteModlist): modlist.txt is written
// from HIGHEST to lowest priority; "+" enabled, "-" disabled, "*" foreign (DLC/Creation Club, not a mod folder);
// overwrite has automatic priority and is not listed. Mods named "…_separator" are separators. Files ending in
// ".mohidden" are hidden by MO2. Root Builder mods keep game-root files in "Root/" (SkyrimMT: "__root__/").
// Wabbajack lists usually also install a "Stock Game" folder (the game + root files + cleaned masters): everything
// in it that differs from the vanilla game becomes a "Game Root" mod.
import Foundation

public struct MO2Instance {
    public let root: URL
    public let modsDir: URL
    public let profilesDir: URL
    public let overwriteDir: URL
    public var gameDir: URL?              // Stock Game: a game copy inside the instance (never the real game folder)
    public var selectedProfile: String?
    public var profiles: [String]

    /// Read ModOrganizer.ini (QSettings: @ByteArray(…) values, doubled backslashes) and the instance layout.
    public static func open(_ root: URL) throws -> MO2Instance {
        let fm = FileManager.default
        let iniURL = root.appendingPathComponent("ModOrganizer.ini")
        guard fm.fileExists(atPath: iniURL.path) else { throw ModKitError.invalid("not an MO2 instance (no ModOrganizer.ini): \(root.path)") }
        let ini = MO2Instance.parseINI((try? String(contentsOf: iniURL, encoding: .utf8)) ?? "")
        func dir(_ key: String, _ fallback: String) -> URL {
            guard let v = ini["Settings"]?[key], !v.isEmpty else { return root.appendingPathComponent(fallback) }
            return MO2Instance.resolve(v.replacingOccurrences(of: "%BASE_DIR%", with: root.path), base: root)
        }
        var inst = MO2Instance(root: root, modsDir: dir("mod_directory", "mods"), profilesDir: dir("profiles_directory", "profiles"),
                               overwriteDir: dir("overwrite_directory", "overwrite"), gameDir: nil,
                               selectedProfile: ini["General"]?["selected_profile"], profiles: [])
        // Only a game copy INSIDE the instance (Wabbajack's "Stock Game") is imported: a gamePath pointing at the real game
        // folder would turn whatever is deployed there into "game-root files".
        let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        if let g = ini["General"]?["gamePath"] {
            let u = MO2Instance.resolve(g, base: root)
            if u.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(rootPath),
               fm.fileExists(atPath: u.appendingPathComponent("SkyrimSE.exe").path) { inst.gameDir = u }
        }
        if inst.gameDir == nil {   // Wabbajack's usual names, relative to the instance
            for n in ["Stock Game", "Game Root", "STOCK GAME", "Stock Folder"] {
                let u = root.appendingPathComponent(n)
                if fm.fileExists(atPath: u.appendingPathComponent("SkyrimSE.exe").path) { inst.gameDir = u; break }
            }
        }
        inst.profiles = ((try? fm.contentsOfDirectory(atPath: inst.profilesDir.path)) ?? [])
            .filter { fm.fileExists(atPath: inst.profilesDir.appendingPathComponent("\($0)/modlist.txt").path) }.sorted()
        return inst
    }

    /// QSettings INI → [section: [key: value]] with @ByteArray(…) unwrapped and "\\\\" → "\\".
    static func parseINI(_ text: String) -> [String: [String: String]] {
        var out: [String: [String: String]] = [:], sec = "General"
        let text = text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text   // UTF-8 BOM (Wabbajack writes one)
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") && line.hasSuffix("]") { sec = String(line.dropFirst().dropLast()); continue }
            guard let eq = line.firstIndex(of: "="), !line.hasPrefix(";") else { continue }
            var v = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            if v.hasPrefix("@ByteArray(") && v.hasSuffix(")") { v = String(v.dropFirst(11).dropLast()) }
            if v.hasPrefix("\"") && v.hasSuffix("\"") && v.count >= 2 { v = String(v.dropFirst().dropLast()) }
            v = v.replacingOccurrences(of: "\\\\", with: "\\")
            out[sec, default: [:]][String(line[..<eq]).trimmingCharacters(in: .whitespaces)] = v
        }
        return out
    }

    /// A path from MO2 settings on this Mac: absolute Unix paths, "Z:\…" (Wine's root drive) or relative ones.
    static func resolve(_ p: String, base: URL) -> URL {
        var s = p.replacingOccurrences(of: "\\", with: "/")
        if s.count >= 2, s.dropFirst().first == ":" {
            let drive = s.prefix(1).uppercased()
            s = String(s.dropFirst(2))
            if drive != "Z" { return base.appendingPathComponent(URL(fileURLWithPath: s).lastPathComponent) }   // foreign drive: same name here
        }
        while s.contains("//") { s = s.replacingOccurrences(of: "//", with: "/") }
        return (s.hasPrefix("/") ? URL(fileURLWithPath: s) : base.appendingPathComponent(s)).standardizedFileURL
    }

    /// Mods of a profile, highest priority first: (folder name, enabled). Foreign entries and separators left out.
    public func modlist(_ profile: String) -> [(name: String, enabled: Bool)] {
        entries(profile).filter { !$0.separator }.map { ($0.name, $0.enabled) }
    }

    /// modlist.txt entries highest priority first, separators included ("Name_separator" → separator "Name").
    public func entries(_ profile: String) -> [(name: String, enabled: Bool, separator: Bool)] {
        let text = (try? String(contentsOf: profilesDir.appendingPathComponent("\(profile)/modlist.txt"), encoding: .utf8)) ?? ""
        return text.split(whereSeparator: \.isNewline).compactMap { raw in
            let l = String(raw).trimmingCharacters(in: .whitespaces)
            guard let f = l.first, f == "+" || f == "-" else { return nil }
            let name = String(l.dropFirst())
            return name.hasSuffix("_separator") ? (String(name.dropLast(10)), true, true) : (name, f == "+", false)
        }
    }

    /// Load order: loadorder.txt (every plugin, in order) with active flags from plugins.txt ("*Name" = active).
    public func loadOrder(_ profile: String) -> [LoadOrderEntry] {
        func lines(_ f: String) -> [String] {
            ((try? String(contentsOf: profilesDir.appendingPathComponent("\(profile)/\(f)"), encoding: .utf8))
                ?? (try? String(contentsOf: profilesDir.appendingPathComponent("\(profile)/\(f)"), encoding: .windowsCP1252)) ?? "")
                .split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("#") }
        }
        let plugins = lines("plugins.txt")
        let active = Set(plugins.filter { $0.hasPrefix("*") }.map { $0.dropFirst().lowercased() })
        var order = lines("loadorder.txt")
        let seen = Set(order.map { $0.lowercased() })
        order += plugins.map { $0.hasPrefix("*") ? String($0.dropFirst()) : $0 }.filter { !seen.contains($0.lowercased()) }
        return order.map { LoadOrderEntry(name: $0, active: active.contains($0.lowercased())) }
    }

    /// Profile-local INIs (MO2 "LocalSettings"): Skyrim.ini, SkyrimPrefs.ini, SkyrimCustom.ini in the profile folder.
    public func profileINIs(_ profile: String) -> [URL] {
        let dir = profilesDir.appendingPathComponent(profile)
        let settings = MO2Instance.parseINI((try? String(contentsOf: dir.appendingPathComponent("settings.ini"), encoding: .utf8)) ?? "")
        guard (settings["General"]?["LocalSettings"] ?? "").lowercased() == "true" else { return [] }
        return ["Skyrim.ini", "SkyrimPrefs.ini", "SkyrimCustom.ini"].map { dir.appendingPathComponent($0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Nexus ids / version from a mod's meta.ini.
    func meta(_ mod: String) -> (nexus: NexusRef?, version: String) {
        let ini = MO2Instance.parseINI((try? String(contentsOf: modsDir.appendingPathComponent("\(mod)/meta.ini"), encoding: .utf8)) ?? "")
        let g = ini["General"] ?? [:]
        let modID = Int(g["modid"] ?? "") ?? 0
        let fileID = (ini["installedFiles"] ?? [:]).first { $0.key.hasSuffix("fileid") }.flatMap { Int($0.value) }
        return (modID > 0 ? NexusRef(modID: modID, fileID: fileID) : nil, g["version"] ?? "")
    }
}

public struct MO2ImportReport {
    public var profile = ""
    public var mods = 0
    public var files = 0
    public var gameRootFiles = 0
    public var plugins = 0
    public var inis = 0
    public var missing: [String] = []   // listed in modlist.txt but no folder
    public var seconds = 0.0
}

extension ModKit {
    var importsURL: URL { stateDir.appendingPathComponent("mo2-imports.json") }

    /// Import `profile` of an MO2 instance as SkyrimMT profile `as name` (created or replaced). Mod folders are cloned
    /// (APFS: no extra space); re-importing the same instance reuses and refreshes the mods it imported before.
    /// `vanillaGame`: the folder to diff the instance's Stock Game against (game-root extras become a mod).
    @discardableResult
    public func importMO2(_ inst: MO2Instance, profile mo2Profile: String, as name: String, vanillaGame: URL?, gameVersion: String?,
                          progress: (Int, Int, String) -> Void = { _, _, _ in }) throws -> MO2ImportReport {
        let fm = FileManager.default
        let t0 = Date()
        var report = MO2ImportReport(); report.profile = name
        let pname = ModKit.sanitize(name)
        var known = readJSON(importsURL, [String: [String: String]].self) ?? [:]   // instance path → MO2 mod name → mod id
        var mine = known[inst.root.path] ?? [:]
        var profileMods: [ProfileMod] = []

        func cloneTree(_ src: URL, to dst: URL) throws -> Int {
            var n = 0
            guard let en = fm.enumerator(at: src, includingPropertiesForKeys: [.isRegularFileKey]) else { return 0 }
            for case let f as URL in en {
                guard (try? f.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
                var rel = String(f.path.dropFirst(src.path.count + 1))
                if rel.lowercased().hasSuffix(".mohidden") || rel.lowercased() == "meta.ini" { continue }
                if rel.hasPrefix("Root/") || rel.hasPrefix("root/") { rel = Deployer.rootFolder + "/" + rel.dropFirst(5) }   // Root Builder
                let d = dst.appendingPathComponent(rel)
                try fm.createDirectory(at: d.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? fm.removeItem(at: d)
                try cloneOrCopy(f, d)
                n += 1
            }
            return n
        }
        func adopt(_ modName: String, from src: URL) throws -> String {
            let tmp = home.appendingPathComponent("incoming/mo2-\(UUID().uuidString)")
            report.files += try cloneTree(src, to: tmp)
            try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
            let meta = inst.meta(modName)
            if let id = mine[modName], let i = mods.firstIndex(where: { $0.id == id }) {   // re-import: refresh in place
                let staging = stagingFolder(mods[i])
                try? fm.removeItem(at: staging)
                try fm.moveItem(at: tmp, to: staging)
                var r = mods[i]; r.version = meta.version; r.nexus = meta.nexus ?? r.nexus
                replaceMod(at: i, with: r)
                return id
            }
            let id = UUID().uuidString
            let folder = "\(ModKit.sanitize(modName))__\(id.prefix(8))"
            try fm.createDirectory(at: modsDir, withIntermediateDirectories: true)
            try fm.moveItem(at: tmp, to: modsDir.appendingPathComponent(folder))
            appendMod(ModRecord(id: id, name: modName, version: meta.version, folder: folder, nexus: meta.nexus))
            mine[modName] = id
            return id
        }

        // mods, lowest priority first (SkyrimMT: later in the list wins). MO2's left pane shows lowest priority at the top
        // with a separator above its mods (lower priority than them), and modlist.txt lists highest first — so the
        // reversed file is exactly SkyrimMT's order with each separator right before its group.
        let ordered = Array(inst.entries(mo2Profile).reversed())
        let modCount = ordered.filter { !$0.separator }.count
        var done = 0
        for m in ordered {
            if m.separator {
                let key = "separator:" + m.name
                let id: String
                if let old = mine[key], mods.contains(where: { $0.id == old }) { id = old }
                else {
                    id = UUID().uuidString
                    let folder = "__separator__\(ModKit.sanitize(m.name))__\(id.prefix(8))"
                    try fm.createDirectory(at: modsDir.appendingPathComponent(folder), withIntermediateDirectories: true)
                    var r = ModRecord(id: id, name: m.name, folder: folder); r.separator = true
                    appendMod(r); mine[key] = id
                }
                profileMods.append(ProfileMod(id: id, enabled: true))
                continue
            }
            progress(done, modCount, m.name); done += 1
            let src = inst.modsDir.appendingPathComponent(m.name)
            guard fm.fileExists(atPath: src.path) else { report.missing.append(m.name); continue }
            let id = try adopt(m.name, from: src)
            profileMods.append(ProfileMod(id: id, enabled: m.enabled)); report.mods += 1
        }

        // Stock Game: files that are not (or differ from) the vanilla game → "<name> – Game Root" mod
        if let stock = inst.gameDir, let vanilla = vanillaGame {
            let extra = home.appendingPathComponent("incoming/mo2-root-\(UUID().uuidString)")
            let stockRoot = stock.resolvingSymlinksInPath().standardizedFileURL
            if let en = fm.enumerator(at: stockRoot, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) {
                for case let f as URL in en {
                    guard (try? f.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
                    let rel = String(f.resolvingSymlinksInPath().standardizedFileURL.path.dropFirst(stockRoot.path.count + 1))
                    let v = vanilla.appendingPathComponent(rel)
                    if fm.fileExists(atPath: v.path), fm.contentsEqual(atPath: f.path, andPath: v.path) { continue }
                    let inData = rel.lowercased().hasPrefix("data/")
                    let d = extra.appendingPathComponent(inData ? String(rel.dropFirst(5)) : Deployer.rootFolder + "/" + rel)
                    try fm.createDirectory(at: d.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try cloneOrCopy(f, d); report.gameRootFiles += 1
                }
            }
            if report.gameRootFiles > 0 {
                let rootName = "\(name) – Game Root"
                let id: String
                if let old = mine[rootName], let i = mods.firstIndex(where: { $0.id == old }) {
                    let staging = stagingFolder(mods[i]); try? fm.removeItem(at: staging); try fm.moveItem(at: extra, to: staging); id = old
                } else {
                    id = UUID().uuidString
                    let folder = "\(ModKit.sanitize(rootName))__\(id.prefix(8))"
                    try fm.moveItem(at: extra, to: modsDir.appendingPathComponent(folder))
                    appendMod(ModRecord(id: id, name: rootName, folder: folder)); mine[rootName] = id
                }
                profileMods.insert(ProfileMod(id: id, enabled: true), at: 0)   // lowest priority: mods override it, like MO2's data
            } else { try? fm.removeItem(at: extra) }
        }

        // game-folder files a list ships for the player to copy by hand (ModdingLinked lists: "__Files Requiring Manual
        // Install" = the SKSE package) → a "Game Files" mod, laid out by the normal installer (loader/DLLs → game folder,
        // Data → Data, sources and readmes left out)
        for dir in ((try? fm.contentsOfDirectory(at: inst.root, includingPropertiesForKeys: [.isDirectoryKey])) ?? []).sorted(by: { $0.path < $1.path }) {
            let n = dir.lastPathComponent.lowercased()
            guard (try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                  n.contains("manual install") || n.contains("game folder files") || n == "game root" || n == "root files" else { continue }
            let work = installWork.appendingPathComponent(UUID().uuidString), out = work.appendingPathComponent("out")
            defer { try? fm.removeItem(at: work) }
            try Installer.prepare(Installer.detect(dir), fomod: nil, into: out)
            let id = try adopt("\(name) – Game Files", from: out)
            if let m = mod(id) {
                let root = stagingFolder(m).appendingPathComponent(Deployer.rootFolder)
                report.gameRootFiles += ((try? fm.contentsOfDirectory(atPath: root.path)) ?? []).count
            }
            profileMods.append(ProfileMod(id: id, enabled: true))
        }

        // overwrite → highest priority
        if fm.fileExists(atPath: inst.overwriteDir.path),
           (fm.enumerator(at: inst.overwriteDir, includingPropertiesForKeys: nil)?.nextObject() != nil) {
            let owName = "\(name) – Overwrite"
            let id = try adopt(owName.isEmpty ? "Overwrite" : owName, from: inst.overwriteDir)
            profileMods.append(ProfileMod(id: id, enabled: true))
        }

        known[inst.root.path] = mine
        try writeJSON(known, to: importsURL)

        // the profile: mods, load order, game version, local INIs
        let lo = inst.loadOrder(mo2Profile)
        report.plugins = lo.count
        var p = profile(pname) ?? Profile(name: pname)
        // a re-import (list update) keeps what the player added to the profile: mods this instance never provided,
        // with their plugins' load-order entries
        let instanceIDs = Set(mine.values)
        let extras = p.mods.filter { !instanceIDs.contains($0.id) && mod($0.id) != nil && !profileMods.contains($0) }
        var extraPlugins: [LoadOrderEntry] = []
        for e in extras { if let m = mod(e.id) {
            let names = Set(((try? fm.contentsOfDirectory(atPath: stagingFolder(m).path)) ?? []).map { $0.lowercased() })
            extraPlugins += p.loadOrder.filter { names.contains($0.name.lowercased()) }
        } }
        p.mods = profileMods + extras
        p.loadOrder = lo + extraPlugins.filter { e in !lo.contains { $0.name.lowercased() == e.name.lowercased() } }
        if let v = gameVersion { p.gameVersion = v }
        try saveProfile(p)
        let inis = inst.profileINIs(mo2Profile)
        let iniDir = profileINIDir(pname)
        try? fm.removeItem(at: iniDir)
        if !inis.isEmpty {
            try fm.createDirectory(at: iniDir, withIntermediateDirectories: true)
            for f in inis { try fm.copyItem(at: f, to: iniDir.appendingPathComponent(f.lastPathComponent)) }
        }
        report.inis = inis.count
        report.seconds = Date().timeIntervalSince(t0)
        return report
    }
}
