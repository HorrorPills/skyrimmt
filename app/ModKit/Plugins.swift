// ModKit plugins (PLAN §8.5): TES4 header parser, plugin types, plugins.txt, load-order validation, basic sort.
// Format facts: UESP Skyrim Mod:Mod File Format (+ /TES4); load-order rules: libloadorder's documentation
// (docs/m1-sources.md). Clean-room: no code from NMM, LOOT or libloadorder.
import Foundation

public struct PluginHeader: Equatable {
    public let name: String
    public let flags: UInt32
    public let version: Float          // HEDR version (1.70 / 1.71 for SSE)
    public let masters: [String]
    public let author: String
    public let description: String
    public var masterFlag: Bool { flags & 0x1 != 0 }
    public var lightFlag: Bool { flags & 0x200 != 0 }
    public var localized: Bool { flags & 0x80 != 0 }
    public var ext: String { (name as NSString).pathExtension.lowercased() }
    /// libloadorder doc/plugin_types: master if .esm or master flag; light if .esl or light flag (.esp may be light)
    public var isMaster: Bool { ext == "esm" || ext == "esl" || masterFlag }
    public var isLight: Bool { ext == "esl" || lightFlag }
}

public enum PluginError: Error, CustomStringConvertible {
    case notAPlugin(String), truncated(String)
    public var description: String {
        switch self { case .notAPlugin(let n): return "\(n) is not a Skyrim plugin (no TES4 header)"; case .truncated(let n): return "\(n): truncated header" }
    }
}

public enum PluginParser {
    public static let extensions: Set<String> = ["esm", "esp", "esl"]

    /// Reads only the TES4 record (24-byte record header + its fields).
    public static func parse(_ url: URL) throws -> PluginHeader {
        let name = url.lastPathComponent
        guard let h = FileHandle(forReadingAtPath: url.path) else { throw PluginError.notAPlugin(name) }
        defer { try? h.close() }
        let head = h.readData(ofLength: 24)
        guard head.count == 24, String(data: head.prefix(4), encoding: .ascii) == "TES4" else { throw PluginError.notAPlugin(name) }
        let size = Int(head.u32(4)), flags = head.u32(8)
        let data = h.readData(ofLength: size)
        guard data.count == size else { throw PluginError.truncated(name) }
        return try parseFields(name: name, flags: flags, data: data)
    }

    static func parseFields(name: String, flags: UInt32, data: Data) throws -> PluginHeader {
        var i = 0, nextSize: Int? = nil
        var version: Float = 0, masters: [String] = [], author = "", desc = ""
        while i + 6 <= data.count {
            let type = String(data: data.subdata(in: i..<i + 4), encoding: .ascii) ?? ""
            var size = Int(data.u16(i + 4))
            i += 6
            if let n = nextSize { size = n; nextSize = nil }
            guard i + size <= data.count else { throw PluginError.truncated(name) }
            let field = data.subdata(in: i..<i + size)
            switch type {
            case "XXXX": nextSize = Int(field.u32(0))
            case "HEDR": if field.count >= 4 { version = Float(bitPattern: field.u32(0)) }
            case "MAST": masters.append(field.zstring)
            case "CNAM": author = field.zstring
            case "SNAM": desc = field.zstring
            default: break
            }
            i += size
        }
        return PluginHeader(name: name, flags: flags, version: version, masters: masters, author: author, description: desc)
    }
}

extension Data {
    func u16(_ o: Int) -> UInt16 { UInt16(self[startIndex + o]) | UInt16(self[startIndex + o + 1]) << 8 }
    func u32(_ o: Int) -> UInt32 { (0..<4).reduce(UInt32(0)) { $0 | UInt32(self[startIndex + o + $1]) << (8 * UInt32($1)) } }
    /// zero-terminated Windows-1252 string
    var zstring: String {
        let bytes = prefix { $0 != 0 }
        return String(data: bytes, encoding: .windowsCP1252) ?? String(decoding: bytes, as: UTF8.self)
    }
}

/// One line of the load order (plugins.txt order = load order; `*` = active).
public struct LoadOrderEntry: Equatable, Codable {
    public var name: String
    public var active: Bool
    public init(name: String, active: Bool) { self.name = name; self.active = active }
}

public enum PluginsTxt {
    /// SE's plugins.txt: Windows-1252, `#` comments, `*Name.esp` = active, plain `Name.esp` = installed but inactive.
    public static func read(_ url: URL) -> [LoadOrderEntry] {
        guard let d = try? Data(contentsOf: url) else { return [] }
        let text = String(data: d, encoding: .windowsCP1252) ?? String(decoding: d, as: UTF8.self)
        var seen = Set<String>(), out: [LoadOrderEntry] = []
        for raw in text.components(separatedBy: .newlines) {
            let l = raw.trimmingCharacters(in: .whitespaces)
            if l.isEmpty || l.hasPrefix("#") { continue }
            let active = l.hasPrefix("*")
            let name = active ? String(l.dropFirst()) : l
            guard seen.insert(name.lowercased()).inserted else { continue }   // duplicates break the game
            out.append(LoadOrderEntry(name: name, active: active))
        }
        return out
    }

    /// Implicit (hardcoded) plugins are not written: the game loads them first anyway.
    public static func write(_ entries: [LoadOrderEntry], implicit: Set<String>, to url: URL) throws {
        var text = "# This file is used by Skyrim to keep track of your downloaded content.\r\n# Please do not modify this file.\r\n"
        for e in entries where !implicit.contains(e.name.lowercased()) { text += (e.active ? "*" : "") + e.name + "\r\n" }
        guard let data = text.data(using: .windowsCP1252) else { throw PluginError.notAPlugin("plugins.txt: a plugin name can't be written in Windows-1252") }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}

public struct LoadOrderIssue: Equatable {
    public enum Kind: String { case missingMaster, inactiveMaster, masterAfterDependent, nonMasterBeforeMaster, tooManyFull, tooManyLight, unreadable }
    public let kind: Kind
    public let plugin: String
    public let detail: String
}

/// The game's load order model for one Data folder.
public struct LoadOrder {
    /// Always loaded first, in this order (libloadorder docs; PLAN S10), then the Creation Club files in Skyrim.ccc.
    public static let baseMasters = ["Skyrim.esm", "Update.esm", "Dawnguard.esm", "HearthFires.esm", "Dragonborn.esm"]
    public static let maxFull = 254, maxLight = 4096   // full slots 00–FD (FE = light, FF = runtime)

    public var implicit: [String] = []                  // present hardcoded plugins, in load order
    public var entries: [LoadOrderEntry] = []           // the player's plugins (plugins.txt order)
    public var headers: [String: PluginHeader] = [:]    // lowercased name → header
    public var unreadable: [String] = []

    /// Scan Data/ for plugins, read Skyrim.ccc and plugins.txt; plugins missing from plugins.txt are appended inactive,
    /// lines for plugins that are gone are dropped.
    public static func load(dataDir: URL, gameDir: URL, pluginsTxt: URL) -> LoadOrder {
        var lo = LoadOrder()
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: dataDir.path)) ?? [])
            .filter { PluginParser.extensions.contains(($0 as NSString).pathExtension.lowercased()) }
        let present = Dictionary(files.map { ($0.lowercased(), $0) }, uniquingKeysWith: { a, _ in a })
        for f in files {
            do { lo.headers[f.lowercased()] = try PluginParser.parse(dataDir.appendingPathComponent(f)) }
            catch { lo.unreadable.append(f) }
        }
        let ccc = ((try? String(contentsOf: gameDir.appendingPathComponent("Skyrim.ccc"), encoding: .windowsCP1252)) ?? "")
            .components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        for n in baseMasters + ccc { if let real = present[n.lowercased()], !lo.implicit.contains(real) { lo.implicit.append(real) } }
        let implicitSet = Set(lo.implicit.map { $0.lowercased() })
        var listed = Set<String>()
        for e in PluginsTxt.read(pluginsTxt) {
            guard let real = present[e.name.lowercased()], !implicitSet.contains(real.lowercased()) else { continue }
            lo.entries.append(LoadOrderEntry(name: real, active: e.active)); listed.insert(real.lowercased())
        }
        for f in files.sorted() where !implicitSet.contains(f.lowercased()) && !listed.contains(f.lowercased()) {
            lo.entries.append(LoadOrderEntry(name: f, active: false))
        }
        return lo
    }

    public var implicitSet: Set<String> { Set(implicit.map { $0.lowercased() }) }
    /// Everything the game loads, in order.
    public var activeOrder: [String] { implicit + entries.filter(\.active).map(\.name) }

    public func validate() -> [LoadOrderIssue] {
        var issues: [LoadOrderIssue] = []
        let order = activeOrder
        let pos = Dictionary(order.enumerated().map { ($1.lowercased(), $0) }, uniquingKeysWith: { a, _ in a })
        let installed = Set(headers.keys).union(implicitSet)
        var seenNonMaster = false
        var full = 0, light = 0
        for (i, name) in order.enumerated() {
            guard let h = headers[name.lowercased()] else { continue }
            if h.isLight { light += 1 } else { full += 1 }
            if !h.isMaster { seenNonMaster = true }
            else if seenNonMaster && i >= implicit.count {
                issues.append(LoadOrderIssue(kind: .nonMasterBeforeMaster, plugin: name, detail: "master file listed after a regular plugin; the game loads it earlier"))
            }
            for m in h.masters {
                let k = m.lowercased()
                if !installed.contains(k) {
                    issues.append(LoadOrderIssue(kind: .missingMaster, plugin: name, detail: "needs \(m), which is not installed"))
                } else if pos[k] == nil {
                    issues.append(LoadOrderIssue(kind: .inactiveMaster, plugin: name, detail: "needs \(m), which is not active"))
                } else if let mp = pos[k], mp > i {
                    issues.append(LoadOrderIssue(kind: .masterAfterDependent, plugin: name, detail: "\(m) must load before it"))
                }
            }
        }
        if full > LoadOrder.maxFull { issues.append(LoadOrderIssue(kind: .tooManyFull, plugin: "", detail: "\(full) full plugins active (max \(LoadOrder.maxFull))")) }
        if light > LoadOrder.maxLight { issues.append(LoadOrderIssue(kind: .tooManyLight, plugin: "", detail: "\(light) light plugins active (max \(LoadOrder.maxLight))")) }
        for u in unreadable { issues.append(LoadOrderIssue(kind: .unreadable, plugin: u, detail: "not a valid plugin file")) }
        return issues
    }

    /// "Basic sort" (fallback when the LOOT helper isn't available, PLAN §8.6): masters before non-masters, every
    /// plugin after all of its masters; otherwise the current order is kept (stable topological sort).
    public mutating func basicSort() {
        let byName = Dictionary(entries.map { ($0.name.lowercased(), $0) }, uniquingKeysWith: { a, _ in a })
        let index = Dictionary(entries.enumerated().map { ($1.name.lowercased(), $0) }, uniquingKeysWith: { a, _ in a })
        func isMaster(_ k: String) -> Bool { headers[k]?.isMaster ?? false }
        var result: [LoadOrderEntry] = [], placed = Set<String>(), visiting = Set<String>()
        func visit(_ k: String) {
            guard !placed.contains(k), let e = byName[k], !visiting.contains(k) else { return }
            visiting.insert(k)
            for m in (headers[k]?.masters ?? []).map({ $0.lowercased() }).sorted(by: { (index[$0] ?? 0) < (index[$1] ?? 0) }) where byName[m] != nil {
                visit(m)
            }
            visiting.remove(k)
            placed.insert(k); result.append(e)
        }
        let keys = entries.map { $0.name.lowercased() }
        for k in keys where isMaster(k) { visit(k) }
        for k in keys where !isMaster(k) { visit(k) }
        entries = result
    }

    /// Put locked plugins back where they were before a sort (`before`), everything else keeps the sorted order.
    public static func keepLocked(before: [LoadOrderEntry], sorted: [LoadOrderEntry], locked: Set<String>) -> [LoadOrderEntry] {
        guard !locked.isEmpty else { return sorted }
        var out = sorted.filter { !locked.contains($0.name.lowercased()) }
        let pinned = before.enumerated().filter { locked.contains($0.element.name.lowercased()) }
        for (i, e) in pinned { out.insert(sorted.first { $0.name.lowercased() == e.name.lowercased() } ?? e, at: min(i, out.count)) }
        return out
    }

    public func write(to url: URL) throws { try PluginsTxt.write(entries, implicit: implicitSet, to: url) }
}

extension ModKit {
    public func lockedPlugins() -> Set<String> { Set((try? currentProfile())?.lockedPlugins ?? []) }

    public func setPluginLocked(_ name: String, _ locked: Bool) throws {
        var p = try currentProfile()
        var set = Set(p.lockedPlugins ?? [])
        if locked { set.insert(name.lowercased()) } else { set.remove(name.lowercased()) }
        p.lockedPlugins = set.isEmpty ? nil : set.sorted()
        try saveProfile(p)
    }

    /// Basic sort that keeps locked plugins in place; writes plugins.txt and the profile.
    public func basicSortKeepingLocks() throws {
        var lo = loadOrder()
        let before = lo.entries
        lo.basicSort()
        lo.entries = LoadOrder.keepLocked(before: before, sorted: lo.entries, locked: lockedPlugins())
        try lo.write(to: pluginsTxt)
        var p = try currentProfile(); p.loadOrder = lo.entries; try saveProfile(p)
    }
}
