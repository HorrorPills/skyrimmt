// ModKit BodySlide (PLAN §8.11): runs the native macOS build of BodySlide (GPL-3.0, a separate program; pinned source +
// macos.patch in tools/bodyslide) unattended against the deployed game and keeps the built meshes as a per-profile
// "BodySlide Output" mod. What modpack guides ask the player to click is decided here instead:
//  * body family — only one female body can own the body meshes (CBBE, 3BA, BHUNP, TBD …): outfits converted for other
//    families are left out; detected from which body project is installed (3BA needs CBBE, so 3BA wins), changeable;
//    no body project (pre-built body meshes) = nothing is built unless the player picks a family;
//  * output conflicts — several outfits writing the same mesh: the chosen family, then the higher-priority mod wins
//    (written to BodySlide's BuildSelection.xml, applied with --noninteractive);
//  * preset — the profile's choice (none = the projects' slider defaults); tri morphs when RaceMenu is installed.
import Foundation

public struct BodySlideOutfit: Equatable {
    public let name: String
    public let output: String        // BodySlide's output key: OutputPath (OS slashes) + "/" + OutputFile
    public let project: String       // deployed .osp, relative to the game folder
    public let modID: String
    public var groups: [String] = []
    public var families: Set<String> = []
}

public struct BodySlidePreset: Equatable { public let name: String; public let groups: [String] }

public struct BodySlideScan {
    public var outfits: [BodySlideOutfit] = []
    public var presets: [BodySlidePreset] = []
    public var familyCounts: [String: Int] = [:]   // family → outfits converted for it
    public var detectedFamily: String?
    public var hasRaceMenu = false
    public func presets(for family: String?) -> [BodySlidePreset] {
        guard let f = family else { return presets }
        let ok = BodySlide.accepted(f)
        return presets.filter { p in p.groups.isEmpty || p.groups.contains { !BodySlide.families(ofGroup: $0).isDisjoint(with: ok) } }
    }
}

public struct BodySlideSettings: Codable, Equatable {
    public var family: String?       // nil = detected
    public var preset: String?       // nil = slider defaults
    public var triMorphs: Bool?      // nil = on when RaceMenu is installed
    public init(family: String? = nil, preset: String? = nil, triMorphs: Bool? = nil) { self.family = family; self.preset = preset; self.triMorphs = triMorphs }
}

public struct BodySlideResult { public var outfits = 0; public var files = 0; public var seconds = 0.0; public var failed: [String] = []; public var family: String? }

public enum BodySlideError: Error, CustomStringConvertible {
    case notInstalled, failed(String)
    public var description: String {
        switch self {
        case .notInstalled: return "BodySlide isn't installed (tools/bodyslide/build.sh)."
        case .failed(let m): return "BodySlide: \(m)"
        }
    }
}

struct BodySlideState: Codable {
    var settings: [String: BodySlideSettings] = [:]   // profile → settings
    var fingerprints: [String: String] = [:]          // profile → inputs fingerprint of its output
}

public enum BodySlide {
    /// Female body families, most specific first (BHUNP 3BBB is BHUNP; CBBE 3BBB is 3BA).
    public static let familyOrder = ["3BA", "BHUNP", "CBBE", "TBD", "UNP"]
    /// Families whose outfits also fit: 3BA is CBBE with extra physics bones, so CBBE outfits work on it (3BA versions win).
    public static let fallbacks: [String: [String]] = ["3BA": ["CBBE"]]
    static func accepted(_ family: String) -> Set<String> { Set([family] + (fallbacks[family] ?? [])) }

    public static let familyNames = ["3BA": "CBBE 3BA (3BBB)", "BHUNP": "BHUNP", "CBBE": "CBBE", "TBD": "Touched by Dibella", "UNP": "UNP"]

    static func words(_ s: String) -> [String] { s.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init) }

    /// The female body family a slider group belongs to (empty: not body-specific, e.g. male bodies, hair collisions).
    public static func families(ofGroup g: String) -> Set<String> {
        let l = g.lowercased(), w = Set(words(g))
        if l.contains("bhunp") || l.contains("uunp") { return ["BHUNP"] }
        if w.contains("3ba") || l.contains("3bbb") || l.contains("cbbe smp") { return ["3BA"] }
        if l.contains("cbbe") { return ["CBBE"] }
        if l.contains("touched by dibella") || w.contains("tbd") { return ["TBD"] }
        if w.contains("unp") { return ["UNP"] }
        return []
    }
}

/// Minimal SAX reader for BodySlide's XML files (projects, groups, presets).
private final class BSXML: NSObject, XMLParserDelegate {
    var sets: [(name: String, path: String, file: String)] = []
    var groups: [(name: String, members: [String])] = []
    var presets: [BodySlidePreset] = []
    private var cur: (name: String, path: String, file: String)?
    private var text = "", groupName: String?, members: [String] = [], presetName: String?, presetGroups: [String] = []

    static func parse(_ url: URL) -> BSXML {
        let d = BSXML()
        if let p = XMLParser(contentsOf: url) { p.delegate = d; p.parse() }
        return d
    }
    func parser(_ parser: XMLParser, didStartElement e: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String] = [:]) {
        text = ""
        switch e {
        case "SliderSet": cur = (a["name"] ?? "", "", "")
        case "Group" where presetName != nil: if let n = a["name"] { presetGroups.append(n) }
        case "Group": groupName = a["name"]; members = []
        case "Member": if let n = a["name"] { members.append(n) }
        case "Preset": presetName = a["name"]; presetGroups = []
        default: break
        }
    }
    func parser(_ parser: XMLParser, foundCharacters s: String) { text += s }
    func parser(_ parser: XMLParser, didEndElement e: String, namespaceURI: String?, qualifiedName: String?) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch e {
        case "OutputPath": cur?.path = t
        case "OutputFile": cur?.file = t
        case "SliderSet": if let c = cur, !c.name.isEmpty { sets.append(c) }; cur = nil
        case "Group" where presetName == nil: if let g = groupName { groups.append((g, members)) }; groupName = nil
        case "Preset": if let n = presetName { presets.append(BodySlidePreset(name: n, groups: presetGroups)) }; presetName = nil
        default: break
        }
        text = ""
    }
}

extension ModKit {
    public var bodySlideDir: URL { home.appendingPathComponent("tools/bodyslide") }
    public var bodySlideInstalled: Bool { FileManager.default.isExecutableFile(atPath: bodySlideDir.appendingPathComponent("BodySlide").path) }
    var bodySlideStateURL: URL { stateDir.appendingPathComponent("bodyslide.json") }
    var bodySlideProjectDir: URL { gameDir.appendingPathComponent("Data/CalienteTools/BodySlide") }

    public static func bodySlideOutputID(_ profile: String) -> String { "bodyslide-output:\(profile)" }
    public static func isBodySlideOutput(_ id: String) -> Bool { id.hasPrefix("bodyslide-output:") }
    static func isBodySlideInput(_ rel: String) -> Bool {
        let l = rel.lowercased()
        return l.hasPrefix("data/calientetools/bodyslide/") && ["slidersets/", "shapedata/", "slidergroups/", "sliderpresets/"]
            .contains { l.dropFirst("data/calientetools/bodyslide/".count).hasPrefix($0) }
    }

    public func bodySlideSettings() -> BodySlideSettings {
        guard let p = try? currentProfile() else { return BodySlideSettings() }
        return readJSON(bodySlideStateURL, BodySlideState.self)?.settings[p.name] ?? BodySlideSettings()
    }
    public func setBodySlideSettings(_ s: BodySlideSettings) throws {
        let p = try currentProfile()
        var st = readJSON(bodySlideStateURL, BodySlideState.self) ?? BodySlideState()
        st.settings[p.name] = s
        try writeJSON(st, to: bodySlideStateURL)
    }

    /// What the deployed BodySlide projects offer (outfits, groups → families, presets).
    public func bodySlideScan() throws -> BodySlideScan {
        let fm = FileManager.default
        let m = try Manifest.load(deployer.layout.manifestURL)
        var scan = BodySlideScan()
        scan.hasRaceMenu = m.entries["data/skse/plugins/skee64.dll"] != nil
        let root = bodySlideProjectDir
        func xmlFiles(_ sub: String, _ ext: String) -> [URL] {
            guard let en = fm.enumerator(at: root.appendingPathComponent(sub), includingPropertiesForKeys: nil) else { return [] }
            return (en.allObjects as? [URL] ?? []).filter { $0.pathExtension.lowercased() == ext }.sorted { $0.path < $1.path }
        }
        var groupsOf: [String: [String]] = [:]
        for f in xmlFiles("SliderGroups", "xml") { for g in BSXML.parse(f).groups { for mbr in g.members { groupsOf[mbr, default: []].append(g.name) } } }
        for f in xmlFiles("SliderPresets", "xml") { scan.presets += BSXML.parse(f).presets }
        var seen = Set<String>()
        for f in xmlFiles("SliderSets", "osp") + xmlFiles("SliderSets", "xml") {
            let rel = "Data/CalienteTools/BodySlide/SliderSets/" + f.path.dropFirst(root.appendingPathComponent("SliderSets").path.count + 1)
            let modID = m.entries[rel.lowercased()]?.modID ?? ""
            for s in BSXML.parse(f).sets where seen.insert(s.name).inserted {   // BodySlide keeps the first set of a name
                let path = s.path.replacingOccurrences(of: "\\", with: "/")
                var o = BodySlideOutfit(name: s.name, output: s.file.isEmpty ? path : path + "/" + s.file, project: rel, modID: modID)
                o.groups = groupsOf[s.name] ?? []
                o.families = o.groups.reduce(into: Set<String>()) { $0.formUnion(BodySlide.families(ofGroup: $1)) }
                scan.outfits.append(o)
            }
        }
        for o in scan.outfits { for f in o.families { scan.familyCounts[f, default: 0] += 1 } }
        // the body meshes decide: a family with a femalebody project, most specific first
        let bodies = scan.outfits.filter { $0.output.lowercased().hasSuffix("actors/character/character assets/femalebody") }
        let bodyFamilies = bodies.reduce(into: Set<String>()) { $0.formUnion($1.families) }
        // no body project = the body meshes come pre-built; guessing a family could mismatch them, so nothing is built
        scan.detectedFamily = BodySlide.familyOrder.first { bodyFamilies.contains($0) }
        return scan
    }

    /// The outfits to build for `family` and, per contested output, the outfit that wins.
    func bodySlidePlan(_ scan: BodySlideScan, family: String?, profile: Profile) -> (outfits: [BodySlideOutfit], choices: [String: String]) {
        guard let family else { return ([], [:]) }   // no body chosen or detected: nothing to build
        let ok = BodySlide.accepted(family)
        let build = scan.outfits.filter { $0.families.isEmpty || !$0.families.isDisjoint(with: ok) }
        let priority = Dictionary(profile.mods.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
        var choices: [String: String] = [:]
        for (out, cands) in Dictionary(grouping: build, by: \.output) where cands.count > 1 && !out.isEmpty {
            let best = cands.max { a, b in
                func rank(_ o: BodySlideOutfit) -> Int { o.families.contains(family) ? 2 : o.families.isDisjoint(with: ok) ? 0 : 1 }
                let fa = rank(a), fb = rank(b)
                if fa != fb { return fa < fb }
                let pa = priority[a.modID] ?? -1, pb = priority[b.modID] ?? -1
                if pa != pb { return pa < pb }
                return a.name > b.name
            }!
            choices[out] = best.name
        }
        return (build, choices)
    }

    public func bodySlideInputs() throws -> (fingerprint: String, count: Int) {
        let build = (try? String(contentsOf: bodySlideDir.appendingPathComponent(".skyrimmt-bodyslide"), encoding: .utf8)) ?? ""
        let s = bodySlideSettings()
        return try deployedInputs(excluding: { ModKit.isBodySlideOutput($0) || ModKit.isPandoraOutput($0) }, ModKit.isBodySlideInput,
                                  extra: [build, s.family ?? "-", s.preset ?? "-", s.triMorphs.map { "\($0)" } ?? "-",
                                          try Manifest.load(deployer.layout.manifestURL).entries["data/skse/plugins/skee64.dll"] == nil ? "norm" : "rm"])
    }

    public func bodySlideNeedsRun() -> Bool {
        guard let p = try? currentProfile(), let inputs = try? bodySlideInputs() else { return false }
        let hasOutput = p.mods.contains { $0.id == ModKit.bodySlideOutputID(p.name) && $0.enabled }
        if inputs.count == 0 { return hasOutput }
        let saved = readJSON(bodySlideStateURL, BodySlideState.self)?.fingerprints[p.name]
        if hasOutput && saved == inputs.fingerprint { return false }
        guard let scan = try? bodySlideScan() else { return false }   // something to build at all?
        return !bodySlidePlan(scan, family: bodySlideSettings().family ?? scan.detectedFamily, profile: p).outfits.isEmpty || hasOutput
    }

    /// Write BodySlide's Config.xml: Skyrim SE, the deployed Data folder and its merged BodySlide projects. `output`:
    /// where the window's own Build writes (default: the game's Data folder).
    public func prepareBodySlideConfig(output: URL? = nil) throws {
        let app = bodySlideDir, data = gameDir.appendingPathComponent("Data")
        // the existing Config.xml keeps what the player set in BodySlide's Settings; the shipped default otherwise
        var config = (try? String(contentsOf: app.appendingPathComponent("Config.xml"), encoding: .utf8))
            ?? (try? String(contentsOf: app.appendingPathComponent("Config.default.xml"), encoding: .utf8)) ?? "<Config>\n</Config>\n"
        func set(_ tag: String, _ value: String) {
            let esc = value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            if let r = config.range(of: "<\(tag)>[^<]*</\(tag)>", options: .regularExpression) { config.replaceSubrange(r, with: "<\(tag)>\(esc)</\(tag)>") }
            else { config = config.replacingOccurrences(of: "</Config>", with: "    <\(tag)>\(esc)</\(tag)>\n</Config>") }
        }
        set("TargetGame", "4"); set("WarnMissingGamePath", "false")
        // the per-game data path lives in <GameDataPaths>; <GameDataFiles> has a tag of the same name (archive blacklist)
        if let sec = config.range(of: "<GameDataPaths>[\\s\\S]*?</GameDataPaths>", options: .regularExpression) {
            var block = String(config[sec])
            if let r = block.range(of: "<SkyrimSpecialEdition>[^<]*</SkyrimSpecialEdition>", options: .regularExpression) {
                block.replaceSubrange(r, with: "<SkyrimSpecialEdition>\(data.path.replacingOccurrences(of: "&", with: "&amp;"))/</SkyrimSpecialEdition>")
            }
            config.replaceSubrange(sec, with: block)
        }
        if let sec = config.range(of: "<GameDataFiles>[\\s\\S]*?</GameDataFiles>", options: .regularExpression),
           let r = config[sec].range(of: "<SkyrimSpecialEdition>[^<]*/</SkyrimSpecialEdition>", options: .regularExpression) {
            config.replaceSubrange(r, with: "<SkyrimSpecialEdition></SkyrimSpecialEdition>")   // undo a path written there by older SkyrimMT builds
        }
        set("GameDataPath", data.path + "/"); set("ProjectPath", bodySlideProjectDir.path); set("OutputDataPath", output.map { $0.path + "/" } ?? "")
        // BodySlide sets the skeleton only in its first-run setup dialog (BodySlideApp.cpp, case SKYRIMSE), which this
        // config skips: same values here, unless the player picked another skeleton in Settings
        if config.range(of: "<DefaultSkeletonReference>[^<]+</DefaultSkeletonReference>", options: .regularExpression) == nil {
            set("DefaultSkeletonReference", "res/skeleton_female_sse.nif"); set("SkeletonRootName", "NPC Root [Root]")
        }
        try config.write(to: app.appendingPathComponent("Config.xml"), atomically: true, encoding: .utf8)
    }

    /// Hand builds from the BodySlide window go to the Overwrite mod (wins over the automatic output, stays managed).
    public func prepareBodySlideWindow() throws -> URL {
        var p = try currentProfile()
        let ow = stagingFolder(try ensureOverwrite())
        let owID = currentOverwriteID()
        if !p.mods.contains(where: { $0.id == owID }) { p.mods.append(ProfileMod(id: owID, enabled: true)); try saveProfile(p) }
        try deploy(p)   // BodySlide reads the game's Data folder: newly enabled body/outfit mods must be in it
        try prepareBodySlideConfig(output: ow)
        return ow
    }

    /// Batch-build every outfit for the profile's body family into its "BodySlide Output" mod.
    @discardableResult
    public func runBodySlide() throws -> BodySlideResult {
        let fm = FileManager.default
        var profile = try currentProfile()
        let outID = ModKit.bodySlideOutputID(profile.name)
        var without = profile; without.mods.removeAll { $0.id == outID }
        try deploy(without)
        let inputs = try bodySlideInputs()
        var state = readJSON(bodySlideStateURL, BodySlideState.self) ?? BodySlideState()
        var result = BodySlideResult()
        let scan = try bodySlideScan()
        let settings = state.settings[profile.name] ?? BodySlideSettings()
        let family = settings.family ?? scan.detectedFamily
        result.family = family
        let plan = bodySlidePlan(scan, family: family, profile: profile)
        if inputs.count == 0 || plan.outfits.isEmpty {
            try removeGeneratedOutput(id: outID, profile: &profile)
            state.fingerprints[profile.name] = nil; try writeJSON(state, to: bodySlideStateURL)
            return result
        }
        guard bodySlideInstalled else { try deploy(profile); throw BodySlideError.notInstalled }

        // BodySlide reads its settings next to the program: paths, conflict choices, outfit list
        try prepareBodySlideConfig()
        let app = bodySlideDir
        func xml(_ s: String) -> String { s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "<", with: "&lt;") }
        let sel = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<BuildSelection>\n"
            + plan.choices.sorted { $0.key < $1.key }.map { "    <OutputChoice path=\"\(xml($0.key))\" choice=\"\(xml($0.value))\"/>\n" }.joined()
            + "</BuildSelection>\n"
        try sel.write(to: app.appendingPathComponent("BuildSelection.xml"), atomically: true, encoding: .utf8)
        try fm.createDirectory(at: home.appendingPathComponent("cache"), withIntermediateDirectories: true)
        let list = home.appendingPathComponent("cache/bodyslide-build-list.txt")
        try plan.outfits.map(\.name).joined(separator: "\n").write(to: list, atomically: true, encoding: .utf8)
        if settings.preset == nil { try? fm.removeItem(at: app.appendingPathComponent("BodySlide.xml")) }   // no remembered preset
        let log = app.appendingPathComponent("Log_BS.txt"); try? fm.removeItem(at: log)

        let t0 = Date()
        let out = home.appendingPathComponent("cache/bodyslide-run-\(Int(t0.timeIntervalSince1970))")
        try? fm.removeItem(at: out); try fm.createDirectory(at: out, withIntermediateDirectories: true)
        let p = Process()
        p.executableURL = app.appendingPathComponent("BodySlide")
        p.currentDirectoryURL = app
        var args = ["--buildlist", list.path, "--targetdir", out.path, "--noninteractive"]
        if let pr = settings.preset { args += ["--preset", pr] }
        if settings.triMorphs ?? scan.hasRaceMenu { args.append("--trimorphs") }
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { try deploy(profile); throw BodySlideError.failed("couldn't start (\(error.localizedDescription))") }
        p.waitUntilExit()
        result.seconds = Date().timeIntervalSince(t0)
        result.outfits = plan.outfits.count

        let logs = home.appendingPathComponent("logs"); try? fm.createDirectory(at: logs, withIntermediateDirectories: true)
        let kept = logs.appendingPathComponent("bodyslide.log"); try? fm.removeItem(at: kept); try? fm.copyItem(at: log, to: kept)
        let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        result.failed = text.split(separator: "\n").compactMap { l in l.range(of: "Failed to build '").map { String(l[$0.upperBound...].prefix { $0 != "'" }) } }
        result.files = (fm.enumerator(at: out, includingPropertiesForKeys: [.isRegularFileKey])?.allObjects as? [URL] ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }.count
        guard p.terminationStatus == 0, result.files > 0 else {
            try? fm.removeItem(at: out); try deploy(profile)
            throw BodySlideError.failed("it stopped with code \(p.terminationStatus) and built nothing — see logs/bodyslide.log")
        }
        try installGeneratedOutput(id: outID, name: "BodySlide Output (\(profile.name))",
                                   folder: "BodySlide Output - \(ModKit.profileFolderName(profile.name))", from: out, profile: &profile)
        state.fingerprints[profile.name] = inputs.fingerprint
        try writeJSON(state, to: bodySlideStateURL)
        return result
    }
}
