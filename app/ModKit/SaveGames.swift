// Save doctor (docs/MODMANAGER.md §3H): reads a save's header and plugin list and compares it with the profile, so
// the player knows before loading whether the save needs mods that are missing or switched off.
// Format (UESP "Skyrim Mod:Save File Format"): "TESV_SAVEGAME", uint32 headerSize, header {uint32 version (12 = SE),
// uint32 saveNumber, wstring playerName, uint32 level, wstring location, wstring gameDate, wstring race, uint16 sex,
// float32 curExp, float32 lvlUpExp, FILETIME, uint32 shotWidth, uint32 shotHeight, uint16 compressionType (SE)},
// screenshot (RGBA in SE), SE: uint32 uncompressedLen, uint32 compressedLen, then (compressed: 0 none / 1 zlib / 2 LZ4)
// uint8 formVersion, uint32 pluginInfoSize, uint8 count + wstring[], light plugins (formVersion >= 78): uint16 count +
// wstring[]. wstring = uint16 length + bytes.
import Foundation
import Compression

public struct SaveInfo: Identifiable, Equatable {
    public var id: String { url.path }
    public var url: URL
    public var saveNumber: Int
    public var formVersion = 0
    public var player: String
    public var level: Int
    public var location: String
    public var race: String
    public var saved: Date
    public var plugins: [String]
    public var lightPlugins: [String]
    public var shot: (width: Int, height: Int, rgba: Data)?
    public static func == (a: SaveInfo, b: SaveInfo) -> Bool { a.url == b.url && a.saved == b.saved && a.plugins == b.plugins && a.lightPlugins == b.lightPlugins }
    public var allPlugins: [String] { plugins + lightPlugins }
}

public struct SaveCheck: Equatable {
    public enum Fix: Equatable { case enablePlugin(String), enableMod(id: String, plugin: String) }
    public var missing: [String] = []        // not installed at all
    public var fixable: [(plugin: String, fix: Fix)] = []   // installed but off
    public var added: [String] = []          // active now, not in the save (usually fine: new mods)
    public var ok: Bool { missing.isEmpty && fixable.isEmpty }
    public static func == (a: SaveCheck, b: SaveCheck) -> Bool { a.missing == b.missing && a.added == b.added && a.fixable.map(\.plugin) == b.fixable.map(\.plugin) }
}

public enum SaveReader {
    struct Cursor {
        let d: Data; var i: Int
        mutating func bytes(_ n: Int) throws -> Data { guard n >= 0, i + n <= d.count else { throw ModKitError.invalid("save file ends early") }; defer { i += n }; return d.subdata(in: (d.startIndex + i)..<(d.startIndex + i + n)) }
        mutating func u8() throws -> Int { Int(try bytes(1)[0]) }
        mutating func u16() throws -> Int { let b = try bytes(2); return Int(b[b.startIndex]) | Int(b[b.startIndex + 1]) << 8 }
        mutating func u32() throws -> Int { let b = try bytes(4); return (0..<4).reduce(0) { $0 | Int(b[b.startIndex + $1]) << (8 * $1) } }
        mutating func u64() throws -> UInt64 { let lo = UInt64(try u32()), hi = UInt64(try u32()); return lo | hi << 32 }
        mutating func wstring() throws -> String {
            let b = try bytes(try u16())
            return String(data: b, encoding: .utf8) ?? String(data: b, encoding: .windowsCP1252) ?? ""
        }
    }

    /// `screenshot`: also return the thumbnail (RGBA).
    public static func read(_ url: URL, screenshot: Bool = false) throws -> SaveInfo {
        let d = try Data(contentsOf: url, options: .mappedIfSafe)
        var c = Cursor(d: d, i: 0)
        guard String(data: try c.bytes(13), encoding: .ascii) == "TESV_SAVEGAME" else { throw ModKitError.invalid("not a Skyrim save") }
        let headerSize = try c.u32(), headerStart = c.i
        let version = try c.u32()
        let num = try c.u32(), player = try c.wstring(), level = try c.u32(), loc = try c.wstring()
        _ = try c.wstring()                       // in-game date
        let race = try c.wstring()
        _ = try c.u16(); _ = try c.bytes(8)       // sex, experience
        let ft = try c.u64()
        let w = try c.u32(), h = try c.u32()
        let compression = version >= 12 ? try c.u16() : 0
        c.i = headerStart + headerSize            // trust headerSize over our field walk
        let shotBytes = (version >= 12 ? 4 : 3) * w * h
        let shotData = try c.bytes(shotBytes)
        var body: Data
        if version >= 12 {
            let ulen = try c.u32(), clen = try c.u32()
            switch compression {
            case 0: body = try c.bytes(min(d.count - c.i, ulen))
            case 1, 2:
                // only the start is needed (plugin lists are near the front); decode up to 1 MB
                let src = try c.bytes(min(clen, d.count - c.i))
                body = try decompress(compression == 2 ? src : src.dropFirst(2), algorithm: compression == 2 ? COMPRESSION_LZ4_RAW : COMPRESSION_ZLIB,
                                      limit: min(ulen, 1 << 20))
            default: throw ModKitError.invalid("unknown save compression \(compression)")
            }
        } else { body = d.subdata(in: c.i..<d.count) }
        var b = Cursor(d: body, i: 0)
        let formVersion = try b.u8()
        _ = try b.u32()                           // pluginInfoSize (both lists)
        var plugins: [String] = [], light: [String] = []
        for _ in 0..<(try b.u8()) { plugins.append(try b.wstring()) }
        if version >= 12 && formVersion >= 78 { for _ in 0..<(try b.u16()) { light.append(try b.wstring()) } }
        // FILETIME: 100 ns since 1601-01-01
        let saved = Date(timeIntervalSince1970: Double(ft) / 1e7 - 11_644_473_600)
        return SaveInfo(url: url, saveNumber: num, formVersion: formVersion, player: player, level: level, location: loc, race: race, saved: saved,
                        plugins: plugins, lightPlugins: light,
                        shot: screenshot && version >= 12 ? (w, h, shotData) : nil)
    }

    static func decompress(_ src: Data, algorithm: compression_algorithm, limit: Int) throws -> Data {
        var out = Data(count: limit)
        let n = out.withUnsafeMutableBytes { dst in
            src.withUnsafeBytes { s in
                compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, limit, s.bindMemory(to: UInt8.self).baseAddress!, src.count, nil, algorithm)
            }
        }
        guard n > 0 else { throw ModKitError.invalid("save data couldn't be decompressed") }
        return out.prefix(n)
    }
}

extension ModKit {
    public var savesDir: URL { myGamesDir.appendingPathComponent("Saves") }

    /// Save files, newest first (separate-saves profiles keep theirs in a subfolder: those included).
    public func saveFiles(limit: Int = 200) -> [URL] {
        let fm = FileManager.default
        var out: [(URL, Date)] = []
        guard let en = fm.enumerator(at: savesDir, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else { return [] }
        for case let u as URL in en where u.pathExtension.lowercased() == "ess" {
            out.append((u, (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast))
        }
        return out.sorted { $0.1 > $1.1 }.prefix(limit).map(\.0)
    }

    /// Compare a save's plugins with the current profile.
    public func checkSave(_ s: SaveInfo) -> SaveCheck {
        let lo = loadOrder()
        let active = Set(lo.activeOrder.map { $0.lowercased() })
        let present = Set(lo.headers.keys)
        var r = SaveCheck()
        // plugin → mod providing it (any installed mod, enabled or not)
        var owner: [String: String] = [:]
        let fm = FileManager.default
        let need = Set(s.allPlugins.map { $0.lowercased() }).subtracting(active)
        if !need.isEmpty {
            for m in mods where !m.isSeparator {
                for f in (try? fm.contentsOfDirectory(atPath: stagingFolder(m).path)) ?? [] where need.contains(f.lowercased()) { owner[f.lowercased()] = owner[f.lowercased()] ?? m.id }
            }
        }
        for p in s.allPlugins where !active.contains(p.lowercased()) {
            if present.contains(p.lowercased()) { r.fixable.append((p, .enablePlugin(p))) }
            else if let id = owner[p.lowercased()] { r.fixable.append((p, .enableMod(id: id, plugin: p))) }
            else { r.missing.append(p) }
        }
        let inSave = Set(s.allPlugins.map { $0.lowercased() })
        r.added = lo.activeOrder.filter { !inSave.contains($0.lowercased()) && !lo.implicitSet.contains($0.lowercased()) }
        return r
    }

    /// Turn on what the save needs that is installed: owning mods first, then the plugins.
    public func fixSave(_ check: SaveCheck) throws {
        var p = try currentProfile()
        var plugins: [String] = []
        for (_, fix) in check.fixable {
            switch fix {
            case .enablePlugin(let n): plugins.append(n)
            case .enableMod(let id, let n):
                if let i = p.mods.firstIndex(where: { $0.id == id }) { p.mods[i].enabled = true } else { p.mods.append(ProfileMod(id: id, enabled: true)) }
                plugins.append(n)
            }
        }
        for n in plugins {
            if let i = p.loadOrder.firstIndex(where: { $0.name.lowercased() == n.lowercased() }) { p.loadOrder[i].active = true }
            else { p.loadOrder.append(LoadOrderEntry(name: n, active: true)) }
        }
        try saveProfile(p)
    }
}

/// A snapshot of a profile's saves taken before an update (APFS clones: instant, no extra space until saves change).
public struct SaveBackup: Identifiable, Equatable {
    public var id: String { url.path }
    public var url: URL
    public var date: Date
    public var reason: String
    public var count: Int
}

extension ModKit {
    var saveBackupsDir: URL { home.appendingPathComponent("backups/saves") }

    /// The folder the current profile's saves live in (its own with separate saves, else the shared one).
    public var activeSavesFolder: URL { (try? currentProfile())?.separateSaves == true ? profileSavesFolder(currentProfileName) : savesDir }

    /// Clone every save (.ess + SKSE co-save) of the active folder into backups/saves/<time> – <reason>; keeps 20.
    @discardableResult
    public func backupSaves(reason: String) -> SaveBackup? {
        let fm = FileManager.default, src = activeSavesFolder
        let files = ((try? fm.contentsOfDirectory(atPath: src.path)) ?? []).filter { ["ess", "skse"].contains(($0 as NSString).pathExtension.lowercased()) }
        guard !files.isEmpty else { return nil }
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH-mm-ss"
        let dst = saveBackupsDir.appendingPathComponent("\(f.string(from: Date())) – \(ModKit.asciiFolderName(reason))")
        do {
            try fm.createDirectory(at: dst, withIntermediateDirectories: true)
            for n in files { try cloneOrCopy(src.appendingPathComponent(n), dst.appendingPathComponent(n)) }
            try "\(currentProfileName)\n\(src.path)\n".write(to: dst.appendingPathComponent("from.txt"), atomically: true, encoding: .utf8)
        } catch { return nil }
        // keep the newest 20 sets
        let all = saveBackups()
        for old in all.dropFirst(20) { try? fm.removeItem(at: old.url) }
        return saveBackups().first { $0.url.lastPathComponent == dst.lastPathComponent }
    }

    public func saveBackups() -> [SaveBackup] {
        let fm = FileManager.default
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH-mm-ss"
        return ((try? fm.contentsOfDirectory(at: saveBackupsDir, includingPropertiesForKeys: nil)) ?? []).compactMap { u in
            let name = u.lastPathComponent
            let parts = name.components(separatedBy: " – ")
            guard let d = f.date(from: parts[0]) else { return nil }
            let n = ((try? fm.contentsOfDirectory(atPath: u.path)) ?? []).filter { $0.lowercased().hasSuffix(".ess") }.count
            return SaveBackup(url: u, date: d, reason: parts.dropFirst().joined(separator: " – "), count: n)
        }.sorted { $0.date > $1.date }
    }

    /// Put a backup's saves back into the folder they came from (saves made since are kept: nothing is overwritten
    /// unless `replace`). Returns how many files were restored.
    @discardableResult
    public func restoreSaves(_ b: SaveBackup, replace: Bool = false) throws -> Int {
        let fm = FileManager.default
        let lines = ((try? String(contentsOf: b.url.appendingPathComponent("from.txt"), encoding: .utf8)) ?? "").components(separatedBy: "\n")
        let dst = lines.count > 1 && !lines[1].isEmpty ? URL(fileURLWithPath: lines[1]) : savesDir
        try fm.createDirectory(at: dst, withIntermediateDirectories: true)
        var n = 0
        for f in (try? fm.contentsOfDirectory(atPath: b.url.path)) ?? [] where ["ess", "skse"].contains((f as NSString).pathExtension.lowercased()) {
            let to = dst.appendingPathComponent(f)
            if fm.fileExists(atPath: to.path) { if replace { try fm.removeItem(at: to) } else { continue } }
            try cloneOrCopy(b.url.appendingPathComponent(f), to); n += 1
        }
        return n
    }
}
