// LOOT rules (docs/MODMANAGER.md §3B): "load A after B" in LOOT's userlist (config/modkit/loot-userlist.yaml), which
// the LOOT helper passes to libloot — the same file format LOOT itself writes:
//   plugins:
//     - name: 'A.esp'
//       after:
//         - 'B.esp'
// (libloot metadata/plugin_metadata.rs: "name", "after"; files may be plain strings — metadata/file.rs.)
import Foundation

extension ModKit {
    var lootUserlistURL: URL { home.appendingPathComponent("config/modkit/loot-userlist.yaml") }

    /// plugin → plugins it must load after (as written by SkyrimMT).
    public func lootRules() -> [String: [String]] {
        guard let text = try? String(contentsOf: lootUserlistURL, encoding: .utf8) else { return [:] }
        var out: [String: [String]] = [:], current: String?, inAfter = false
        func unquote(_ s: Substring) -> String {
            var t = s.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("'") && t.hasSuffix("'") && t.count >= 2 { t = String(t.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'") }
            else if t.hasPrefix("\"") && t.hasSuffix("\"") && t.count >= 2 { t = String(t.dropFirst().dropLast()) }
            return t
        }
        for line in text.components(separatedBy: .newlines) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("- name:") { current = unquote(t.dropFirst(7)); inAfter = false; if out[current!] == nil { out[current!] = [] } }
            else if t == "after:" { inAfter = true }
            else if inAfter, t.hasPrefix("- "), let c = current { out[c, default: []].append(unquote(t.dropFirst(2))) }
            else if !t.isEmpty && !t.hasPrefix("#") && t.hasSuffix(":") { inAfter = false }
        }
        return out.filter { !$0.value.isEmpty }
    }

    public func setLoadAfter(_ plugin: String, after: [String]) throws {
        var rules = lootRules()
        rules[plugin] = after.isEmpty ? nil : Array(NSOrderedSet(array: after)) as? [String]
        func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "''") + "'" }
        var y = "# Written by SkyrimMT (Plugins → Load after). LOOT userlist format.\nplugins:\n"
        for (p, a) in rules.sorted(by: { $0.key.lowercased() < $1.key.lowercased() }) {
            y += "  - name: \(q(p))\n    after:\n" + a.map { "      - \(q($0))\n" }.joined()
        }
        if rules.isEmpty { y = "# Written by SkyrimMT (Plugins → Load after). LOOT userlist format.\nplugins: []\n" }
        try FileManager.default.createDirectory(at: lootUserlistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try atomicWrite(y, to: lootUserlistURL)
    }
}
