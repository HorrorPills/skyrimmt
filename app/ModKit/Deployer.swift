// ModKit deployer (PLAN §8.8): the ONE place that writes into the game folder.
//   plan(mods)  → winners per file (case-insensitive paths), conflicts per mod pair
//   deploy(mods) → diff against the manifest, journaled apply (APFS clone → hardlink → copy, in parallel), atomic manifest commit
//   purge()     → remove everything we deployed, restore backed-up files, remove folders we created
//   verify()    → cheap drift check of deployed files (inode/size/mtime), never fixes anything by itself
// Staging layout: every mod folder holds its files exactly as under Data/; a top-level "__root__" folder holds files
// for the game folder itself (SKSE's loader and DLLs).
// Crash safety: the planned operations are written to journal.tsv before anything changes; every vanilla/unmanaged
// file moved aside is appended (fsync'd) as it happens. recover() re-applies a leftover journal idempotently.
import Foundation
import Darwin

public struct GameLayout {
    public let gameDir: URL        // folder with SkyrimSE.exe and Data/
    public let stateDir: URL       // manifest, journal, baseline ($SKYRIM_HOME/config/modkit)
    public let backupDir: URL      // files moved aside while a mod replaces them ($SKYRIM_HOME/backups/modkit)
    public init(gameDir: URL, stateDir: URL, backupDir: URL) { self.gameDir = gameDir; self.stateDir = stateDir; self.backupDir = backupDir }
    var manifestURL: URL { stateDir.appendingPathComponent("manifest.tsv") }
    var journalURL: URL { stateDir.appendingPathComponent("journal.tsv") }
    var baselineURL: URL { stateDir.appendingPathComponent("baseline.tsv") }
}

/// A mod as the deployer sees it: its staging folder, in priority order (later wins).
public struct StagedMod: Equatable {
    public let id: String
    public let folder: URL
    public init(id: String, folder: URL) { self.id = id; self.folder = folder }
}

public struct PlannedFile: Equatable {
    public let rel: String         // path relative to the game folder, original spelling ("Data/Textures/x.dds")
    public let source: String      // absolute path of the staging file
    public let modID: String
}

/// Files that break on macOS (DXMT is stricter than Windows drivers) and are left out of the deploy so the game's own
/// version is used. Each rule was found with a real mod (docs/STATUS.md "macOS compatibility rules").
public enum MacCompat {
    /// A texture under textures/cubemaps/ that isn't a cubemap (e.g. The Eyes of Beauty's 2D BC7 "eyecubemap.dds"):
    /// Skyrim samples these as cubes; Windows tolerates the 2D texture, DXMT renders white (white eyes in RaceMenu).
    public static func hideReason(rel: String, source: String) -> String? {
        let l = rel.lowercased()
        // Community Shaders' Upscaling feature builds a Direct3D 12 proxy swap chain at start-up (DLSS/FSR frame
        // generation): macOS has Direct3D 11 only (DXMT) → E_NOINTERFACE, the game quits within seconds (crash log
        // 2026-10-18, A Dragonborn's Fate). CS loads a feature only when its Features/<name>.ini exists.
        if l == "data/shaders/features/upscaling.ini" { return "Community Shaders Upscaling needs Direct3D 12 (not on macOS) — left out so the game starts" }
        guard l.hasPrefix("data/textures/cubemaps/"), l.hasSuffix(".dds"), let h = FileHandle(forReadingAtPath: source) else { return nil }
        defer { try? h.close() }
        let b = h.readData(ofLength: 148)
        guard b.count >= 128, b.prefix(4) == Data("DDS ".utf8) else { return nil }
        let caps2 = b.u32(112)
        var cube = caps2 & 0x200 != 0
        if b.count >= 148, b.subdata(in: 84..<88) == Data("DX10".utf8) { cube = cube || (b.u32(136) & 0x4 != 0) }
        return cube ? nil : "not a cubemap (renders white on macOS)"
    }
}

public struct DeployPlan {
    public var files: [String: PlannedFile] = [:]           // key = lowercased rel
    public var hidden: [String: String] = [:]               // rel → why it was left out (MacCompat)
    /// (winner, loser) → number of files the winner overrides
    public var conflicts: [String: [String: Int]] = [:]
    public var overridden: [String: [String]] = [:]         // key → mod ids that lost this file
}

public struct DeployReport {
    public var linked = 0, cloned = 0, copied = 0, removed = 0, backedUp = 0, restored = 0, unchanged = 0
    public var keptModified: [String] = []                   // deployed files changed outside SkyrimMT: left in place
    public var seconds = 0.0
}

public struct VerifyReport {
    public var missing: [String] = []
    public var changed: [String] = []
    public var ok: Bool { missing.isEmpty && changed.isEmpty }
}

public enum DeployError: Error, CustomStringConvertible {
    case io(String), locked(String), simulatedCrash
    public var description: String {
        switch self { case .io(let m): return m; case .locked(let m): return m; case .simulatedCrash: return "simulated crash" }
    }
}

struct ManifestEntry: Equatable {
    var rel: String, modID: String, source: String
    var dev: Int64, ino: UInt64, size: Int64, mtimeNs: Int64
    var srcIno: UInt64 = 0     // the staging file's inode when placed: replaced files (update, reinstall, restore) differ
}

struct Manifest {
    var entries: [String: ManifestEntry] = [:]
    var backups: [String: String] = [:]      // key → backup path relative to backupDir
    var createdDirs: Set<String> = []        // rel paths of folders we created (removed on purge when empty)

    // TSV: "F\trel\tmodID\tsource\tdev\tino\tsize\tmtime[\tsrcIno]" / "B\tkey\tbackupRel" / "D\trel"
    static func load(_ url: URL) throws -> Manifest {
        var m = Manifest()
        guard FileManager.default.fileExists(atPath: url.path) else { return m }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        // byte-level parse (Swift's String.split costs ~7 µs per line: 500k-file manifests are read on every deploy)
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let b = raw.bindMemory(to: UInt8.self)
            var fields: [(Int, Int)] = []; fields.reserveCapacity(8)
            func str(_ r: (Int, Int)) -> String { String(decoding: UnsafeBufferPointer(rebasing: b[r.0..<r.1]), as: UTF8.self) }
            func int(_ r: (Int, Int)) -> Int64 {
                var v: Int64 = 0, i = r.0, neg = false
                if i < r.1, b[i] == 45 { neg = true; i += 1 }
                while i < r.1 { let c = b[i]; guard c >= 48 && c <= 57 else { return 0 }; v = v &* 10 &+ Int64(c - 48); i += 1 }
                return neg ? -v : v
            }
            var start = 0
            m.entries.reserveCapacity(b.count / 160)
            while start < b.count {
                var end = start
                while end < b.count && b[end] != 10 { end += 1 }
                fields.removeAll(keepingCapacity: true)
                var fs = start
                for i in start..<end where b[i] == 9 { fields.append((fs, i)); fs = i + 1 }
                fields.append((fs, end))
                if end > start {
                    switch b[start] {
                    case 70 where (fields.count == 8 || fields.count == 9) && fields[0].1 - fields[0].0 == 1:   // F
                        let rel = str(fields[1])
                        m.entries[rel.lowercased()] = ManifestEntry(rel: rel, modID: str(fields[2]), source: str(fields[3]), dev: int(fields[4]),
                                                                    ino: UInt64(bitPattern: int(fields[5])), size: int(fields[6]), mtimeNs: int(fields[7]),
                                                                    srcIno: fields.count == 9 ? UInt64(bitPattern: int(fields[8])) : 0)
                    case 66 where fields.count == 3 && fields[0].1 - fields[0].0 == 1: m.backups[str(fields[1])] = str(fields[2])   // B
                    case 68 where fields.count == 2 && fields[0].1 - fields[0].0 == 1: m.createdDirs.insert(str(fields[1]))          // D
                    default: break
                    }
                }
                start = end + 1
            }
        }
        return m
    }

    func save(_ url: URL) throws {
        var out = "# SkyrimMT deploy manifest v1\n"
        out.reserveCapacity(entries.count * 160)
        for (_, e) in entries.sorted(by: { $0.key < $1.key }) {
            out += "F\t\(e.rel)\t\(e.modID)\t\(e.source)\t\(e.dev)\t\(e.ino)\t\(e.size)\t\(e.mtimeNs)\t\(e.srcIno)\n"
        }
        for (k, b) in backups.sorted(by: { $0.key < $1.key }) { out += "B\t\(k)\t\(b)\n" }
        for d in createdDirs.sorted() { out += "D\t\(d)\n" }
        try atomicWrite(out, to: url)
    }
}

func atomicWrite(_ text: String, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).tmp.\(getpid())")
    guard let data = text.data(using: .utf8) else { throw DeployError.io("encode \(url.path)") }
    let fd = open(tmp.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
    guard fd >= 0 else { throw DeployError.io("open \(tmp.path): \(String(cString: strerror(errno)))") }
    let ok = data.withUnsafeBytes { p -> Bool in
        var off = 0
        while off < p.count { let n = write(fd, p.baseAddress! + off, p.count - off); if n <= 0 { return false }; off += n }
        return true
    }
    fsync(fd); close(fd)
    guard ok, rename(tmp.path, url.path) == 0 else { unlink(tmp.path); throw DeployError.io("write \(url.path)") }
}

struct FileStat { let dev: Int64; let ino: UInt64; let size: Int64; let mtimeNs: Int64; let isDir: Bool }
func lstatPath(_ path: String) -> FileStat? {
    var st = stat()
    guard lstat(path, &st) == 0 else { return nil }
    return FileStat(dev: Int64(st.st_dev), ino: UInt64(st.st_ino), size: Int64(st.st_size),
                    mtimeNs: Int64(st.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(st.st_mtimespec.tv_nsec),
                    isDir: (st.st_mode & S_IFMT) == S_IFDIR)
}

public final class Deployer {
    public let layout: GameLayout
    /// Test hook: throw DeployError.simulatedCrash after this many file operations (crash-recovery tests).
    public var failAfterOps: Int?
    private var ops = 0
    public static let rootFolder = "__root__"

    public init(layout: GameLayout) { self.layout = layout }

    private let opsLock = NSLock()
    private func tick() throws {
        guard let n = failAfterOps else { return }
        opsLock.lock(); ops += 1; let over = ops > n; opsLock.unlock()
        if over { throw DeployError.simulatedCrash }
    }

    // MARK: plan

    /// Winner per file: mods in priority order, later wins. Paths compare case-insensitively (Windows/APFS semantics);
    /// the winner's spelling is used.
    public func plan(_ mods: [StagedMod]) -> DeployPlan {
        // scan mod folders in parallel (I/O-bound: 2,000 mods / 500k files), merge in priority order → same result
        // as a sequential scan
        typealias Scan = (files: [(rel: String, src: String)], hidden: [(String, String)])
        var scans = [Scan](repeating: ([], []), count: mods.count)
        scans.withUnsafeMutableBufferPointer { out in
            DispatchQueue.concurrentPerform(iterations: mods.count) { i in out[i] = Deployer.scan(mods[i]) }
        }
        var plan = DeployPlan()
        plan.files.reserveCapacity(scans.reduce(0) { $0 + $1.files.count })
        for (mod, sc) in zip(mods, scans) {
            for (rel, why) in sc.hidden { plan.hidden[rel] = why }
            for f in sc.files {
                let key = f.rel.lowercased()
                if let prev = plan.files[key], prev.modID != mod.id {
                    plan.conflicts[mod.id, default: [:]][prev.modID, default: 0] += 1
                    plan.overridden[key, default: []].append(prev.modID)
                }
                plan.files[key] = PlannedFile(rel: f.rel, source: f.src, modID: mod.id)
            }
        }
        return plan
    }

    private static func scan(_ mod: StagedMod) -> (files: [(rel: String, src: String)], hidden: [(String, String)]) {
        var files: [(rel: String, src: String)] = [], hidden: [(String, String)] = []
        let base = mod.folder.path
        // readdir reports each entry's type: no lstat per file (500k files: the scan is most of a plan)
        func walk(_ dir: String, _ prefix: String) {
            guard let d = opendir(dir) else { return }
            defer { closedir(d) }
            while let e = readdir(d) {
                let name = withUnsafePointer(to: e.pointee.d_name) { $0.withMemoryRebound(to: CChar.self, capacity: Int(e.pointee.d_namlen) + 1) { String(cString: $0) } }
                if name == "." || name == ".." { continue }
                let path = dir + "/" + name, relAny = prefix.isEmpty ? name : prefix + "/" + name
                var type = e.pointee.d_type
                if type == DT_UNKNOWN { type = (lstatPath(path)?.isDir ?? false) ? UInt8(DT_DIR) : UInt8(DT_REG) }
                if type == DT_DIR { walk(path, relAny); continue }
                let rel: String
                if relAny.hasPrefix(Deployer.rootFolder + "/") { rel = String(relAny.dropFirst(Deployer.rootFolder.count + 1)) }
                else { rel = "Data/" + relAny }
                if name == ".DS_Store" { continue }
                if name.lowercased().hasSuffix(".mohidden") { continue }   // hidden by the player (MO2 convention)
                if let why = MacCompat.hideReason(rel: rel, source: path) { hidden.append((rel, why)); continue }
                files.append((rel, path))
            }
        }
        walk(base, "")
        return (files, hidden)
    }

    // MARK: deploy

    public func deploy(_ mods: [StagedMod]) throws -> DeployReport {
        try recoverIfNeeded()
        return try apply(plan(mods).files)
    }

    func apply(_ desired: [String: PlannedFile]) throws -> DeployReport {
        let t0 = Date()
        var report = DeployReport()
        var m = try Manifest.load(layout.manifestURL)
        try ensureBaseline()
        // diff
        var removes: [String] = [], adds: [String] = []
        for (k, e) in m.entries where desired[k]?.source != e.source || desired[k]?.rel != e.rel { removes.append(k) }
        for (k, p) in desired where m.entries[k]?.source != p.source || m.entries[k]?.rel != p.rel { adds.append(k) }
        // same source path, new content (a mod updated/reinstalled in place): placed again
        let (stale, backfill) = staleCheck(m, desired)
        removes += stale; adds += stale
        for (k, ino) in backfill { m.entries[k]?.srcIno = ino }
        report.unchanged = desired.count - adds.count
        if removes.isEmpty && adds.isEmpty {
            if !backfill.isEmpty { try m.save(layout.manifestURL) }   // manifests from before srcIno: recorded once
            report.seconds = Date().timeIntervalSince(t0); return report
        }
        // journal: the full target state, written before anything changes
        var j = "# SkyrimMT deploy journal v1\n"
        for k in adds.sorted() { let p = desired[k]!; j += "A\t\(p.rel)\t\(p.modID)\t\(p.source)\n" }
        for k in removes.sorted() { j += "R\t\(k)\n" }
        try atomicWrite(j, to: layout.journalURL)
        try execute(&m, desired: desired, removes: removes, adds: adds, report: &report)
        try m.save(layout.manifestURL)
        try? FileManager.default.removeItem(at: layout.journalURL)
        report.seconds = Date().timeIntervalSince(t0)
        return report
    }

    /// Deployed entries whose staging file changed since it was placed: another inode (the file was replaced — update,
    /// reinstall, snapshot restore), else size or mtime second (clones and links keep both; seconds because a plain-copy
    /// fallback may not keep nanoseconds). Checked in parallel (~1 µs per file). Entries recorded before the inode was
    /// kept get it filled in (`backfill`).
    func staleKeys(_ m: Manifest, _ desired: [String: PlannedFile]) -> [String] { staleCheck(m, desired).stale }

    func staleCheck(_ m: Manifest, _ desired: [String: PlannedFile]) -> (stale: [String], backfill: [(String, UInt64)]) {
        let same: [(String, ManifestEntry)] = desired.compactMap { k, p in
            guard let e = m.entries[k], e.source == p.source, e.rel == p.rel else { return nil }
            return (k, e)
        }
        var flag = [UInt8](repeating: 0, count: same.count)      // 1 stale, 2 needs its inode recorded
        var inos = [UInt64](repeating: 0, count: same.count)
        flag.withUnsafeMutableBufferPointer { out in
            inos.withUnsafeMutableBufferPointer { ino in
                try? parallel(same.count) { i in
                    let e = same[i].1
                    guard let st = lstatPath(e.source) else { return }   // gone: the deploy reports it when placing
                    // SkyrimMT's built-in files are new copies after every app install: their size + date decide
                    if e.srcIno != 0 && st.ino != e.srcIno && !e.modID.hasPrefix("builtin:") { out[i] = 1; return }
                    if st.size != e.size || st.mtimeNs / 1_000_000_000 != e.mtimeNs / 1_000_000_000 { out[i] = 1; return }
                    if e.srcIno == 0 { out[i] = 2; ino[i] = st.ino }
                }
            }
        }
        return (same.indices.filter { flag[$0] == 1 }.map { same[$0].0 }, same.indices.filter { flag[$0] == 2 }.map { (same[$0].0, inos[$0]) })
    }

    private func execute(_ m: inout Manifest, desired: [String: PlannedFile], removes: [String], adds: [String],
                         report: inout DeployReport) throws {
        let game = layout.gameDir.path
        let addSet = Set(adds)
        // 1. removals (parallel): only files that are still exactly what we deployed
        let rem: [(String, ManifestEntry)] = removes.compactMap { k in m.entries[k].map { (k, $0) } }
        var outcome = [UInt8](repeating: 0, count: rem.count)          // 0 gone already, 1 removed, 2 modified → kept
        try outcome.withUnsafeMutableBufferPointer { out in
            try parallel(rem.count) { i in
                let e = rem[i].1, path = game + "/" + e.rel
                guard let st = lstatPath(path) else { return }
                if st.ino == e.ino && st.dev == e.dev {
                    try self.tick()
                    guard unlink(path) == 0 else { throw DeployError.io("remove \(path): \(String(cString: strerror(errno)))") }
                    out[i] = 1
                } else { out[i] = 2 }
            }
        }
        for (i, (k, e)) in rem.enumerated() {
            if outcome[i] == 1 { report.removed += 1 } else if outcome[i] == 2 { report.keptModified.append(e.rel) }
            m.entries[k] = nil
            if !addSet.contains(k), let b = m.backups[k] {   // put back what our file had replaced
                try tick()
                try restoreBackup(b, to: game + "/" + e.rel)
                m.backups[k] = nil; report.restored += 1
            }
        }
        report.keptModified.sort()
        // 2. additions: classify (sequential: moving files aside is rare and journaled), create folders, then place in
        //    parallel and record what landed
        var todo: [(key: String, file: PlannedFile, src: FileStat)] = []
        for k in adds {
            let p = desired[k]!, path = game + "/" + p.rel
            guard let srcSt = lstatPath(p.source) else { throw DeployError.io("missing staging file \(p.source)") }
            if let st = lstatPath(path) {
                if ours(st, srcSt) { todo.append((k, p, srcSt)); continue }   // placed before a crash: keep
                try tick()
                let b = try moveAside(path, key: k)   // a vanilla/unmanaged/leftover file occupies the path
                if m.backups[k] == nil { m.backups[k] = b }
                report.backedUp += 1
            }
            todo.append((k, p, srcSt))
        }
        var knownDirs = Set<String>()
        for t in todo {
            let dir = ((game + "/" + t.file.rel) as NSString).deletingLastPathComponent
            if knownDirs.insert(dir).inserted { try makeParents(of: game + "/" + t.file.rel, created: &m.createdDirs) }
        }
        var how = [UInt8](repeating: 0, count: todo.count)              // 0 already there, 1 clone, 2 link, 3 copy
        var stats = [FileStat?](repeating: nil, count: todo.count)
        try how.withUnsafeMutableBufferPointer { hw in
            try stats.withUnsafeMutableBufferPointer { sts in
                try parallel(todo.count) { i in
                    let t = todo[i], path = game + "/" + t.file.rel
                    if let st = lstatPath(path), self.ours(st, t.src) { sts[i] = st; return }
                    try self.tick()
                    hw[i] = try self.place(t.file.source, at: path)
                    guard let st = lstatPath(path) else { throw DeployError.io("deploy failed for \(path)") }
                    sts[i] = st
                }
            }
        }
        for (i, t) in todo.enumerated() {
            switch how[i] { case 1: report.cloned += 1; case 2: report.linked += 1; case 3: report.copied += 1; default: break }
            let st = stats[i]!
            m.entries[t.key] = ManifestEntry(rel: t.file.rel, modID: t.file.modID, source: t.file.source, dev: st.dev, ino: st.ino,
                                             size: st.size, mtimeNs: st.mtimeNs, srcIno: t.src.ino)
        }
    }

    /// The file at the target is our placement of `src`: a hardlink (same inode) or a clone/copy (clonefile and our
    /// copy keep size and nanosecond mtime).
    private func ours(_ st: FileStat, _ src: FileStat) -> Bool {
        (st.ino == src.ino && st.dev == src.dev) || (st.size == src.size && st.mtimeNs == src.mtimeNs && !st.isDir)
    }

    /// APFS clone (fastest on APFS: ~70–100 µs vs ~260 µs for link(2), measured; independent copy-on-write file, so a
    /// tool editing the deployed file can't change the staging copy) → hardlink → plain copy (keeps mtime).
    private func place(_ src: String, at dst: String) throws -> UInt8 {
        if clonefile(src, dst, 0) == 0 { return 1 }
        if errno == EEXIST { throw DeployError.io("exists: \(dst)") }
        if link(src, dst) == 0 { return 2 }
        do {
            try FileManager.default.copyItem(atPath: src, toPath: dst)
            if let a = try? FileManager.default.attributesOfItem(atPath: src)[.modificationDate] as? Date {
                try? FileManager.default.setAttributes([.modificationDate: a], ofItemAtPath: dst)
            }
            return 3
        } catch { throw DeployError.io("copy \(src) → \(dst): \(error.localizedDescription)") }
    }

    /// Run `body(0..<n)` on all cores in chunks; the first error stops the rest and is rethrown.
    private func parallel(_ n: Int, _ body: (Int) throws -> Void) throws {
        guard n > 0 else { return }
        let lock = NSLock(); var firstError: Error?
        let chunk = max(64, n / (ProcessInfo.processInfo.activeProcessorCount * 4))
        DispatchQueue.concurrentPerform(iterations: (n + chunk - 1) / chunk) { c in
            for i in (c * chunk)..<min(n, (c + 1) * chunk) {
                lock.lock(); let stop = firstError != nil; lock.unlock()
                if stop { return }
                do { try body(i) } catch { lock.lock(); if firstError == nil { firstError = error }; lock.unlock(); return }
            }
        }
        if let e = firstError { throw e }
    }

    private func makeParents(of path: String, created: inout Set<String>) throws {
        let game = layout.gameDir.path
        var dir = (path as NSString).deletingLastPathComponent
        var missing: [String] = []
        while dir.count > game.count, lstatPath(dir) == nil { missing.append(dir); dir = (dir as NSString).deletingLastPathComponent }
        for d in missing.reversed() {
            if mkdir(d, 0o755) != 0 && errno != EEXIST { throw DeployError.io("mkdir \(d): \(String(cString: strerror(errno)))") }
            created.insert(String(d.dropFirst(game.count + 1)))
        }
    }

    /// Move a file out of the game folder into backupDir, keeping its relative path; journaled (fsync) so a crash right
    /// after can still restore it. Returns the backup path relative to backupDir.
    private func moveAside(_ path: String, key: String) throws -> String {
        let rel = String(path.dropFirst(layout.gameDir.path.count + 1))
        var b = "files/" + rel
        if lstatPath(layout.backupDir.path + "/" + b) != nil { b = "extra/\(Int(Date().timeIntervalSince1970 * 1000))/" + rel }
        let dst = layout.backupDir.path + "/" + b
        try FileManager.default.createDirectory(atPath: (dst as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try appendJournal("B\t\(key)\t\(b)\n")
        guard rename(path, dst) == 0 else { throw DeployError.io("move aside \(path): \(String(cString: strerror(errno)))") }
        return b
    }

    private func restoreBackup(_ b: String, to path: String) throws {
        let src = layout.backupDir.path + "/" + b
        guard lstatPath(src) != nil else { return }
        if lstatPath(path) != nil { return }   // something else is there now: keep the backup, don't clobber
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        guard rename(src, path) == 0 else { throw DeployError.io("restore \(path): \(String(cString: strerror(errno)))") }
    }

    private func appendJournal(_ line: String) throws {
        let fd = open(layout.journalURL.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard fd >= 0 else { throw DeployError.io("journal: \(String(cString: strerror(errno)))") }
        defer { close(fd) }
        let ok = line.withCString { write(fd, $0, strlen($0)) } > 0
        fsync(fd)
        if !ok { throw DeployError.io("journal write failed") }
    }

    // MARK: recovery

    public var needsRecovery: Bool { FileManager.default.fileExists(atPath: layout.journalURL.path) }

    /// Finish an interrupted deploy: the journal holds the complete target state (A lines) plus files moved aside
    /// (B lines). Re-applying is idempotent: links that already exist are recognised by inode.
    public func recoverIfNeeded() throws {
        guard needsRecovery else { return }
        let text = try String(contentsOf: layout.journalURL, encoding: .utf8)
        var m = try Manifest.load(layout.manifestURL)
        var desired: [String: PlannedFile] = [:]
        var removes: [String] = []
        for line in text.split(separator: "\n") {
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            switch f.first {
            case "A" where f.count == 4: desired[f[1].lowercased()] = PlannedFile(rel: f[1], source: f[3], modID: f[2])
            case "R" where f.count == 2: removes.append(f[1])
            case "B" where f.count == 3: if m.backups[f[1]] == nil { m.backups[f[1]] = f[2] }
            default: continue
            }
        }
        // unchanged entries of the old manifest stay part of the target
        let removeSet = Set(removes)
        for (k, e) in m.entries where desired[k] == nil && !removeSet.contains(k) {
            desired[k] = PlannedFile(rel: e.rel, source: e.source, modID: e.modID)
        }
        var report = DeployReport()
        let adds = desired.keys.filter { m.entries[$0]?.source != desired[$0]!.source }
        // removals whose file is already gone are fine; entries already re-linked count as unchanged
        try execute(&m, desired: desired, removes: removes.filter { m.entries[$0] != nil }, adds: adds, report: &report)
        try m.save(layout.manifestURL)
        try FileManager.default.removeItem(at: layout.journalURL)
    }

    // MARK: purge / verify / unmanaged

    /// Remove every deployed file (only if still ours), restore everything moved aside, remove folders we created.
    @discardableResult
    public func purge() throws -> DeployReport {
        try recoverIfNeeded()
        let t0 = Date()
        var m = try Manifest.load(layout.manifestURL)
        var report = DeployReport()
        try atomicWrite("# SkyrimMT deploy journal v1 (purge)\n" + m.entries.keys.sorted().map { "R\t\($0)\n" }.joined(), to: layout.journalURL)
        try execute(&m, desired: [:], removes: Array(m.entries.keys), adds: [], report: &report)
        for (k, b) in m.backups {   // backups whose file is no longer in the manifest (e.g. after keptModified)
            try restoreBackup(b, to: layout.gameDir.path + "/" + (b.hasPrefix("files/") ? String(b.dropFirst(6)) : String(b.split(separator: "/", maxSplits: 2).last ?? "")))
            m.backups[k] = nil; report.restored += 1
        }
        for d in m.createdDirs.sorted(by: { $0.count > $1.count }) { rmdir(layout.gameDir.path + "/" + d) }   // only empty ones go
        m.createdDirs = []
        try m.save(layout.manifestURL)
        try? FileManager.default.removeItem(at: layout.journalURL)
        report.seconds = Date().timeIntervalSince(t0)
        return report
    }

    public func verify(only include: ((String) -> Bool)? = nil) throws -> VerifyReport {
        let m = try Manifest.load(layout.manifestURL)
        let list = m.entries.filter { include?($0.key) ?? true }.map(\.value)
        var state = [UInt8](repeating: 0, count: list.count)   // 0 ok, 1 missing, 2 changed (lstat in parallel)
        let game = layout.gameDir.path
        state.withUnsafeMutableBufferPointer { out in
            try? parallel(list.count) { i in
                let e = list[i]
                guard let st = lstatPath(game + "/" + e.rel) else { out[i] = 1; return }
                if st.ino != e.ino || st.dev != e.dev || st.size != e.size || st.mtimeNs != e.mtimeNs { out[i] = 2 }
            }
        }
        var r = VerifyReport()
        for (i, e) in list.enumerated() { if state[i] == 1 { r.missing.append(e.rel) } else if state[i] == 2 { r.changed.append(e.rel) } }
        r.missing.sort(); r.changed.sort()
        return r
    }

    /// Put deployed files back from staging (after something overwrote them in the game folder). The current file is
    /// kept in backups/drift/<time>/. Returns the restored paths.
    @discardableResult
    public func restore(_ rels: [String], keepBackup: Bool = true) throws -> [String] {
        var m = try Manifest.load(layout.manifestURL)
        let stamp = Int(Date().timeIntervalSince1970)
        var done: [String] = []
        for rel in rels {
            let k = rel.lowercased()
            guard let e = m.entries[k] else { continue }
            let path = layout.gameDir.path + "/" + e.rel
            if lstatPath(path) != nil, !keepBackup { guard unlink(path) == 0 else { throw DeployError.io("remove \(path)") } }
            else if lstatPath(path) != nil {
                let b = layout.backupDir.path + "/drift/\(stamp)/" + e.rel
                try FileManager.default.createDirectory(atPath: (b as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                guard rename(path, b) == 0 else { throw DeployError.io("move aside \(path)") }
            }
            _ = try place(e.source, at: path)
            guard let st = lstatPath(path) else { continue }
            m.entries[k] = ManifestEntry(rel: e.rel, modID: e.modID, source: e.source, dev: st.dev, ino: st.ino, size: st.size, mtimeNs: st.mtimeNs,
                                         srcIno: lstatPath(e.source)?.ino ?? 0)
            done.append(e.rel)
        }
        try m.save(layout.manifestURL)
        return done
    }

    public func deployedCount() throws -> Int { try Manifest.load(layout.manifestURL).entries.count }

    /// Snapshot of the game folder before SkyrimMT ever deployed (vanilla + whatever the player had): taken once.
    func ensureBaseline() throws {
        guard !FileManager.default.fileExists(atPath: layout.baselineURL.path) else { return }
        try atomicWrite(listGameFiles().sorted().joined(separator: "\n") + "\n", to: layout.baselineURL)
    }

    func listGameFiles() -> [String] { fastFileList(layout.gameDir.path) }

    /// The game as it was before SkyrimMT deployed anything, as APFS clones in `dir` (no extra space): baseline files,
    /// taken from their backup where a mod replaced them. For tools that must read vanilla files (Wabbajack's game-file
    /// sources check hashes) while mods stay deployed. Returns the number of files.
    @discardableResult
    public func makeVanillaView(at dir: URL) throws -> Int {
        let fm = FileManager.default
        let m = try Manifest.load(layout.manifestURL)
        var base = ((try? String(contentsOf: layout.baselineURL, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        if base.isEmpty { base = listGameFiles().filter { m.entries[$0.lowercased()] == nil } }   // never deployed: what is there
        try? fm.removeItem(at: dir)
        var n = 0
        for rel in base {
            let k = rel.lowercased()
            let src: URL
            if let b = m.backups[k] { src = layout.backupDir.appendingPathComponent(b) }
            else if m.entries[k] != nil { continue }          // ours, no original to restore
            else { src = layout.gameDir.appendingPathComponent(rel) }
            guard fm.fileExists(atPath: src.path) else { continue }
            let d = dir.appendingPathComponent(rel)
            try fm.createDirectory(at: d.deletingLastPathComponent(), withIntermediateDirectories: true)
            try cloneOrCopy(src, d); n += 1
        }
        return n
    }

    /// Files in the game folder that are neither deployed by us nor part of the baseline: added by the player or a
    /// tool (shown as "unmanaged files"; the Overwrite mod idea of PLAN §8.8 builds on this).
    public func unmanagedFiles() throws -> [String] {
        let m = try Manifest.load(layout.manifestURL)
        let base = Set(((try? String(contentsOf: layout.baselineURL, encoding: .utf8)) ?? "").split(separator: "\n").map { $0.lowercased() })
        return listGameFiles().filter { m.entries[$0.lowercased()] == nil && !base.contains($0.lowercased()) }.sorted()
    }
}

/// Every file (not folder) under `root`, relative paths: readdir with entry types, one tree level at a time with the
/// folders of a level read in parallel (25k files: ~20× faster than FileManager's enumerator).
func fastFileList(_ root: String) -> [String] {
    var level = [""], files: [String] = []
    while !level.isEmpty {
        var outs = [(files: [String], dirs: [String])](repeating: ([], []), count: level.count)
        outs.withUnsafeMutableBufferPointer { o in
            DispatchQueue.concurrentPerform(iterations: level.count) { i in
                let rel = level[i], dir = rel.isEmpty ? root : root + "/" + rel
                guard let d = opendir(dir) else { return }
                defer { closedir(d) }
                var fs: [String] = [], ds: [String] = []
                while let e = readdir(d) {
                    let name = withUnsafePointer(to: e.pointee.d_name) { $0.withMemoryRebound(to: CChar.self, capacity: Int(e.pointee.d_namlen) + 1) { String(cString: $0) } }
                    if name == "." || name == ".." { continue }
                    let r = rel.isEmpty ? name : rel + "/" + name
                    var type = e.pointee.d_type
                    if type == DT_UNKNOWN { type = (lstatPath(root + "/" + r)?.isDir ?? false) ? UInt8(DT_DIR) : UInt8(DT_REG) }
                    if type == DT_DIR { ds.append(r) } else { fs.append(r) }
                }
                o[i] = (fs, ds)
            }
        }
        level = outs.flatMap(\.dirs); files += outs.flatMap(\.files)
    }
    return files
}
