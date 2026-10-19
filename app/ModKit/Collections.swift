// ModKit Nexus collections: read a collection (GraphQL v2 + its bundle's collection.json), download its mods through
// the user's own account (Premium: API download links; free accounts: the user clicks each file's download on the
// website and the nxm link is matched here — Nexus rule), install them with the author's FOMOD choices, order them by
// phase + mod rules, apply the author's plugin load order, deploy — into a profile of its own, so the player's other
// setups are untouched. Removing a collection removes its profile and the mods only it used.
// Facts: GraphQL schema (api.nexusmods.com/v2/graphql introspection), collection.json keys (nexus-collection-dl, MIT,
// read for facts), docs/m1-sources.md.
import Foundation

/// https://www.nexusmods.com/games/skyrimspecialedition/collections/<slug>[/revisions/<n>],
/// https://next.nexusmods.com/skyrimspecialedition/collections/<slug>, nxm://skyrimspecialedition/collections/<slug>/revisions/<n>, or a bare slug.
public struct CollectionRef: Equatable {
    public let slug: String
    public let revision: Int?
    public init?(_ text: String) {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.range(of: #"^[a-z0-9]{6}$"#, options: .regularExpression) != nil { slug = s; revision = nil; return }
        guard let c = URLComponents(string: s) else { return nil }
        var parts = c.path.split(separator: "/").map(String.init)
        if c.scheme?.lowercased() == "nxm", let h = c.host { parts.insert(h, at: 0) }
        guard let i = parts.firstIndex(of: "collections"), i + 1 < parts.count else { return nil }
        if i > 0, parts[i - 1].lowercased() != nexusGame { return nil }
        slug = parts[i + 1]
        if let r = parts.firstIndex(of: "revisions"), r + 1 < parts.count { revision = Int(parts[r + 1]) } else { revision = nil }
    }
}

public struct CollectionFile: Equatable {
    public let modID: Int, fileID: Int
    public let modName: String, fileName: String, version: String
    public let size: Int64
    public let optional: Bool
}

public struct CollectionInfo: Equatable {
    public let slug: String, name: String, revision: Int
    public let downloadLink: String          // relative API path to the bundle's download links
    public let gameVersions: [String]
    public let totalSize: Int64
    public let files: [CollectionFile]
}

/// One entry of collection.json "mods".
public struct CollectionMod: Equatable {
    public var name: String
    public var optional: Bool
    public var phase: Int
    public var sourceType: String            // nexus | bundle | browse | direct | manual
    public var modID: Int?, fileID: Int?
    public var md5: String?
    public var logicalFilename: String?
    public var url: String?
    public var instructions: String?
    public var choices: [String: Any]?
    public static func == (a: CollectionMod, b: CollectionMod) -> Bool { a.name == b.name && a.modID == b.modID && a.fileID == b.fileID && a.sourceType == b.sourceType }
}

public struct CollectionRule: Equatable { public let type: String; public let source: [String: String]; public let reference: [String: String] }

public struct CollectionManifest {
    public var name = ""
    public var installInstructions = ""
    public var mods: [CollectionMod] = []
    public var rules: [CollectionRule] = []
    public var loadOrder: [LoadOrderEntry] = []
    public var bundleDir: URL?               // extracted bundle (bundled files)

    public static func parse(_ data: Data) throws -> CollectionManifest {
        guard let j = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw NexusError.badResponse("collection.json") }
        var m = CollectionManifest()
        let info = j["info"] as? [String: Any] ?? [:]
        m.name = info["name"] as? String ?? ""
        m.installInstructions = info["installInstructions"] as? String ?? ""
        func int(_ v: Any?) -> Int? { (v as? Int) ?? (v as? String).flatMap(Int.init) ?? (v as? Double).map(Int.init) }
        func strings(_ v: Any?) -> [String: String] {
            ((v as? [String: Any]) ?? [:]).reduce(into: [:]) { r, kv in if let s = kv.value as? String { r[kv.key] = s } else if let i = int(kv.value) { r[kv.key] = String(i) } }
        }
        for e in j["mods"] as? [[String: Any]] ?? [] {
            let src = e["source"] as? [String: Any] ?? [:]
            m.mods.append(CollectionMod(name: e["name"] as? String ?? "", optional: e["optional"] as? Bool ?? false, phase: int(e["phase"]) ?? 0,
                                        sourceType: (src["type"] as? String ?? "nexus").lowercased(), modID: int(src["modId"]), fileID: int(src["fileId"]),
                                        md5: src["md5"] as? String, logicalFilename: src["logicalFilename"] as? String, url: src["url"] as? String,
                                        instructions: (src["instructions"] as? String) ?? (e["instructions"] as? String), choices: e["choices"] as? [String: Any]))
        }
        for r in j["modRules"] as? [[String: Any]] ?? [] {
            m.rules.append(CollectionRule(type: (r["type"] as? String ?? "").lowercased(), source: strings(r["source"]), reference: strings(r["reference"])))
        }
        let lo = (j["loadOrder"] as? [[String: Any]]) ?? (j["plugins"] as? [[String: Any]]) ?? []
        m.loadOrder = lo.compactMap { e in
            guard let n = (e["name"] as? String) ?? (e["id"] as? String), !n.isEmpty else { return nil }
            return LoadOrderEntry(name: n, active: e["enabled"] as? Bool ?? true)
        }
        return m
    }

    /// FOMOD choices of a mod as "step/group" → option names (FomodInstaller.replay). Vortex format:
    /// {"type":"fomod","options":[{"name":step,"groups":[{"name":group,"choices":[{"name":option,"idx":n}]}]}]}.
    public static func fomodChoices(_ c: [String: Any]?) -> [String: [String]]? {
        guard let opts = c?["options"] as? [[String: Any]] else { return nil }
        var r: [String: [String]] = [:]
        for step in opts {
            let s = step["name"] as? String ?? ""
            for g in step["groups"] as? [[String: Any]] ?? [] {
                r["\(s)/\(g["name"] as? String ?? "")"] = (g["choices"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
            }
        }
        return r
    }

    /// Mods ordered for priority: phases first, then the author's before/after/requires rules, stable by list order.
    public func ordered(_ subset: [CollectionMod]) -> [CollectionMod] {
        func key(_ ref: [String: String]) -> Int? {
            subset.firstIndex { m in
                (ref["logicalFileName"].map { $0 == m.logicalFilename } ?? false) || (ref["fileMD5"].map { $0 == m.md5 } ?? false)
                    || (ref["modId"].flatMap(Int.init).map { $0 == m.modID } ?? false)
            }
        }
        var after = [Set<Int>](repeating: [], count: subset.count)   // after[b] contains a: a loads (wins less) before b
        for r in rules {
            guard let s = key(r.source), let t = key(r.reference), s != t else { continue }
            switch r.type {
            case "before": after[t].insert(s)
            case "after", "requires": after[s].insert(t)
            default: break
            }
        }
        var placed = Set<Int>(), visiting = Set<Int>(), out: [Int] = []
        func visit(_ i: Int) {
            guard !placed.contains(i), !visiting.contains(i) else { return }
            visiting.insert(i)
            for a in after[i].sorted(by: { (subset[$0].phase, $0) < (subset[$1].phase, $1) }) { visit(a) }
            visiting.remove(i); placed.insert(i); out.append(i)
        }
        for i in subset.indices.sorted(by: { (subset[$0].phase, $0) < (subset[$1].phase, $1) }) { visit(i) }
        return out.map { subset[$0] }
    }
}

extension NexusClient {
    public static let graphqlURL = URL(string: "https://api.nexusmods.com/v2/graphql")!

    func graphql(_ query: String, _ variables: [String: Any]) async throws -> [String: Any] {
        var req = URLRequest(url: NexusClient.graphqlURL, timeoutInterval: 30)
        req.httpMethod = "POST"
        req.httpBody = try JSONSerialization.data(withJSONObject: ["query": query, "variables": variables])
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let k = apiKey { req.setValue(k, forHTTPHeaderField: "apikey") }
        req.setValue(appName, forHTTPHeaderField: "Application-Name")
        req.setValue(appVersion, forHTTPHeaderField: "Application-Version")
        req.setValue("\(appName)/\(appVersion) (macOS; Apple Silicon)", forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await session.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200, let j = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NexusError.http((resp as? HTTPURLResponse)?.statusCode ?? -1, "GraphQL")
        }
        if let errs = j["errors"] as? [[String: Any]], !errs.isEmpty { throw NexusError.badResponse(errs.compactMap { $0["message"] as? String }.joined(separator: "; ")) }
        return j["data"] as? [String: Any] ?? [:]
    }

    public func collection(_ ref: CollectionRef) async throws -> CollectionInfo {
        var vars: [String: Any] = ["s": ref.slug]
        if let r = ref.revision { vars["r"] = r }
        let d = try await graphql("""
            query($s: String!, $r: Int) { collectionRevision(slug: $s, revision: $r, domainName: "\(nexusGame)") {
              revisionNumber downloadLink totalSize gameVersions { reference } collection { name slug game { domainName } }
              modFiles { fileId optional file { fileId name version sizeInBytes mod { modId name } } } } }
            """, vars)
        guard let r = d["collectionRevision"] as? [String: Any], let col = r["collection"] as? [String: Any] else {
            throw NexusError.badResponse("collection \(ref.slug) not found")
        }
        let game = ((col["game"] as? [String: Any])?["domainName"] as? String ?? nexusGame).lowercased()
        guard game == nexusGame else { throw NexusError.wrongGame(game) }
        func i64(_ v: Any?) -> Int64 { (v as? Int64) ?? (v as? Int).map(Int64.init) ?? (v as? String).flatMap(Int64.init) ?? 0 }
        let files: [CollectionFile] = (r["modFiles"] as? [[String: Any]] ?? []).compactMap { mf in
            guard let f = mf["file"] as? [String: Any], let m = f["mod"] as? [String: Any], let mid = m["modId"] as? Int, let fid = f["fileId"] as? Int else { return nil }
            return CollectionFile(modID: mid, fileID: fid, modName: m["name"] as? String ?? "", fileName: f["name"] as? String ?? "",
                                  version: f["version"] as? String ?? "", size: i64(f["sizeInBytes"]), optional: mf["optional"] as? Bool ?? false)
        }
        return CollectionInfo(slug: col["slug"] as? String ?? ref.slug, name: col["name"] as? String ?? ref.slug, revision: r["revisionNumber"] as? Int ?? 0,
                              downloadLink: r["downloadLink"] as? String ?? "", gameVersions: (r["gameVersions"] as? [[String: Any]] ?? []).compactMap { $0["reference"] as? String },
                              totalSize: i64(r["totalSize"]), files: files)
    }

    /// The bundle (collection.json + bundled files): its download_link endpoint returns CDN URLs.
    public func downloadBundle(_ info: CollectionInfo, into dir: URL) async throws -> CollectionManifest {
        let path = info.downloadLink.hasPrefix("/") ? String(info.downloadLink.dropFirst()) : info.downloadLink
        let any = try await request(path, absolute: URL(string: "https://api.nexusmods.com/" + path))
        let links = ((any as? [String: Any])?["download_links"] as? [[String: Any]]) ?? []
        guard let s = links.first?["URI"] as? String, let url = URL(string: s) else { throw NexusError.badResponse("collection bundle link") }
        let archive = dir.appendingPathComponent("bundle.7z")
        try await NexusDownloader(client: self, folder: dir).fetch(url, to: archive, expectedSize: nil) { _, _ in }
        let x = dir.appendingPathComponent("bundle")
        try Installer.extract(archive, to: x)
        guard let cj = FileManager.default.enumerator(at: x, includingPropertiesForKeys: nil)?.compactMap({ $0 as? URL })
            .first(where: { $0.lastPathComponent.lowercased() == "collection.json" }) else { throw NexusError.badResponse("collection.json missing in bundle") }
        var m = try CollectionManifest.parse(Data(contentsOf: cj))
        m.bundleDir = cj.deletingLastPathComponent()
        return m
    }
}

extension NexusDownloader {
    /// An archive of this Nexus file already in the downloads folder (its .meta.json names the file; size or MD5 must
    /// match when known) — no API call, no click for free accounts.
    public func existingDownload(modID: Int, fileID: Int, md5: String?, size: Int64?) -> URL? {
        let fm = FileManager.default
        for f in (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey])) ?? [] where f.pathExtension == "json" && f.lastPathComponent.hasSuffix(".meta.json") {
            guard let d = try? Data(contentsOf: f), let m = try? { let j = JSONDecoder(); j.dateDecodingStrategy = .iso8601; return try j.decode(DownloadMeta.self, from: d) }(), m.modID == modID, m.fileID == fileID else { continue }
            let archive = f.deletingPathExtension().deletingPathExtension()
            guard let sz = (try? archive.resourceValues(forKeys: [.fileSizeKey]))?.fileSize else { continue }
            if let want = md5, !want.isEmpty, let have = m.md5, !have.isEmpty { if want.lowercased() == have.lowercased() { return archive } else { continue } }
            if let want = size, want > 0 { if Int64(sz) == want { return archive } else { continue } }
            return archive
        }
        return nil
    }

    /// Download one known file (collections: name/md5/size come from the collection, so the only API call is the
    /// download link — keeps a 60-mod collection far inside the rate limits). Premium: no nxm key needed.
    public func downloadFile(modID: Int, fileID: Int, fileName: String, md5: String?, size: Int64?, key: String? = nil, expires: Int? = nil,
                             modName: String? = nil, version: String = "",
                             progress: @escaping (Int64, Int64?) -> Void = { _, _ in }) async throws -> URL {
        let urls = try await client.downloadURLs(modID: modID, fileID: fileID, key: key, expires: expires)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var name = urls[0].lastPathComponent.removingPercentEncoding ?? urls[0].lastPathComponent
        if name.isEmpty || !name.contains(".") { name = "\(fileName)-\(modID)-\(fileID).7z" }
        let dst = folder.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: dst.path), let want = md5, (try? md5Hex(of: dst)) == want.lowercased() { return dst }   // already here
        try await fetch(urls[0], to: dst, expectedSize: size.flatMap { $0 > 0 ? $0 : nil }, progress: progress)
        if let want = md5, !want.isEmpty, try md5Hex(of: dst) != want.lowercased() { try? FileManager.default.removeItem(at: dst); throw NexusError.checksum }
        let meta = DownloadMeta(modID: modID, fileID: fileID, modName: modName ?? fileName, fileName: fileName, version: version, md5: md5, downloadedAt: Date())
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        try enc.encode(meta).write(to: dst.appendingPathExtension("meta.json"), options: .atomic)
        return dst
    }
}

/// What SkyrimMT installed for a collection (to update or remove it later).
public struct InstalledCollection: Codable, Equatable {
    public var slug: String
    public var name: String
    public var revision: Int
    public var profile: String
    public var previousProfile: String
    public var modIDs: [String]          // ModRecord ids installed by this collection
    public var gameVersion: String?      // the Skyrim version the collection runs on (from the SKSE it ships)
    public var failed: [String]? = nil   // names that didn't install (Repair retries them)
}

public struct CollectionDiff: Equatable {
    public var fromRevision: Int, toRevision: Int
    public var added: [String] = [], removed: [String] = [], changed: [String] = []
    public var summary: String {
        var parts: [String] = []
        if !added.isEmpty { parts.append("\(added.count) new") }
        if !changed.isEmpty { parts.append("\(changed.count) updated") }
        if !removed.isEmpty { parts.append("\(removed.count) removed") }
        return parts.isEmpty ? "load order and settings only" : parts.joined(separator: ", ")
    }
}

public enum CollectionItemState: Equatable { case queued, downloading(Double?), installing, done, reused, skipped(String), failed(String) }

extension ModKit {
    var collectionsURL: URL { stateDir.appendingPathComponent("collections.json") }
    public func installedCollections() -> [InstalledCollection] { readJSON(collectionsURL, [InstalledCollection].self) ?? [] }
    func saveCollections(_ c: [InstalledCollection]) throws { try writeJSON(c, to: collectionsURL) }

    /// Install a collection into its own profile. `progress(index, state)` reports per mod (index into `items`).
    /// Returns the profile name. Premium accounts only for unattended downloads (free accounts: nxmFor lets the caller
    /// wait for the user's own website click for that file).
    public func installCollection(info: CollectionInfo, manifest: CollectionManifest, items: [CollectionMod], client: NexusClient,
                                  gameVersion: String,
                                  progress: @escaping (Int, CollectionItemState) -> Void,
                                  nxmFor: ((CollectionMod) async -> NxmLink?)? = nil) async throws -> String {
        let earlierInstall = installedCollections().first { $0.slug == info.slug }
        // an update goes into the profile the collection already has (even if the author renamed it)
        let profileName = earlierInstall.flatMap { profile($0.profile) != nil ? $0.profile : nil } ?? ModKit.sanitize(info.name.isEmpty ? info.slug : info.name)
        // what the player added to the collection's profile (and generated output) survives an update
        let before = profile(profileName)
        let collectionMods = Set(earlierInstall?.modIDs ?? [])
        let extras = (before?.mods ?? []).filter { !collectionMods.contains($0.id) }
        var extraPlugins: [LoadOrderEntry] = []
        for e in extras { if let m = mod(e.id) {
            let names = Set(((try? FileManager.default.contentsOfDirectory(atPath: stagingFolder(m).path)) ?? []).map { $0.lowercased() })
            extraPlugins += (before?.loadOrder ?? []).filter { names.contains($0.name.lowercased()) }
        } }
        // keep the collection's metadata (reinstall / repair / diagnostics)
        if let b = manifest.bundleDir {
            let keep = stateDir.appendingPathComponent("collections/\(info.slug).json")
            try? FileManager.default.createDirectory(at: keep.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: keep)
            try? FileManager.default.copyItem(at: b.appendingPathComponent("collection.json"), to: keep)
        }
        let previous = currentProfileName
        if profile(profileName) == nil { try createProfile(profileName) }
        // installs go into the collection's profile (no deploy yet)
        try atomicWrite(profileName + "\n", to: currentURL)
        var p = try currentProfile(); p.mods = []; if let v = profile(profileName)?.gameVersion { p.gameVersion = v }; try saveProfile(p)
        let dl = NexusDownloader(client: client, folder: home.appendingPathComponent("downloads"))
        var ids: [Int: String] = [:]          // item index → ModRecord id
        var installedHere: [String] = []
        var deferred: [(Int, URL)] = []      // FOMODs whose conditions need mods installed later in this run
        var gameVersion = gameVersion
        var detectedVersion: String?
        var failedNames: [String] = []
        func install(_ i: Int, _ item: CollectionMod, archive: URL, allowDefer: Bool) throws {
            let mid = item.modID!, fid = item.fileID!
            let file = info.files.first { $0.modID == mid && $0.fileID == fid }
            progress(i, .installing)
            let (work, layout) = try beginInstall(archive: archive)
            var fomod: FomodInstaller?
            if case .fomod(_, let cfg) = layout {
                let inst = FomodInstaller(config: try FomodParser.load(cfg),
                                          context: fomodContext(gameVersion: gameVersion, stagedProfileMods: Array(ids.values)))
                if let saved = CollectionManifest.fomodChoices(item.choices) { inst.replay(saved) }
                inst.applyAllDefaults()
                inst.makeRosettaSafe()
                if allowDefer && !inst.problems().isEmpty {
                    try? FileManager.default.removeItem(at: work)
                    deferred.append((i, archive)); progress(i, .queued); return
                }
                fomod = inst
            }
            let rec = try finishInstall(work: work, layout: layout, name: item.name.isEmpty ? (file?.modName ?? "Mod \(mid)") : item.name,
                                        version: file?.version ?? "", fomod: fomod,
                                        source: SourceArchive(path: archive.path, md5: item.md5), nexus: NexusRef(modID: mid, fileID: fid))
            ids[i] = rec.id; installedHere.append(rec.id)
            progress(i, .done)
        }
        /// The game version a collection really targets: the SKSE build it ships (skse64_1_6_1170.dll → 1.6.1170).
        /// Collection metadata can be wrong (seen: "1.7.104" on a collection shipping SKSE for 1.6.1170).
        func skseVersion(_ id: String) -> String? {
            guard let m = mod(id) else { return nil }
            let root = stagingFolder(m).appendingPathComponent(Deployer.rootFolder)
            for f in (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [] {
                let l = f.lowercased()
                if l.hasPrefix("skse64_1_"), l.hasSuffix(".dll"), !l.contains("loader") {
                    return String(l.dropFirst("skse64_".count).dropLast(4)).replacingOccurrences(of: "_", with: ".")
                }
            }
            return nil
        }
        // SKSE first: its build tells every FOMOD below which game version it installs for
        let ordered = items.indices.sorted { (items[$0].modID == 30379 ? 0 : 1, $0) < (items[$1].modID == 30379 ? 0 : 1, $1) }
        // Premium: fetch the archives 4 at a time first (one CDN connection rarely fills a fast line), then install in
        // the author's order below. Free accounts click once per file, so their downloads stay one by one.
        var prefetched: [Int: URL] = [:]
        if nxmFor == nil {
            let todo = ordered.filter { i in
                let it = items[i]
                guard it.sourceType == "nexus", let mid = it.modID, let fid = it.fileID else { return false }
                return !mods.contains { $0.nexus?.modID == mid && $0.nexus?.fileID == fid }
            }
            prefetched = await withTaskGroup(of: (Int, URL?).self) { group in
                var next = 0, out: [Int: URL] = [:]
                func add() {
                    guard next < todo.count else { return }
                    let i = todo[next]; next += 1
                    let item = items[i], file = info.files.first { $0.modID == item.modID && $0.fileID == item.fileID }
                    group.addTask {
                        if let have = dl.existingDownload(modID: item.modID!, fileID: item.fileID!, md5: item.md5, size: file?.size) { return (i, have) }
                        progress(i, .downloading(nil))
                        let a = try? await dl.downloadFile(modID: item.modID!, fileID: item.fileID!, fileName: file?.fileName ?? item.name, md5: item.md5,
                                                           size: file?.size, modName: file?.modName ?? item.name, version: file?.version ?? "") { got, total in
                            progress(i, .downloading(total.map { $0 > 0 ? Double(got) / Double($0) : 0 }))
                        }
                        progress(i, .queued)
                        return (i, a)   // nil: the install loop retries it and reports the error
                    }
                }
                for _ in 0..<4 { add() }
                for await (i, url) in group { if let url { out[i] = url }; add() }
                return out
            }
        }
        for i in ordered {
            let item = items[i]
            guard item.sourceType == "nexus", let mid = item.modID, let fid = item.fileID else {
                if item.sourceType == "bundle", let b = manifest.bundleDir, let rec = try? installBundled(item, from: b) {
                    ids[i] = rec.id; installedHere.append(rec.id); progress(i, .done)
                } else {
                    progress(i, .skipped(item.sourceType == "nexus" ? "no Nexus file id" : "not on Nexus: \(item.url ?? item.instructions ?? item.sourceType)"))
                }
                continue
            }
            if let existing = mods.first(where: { $0.nexus?.modID == mid && $0.nexus?.fileID == fid }) {
                ids[i] = existing.id; progress(i, .reused)
                if mid == 30379, let v = skseVersion(existing.id) { detectedVersion = v; gameVersion = v }
                continue
            }
            do {
                progress(i, .downloading(nil))
                let file = info.files.first { $0.modID == mid && $0.fileID == fid }
                var archive: URL
                if let pre = prefetched[i] { archive = pre }
                else if let have = dl.existingDownload(modID: mid, fileID: fid, md5: item.md5, size: file?.size) { archive = have }
                else {
                    var key: String?, exp: Int?
                    if let nxmFor {
                        guard let link = await nxmFor(item) else { progress(i, .skipped("skipped by you")); failedNames.append(item.name); continue }
                        key = link.key; exp = link.expires
                    }
                    archive = try await dl.downloadFile(modID: mid, fileID: fid, fileName: file?.fileName ?? item.name, md5: item.md5,
                                                        size: file?.size, key: key, expires: exp, modName: file?.modName ?? item.name, version: file?.version ?? "") { got, total in
                        progress(i, .downloading(total.map { $0 > 0 ? Double(got) / Double($0) : 0 }))
                    }
                }
                try install(i, item, archive: archive, allowDefer: true)
                if mid == 30379, let id = ids[i], let v = skseVersion(id) { detectedVersion = v; gameVersion = v }
            } catch {
                progress(i, .failed("\(error)")); failedNames.append(item.name)
            }
        }
        // second pass: their dependencies are installed now
        for (i, archive) in deferred {
            do { try install(i, items[i], archive: archive, allowDefer: false) } catch { progress(i, .failed("\(error)")); failedNames.append(items[i].name) }
        }
        // priority: phases + the author's rules; then the author's plugin order; deploy
        let order = manifest.ordered(items)
        p = try currentProfile()
        p.mods = order.compactMap { item in items.firstIndex(of: item).flatMap { ids[$0] } }.reduce(into: [ProfileMod]()) { r, id in
            if !r.contains(where: { $0.id == id }) { r.append(ProfileMod(id: id, enabled: true)) }
        }
        for e in extras where !p.mods.contains(where: { $0.id == e.id }) && mod(e.id) != nil { p.mods.append(e) }
        p.loadOrder = manifest.loadOrder
        for e in extraPlugins where !p.loadOrder.contains(where: { $0.name.lowercased() == e.name.lowercased() }) { p.loadOrder.append(e) }
        if let v = detectedVersion { p.gameVersion = v }   // the profile remembers its Skyrim version (profile switches)
        try saveProfile(p)
        var cols = installedCollections().filter { $0.slug != info.slug }
        // mods only the previous revision used: gone from the profile → removed unless another profile uses them
        let current = Set(p.mods.map(\.id))
        let stillUsed = Set(profileNames().compactMap { profile($0) }.flatMap { $0.mods.map(\.id) })
        var earlier = earlierInstall?.modIDs ?? []
        for id in earlier where !current.contains(id) && !stillUsed.contains(id) { try? removeMod(id) }
        earlier = earlier.filter { current.contains($0) || stillUsed.contains($0) }
        cols.append(InstalledCollection(slug: info.slug, name: info.name, revision: info.revision, profile: profileName,
                                        previousProfile: previous == profileName ? (earlier.isEmpty ? "Default" : (installedCollections().first { $0.slug == info.slug }?.previousProfile ?? "Default")) : previous,
                                        modIDs: Array(Set(earlier + installedHere)), gameVersion: detectedVersion, failed: failedNames.isEmpty ? nil : failedNames))
        try saveCollections(cols)
        try deploy(p)
        return profileName
    }

    func installBundled(_ item: CollectionMod, from bundle: URL) throws -> ModRecord? {
        let fm = FileManager.default
        let candidates = ["bundled/" + item.name, "bundled/" + (item.logicalFilename ?? "")].map { bundle.appendingPathComponent($0) }
        guard let src = candidates.first(where: { fm.fileExists(atPath: $0.path) }) else { return nil }
        let out = home.appendingPathComponent("cache/install/\(UUID().uuidString)")
        try copyTree(src, to: out, skipFomod: false)
        return try addMod(name: item.name, from: out)
    }

    /// Remove a collection: back to the previous profile (deployed), delete the collection's profile, and remove the
    /// mods it installed unless another profile still uses them.
    /// What a newer revision changes for an installed collection (by Nexus mod/file).
    public func collectionDiff(slug: String, latest: CollectionInfo) -> CollectionDiff {
        let c = installedCollections().first { $0.slug == slug }
        // the collection's own records + what its profile uses (mods reused from an earlier install aren't in modIDs)
        let ids = Array(Set((c?.modIDs ?? []) + ((c.flatMap { profile($0.profile) })?.mods.map(\.id) ?? [])))
        let have = ids.compactMap { mod($0) }.compactMap { m -> (Int, Int, String)? in
            guard let n = m.nexus, let f = n.fileID else { return nil }; return (n.modID, f, m.name) }
        let haveFiles = Set(have.map { "\($0.0):\($0.1)" }), haveMods = Dictionary(have.map { ($0.0, $0.2) }, uniquingKeysWith: { a, _ in a })
        var d = CollectionDiff(fromRevision: c?.revision ?? 0, toRevision: latest.revision)
        let required = latest.files.filter { !$0.optional }
        let latestMods = Set(required.map(\.modID))
        for f in required where !haveFiles.contains("\(f.modID):\(f.fileID)") {
            if haveMods[f.modID] != nil { d.changed.append(f.modName.isEmpty ? haveMods[f.modID]! : f.modName) } else { d.added.append(f.modName) }
        }
        let latestFiles = Set(latest.files.map { "\($0.modID):\($0.fileID)" })
        // removed: only the collection's own records — anything else in its profile is kept by an update
        let own = Set(c?.modIDs ?? [])
        for id in own { if let m = mod(id), let n = m.nexus, let f = n.fileID, !latestFiles.contains("\(n.modID):\(f)") && !latestMods.contains(n.modID) { d.removed.append(m.name) } }
        d.removed.sort()
        return d
    }

    /// Put the collection author's plugin order (and which plugins are active) back into its profile; deployed right
    /// away when that profile is active. Mods are not touched.
    public func applyCollectionLoadOrder(slug: String, manifest: CollectionManifest) throws {
        guard let c = installedCollections().first(where: { $0.slug == slug }), var p = profile(c.profile) else {
            throw ModKitError.invalid("collection \(slug) has no profile")
        }
        guard !manifest.loadOrder.isEmpty else { throw ModKitError.invalid("the collection has no load order") }
        p.loadOrder = manifest.loadOrder
        if p.gameVersion == nil, let v = c.gameVersion { p.gameVersion = v }
        try saveProfile(p)
        if p.name == currentProfileName { try deploy(p) }
    }

    /// The version key to switch to for a profile's wanted version: "steam" when Steam's install IS that version (lists
    /// and collections record numbers like "1.7.104" or "1.7.104.0"), a pinned copy when one is installed (Steam can
    /// update underneath), else the number as is (the caller offers the download).
    public static func versionKey(_ wanted: String, steamVersion: String, installed: [String]) -> String {
        func norm(_ v: String) -> String { var p = v.split(separator: "."); while p.count > 3, p.last == "0" { p.removeLast() }; return p.joined(separator: ".") }
        if wanted == "steam" || wanted.isEmpty { return "steam" }
        if let pinned = installed.first(where: { norm($0) == norm(wanted) }) { return pinned }
        if !steamVersion.isEmpty, norm(steamVersion) == norm(wanted) { return "steam" }
        return wanted
    }

    /// The Skyrim version a profile runs on: its own setting, else the version of the collection that made it.
    public func effectiveGameVersion(_ profileName: String) -> String {
        if let v = profile(profileName)?.gameVersion, !v.isEmpty { return v }
        return installedCollections().first { $0.profile == profileName }?.gameVersion ?? "steam"
    }

    public func removeCollection(slug: String) throws {
        var cols = installedCollections()
        guard let c = cols.first(where: { $0.slug == slug }) else { throw ModKitError.invalid("collection \(slug) is not installed") }
        let back = profile(c.previousProfile) != nil ? c.previousProfile : "Default"
        if profile(back) == nil { try createProfile(back) }
        if currentProfileName == c.profile {
            // files the collection's mods wrote while playing go with the collection (recoverable in backups)
            let keep = home.appendingPathComponent("backups/removed-collections/\(c.slug)")
            for rel in try generatedFiles() {
                let dst = keep.appendingPathComponent(rel)
                try FileManager.default.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? FileManager.default.removeItem(at: dst)
                try FileManager.default.moveItem(at: gameDir.appendingPathComponent(rel), to: dst)
            }
        }
        _ = try switchProfile(to: back)
        try? FileManager.default.removeItem(at: profilesDir.appendingPathComponent(c.profile))
        let stillUsed = Set(profileNames().compactMap { profile($0) }.flatMap { $0.mods.map(\.id) })
        for id in c.modIDs where !stillUsed.contains(id) { try? removeMod(id) }
        cols.removeAll { $0.slug == slug }
        try saveCollections(cols)
    }
}
