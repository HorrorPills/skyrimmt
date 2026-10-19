// Nexus mod details for the Mod Manager (summary, picture, author, endorsements, downloads): GraphQL
// legacyModsByDomain, 100 mods per request, no login; cached a week in nexus-details.json.
import Foundation

public struct NexusModDetails: Codable, Equatable {
    public var modID: Int
    public var name: String
    public var summary: String
    public var author: String
    public var version: String
    public var endorsements: Int
    public var downloads: Int
    public var picture: String?          // large thumbnail
    public var pictureBlurred: String?   // for adult content
    public var adult: Bool
    public var fetched: Date
}

extension NexusClient {
    public func modDetails(modIDs: [Int]) async throws -> [Int: NexusModDetails] {
        var out: [Int: NexusModDetails] = [:]
        for chunk in stride(from: 0, to: modIDs.count, by: 100).map({ Array(modIDs[$0..<min($0 + 100, modIDs.count)]) }) {
            let d = try await graphql("""
                query($ids: [CompositeDomainWithIdInput!]!, $n: Int) { legacyModsByDomain(ids: $ids, count: $n) { nodes {
                  modId name summary author version endorsements downloads thumbnailLargeUrl thumbnailLargeBlurredUrl adultContent } } }
                """, ["ids": chunk.map { ["gameDomain": nexusGame, "modId": $0] }, "n": chunk.count])
            for n in ((d["legacyModsByDomain"] as? [String: Any])?["nodes"] as? [[String: Any]]) ?? [] {
                guard let id = n["modId"] as? Int else { continue }
                out[id] = NexusModDetails(modID: id, name: n["name"] as? String ?? "", summary: n["summary"] as? String ?? "",
                                          author: n["author"] as? String ?? "", version: n["version"] as? String ?? "",
                                          endorsements: n["endorsements"] as? Int ?? 0, downloads: n["downloads"] as? Int ?? 0,
                                          picture: n["thumbnailLargeUrl"] as? String, pictureBlurred: n["thumbnailLargeBlurredUrl"] as? String,
                                          adult: n["adultContent"] as? Bool ?? false, fetched: Date())
            }
        }
        return out
    }
}

extension ModKit {
    var nexusDetailsURL: URL { stateDir.appendingPathComponent("nexus-details.json") }

    public func cachedNexusDetails() -> [Int: NexusModDetails] {
        Dictionary((readJSON(nexusDetailsURL, [NexusModDetails].self) ?? []).map { ($0.modID, $0) }, uniquingKeysWith: { a, _ in a })
    }

    /// Details for every installed Nexus mod, refreshing entries older than `maxAge` (one request per 100 mods).
    @discardableResult
    public func refreshNexusDetails(maxAge: TimeInterval = 7 * 86400, fetch: ([Int]) async throws -> [Int: NexusModDetails]) async -> [Int: NexusModDetails] {
        var have = cachedNexusDetails()
        let now = Date()
        let ids = Set(mods.compactMap { $0.nexus?.modID }).filter { id in have[id].map { now.timeIntervalSince($0.fetched) > maxAge } ?? true }
        guard !ids.isEmpty else { return have }
        if let fresh = try? await fetch(ids.sorted()) {
            for (k, v) in fresh { have[k] = v }
            try? writeJSON(Array(have.values).sorted { $0.modID < $1.modID }, to: nexusDetailsURL)
        }
        return have
    }
}

/// A search result on Nexus Mods (GraphQL `mods`, no login needed).
public struct NexusSearchHit: Identifiable, Equatable {
    public var id: Int { modID }
    public var modID: Int
    public var name: String
    public var summary: String
    public var author: String
    public var endorsements: Int
    public var downloads: Int
    public var thumbnail: String?
    public var thumbnailBlurred: String?
    public var adult: Bool
    public var category: String
}

public enum NexusSort: String, CaseIterable, Identifiable {
    case endorsements = "Most endorsed", downloads = "Most downloaded", updatedAt = "Recently updated", relevance = "Best match"
    public var id: String { rawValue }
    var field: String { switch self { case .endorsements: return "endorsements"; case .downloads: return "downloads"; case .updatedAt: return "updatedAt"; case .relevance: return "relevance" } }
}

extension NexusClient {
    public func searchMods(_ text: String, sort: NexusSort, offset: Int = 0, count: Int = 30) async throws -> (total: Int, hits: [NexusSearchHit]) {
        let q = text.trimmingCharacters(in: .whitespaces)
        var filter = "gameDomainName: [{value: \"\(nexusGame)\"}]"
        if !q.isEmpty { filter += ", nameStemmed: [{value: $q, op: MATCHES}]" }
        let sortField = (q.isEmpty && sort == .relevance) ? "endorsements" : sort.field
        // declare $q only when it is used (GraphQL rejects unused variables)
        var vars: [String: Any] = ["o": offset, "n": count]
        if !q.isEmpty { vars["q"] = q }
        let d = try await graphql("""
            query(\(q.isEmpty ? "" : "$q: String!, ")$o: Int, $n: Int) { mods(filter: { \(filter) }, sort: [{\(sortField): {direction: DESC}}], offset: $o, count: $n) {
              totalCount nodes { modId name summary author endorsements downloads thumbnailUrl thumbnailBlurredUrl adultContent modCategory { name } } } }
            """, vars)
        let m = d["mods"] as? [String: Any] ?? [:]
        let hits = (m["nodes"] as? [[String: Any]] ?? []).compactMap { n -> NexusSearchHit? in
            guard let id = n["modId"] as? Int else { return nil }
            return NexusSearchHit(modID: id, name: n["name"] as? String ?? "", summary: n["summary"] as? String ?? "", author: n["author"] as? String ?? "",
                                  endorsements: n["endorsements"] as? Int ?? 0, downloads: n["downloads"] as? Int ?? 0,
                                  thumbnail: n["thumbnailUrl"] as? String, thumbnailBlurred: n["thumbnailBlurredUrl"] as? String,
                                  adult: n["adultContent"] as? Bool ?? false, category: (n["modCategory"] as? [String: Any])?["name"] as? String ?? "")
        }
        return (m["totalCount"] as? Int ?? hits.count, hits)
    }
}
