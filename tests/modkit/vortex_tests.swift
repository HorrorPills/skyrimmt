// Vortex bridge (ModKit/VortexBridge.swift): deployed files listed the way Vortex does for third-party launchers.
import Foundation

func vortexBridgeTests() {
    section("vortex deployment manifests")
    let f = Fixture("vortex")
    let k = f.kit
    _ = f.addMod("Keizaal Content", ["Keizaal.esp": "esp", "meshes/keizaal/a.nif": "nif"])
    _ = f.addMod("Engine Fixes - SKSE64 Preloader", ["__root__/d3dx9_42.dll": "dll"])
    _ = try! k.deploy()
    let n = try! k.writeVortexDeployment()
    check(n == 3, "every deployed file listed (\(n))")

    func manifest(_ rel: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(contentsOf: f.game.appendingPathComponent(rel)))) as? [String: Any] ?? [:]
    }
    func entries(_ doc: [String: Any]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: ((doc["files"] as? [[String: String]]) ?? []).map { ($0["relPath"] ?? "", $0["source"] ?? "") })
    }
    let data = manifest("Data/vortex.deployment.json"), root = manifest("vortex.deployment.dinput.json")
    check(entries(data) == ["Keizaal.esp": "Keizaal Content", "meshes\\keizaal\\a.nif": "Keizaal Content"],
          "Data files relative to Data, Windows separators, mod name as source (\(entries(data)))")
    check(entries(root) == ["d3dx9_42.dll": "Engine Fixes - SKSE64 Preloader"], "game-folder files in the root manifest (\(entries(root)))")
    let target = data["targetPath"] as? String ?? ""
    check(target.hasPrefix("Z:\\") && target.hasSuffix("\\Data") && !target.contains("/"), "targetPath is the Wine path of Data (\(target))")
    try? fm.removeItem(at: f.home)
}
