// ModKit Vortex bridge: third-party launchers made for Vortex collections (Keizaal Online's) read Vortex's deployment
// manifests to know which game files a mod manager owns: their updater then leaves those files alone (it deleted
// SkyrimMT's Keizaal.esp otherwise) and their setup sees the collection as deployed. SkyrimMT writes the same files
// from its own deploy manifest: Data/vortex.deployment.json (Data files) and vortex.deployment.dinput.json (game folder).
import Foundation

extension ModKit {
    static let vortexDataManifest = "Data/vortex.deployment.json"
    static let vortexRootManifest = "vortex.deployment.dinput.json"

    /// Write both manifests for what is deployed now; returns the number of files listed.
    @discardableResult
    public func writeVortexDeployment() throws -> Int {
        let m = try Manifest.load(deployer.layout.manifestURL)
        let names = Dictionary(mods.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        var data: [[String: String]] = [], root: [[String: String]] = []
        for e in m.entries.values.sorted(by: { $0.rel.lowercased() < $1.rel.lowercased() }) {
            let file = ["source": names[e.modID] ?? "SkyrimMT"]
            if e.rel.lowercased().hasPrefix("data/") {
                data.append(file.merging(["relPath": ModKit.windowsPath(String(e.rel.dropFirst(5)))]) { a, _ in a })
            } else {
                root.append(file.merging(["relPath": ModKit.windowsPath(e.rel)]) { a, _ in a })
            }
        }
        try writeVortexManifest(ModKit.vortexDataManifest, target: gameDir.appendingPathComponent("Data"), files: data)
        try writeVortexManifest(ModKit.vortexRootManifest, target: gameDir, files: root)
        return data.count + root.count
    }

    private func writeVortexManifest(_ rel: String, target: URL, files: [[String: String]]) throws {
        let doc: [String: Any] = ["version": 1, "instance": "skyrimmt", "targetPath": "Z:" + ModKit.windowsPath(target.path), "files": files]
        try JSONSerialization.data(withJSONObject: doc, options: [.prettyPrinted, .sortedKeys])
            .write(to: gameDir.appendingPathComponent(rel), options: .atomic)
    }

    static func windowsPath(_ p: String) -> String { p.replacingOccurrences(of: "/", with: "\\") }
}
