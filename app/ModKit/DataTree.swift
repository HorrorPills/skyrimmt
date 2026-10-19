// The game's Data folder as the profile deploys it (MO2's Data tab): every file with the mod it comes from, the mods
// it overrides, and per folder which mods put files there and how many of its files more than one mod provides.
import Foundation

public final class DataNode: Identifiable {
    public let id: String                    // lowercased path below Data ("textures/actors")
    public let name: String                  // spelling of the winning file / first folder seen
    public var children: [DataNode]?         // nil = file
    public var winner: String?               // file: mod id, or ModKit.vanillaOrigin
    public var losers: [String] = []         // file: overridden mod ids (vanilla included)
    public var mods: [String: Int] = [:]     // folder: mod id → files it has below (overridden ones included)
    public var conflicts = 0                 // folder: files below provided by more than one source
    public var files = 0                     // folder: files below
    init(id: String, name: String, folder: Bool) { self.id = id; self.name = name; children = folder ? [] : nil }
    public var isFolder: Bool { children != nil }
}

extension ModKit {
    public static let vanillaOrigin = "vanilla"

    /// Build the tree from a deploy plan plus the game's own Data files (baseline, relative to the game folder).
    public static func dataTree(_ plan: DeployPlan, baseline: [String]) -> DataNode {
        let root = DataNode(id: "", name: "Data", folder: true)
        var index: [String: DataNode] = ["": root]
        func folder(_ path: String, _ name: String) -> DataNode {
            if let n = index[path] { return n }
            let parentPath = (path as NSString).deletingLastPathComponent
            let parent = folder(parentPath, (parentPath as NSString).lastPathComponent)
            let n = DataNode(id: path, name: name, folder: true)
            parent.children!.append(n); index[path] = n
            return n
        }
        var vanilla: [String: String] = [:]   // key below Data → spelling
        for rel in baseline where rel.lowercased().hasPrefix("data/") { vanilla[String(rel.lowercased().dropFirst(5))] = String(rel.dropFirst(5)) }
        var entries: [(key: String, rel: String, winner: String, losers: [String])] = []
        for (k, f) in plan.files where k.hasPrefix("data/") {
            let key = String(k.dropFirst(5))
            var losers = plan.overridden[k] ?? []
            if vanilla[key] != nil { losers.insert(vanillaOrigin, at: 0) }
            entries.append((key, String(f.rel.dropFirst(5)), f.modID, losers))
        }
        for (key, rel) in vanilla where plan.files["data/" + key] == nil { entries.append((key, rel, vanillaOrigin, [])) }
        for e in entries {
            let parts = e.rel.split(separator: "/").map(String.init)
            let keyParts = e.key.split(separator: "/").map(String.init)
            var path = ""
            var chain: [DataNode] = [root]
            for (i, p) in parts.dropLast().enumerated() {
                path = path.isEmpty ? keyParts[i] : path + "/" + keyParts[i]
                chain.append(folder(path, p))
            }
            let file = DataNode(id: e.key, name: parts.last ?? e.rel, folder: false)
            file.winner = e.winner; file.losers = e.losers
            chain.last!.children!.append(file); index[e.key] = file
            let conflict = !e.losers.isEmpty
            for n in chain {
                n.files += 1
                if conflict { n.conflicts += 1 }
                n.mods[e.winner, default: 0] += 1
                for l in e.losers { n.mods[l, default: 0] += 1 }
            }
        }
        func sort(_ n: DataNode) {
            n.children?.sort { a, b in a.isFolder != b.isFolder ? a.isFolder : a.name.localizedStandardCompare(b.name) == .orderedAscending }
            n.children?.forEach(sort)
        }
        sort(root)
        return root
    }

    public func dataTree(_ p: Profile? = nil) throws -> DataNode {
        let base = ((try? String(contentsOf: deployer.layout.baselineURL, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        return ModKit.dataTree(try plan(p), baseline: base.isEmpty ? deployer.listGameFiles() : base)
    }
}
