// Categories from Nexus (docs/MODMANAGER.md §3A): one GraphQL request per 100 mods (legacyModsByDomain → modCategory,
// no login needed). Only empty categories are filled — a category the player typed is never overwritten.
import Foundation

extension NexusClient {
    /// Nexus category name per mod id.
    public func categories(modIDs: [Int]) async throws -> [Int: String] {
        var out: [Int: String] = [:]
        for chunk in stride(from: 0, to: modIDs.count, by: 100).map({ Array(modIDs[$0..<min($0 + 100, modIDs.count)]) }) {
            let d = try await graphql("""
                query($ids: [CompositeDomainWithIdInput!]!, $n: Int) { legacyModsByDomain(ids: $ids, count: $n) { nodes { modId modCategory { name } } } }
                """, ["ids": chunk.map { ["gameDomain": nexusGame, "modId": $0] }, "n": chunk.count])
            for n in ((d["legacyModsByDomain"] as? [String: Any])?["nodes"] as? [[String: Any]]) ?? [] {
                if let id = n["modId"] as? Int, let c = (n["modCategory"] as? [String: Any])?["name"] as? String, !c.isEmpty { out[id] = c }
            }
        }
        return out
    }
}

extension ModKit {
    /// Nexus mods without a category.
    public var modsMissingCategory: [ModRecord] { mods.filter { !$0.isSeparator && $0.nexus != nil && ($0.category ?? "").isEmpty } }

    /// Fill empty categories; returns how many mods got one.
    @discardableResult
    public func fillCategories(fetch: ([Int]) async throws -> [Int: String]) async throws -> Int {
        let todo = modsMissingCategory
        guard !todo.isEmpty else { return 0 }
        let cats = try await fetch(Array(Set(todo.compactMap { $0.nexus?.modID })).sorted())
        var n = 0
        let ids = Set(todo.map(\.id))
        editMods { all in
            for i in all.indices where ids.contains(all[i].id) {
                if let c = all[i].nexus.flatMap({ cats[$0.modID] }) { all[i].category = c; n += 1 }
            }
        }
        return n
    }
}
