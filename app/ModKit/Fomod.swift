// ModKit FOMOD engine (PLAN §8.4): parses fomod/ModuleConfig.xml (XML installers only — C# script installers are not
// run), evaluates steps/groups/conditions, and resolves the files to install. Clean-room, from the public FOMOD schema
// (github.com/GandaG/fomod-schema ModuleConfig.xsd, MIT) — no code from NMM/Vortex/MO2.
// Schema facts used: destination defaults to source; higher priority installs later; list order attribute
// Ascending (default) / Descending / Explicit; dependencyType: first matching pattern wins, else defaultType;
// conditionalFileInstalls: every matching pattern installs.
import Foundation

public indirect enum FomodDependency: Equatable {
    case file(String, FileState)
    case flag(String, String)
    case game(String)
    case fomm(String)
    case all([FomodDependency])     // operator="And" (default)
    case any([FomodDependency])     // operator="Or"
    public enum FileState: String { case active = "Active", inactive = "Inactive", missing = "Missing" }
}

public enum FomodPluginType: String { case required = "Required", optional = "Optional", recommended = "Recommended",
                                      notUsable = "NotUsable", couldBeUsable = "CouldBeUsable" }
public enum FomodGroupType: String { case atLeastOne = "SelectAtLeastOne", atMostOne = "SelectAtMostOne",
                                     exactlyOne = "SelectExactlyOne", all = "SelectAll", any = "SelectAny" }

public struct FomodFile: Equatable {
    public var source: String
    public var destination: String?
    public var isFolder: Bool
    public var alwaysInstall = false
    public var installIfUsable = false
    public var priority = 0
}

public struct FomodOption: Equatable {
    public var name: String
    public var description = ""
    public var image: String?
    public var files: [FomodFile] = []
    public var flags: [(String, String)] = []
    public var type: FomodPluginType = .optional
    public var typePatterns: [(FomodDependency, FomodPluginType)] = []   // dependencyType
    public static func == (a: FomodOption, b: FomodOption) -> Bool { a.name == b.name && a.files == b.files }
}

public struct FomodGroup: Equatable { public var name: String; public var type: FomodGroupType; public var options: [FomodOption] }
public struct FomodStep: Equatable { public var name: String; public var visible: FomodDependency?; public var groups: [FomodGroup] }

public struct FomodConfig {
    public var moduleName = ""
    public var moduleImage: String?
    public var moduleDependencies: FomodDependency?
    public var required: [FomodFile] = []
    public var steps: [FomodStep] = []
    public var conditional: [(FomodDependency, [FomodFile])] = []
}

/// What the installer knows about the player's setup (fileDependency / gameDependency / fommDependency).
public struct FomodContext {
    public var pluginState: (String) -> FomodDependency.FileState
    public var gameVersion: String
    public init(pluginState: @escaping (String) -> FomodDependency.FileState = { _ in .missing }, gameVersion: String = "1.0") {
        self.pluginState = pluginState; self.gameVersion = gameVersion
    }
}

public enum FomodError: Error, CustomStringConvertible {
    case unreadable(String), invalid(String)
    public var description: String { switch self { case .unreadable(let m): return "FOMOD: can't read \(m)"; case .invalid(let m): return "FOMOD: \(m)" } }
}

// MARK: - parsing

public enum FomodParser {
    /// FOMOD XML is often UTF-16 with a BOM, sometimes mislabelled: decode by BOM first, then let XMLDocument parse.
    public static func load(_ url: URL) throws -> FomodConfig {
        guard let raw = try? Data(contentsOf: url) else { throw FomodError.unreadable(url.lastPathComponent) }
        var text: String?
        if raw.starts(with: [0xFF, 0xFE]) { text = String(data: raw, encoding: .utf16LittleEndian) }
        else if raw.starts(with: [0xFE, 0xFF]) { text = String(data: raw, encoding: .utf16BigEndian) }
        else if raw.starts(with: [0xEF, 0xBB, 0xBF]) { text = String(data: raw.dropFirst(3), encoding: .utf8) }
        else { text = String(data: raw, encoding: .utf8) ?? String(data: raw, encoding: .windowsCP1252) }
        guard var t = text else { throw FomodError.unreadable(url.lastPathComponent) }
        t = t.replacingOccurrences(of: "\u{FEFF}", with: "")
        // the encoding is already decoded: drop the declaration so XMLDocument doesn't re-interpret it
        if let r = t.range(of: #"^\s*<\?xml[^>]*\?>"#, options: .regularExpression) { t.removeSubrange(r) }
        return try parse(t)
    }

    public static func parse(_ xml: String) throws -> FomodConfig {
        let doc: XMLDocument
        do { doc = try XMLDocument(xmlString: xml, options: [.nodePreserveWhitespace]) } catch { throw FomodError.invalid("XML: \(error.localizedDescription)") }
        guard let root = doc.rootElement() else { throw FomodError.invalid("empty document") }
        var c = FomodConfig()
        c.moduleName = child(root, "moduleName")?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        c.moduleImage = child(root, "moduleImage")?.attr("path")
        if let d = child(root, "moduleDependencies") { c.moduleDependencies = composite(d) }
        if let r = child(root, "requiredInstallFiles") { c.required = files(r) }
        if let steps = child(root, "installSteps") {
            c.steps = ordered(children(steps, "installStep"), steps.attr("order"), name: { $0.attr("name") ?? "" }).map { s in
                let groupsEl = child(s, "optionalFileGroups")
                let groups = groupsEl.map { ge in
                    ordered(children(ge, "group"), ge.attr("order"), name: { $0.attr("name") ?? "" }).map(group)
                } ?? []
                return FomodStep(name: s.attr("name") ?? "", visible: child(s, "visible").map(composite), groups: groups)
            }
        }
        if let cf = child(root, "conditionalFileInstalls"), let pats = child(cf, "patterns") {
            c.conditional = children(pats, "pattern").map { p in
                (child(p, "dependencies").map(composite) ?? .all([]), child(p, "files").map(files) ?? [])
            }
        }
        return c
    }

    static func group(_ g: XMLElement) -> FomodGroup {
        let type = FomodGroupType(rawValue: g.attr("type") ?? "") ?? .any
        let pl = child(g, "plugins")
        let opts = pl.map { p in ordered(children(p, "plugin"), p.attr("order"), name: { $0.attr("name") ?? "" }).map(option) } ?? []
        return FomodGroup(name: g.attr("name") ?? "", type: type, options: opts)
    }

    static func option(_ p: XMLElement) -> FomodOption {
        var o = FomodOption(name: p.attr("name") ?? "")
        o.description = child(p, "description")?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        o.image = child(p, "image")?.attr("path")
        o.files = child(p, "files").map(files) ?? []
        o.flags = child(p, "conditionFlags").map { children($0, "flag").map { ($0.attr("name") ?? "", $0.stringValue ?? "") } } ?? []
        if let td = child(p, "typeDescriptor") {
            if let t = child(td, "type") { o.type = FomodPluginType(rawValue: t.attr("name") ?? "") ?? .optional }
            if let dt = child(td, "dependencyType") {
                o.type = FomodPluginType(rawValue: child(dt, "defaultType")?.attr("name") ?? "") ?? .optional
                o.typePatterns = child(dt, "patterns").map { children($0, "pattern").map { pat in
                    (child(pat, "dependencies").map(composite) ?? .all([]), FomodPluginType(rawValue: child(pat, "type")?.attr("name") ?? "") ?? .optional)
                } } ?? []
            }
        }
        return o
    }

    static func files(_ list: XMLElement) -> [FomodFile] {
        (list.children ?? []).compactMap { $0 as? XMLElement }.compactMap { e in
            let n = e.name?.lowercased()
            guard n == "file" || n == "folder" else { return nil }
            return FomodFile(source: e.attr("source") ?? "", destination: e.attr("destination"), isFolder: n == "folder",
                             alwaysInstall: e.attr("alwaysInstall")?.lowercased() == "true",
                             installIfUsable: e.attr("installIfUsable")?.lowercased() == "true",
                             priority: Int(e.attr("priority") ?? "") ?? 0)
        }
    }

    static func composite(_ e: XMLElement) -> FomodDependency {
        let parts: [FomodDependency] = (e.children ?? []).compactMap { $0 as? XMLElement }.compactMap { d in
            switch d.name?.lowercased() {
            case "filedependency": return .file(d.attr("file") ?? "", FomodDependency.FileState(rawValue: d.attr("state") ?? "") ?? .active)
            case "flagdependency": return .flag(d.attr("flag") ?? "", d.attr("value") ?? "")
            case "gamedependency": return .game(d.attr("version") ?? "")
            case "fommdependency": return .fomm(d.attr("version") ?? "")
            case "dependencies": return composite(d)
            default: return nil
            }
        }
        return e.attr("operator")?.lowercased() == "or" ? .any(parts) : .all(parts)
    }

    /// Ascending (default): by name; Descending: reverse; Explicit: document order.
    static func ordered(_ items: [XMLElement], _ order: String?, name: (XMLElement) -> String) -> [XMLElement] {
        switch order?.lowercased() {
        case "explicit": return items
        case "descending": return items.sorted { name($0).localizedStandardCompare(name($1)) == .orderedDescending }
        default: return items.sorted { name($0).localizedStandardCompare(name($1)) == .orderedAscending }
        }
    }

    static func children(_ e: XMLElement, _ name: String) -> [XMLElement] {
        (e.children ?? []).compactMap { $0 as? XMLElement }.filter { $0.name?.lowercased() == name.lowercased() }
    }
    static func child(_ e: XMLElement, _ name: String) -> XMLElement? { children(e, name).first }
}

extension XMLElement {
    func attr(_ name: String) -> String? {
        (attributes ?? []).first { $0.name?.lowercased() == name.lowercased() }?.stringValue
    }
}

// MARK: - evaluation

public final class FomodInstaller {
    public let config: FomodConfig
    public let context: FomodContext
    /// selections[stepIndex][groupIndex] = selected option indices
    public var selections: [Int: [Int: Set<Int>]] = [:]

    public init(config: FomodConfig, context: FomodContext) { self.config = config; self.context = context }

    func versionAtLeast(_ have: String, _ want: String) -> Bool { !isNewerVersion(want, than: have) }
    func isNewerVersion(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) { let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0; if l != r { return l > r } }
        return false
    }

    public func evaluate(_ d: FomodDependency, flags: [String: String]) -> Bool {
        switch d {
        case .file(let f, let state): return context.pluginState(f) == state
        case .flag(let f, let v): return (flags[f] ?? "") == v
        case .game(let v): return versionAtLeast(context.gameVersion, v)
        case .fomm: return true   // "mod manager version": always satisfied (PLAN §8.4)
        case .all(let ds): return ds.allSatisfy { evaluate($0, flags: flags) }
        case .any(let ds): return ds.isEmpty || ds.contains { evaluate($0, flags: flags) }
        }
    }

    public func type(of o: FomodOption, flags: [String: String]) -> FomodPluginType {
        for (dep, t) in o.typePatterns where evaluate(dep, flags: flags) { return t }
        return o.type
    }

    /// Flags set by the selections of all *visible* steps before `step` (steps are evaluated in order).
    public func flags(before step: Int) -> [String: String] {
        var f: [String: String] = [:]
        for s in 0..<min(step, config.steps.count) where isVisible(s, flags: f) {
            for (g, sel) in selections[s] ?? [:] { for o in sel.sorted() { for (k, v) in config.steps[s].groups[g].options[o].flags { f[k] = v } } }
        }
        return f
    }
    public var finalFlags: [String: String] { flags(before: config.steps.count) }

    public func isVisible(_ s: Int, flags: [String: String]) -> Bool { config.steps[s].visible.map { evaluate($0, flags: flags) } ?? true }
    public var visibleSteps: [Int] {
        (0..<config.steps.count).filter { isVisible($0, flags: flags(before: $0)) }
    }

    /// Default selection for a step (call when the wizard first shows it): Required always, Recommended preselected,
    /// SelectAll = everything usable, SelectExactlyOne = first recommended or first usable.
    public func applyDefaults(step s: Int) {
        let fl = flags(before: s)
        var stepSel: [Int: Set<Int>] = [:]
        for (gi, g) in config.steps[s].groups.enumerated() {
            let types = g.options.map { type(of: $0, flags: fl) }
            var sel = Set<Int>()
            switch g.type {
            case .all: sel = Set(types.indices.filter { types[$0] != .notUsable })
            case .exactlyOne, .atLeastOne:
                if let i = types.firstIndex(of: .required) ?? types.firstIndex(of: .recommended) ?? types.firstIndex(where: { $0 != .notUsable }) { sel = [i] }
                if g.type == .atLeastOne { sel.formUnion(types.indices.filter { types[$0] == .required || types[$0] == .recommended }) }
            case .atMostOne:
                if let i = types.firstIndex(of: .required) ?? types.firstIndex(of: .recommended) { sel = [i] }
            case .any: sel = Set(types.indices.filter { types[$0] == .required || types[$0] == .recommended })
            }
            stepSel[gi] = sel
        }
        selections[s] = stepSel
    }

    /// Validation of one group's selection against its type and the option types. nil = OK.
    public func problem(step s: Int, group gi: Int) -> String? {
        let g = config.steps[s].groups[gi], fl = flags(before: s)
        let sel = selections[s]?[gi] ?? []
        let types = g.options.map { type(of: $0, flags: fl) }
        if sel.contains(where: { types[$0] == .notUsable }) { return "\(g.name): an option that can't be used is selected" }
        if types.indices.contains(where: { types[$0] == .required && !sel.contains($0) }) { return "\(g.name): a required option is not selected" }
        switch g.type {
        case .exactlyOne where sel.count != 1: return "\(g.name): choose exactly one"
        case .atMostOne where sel.count > 1: return "\(g.name): choose at most one"
        case .atLeastOne where sel.isEmpty: return "\(g.name): choose at least one"
        case .all where sel.count != types.filter({ $0 != .notUsable }).count: return "\(g.name): all options are installed"
        default: return nil
        }
    }

    public func problems() -> [String] {
        visibleSteps.flatMap { s in config.steps[s].groups.indices.compactMap { problem(step: s, group: $0) } }
    }

    /// Files to install, in install order (priority ascending, then document order; later overwrites earlier).
    public func resolvedFiles() -> [FomodFile] {
        var out: [(FomodFile, Int)] = []
        var n = 0
        func add(_ fs: [FomodFile]) { for f in fs { out.append((f, n)); n += 1 } }
        add(config.required)
        for s in visibleSteps {
            let fl = flags(before: s)
            for (gi, g) in config.steps[s].groups.enumerated() {
                let sel = selections[s]?[gi] ?? []
                for (oi, o) in g.options.enumerated() {
                    let t = type(of: o, flags: fl)
                    if sel.contains(oi) { add(o.files) }
                    else { add(o.files.filter { $0.alwaysInstall || ($0.installIfUsable && t != .notUsable) }) }
                }
            }
        }
        let fl = finalFlags
        for (dep, fs) in config.conditional where evaluate(dep, flags: fl) { add(fs) }
        return out.sorted { $0.0.priority != $1.0.priority ? $0.0.priority < $1.0.priority : $0.1 < $1.1 }.map(\.0)
    }

    /// Defaults for every step that is (or becomes) visible: steps revealed by earlier choices' flags get theirs too.
    public func applyAllDefaults() {
        var done = Set<Int>()
        for _ in 0..<(config.steps.count + 1) {
            let todo = visibleSteps.filter { !done.contains($0) }
            if todo.isEmpty { break }
            for s in todo { if selections[s] == nil { applyDefaults(step: s) }; done.insert(s) }
        }
    }

    /// Choices that can't work on Apple Silicon under Rosetta (no AVX-512, no NVIDIA CUDA): swapped for the closest
    /// option in the same group (AVX2 / non-CUDA). Returns the names that were changed.
    @discardableResult
    public func makeRosettaSafe() -> [String] {
        var changed: [String] = []
        for (s, groups) in selections { for (gi, sel) in groups {
            let opts = config.steps[s].groups[gi].options
            var new = sel
            for oi in sel {
                let n = opts[oi].name.lowercased()
                let bad = n.contains("avx512") || n.contains("avx-512") || (n.contains("cuda") && !n.contains("not cuda") && !n.contains("no cuda"))
                guard bad else { continue }
                let alt = opts.firstIndex { let m = $0.name.lowercased(); return m.contains("avx2") && !m.contains("512") }
                    ?? opts.firstIndex { let m = $0.name.lowercased(); return m.contains("not cuda") || m.contains("no cuda") }
                    ?? opts.firstIndex { let m = $0.name.lowercased(); return m.contains("avx") && !m.contains("512") && !m.contains("cuda") }
                if let a = alt { new.remove(oi); new.insert(a); changed.append("\(opts[oi].name) → \(opts[a].name)") }
            }
            selections[s]?[gi] = new
        } }
        return changed
    }

    /// Saved choices (ModRecord.installChoices): "step/group" → option names; replayed on reinstall.
    public var choices: [String: [String]] {
        var r: [String: [String]] = [:]
        for s in visibleSteps { for (gi, g) in config.steps[s].groups.enumerated() {
            r["\(config.steps[s].name)/\(g.name)"] = (selections[s]?[gi] ?? []).sorted().map { g.options[$0].name }
        } }
        return r
    }
    /// Names are matched case-insensitively and trimmed; by "step/group", else by group name alone (some exporters
    /// write empty or different step names). A group whose saved names match nothing keeps its default.
    public func replay(_ saved: [String: [String]]) {
        func norm(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        let byKey = Dictionary(saved.map { (norm($0.key), $0.value.map(norm)) }, uniquingKeysWith: { a, _ in a })
        var byGroup: [String: [String]] = [:]
        for (k, v) in saved { let g = norm(String(k.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).last ?? "")); if byGroup[g] == nil { byGroup[g] = v.map(norm) } }
        for s in 0..<config.steps.count {
            applyDefaults(step: s)
            for (gi, g) in config.steps[s].groups.enumerated() {
                guard let names = byKey["\(norm(config.steps[s].name))/\(norm(g.name))"] ?? byGroup[norm(g.name)] else { continue }
                let picked = Set(g.options.indices.filter { names.contains(norm(g.options[$0].name)) })
                if !picked.isEmpty || g.type == .any || g.type == .atMostOne { selections[s]?[gi] = picked }
            }
        }
    }

    /// Copy the resolved files from the extracted archive (`base` = folder containing "fomod/") into `out` (laid out
    /// like Data/). Sources and destinations are Windows paths: backslashes, case-insensitive.
    public func install(from base: URL, to out: URL) throws {
        let index = CaseIndex(base)
        let fm = FileManager.default
        for f in resolvedFiles() {
            let srcRel = normalize(f.source)
            guard let src = index.resolve(srcRel) else {
                if srcRel.isEmpty && f.isFolder { try copyTree(base, to: out.appendingPathComponent(normalize(f.destination ?? "")), skipFomod: true); continue }
                throw FomodError.invalid("file listed in the installer is missing: \(f.source)")
            }
            let dstRel = normalize(f.destination ?? f.source)
            if f.isFolder {
                try copyTree(src, to: dstRel.isEmpty ? out : out.appendingPathComponent(dstRel), skipFomod: false)
            } else {
                // a file's destination is the full target path; an empty destination means "Data root, same name"
                let dst = dstRel.isEmpty ? out.appendingPathComponent(src.lastPathComponent) : out.appendingPathComponent(dstRel)
                try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? fm.removeItem(at: dst)
                try cloneOrCopy(src, dst)
            }
        }
    }
}

func normalize(_ p: String) -> String {
    p.replacingOccurrences(of: "\\", with: "/").split(separator: "/").filter { !$0.isEmpty && $0 != "." }.joined(separator: "/")
}

/// Case-insensitive lookup of relative paths inside an extracted archive.
struct CaseIndex {
    let base: URL
    var map: [String: String] = [:]
    init(_ base: URL) {
        self.base = base
        if let en = FileManager.default.enumerator(atPath: base.path) {
            while let rel = en.nextObject() as? String { map[rel.lowercased()] = rel }
        }
    }
    func resolve(_ rel: String) -> URL? { map[rel.lowercased()].map { base.appendingPathComponent($0) } }
}

func cloneOrCopy(_ src: URL, _ dst: URL) throws {
    if clonefile(src.path, dst.path, 0) == 0 { return }
    try FileManager.default.copyItem(at: src, to: dst)
}

/// Merge-copy a folder (existing files are overwritten: later install entries win).
func copyTree(_ src: URL, to dst: URL, skipFomod: Bool) throws {
    let fm = FileManager.default
    try fm.createDirectory(at: dst, withIntermediateDirectories: true)
    guard let en = fm.enumerator(atPath: src.path) else { return }
    while let rel = en.nextObject() as? String {
        if skipFomod && rel.lowercased().hasPrefix("fomod") { continue }
        let s = src.appendingPathComponent(rel), d = dst.appendingPathComponent(rel)
        var isDir: ObjCBool = false
        fm.fileExists(atPath: s.path, isDirectory: &isDir)
        if isDir.boolValue { try fm.createDirectory(at: d, withIntermediateDirectories: true) }
        else { try? fm.removeItem(at: d); try cloneOrCopy(s, d) }
    }
}
