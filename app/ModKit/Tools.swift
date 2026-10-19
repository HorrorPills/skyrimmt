// ModKit tools + Overwrite (PLAN §8.11, §8.8): Windows modding tools (SSEEdit, BodySlide, Pandora, …) registered by
// the player and run in Skyrim's prefix; whatever a tool writes into Data/ is captured into the "Overwrite" mod
// (highest priority), so the game folder stays fully managed and a purge still returns it to vanilla.
import Foundation

public struct ToolEntry: Codable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var exe: String            // absolute macOS path of the .exe (usually inside a mod's staging or the prefix)
    public var arguments: String = ""
    /// Tools that write into a folder of their choosing (-o:): the folder's content becomes this mod after each run.
    public var outputMod: String? = nil
    public init(name: String, exe: String, arguments: String = "", outputMod: String? = nil) {
        id = UUID().uuidString; self.name = name; self.exe = exe; self.arguments = arguments; self.outputMod = outputMod
    }
}

/// Known tools: the exe name to look for and the arguments they need (PLAN §8.11).
public struct ToolPreset {
    public let name: String; public let exe: String; public let arguments: String; public let note: String
    public var outputMod: String? = nil
}
public let toolPresets: [ToolPreset] = [
    ToolPreset(name: "SSEEdit", exe: "SSEEdit.exe", arguments: "", note: "xEdit for Skyrim SE (finds conflicts, cleans plugins)."),
    ToolPreset(name: "SSEEdit Quick Auto Clean", exe: "SSEEditQuickAutoClean.exe", arguments: "", note: "Cleans a master file."),
    ToolPreset(name: "BodySlide", exe: "BodySlide x64.exe", arguments: "", note: "Builds body/outfit meshes; output is captured into Overwrite."),
    ToolPreset(name: "Cathedral Assets Optimizer", exe: "Cathedral Assets Optimizer.exe", arguments: "", note: "Optimises meshes/textures."),
    // DynDOLOD 3 (dyndolod.info Generation-Instructions, Command-Line-Argument): game mode -sse, -o:"<output\>"; each
    // output is installed as a mod that overwrites everything, and TexGen's output must be active before DynDOLOD runs.
    ToolPreset(name: "TexGen", exe: "TexGenx64.exe", arguments: "-sse", note: "Step 1 of DynDOLOD: LOD textures; output becomes the “TexGen Output” mod.", outputMod: "TexGen Output"),
    ToolPreset(name: "DynDOLOD", exe: "DynDOLODx64.exe", arguments: "-sse", note: "Step 2: distant LOD (run TexGen first); output becomes the “DynDOLOD Output” mod.", outputMod: "DynDOLOD Output"),
    ToolPreset(name: "xLODGen", exe: "xLODGenx64.exe", arguments: "-sse", note: "Terrain LOD; output becomes the “xLODGen Output” mod.", outputMod: "xLODGen Output"),
]

public struct CaptureSnapshot { let unmanaged: Set<String>; var outputDir: URL? = nil; var outputMod: String? = nil }

extension ModKit {
    /// The shared Overwrite of profiles made before 2026-10-19 (they keep it); new profiles get their own.
    public static let overwriteID = "overwrite"
    /// Generated files belong to the setup that made them: one Overwrite per profile (a list's shader settings or
    /// animation output must not leak into another profile).
    public static func overwriteID(for profile: String) -> String { "overwrite:" + profile }
    public static func isOverwrite(_ id: String) -> Bool { id == overwriteID || id.hasPrefix("overwrite:") }
    /// The Overwrite the current profile uses: the shared one if it already has it, else its own.
    func currentOverwriteID() -> String {
        let p = try? currentProfile()
        if p?.mods.contains(where: { $0.id == ModKit.overwriteID }) == true { return ModKit.overwriteID }
        return ModKit.overwriteID(for: currentProfileName)
    }
    var toolsURL: URL { stateDir.appendingPathComponent("tools.json") }

    /// Registered tools whose program still exists (a tool inside a removed mod disappears with it).
    public func tools() -> [ToolEntry] {
        (readJSON(toolsURL, [ToolEntry].self) ?? []).filter { FileManager.default.fileExists(atPath: $0.exe) }
    }
    public func saveTools(_ t: [ToolEntry]) throws { try writeJSON(t, to: toolsURL) }

    /// Known tools present among installed mods: one pass over each mod's top two folder levels (tools live there;
    /// a full walk of 500k mod files would take seconds). Preset name → exe.
    public func detectTools(_ presets: [ToolPreset]) -> [String: URL] {
        let fm = FileManager.default
        let wanted = Dictionary(presets.map { ($0.exe.lowercased(), $0.name) }, uniquingKeysWith: { a, _ in a })
        var found: [String: URL] = [:]
        for m in mods where !m.isSeparator {
            let root = stagingFolder(m)
            var dirs = [root]
            for d in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
                where (try? d.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { dirs.append(d) }
            for d in dirs {
                for f in (try? fm.contentsOfDirectory(atPath: d.path)) ?? [] {
                    if let n = wanted[f.lowercased()], found[n] == nil { found[n] = d.appendingPathComponent(f) }
                }
            }
        }
        return found
    }

    /// A tool entry for a preset. LOD tools (DynDOLOD, TexGen, xLODGen) must not run from game, Data or mod manager
    /// folders (dyndolod.info Installation-Instructions): their logs and caches would become mod files. When the exe sits
    /// in a mod, its folder is cloned (APFS: no extra space) to tools/<mod folder>/ and run from there; an existing
    /// clone is reused (it holds the tool's settings and caches).
    public func toolEntry(preset p: ToolPreset?, exe: URL, name: String? = nil) throws -> ToolEntry {
        var run = exe
        let mods = modsDir.standardizedFileURL.path + "/"
        if p?.outputMod != nil, exe.standardizedFileURL.path.hasPrefix(mods) {
            let rel = String(exe.standardizedFileURL.path.dropFirst(mods.count))   // <mod folder>/…/Tool.exe
            let srcDir = exe.deletingLastPathComponent()
            let dstDir = home.appendingPathComponent("tools").appendingPathComponent((rel as NSString).deletingLastPathComponent)
            if !FileManager.default.fileExists(atPath: dstDir.path) {
                try FileManager.default.createDirectory(at: dstDir.deletingLastPathComponent(), withIntermediateDirectories: true)
                try cloneOrCopy(srcDir, dstDir)
            }
            run = dstDir.appendingPathComponent(exe.lastPathComponent)
        }
        return ToolEntry(name: name ?? p?.name ?? exe.deletingPathExtension().lastPathComponent, exe: run.path,
                         arguments: p?.arguments ?? "", outputMod: p?.outputMod)
    }

    /// Find a preset's exe among installed mods (staging) and the game folder.
    public func findTool(_ exeName: String) -> URL? {
        for root in [modsDir, gameDir] {
            guard let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { continue }
            for case let u as URL in en where u.lastPathComponent.caseInsensitiveCompare(exeName) == .orderedSame { return u }
        }
        return nil
    }

    /// The current profile's Overwrite mod: created on demand, always last (wins every conflict).
    @discardableResult
    func ensureOverwrite() throws -> ModRecord {
        let id = currentOverwriteID()
        if let m = mod(id) { return m }
        let rec = id == ModKit.overwriteID ? ModRecord(id: id, name: "Overwrite (tool output)", folder: "Overwrite")
            : ModRecord(id: id, name: "Overwrite (\(currentProfileName))", folder: "Overwrite__\(ModKit.sanitize(currentProfileName))")
        try FileManager.default.createDirectory(at: modsDir.appendingPathComponent(rec.folder), withIntermediateDirectories: true)
        appendMod(rec)
        return rec
    }

    /// Before running a tool: remember which unmanaged files already exist (the player's own files stay theirs).
    public func beginToolRun() throws -> CaptureSnapshot {
        CaptureSnapshot(unmanaged: Set(try deployer.unmanagedFiles().map { $0.lowercased() }))
    }

    /// Like beginToolRun, plus an empty dedicated output folder for tools with an output mod. Returns the snapshot and
    /// the full argument list (the tool's own arguments + -o:"Z:\…\").
    public func beginToolRun(_ t: ToolEntry) throws -> (CaptureSnapshot, [String]) {
        var snap = try beginToolRun()
        var args = t.arguments.split(separator: " ").map(String.init)
        if let name = t.outputMod {
            let dir = home.appendingPathComponent("cache/tool-output/\(ModKit.sanitize(name))")
            Installer.forceRemove(dir)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            snap.outputDir = dir; snap.outputMod = name
            args.append("-o:" + ModKit.winPath(dir, dir: true))
        }
        return (snap, args)
    }

    /// The tool's output folder → its output mod (content replaced as a whole: a new run is a new generation; a new
    /// mod goes last before Overwrite, enabled). Returns the number of files; 0 = the tool wrote nothing (the old output stays).
    @discardableResult
    func installToolOutput(_ snap: CaptureSnapshot) throws -> Int {
        guard let dir = snap.outputDir, let name = snap.outputMod else { return 0 }
        let fm = FileManager.default
        var count = 0
        if let en = fm.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey]) {
            for case let u as URL in en where (try? u.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true { count += 1 }
        }
        guard count > 0 else { Installer.forceRemove(dir); return 0 }
        if let old = mods.first(where: { $0.name == name }) {
            // same mod, new content: keeps its place and on/off state in every profile
            let staging = stagingFolder(old)
            Installer.forceRemove(staging)
            try fm.moveItem(at: dir, to: staging)
            var p = try currentProfile()
            if !p.mods.contains(where: { $0.id == old.id }) {
                p.mods.append(ProfileMod(id: old.id, enabled: true))
                if let ow = p.mods.firstIndex(where: { ModKit.isOverwrite($0.id) }) { p.mods.append(p.mods.remove(at: ow)) }
                try saveProfile(p)
            }
        } else {
            try addMod(name: name, from: dir)   // last before Overwrite, enabled
        }
        return count
    }

    /// After the tool exited: new files in Data/ and deployed files the tool changed go into Overwrite, then deploy so
    /// they are managed again. Returns the captured paths (relative to the game folder).
    @discardableResult
    public func finishToolRun(_ snap: CaptureSnapshot) throws -> [String] { try finishToolRunCounting(snap).captured }

    /// finishToolRun + how many files went into the tool's output mod.
    public func finishToolRunCounting(_ snap: CaptureSnapshot) throws -> (captured: [String], output: Int) {
        let fm = FileManager.default
        let installed = try installToolOutput(snap)
        let newFiles = try deployer.unmanagedFiles().filter { !snap.unmanaged.contains($0.lowercased()) && $0.hasPrefix("Data/") }
        let changed = try deployer.verify().changed.filter { $0.hasPrefix("Data/") }
        if newFiles.isEmpty && changed.isEmpty {
            if installed > 0 { try deploy(try currentProfile()) }
            return ([], installed)
        }
        let ow = try ensureOverwrite()
        let owDir = stagingFolder(ow)
        for rel in newFiles + changed {
            let src = gameDir.appendingPathComponent(rel)
            let dst = owDir.appendingPathComponent(String(rel.dropFirst("Data/".count)))
            try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.removeItem(at: dst)
            if newFiles.contains(rel) { try fm.moveItem(at: src, to: dst) }   // new: move (deploy puts a clone back)
            else { try cloneOrCopy(src, dst) }                                 // changed deployed file: keep the tool's version
        }
        var p = try currentProfile()
        p.mods.removeAll { $0.id == ow.id }
        p.mods.append(ProfileMod(id: ow.id, enabled: true))
        try saveProfile(p)
        try deploy(p)
        return ((newFiles + changed).sorted(), installed)
    }
}

extension ModKit {
    /// Files mods created while the game ran (an SKSE plugin writing its .ini, a script cache…): unmanaged files inside
    /// folders SkyrimMT itself created. Without the mods those folders wouldn't exist, so these files belong to the
    /// mods — never to the player (files the player put elsewhere are not touched).
    public func generatedFiles() throws -> [String] {
        let m = try Manifest.load(deployer.layout.manifestURL)
        // folders SkyrimMT created + folders the game/mods create for their output (Community Shaders' compiled
        // shader cache: per setup, ~3,500 files, 5 minutes to rebuild)
        let created = m.createdDirs.map { $0.lowercased() + "/" } + ["data/shadercache/"]
        guard m.createdDirs.count > 0 else { return [] }
        // written while playing = modified after the last deploy. Mod files that lost their deploy record keep their
        // archive dates (2014–2022 in the 2026-10-18 incident: 24,918 stale files ended up in Overwrite) — not ours to take.
        let deployedAt = (try? deployer.layout.manifestURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        let cutoff = deployedAt.addingTimeInterval(-120)   // clock/rounding slack
        return try deployer.unmanagedFiles().filter { f in
            let l = f.lowercased()
            guard created.contains(where: { l.hasPrefix($0) }) else { return false }
            let mt = (try? gameDir.appendingPathComponent(f).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantFuture
            return mt >= cutoff
        }
    }

    /// Move generated files into the Overwrite mod of the current profile (kept, managed, and out of the game folder
    /// when another profile or a purge is applied).
    @discardableResult
    public func captureGenerated() throws -> [String] {
        // + deployed files the game or a plugin rewrote (settings INIs, logs): they belong to this profile too — left in
        // the game folder they would carry into the next profile. Program files are restored instead (restoreDriftedBinaries).
        let edited = ((try? deployer.verify().changed) ?? []).filter { $0.hasPrefix("Data/") && !["dll", "exe", "bsa"].contains(($0 as NSString).pathExtension.lowercased()) }
        let files = Array(Set(try generatedFiles() + edited)).sorted()
        guard !files.isEmpty else { return [] }
        let ow = try ensureOverwrite()
        let owDir = stagingFolder(ow)
        for rel in files {
            let dst = rel.hasPrefix("Data/") ? owDir.appendingPathComponent(String(rel.dropFirst(5)))
                                             : owDir.appendingPathComponent(Deployer.rootFolder).appendingPathComponent(rel)
            try FileManager.default.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: dst)
            try FileManager.default.moveItem(at: gameDir.appendingPathComponent(rel), to: dst)
        }
        var p = try currentProfile()
        if !p.mods.contains(where: { $0.id == ow.id }) { p.mods.append(ProfileMod(id: ow.id, enabled: true)); try saveProfile(p) }
        return files
    }
}
