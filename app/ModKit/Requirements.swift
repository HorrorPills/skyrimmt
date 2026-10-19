// Requirements (docs/MODMANAGER.md §3A/§3E): what installed mods need and what is missing — Nexus requirements
// (GraphQL v2 Mod.modRequirements.nexusRequirements: modId, modName, notes, externalRequirement, url) plus missing
// plugin masters — and the file to install for a missing Nexus requirement (its primary main file).
// Requirements are cached per mod for a week; checking a 500-mod profile costs one request per uncached mod.
import Foundation

public struct ModRequirement: Codable, Equatable {
    public var modID: Int
    public var name: String
    public var notes: String
    public var external: Bool
    public var url: String
    /// Not a real requirement for Skyrim SE/AE on this Mac: VR-only, Legendary-Edition-only, or listed only for credit.
    public var notApplicable: Bool {
        let n = notes.lowercased(), nm = name.lowercased()
        let words = Set(nm.split { !$0.isLetter && !$0.isNumber }.map(String.init))
        if words.contains("vr") || nm.contains("skse vr") || nm.contains("sksevr") || nm.contains("skyrimvr") || nm.contains("skyrim vr") { return true }
        if ["for vr", "vr only", "vr users only", "only for vr", "skyrim vr"].contains(where: n.contains) && !n.contains("not vr") { return true }
        if ["no files needed", "no file needed", "for credit", "credit only", "for info and credit", "not required", "not needed",
            "oldrim", "legendary edition", "for le ", "le only"].contains(where: n.contains) { return true }
        return false
    }

    /// The author marked it as needed only for some options ("If you choose…", "optional", "for the … version").
    public var conditional: Bool {
        let n = notes.lowercased()
        return ["if you ", "if using", "optional", "only if", "only for", "only needed", "if you use", "for the ", "patch for", "recommended", "suggested"].contains { n.contains($0) }
    }
}

public struct RequirementIssue: Identifiable, Equatable {
    public enum State: Equatable { case missing, disabled(String) /* mod id */ }
    public var id: String { "nexus:\(requirement.modID)" }
    public var requirement: ModRequirement
    public var requiredBy: [String]          // mod names
    public var state: State
}

public struct MissingMaster: Identifiable, Equatable {
    public var id: String { master }
    public var master: String
    public var neededBy: [String]            // plugin names
}

struct RequirementCache: Codable { var fetched: [String: Date] = [:]; var reqs: [String: [ModRequirement]] = [:] }

extension NexusClient {
    /// Nexus requirements of a Skyrim SE mod (no login needed for this query).
    public func requirements(modID: Int) async throws -> [ModRequirement] {
        let d = try await graphql("""
            query($m: ID!) { mod(modId: $m, gameId: 1704) { modRequirements { nexusRequirements { nodes { modId modName notes externalRequirement url } } } } }
            """, ["m": String(modID)])
        let nodes = (((d["mod"] as? [String: Any])?["modRequirements"] as? [String: Any])?["nexusRequirements"] as? [String: Any])?["nodes"] as? [[String: Any]] ?? []
        return nodes.compactMap { n in
            let id = Int(n["modId"] as? String ?? "") ?? (n["modId"] as? Int) ?? 0
            let ext = n["externalRequirement"] as? Bool ?? false
            guard id > 0 || ext else { return nil }
            return ModRequirement(modID: id, name: n["modName"] as? String ?? "", notes: n["notes"] as? String ?? "", external: ext, url: n["url"] as? String ?? "")
        }
    }

    /// The file to install for a requirement: the primary (newest) MAIN file, else the newest file.
    public func mainFile(modID: Int) async throws -> NexusFileInfo? {
        let files = try await files(modID)
        let main = files.filter { $0.category.uppercased() == "MAIN" }
        if let primary = main.first(where: \.isPrimary) ?? files.first(where: { $0.isPrimary && $0.category.uppercased() != "OLD_VERSION" && $0.category.uppercased() != "ARCHIVED" }) { return primary }
        return (main.isEmpty ? files.filter { $0.category.uppercased() != "OLD_VERSION" && $0.category.uppercased() != "ARCHIVED" } : main)
            .max { $0.uploadedTimestamp < $1.uploadedTimestamp }
    }
}

extension ModKit {
    var requirementCacheURL: URL { stateDir.appendingPathComponent("requirements-cache.json") }

    /// Missing / disabled Nexus requirements of the enabled mods in the current profile.
    /// `fetch` is the network call (NexusClient.requirements); results are cached for `maxAge`.
    public func checkRequirements(maxAge: TimeInterval = 7 * 86400,
                                  fetch: (Int) async throws -> [ModRequirement]) async throws -> [RequirementIssue] {
        let p = try currentProfile()
        var cache = readJSON(requirementCacheURL, RequirementCache.self) ?? RequirementCache()
        let enabled = Set(p.mods.filter(\.enabled).map(\.id))
        var byNexus: [Int: (id: String, enabled: Bool)] = [:]
        for pm in p.mods { if let n = mod(pm.id)?.nexus?.modID { if byNexus[n]?.enabled != true { byNexus[n] = (pm.id, pm.enabled) } } }
        var issues: [Int: RequirementIssue] = [:]
        let now = Date()
        for pm in p.mods where enabled.contains(pm.id) {
            guard let m = mod(pm.id), let nid = m.nexus?.modID else { continue }
            let key = String(nid)
            var reqs = cache.reqs[key]
            if reqs == nil || now.timeIntervalSince(cache.fetched[key] ?? .distantPast) > maxAge {
                if let fresh = try? await fetch(nid) { reqs = fresh; cache.reqs[key] = fresh; cache.fetched[key] = now }
            }
            for r in reqs ?? [] where !r.external && r.modID != nid && !r.notApplicable {
                let have = byNexus[r.modID]
                if have?.enabled == true { continue }
                if var i = issues[r.modID] { if !i.requiredBy.contains(m.name) { i.requiredBy.append(m.name) }; issues[r.modID] = i }
                else { issues[r.modID] = RequirementIssue(requirement: r, requiredBy: [m.name], state: have.map { .disabled($0.id) } ?? .missing) }
            }
        }
        try? writeJSON(cache, to: requirementCacheURL)
        // unconditional first, then by how many mods need it
        return issues.values.sorted { a, b in
            if a.requirement.conditional != b.requirement.conditional { return !a.requirement.conditional }
            return a.requiredBy.count > b.requiredBy.count
        }
    }

    /// Masters that active plugins need but which are not installed at all (inactive ones are a load-order issue).
    public func missingMasters() -> [MissingMaster] {
        let lo = loadOrder()
        let present = Set(lo.headers.keys)
        var need: [String: [String]] = [:]
        for e in lo.entries where e.active {
            for m in lo.headers[e.name.lowercased()]?.masters ?? [] where !present.contains(m.lowercased()) {
                need[m, default: []].append(e.name)
            }
        }
        return need.map { MissingMaster(master: $0.key, neededBy: $0.value) }.sorted { $0.master < $1.master }
    }
}
