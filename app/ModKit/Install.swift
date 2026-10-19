// ModKit install pipeline (PLAN §8.4): archive → extract (system bsdtar/libarchive: zip, 7z, rar, tar) → detect the
// layout → (FOMOD wizard) → prepared folder laid out like Data/ (+ "__root__" for game-folder files) → ModKit.addMod.
// Crash safety: work happens in $SKYRIM_HOME/cache/install/<uuid>; the finished folder is moved into staging with a
// single rename (ModKit.addMod), so an interrupted install leaves only a temp folder, removed by cleanupStale().
import Foundation
import CryptoKit

func SHA256Hex(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }

public enum ModLayout: Equatable {
    case fomod(root: URL, config: URL)     // root = folder that contains "fomod/"
    case scriptOnly(root: URL)             // fomod/script.cs without ModuleConfig.xml: not supported
    case skse(root: URL)                   // SKSE runtime: loader + DLLs for the game folder, Data/ for scripts
    case gameRoot(root: URL)               // only DLL/EXE files at the top (e.g. SSE Engine Fixes part 2): game folder
    case data(root: URL)                   // plain mod: root is the Data folder
    case unknown(root: URL)
}

public enum InstallError: Error, CustomStringConvertible {
    case extract(String), layout(String)
    public var description: String { switch self { case .extract(let m): return "Couldn't unpack: \(m)"; case .layout(let m): return m } }
}

public enum Installer {
    /// Folder names that only appear at the top of Data/ (case-insensitive).
    static let dataFolders: Set<String> = ["meshes", "textures", "scripts", "interface", "skse", "sound", "music", "seq",
        "strings", "lodsettings", "shadersfx", "grass", "dyndolod", "video", "materials", "calientetools", "netscriptframework",
        "skyproc patchers", "facegen", "tools", "nemesis_engine", "pandora_engine", "source", "terrain", "trees", "distantlod", "lsdata"]
    static let dataExtensions: Set<String> = ["esp", "esm", "esl", "bsa", "ba2", "ini", "modgroups", "txt"]

    /// bsdtar from the base system (libarchive 3.7.x) handles most archives; what it can't (zip Deflate64, RAR with
    /// large dictionaries — seen in a real collection) falls back to the official 7-Zip for macOS (7zz, LGPL + unRAR
    /// licence, github.com/ip7z/7zip), fetched once into `toolsDir` with its published SHA-256.
    public static func extract(_ archive: URL, to dir: URL, toolsDir: URL? = nil) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let (code, msg) = run("/usr/bin/bsdtar", ["-xf", archive.path, "-C", dir.path])
        if code == 0 { makeWritable(dir); return }
        guard let tools = toolsDir else { throw InstallError.extract(msg.isEmpty ? "bsdtar failed (\(code))" : msg) }
        let sz = try sevenZip(tools)
        try? FileManager.default.removeItem(at: dir); try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let (c2, m2) = run(sz.path, ["x", "-y", "-bd", "-o" + dir.path, archive.path])
        guard c2 == 0 else { throw InstallError.extract("bsdtar: \(msg); 7-Zip: \(m2.split(separator: "\n").suffix(3).joined(separator: " "))") }
        makeWritable(dir)
    }

    /// Archives can carry read-only folders (seen: music mods); left as they are, SkyrimMT couldn't delete its own
    /// work folders (cache/install grew) or a mod's files later. Owner-writable everywhere; nothing else changes.
    public static func makeWritable(_ root: URL) {
        guard let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil, options: []) else { return }
        for case let u as URL in en {
            var st = stat()
            guard lstat(u.path, &st) == 0, (st.st_mode & S_IFMT) != S_IFLNK, st.st_mode & S_IWUSR == 0 else { continue }
            chmod(u.path, st.st_mode | S_IWUSR | ((st.st_mode & S_IFMT) == S_IFDIR ? S_IXUSR : 0))
        }
    }

    /// Remove a tree even if parts of it are read-only.
    public static func forceRemove(_ url: URL) {
        if (try? FileManager.default.removeItem(at: url)) != nil { return }
        var st = stat(); if lstat(url.path, &st) == 0 { chmod(url.path, st.st_mode | S_IWUSR | S_IXUSR) }
        makeWritable(url)
        try? FileManager.default.removeItem(at: url)
    }

    static func run(_ exe: String, _ args: [String]) -> (Int32, String) {
        let p = Process(); p.executableURL = URL(fileURLWithPath: exe); p.arguments = args
        let err = Pipe(); p.standardError = err; p.standardOutput = err
        do { try p.run() } catch { return (-1, "\(error)") }
        let d = err.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        return (p.terminationStatus, String(decoding: d, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// The official 7-Zip for macOS (ip7z/7zip latest release, *-mac.tar.xz), checksum-verified.
    static func sevenZip(_ tools: URL) throws -> URL {
        let dir = tools.appendingPathComponent("7zip"), exe = dir.appendingPathComponent("7zz")
        if FileManager.default.isExecutableFile(atPath: exe.path) { return exe }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let api = try? Data(contentsOf: URL(string: "https://api.github.com/repos/ip7z/7zip/releases/latest")!),
              let j = try? JSONSerialization.jsonObject(with: api) as? [String: Any],
              let a = (j["assets"] as? [[String: Any]])?.first(where: { ($0["name"] as? String)?.hasSuffix("-mac.tar.xz") == true }),
              let s = a["browser_download_url"] as? String, let url = URL(string: s), let digest = a["digest"] as? String,
              let data = try? Data(contentsOf: url) else { throw InstallError.extract("couldn't download 7-Zip for macOS") }
        guard "sha256:" + SHA256Hex(data) == digest else { throw InstallError.extract("7-Zip download checksum mismatch") }
        let tar = dir.appendingPathComponent("7z-mac.tar.xz"); try data.write(to: tar)
        let (c, m) = run("/usr/bin/tar", ["-xJf", tar.path, "-C", dir.path]); try? FileManager.default.removeItem(at: tar)
        guard c == 0, FileManager.default.isExecutableFile(atPath: exe.path) else { throw InstallError.extract("couldn't unpack 7-Zip: \(m)") }
        _ = run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", dir.path])
        return exe
    }

    static func entries(_ dir: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0 != ".DS_Store" && $0 != "__MACOSX" }
    }
    static func isDir(_ u: URL) -> Bool { var d: ObjCBool = false; return FileManager.default.fileExists(atPath: u.path, isDirectory: &d) && d.boolValue }

    /// Detect the layout; one wrapper folder (e.g. "ModName v1.2/") is stripped, a "Data/" top folder is used as root.
    public static func detect(_ dir: URL) -> ModLayout {
        var root = dir
        for _ in 0..<2 {
            let e = entries(root)
            if let f = e.first(where: { $0.lowercased() == "fomod" }), isDir(root.appendingPathComponent(f)) {
                let fom = root.appendingPathComponent(f)
                if let cfg = entries(fom).first(where: { $0.lowercased() == "moduleconfig.xml" }) {
                    return .fomod(root: root, config: fom.appendingPathComponent(cfg))
                }
                if entries(fom).contains(where: { $0.lowercased() == "script.cs" }) { return .scriptOnly(root: root) }
            }
            if e.contains(where: { $0.lowercased() == "skse64_loader.exe" }) { return .skse(root: root) }
            if let d = e.first(where: { $0.lowercased() == "data" }), isDir(root.appendingPathComponent(d)), e.count <= 3 {
                return .data(root: root.appendingPathComponent(d))
            }
            // only DLL/EXE (+ notes) at the top and no folders: files for the game folder (SSE Engine Fixes part 2)
            let bins = e.filter { ["dll", "exe"].contains(($0 as NSString).pathExtension.lowercased()) }
            if !bins.isEmpty && !e.contains(where: { isDir(root.appendingPathComponent($0)) })
                && e.allSatisfy({ ["dll", "exe", "txt", "md", "toml", "ini"].contains(($0 as NSString).pathExtension.lowercased()) }) {
                return .gameRoot(root: root)
            }
            if e.contains(where: { dataFolders.contains($0.lowercased()) || dataExtensions.contains(($0 as NSString).pathExtension.lowercased()) && $0.lowercased() != "readme.txt" }) {
                return .data(root: root)
            }
            let dirs = e.filter { isDir(root.appendingPathComponent($0)) }
            if dirs.count == 1 && e.count <= 2 { root = root.appendingPathComponent(dirs[0]); continue }   // wrapper folder
            break
        }
        return .unknown(root: root)
    }

    /// Prepare the folder that becomes the mod's staging folder.
    ///  - data: copy the Data root as is
    ///  - skse: top-level files → __root__/ (loader, DLLs); its Data/ folder → Data
    ///  - fomod: run the installer (selections must be made)
    public static func prepare(_ layout: ModLayout, fomod: FomodInstaller? = nil, into out: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: out, withIntermediateDirectories: true)
        switch layout {
        case .data(let root), .unknown(let root):
            try copyTree(root, to: out, skipFomod: false)
        case .skse(let root):
            for name in entries(root) {
                let src = root.appendingPathComponent(name)
                if name.lowercased() == "data" && isDir(src) { try copyTree(src, to: out, skipFomod: false); continue }
                if isDir(src) { continue }   // src/ and other folders of the SKSE archive are not needed in the game
                let ext = (name as NSString).pathExtension.lowercased()
                guard ext == "exe" || ext == "dll" else { continue }
                let dst = out.appendingPathComponent(Deployer.rootFolder).appendingPathComponent(name)
                try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
                try cloneOrCopy(src, dst)
            }
        case .gameRoot(let root):
            for name in entries(root) where ["dll", "exe", "toml", "ini"].contains((name as NSString).pathExtension.lowercased()) {
                let dst = out.appendingPathComponent(Deployer.rootFolder).appendingPathComponent(name)
                try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
                try cloneOrCopy(root.appendingPathComponent(name), dst)
            }
        case .fomod(let root, _):
            guard let fomod else { throw InstallError.layout("this mod has an installer: choose its options first") }
            let problems = fomod.problems()
            guard problems.isEmpty else { throw InstallError.layout(problems.joined(separator: "; ")) }
            try fomod.install(from: root, to: out)
        case .scriptOnly:
            throw InstallError.layout("This mod uses a C# script installer, which SkyrimMT doesn't run. Install it as plain files or pick the files by hand.")
        }
    }
}

extension ModKit {
    var installWork: URL { home.appendingPathComponent("cache/install") }

    /// Leftovers of interrupted installs (PLAN §8.4 step 5: "a journal not marked done is rolled back").
    public func cleanupStale() {
        Installer.forceRemove(installWork)
        Installer.forceRemove(home.appendingPathComponent("incoming"))
    }

    /// Unpack an archive for installation; the caller inspects the layout (and runs the FOMOD wizard) before
    /// finishInstall. Returns the work folder and the detected layout.
    public func beginInstall(archive: URL) throws -> (work: URL, layout: ModLayout) {
        let work = installWork.appendingPathComponent(UUID().uuidString)
        do { try Installer.extract(archive, to: work.appendingPathComponent("x"), toolsDir: home.appendingPathComponent("tools")) }
        catch { try? FileManager.default.removeItem(at: work); throw error }
        return (work, Installer.detect(work.appendingPathComponent("x")))
    }

    @discardableResult
    public func finishInstall(work: URL, layout: ModLayout, name: String, version: String = "", fomod: FomodInstaller? = nil,
                              source: SourceArchive? = nil, nexus: NexusRef? = nil) throws -> ModRecord {
        defer { try? FileManager.default.removeItem(at: work) }
        let out = work.appendingPathComponent("out")
        try Installer.prepare(layout, fomod: fomod, into: out)
        var rec = try addMod(name: name, from: out, version: version, nexus: nexus)
        if source != nil || fomod != nil {
            rec.source = source; rec.installChoices = fomod?.choices
            if let i = mods.firstIndex(where: { $0.id == rec.id }) { replaceMod(at: i, with: rec) }
        }
        return rec
    }

    /// Plugin states for FOMOD fileDependency checks, from the current load order.
    /// `stagedProfileMods`: plugins of these installed (not yet deployed) mods count as active — during a collection
    /// install the mods a FOMOD depends on are in staging, not in the game folder yet.
    public func fomodContext(gameVersion: String, stagedProfileMods: [String] = []) -> FomodContext {
        let lo = loadOrder()
        var active = Set(lo.activeOrder.map { $0.lowercased() })
        let installed = Set(lo.headers.keys)
        for id in stagedProfileMods {
            guard let m = mod(id) else { continue }
            for f in (try? FileManager.default.contentsOfDirectory(atPath: stagingFolder(m).path)) ?? []
                where PluginParser.extensions.contains((f as NSString).pathExtension.lowercased()) { active.insert(f.lowercased()) }
        }
        return FomodContext(pluginState: { name in
            let k = name.lowercased()
            return active.contains(k) ? .active : installed.contains(k) ? .inactive : .missing
        }, gameVersion: gameVersion)
    }
}
