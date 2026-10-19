// ModKit Nexus Mods integration (PLAN §8.7): nxm links, API v1 client, API key in the Keychain, downloads with resume
// + MD5 check + .meta.json sidecars, update checks via updated.json. Follows the API Acceptable Use Policy: identifies
// itself (Application-Name/Version, User-Agent), only acts on user actions, never scrapes, backs off on 429.
// Free accounts get download links only with the key/expires of an nxm link the user clicked on the website.
// Endpoint facts: docs/m1-sources.md (pynxm source + AUP). Personal API keys are for testing/personal use; a public
// release needs the registered-app SSO flow (owner touchpoint).
import Foundation
import Security
import CryptoKit

public let nexusGame = "skyrimspecialedition"

/// nxm://skyrimspecialedition/mods/<mod>/files/<file>?key=<k>&expires=<t>&user_id=<u>
public struct NxmLink: Equatable {
    public let game: String
    public let modID: Int
    public let fileID: Int
    public let key: String?
    public let expires: Int?
    public let userID: Int?

    public init?(_ s: String) {
        guard let c = URLComponents(string: s), c.scheme?.lowercased() == "nxm", let host = c.host else { return nil }
        let parts = c.path.split(separator: "/").map(String.init)
        guard parts.count >= 4, parts[0] == "mods", parts[2] == "files", let m = Int(parts[1]), let f = Int(parts[3]) else { return nil }
        let q = Dictionary((c.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        game = host.lowercased(); modID = m; fileID = f
        key = q["key"].flatMap { $0.isEmpty ? nil : $0 }; expires = q["expires"].flatMap(Int.init); userID = q["user_id"].flatMap(Int.init)
    }
    public var isSkyrimSE: Bool { game == nexusGame }
    public var isExpired: Bool { expires.map { Date(timeIntervalSince1970: TimeInterval($0)) < Date() } ?? false }
}

public enum NexusError: Error, CustomStringConvertible, Equatable {
    case noKey, invalidKey, rateLimited(retryAfter: Int?), http(Int, String), badResponse(String), premiumRequired, linkExpired, wrongGame(String), checksum
    public var description: String {
        switch self {
        case .noKey: return "Add your Nexus Mods API key first."
        case .invalidKey: return "Nexus Mods rejected the API key."
        case .rateLimited: return "Nexus Mods rate limit reached — try again later."
        case .http(let c, let m): return "Nexus Mods answered HTTP \(c)\(m.isEmpty ? "" : ": " + m)"
        case .badResponse(let m): return "Unexpected reply from Nexus Mods (\(m))."
        case .premiumRequired: return "Direct downloads need Nexus Premium — click “Mod Manager Download” on the website instead."
        case .linkExpired: return "This download link has expired — click “Mod Manager Download” on the website again."
        case .wrongGame(let g): return "This link is for \(g), not Skyrim Special Edition."
        case .checksum: return "The download is damaged (checksum mismatch)."
        }
    }
}

public struct NexusUser: Equatable { public let name: String; public let premium: Bool; public let supporter: Bool }
public struct NexusModInfo: Equatable { public let modID: Int; public let name: String; public let version: String; public let summary: String; public let updatedTimestamp: Int }
public struct NexusFileInfo: Equatable {
    public let fileID: Int; public let name: String; public let fileName: String; public let version: String
    public let category: String; public let sizeBytes: Int64?; public let md5: String?; public let uploadedTimestamp: Int
    public var isPrimary = false   // the author's main download (a mod can have several MAIN files, e.g. CBBE body + outfits)
}
public struct RateLimit: Equatable { public var daily: Int?; public var hourly: Int? }

/// Thin API v1 client. `session`/`baseURL` are injectable for offline tests.
public final class NexusClient {
    public let baseURL: URL
    public var apiKey: String?
    public let session: URLSession
    public private(set) var rateLimit = RateLimit()
    public let appName = "SkyrimMT"
    public let appVersion: String
    private var cache: [String: (Date, Data)] = [:]   // 24 h cache for mod/file info (PLAN §8.7)

    public init(apiKey: String?, appVersion: String, baseURL: URL = URL(string: "https://api.nexusmods.com/v1/")!, session: URLSession = .shared) {
        self.apiKey = apiKey; self.appVersion = appVersion; self.baseURL = baseURL; self.session = session
    }

    func request(_ path: String, query: [String: String] = [:], cacheable: Bool = false, absolute: URL? = nil,
                 method: String = "GET", form: [String: String]? = nil) async throws -> Any {
        guard let key = apiKey, !key.isEmpty else { throw NexusError.noKey }
        var comps = URLComponents(url: absolute ?? baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { comps.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) } }
        let url = comps.url!
        if cacheable, let (t, d) = cache[url.absoluteString], Date().timeIntervalSince(t) < 24 * 3600 { return try JSONSerialization.jsonObject(with: d) }
        var req = URLRequest(url: url, timeoutInterval: 30)
        req.setValue(key, forHTTPHeaderField: "apikey")
        req.setValue(appName, forHTTPHeaderField: "Application-Name")
        req.setValue(appVersion, forHTTPHeaderField: "Application-Version")
        req.setValue("\(appName)/\(appVersion) (macOS; Apple Silicon)", forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.httpMethod = method
        if let form {   // the v1 API takes POST parameters as form data
            var c = URLComponents(); c.queryItems = form.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
            req.httpBody = Data((c.percentEncodedQuery ?? "").utf8)
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        }
        let (data, resp) = try await session.data(for: req)
        guard let h = resp as? HTTPURLResponse else { throw NexusError.badResponse("no HTTP response") }
        rateLimit.daily = (h.value(forHTTPHeaderField: "X-RL-Daily-Remaining")).flatMap(Int.init) ?? rateLimit.daily
        rateLimit.hourly = (h.value(forHTTPHeaderField: "X-RL-Hourly-Remaining")).flatMap(Int.init) ?? rateLimit.hourly
        let message = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["message"] as? String ?? ""
        switch h.statusCode {
        case 200: break
        case 401: throw NexusError.invalidKey
        case 403 where message.lowercased().contains("premium"): throw NexusError.premiumRequired
        case 410: throw NexusError.linkExpired
        case 429: throw NexusError.rateLimited(retryAfter: h.value(forHTTPHeaderField: "Retry-After").flatMap(Int.init))
        default: throw NexusError.http(h.statusCode, message)
        }
        if cacheable { cache[url.absoluteString] = (Date(), data) }
        do { return try JSONSerialization.jsonObject(with: data) } catch { throw NexusError.badResponse("not JSON") }
    }

    /// Endorse a mod (Nexus API v1 POST games/{game}/mods/{id}/endorse.json, form field "version").
    public func endorse(modID: Int, version: String) async throws {
        _ = try await request("games/\(nexusGame)/mods/\(modID)/endorse.json", method: "POST", form: ["version": version])
    }

    /// Track / untrack a mod on Nexus (API v1 user/tracked_mods.json: domain_name query, mod_id form field).
    public func setTracked(modID: Int, _ on: Bool) async throws {
        _ = try await request("user/tracked_mods.json", query: ["domain_name": nexusGame], method: on ? "POST" : "DELETE", form: ["mod_id": String(modID)])
    }

    /// Mod ids the player tracks for Skyrim SE (GET user/tracked_mods.json → [{mod_id, domain_name}]).
    public func trackedMods() async throws -> Set<Int> {
        let a = try await request("user/tracked_mods.json") as? [[String: Any]] ?? []
        return Set(a.compactMap { ($0["domain_name"] as? String) == nexusGame ? $0["mod_id"] as? Int : nil })
    }

    /// The player's endorsements: Skyrim SE mod id → "Endorsed" / "Abstained" (GET user/endorsements.json).
    public func endorsements() async throws -> [Int: String] {
        let a = try await request("user/endorsements.json") as? [[String: Any]] ?? []
        var out: [Int: String] = [:]
        for e in a where (e["domain_name"] as? String) == nexusGame { if let id = e["mod_id"] as? Int { out[id] = e["status"] as? String ?? "" } }
        return out
    }

    public func validate() async throws -> NexusUser {
        guard let j = try await request("users/validate.json") as? [String: Any], let name = j["name"] as? String else { throw NexusError.badResponse("validate") }
        return NexusUser(name: name, premium: j["is_premium"] as? Bool ?? false, supporter: j["is_supporter"] as? Bool ?? false)
    }

    public func mod(_ id: Int) async throws -> NexusModInfo {
        guard let j = try await request("games/\(nexusGame)/mods/\(id).json", cacheable: true) as? [String: Any] else { throw NexusError.badResponse("mod") }
        return NexusModInfo(modID: id, name: j["name"] as? String ?? "Mod \(id)", version: j["version"] as? String ?? "",
                            summary: j["summary"] as? String ?? "", updatedTimestamp: j["updated_timestamp"] as? Int ?? 0)
    }

    public func files(_ modID: Int) async throws -> [NexusFileInfo] {
        guard let j = try await request("games/\(nexusGame)/mods/\(modID)/files.json", cacheable: true) as? [String: Any],
              let arr = j["files"] as? [[String: Any]] else { throw NexusError.badResponse("files") }
        return arr.map(Self.fileInfo)
    }

    static func fileInfo(_ f: [String: Any]) -> NexusFileInfo {
        let size: Int64? = (f["size_in_bytes"] as? Int64) ?? (f["size_in_bytes"] as? Int).map(Int64.init) ?? (f["size_kb"] as? Int).map { Int64($0) * 1024 }
        return NexusFileInfo(fileID: f["file_id"] as? Int ?? 0, name: f["name"] as? String ?? "", fileName: f["file_name"] as? String ?? "",
                             version: f["version"] as? String ?? "", category: f["category_name"] as? String ?? "",
                             sizeBytes: size, md5: f["md5"] as? String, uploadedTimestamp: f["uploaded_timestamp"] as? Int ?? 0,
                             isPrimary: (f["is_primary"] as? Bool) ?? ((f["is_primary"] as? Int) == 1))
    }

    /// Download URLs for a file. Free accounts must pass the nxm link's key + expires (the user clicked "Mod Manager
    /// Download" on the website); premium accounts may omit them. Never automated around (AUP).
    public func downloadURLs(modID: Int, fileID: Int, key: String?, expires: Int?) async throws -> [URL] {
        var q: [String: String] = [:]
        if let key, let expires { q = ["key": key, "expires": String(expires)] }
        guard let arr = try await request("games/\(nexusGame)/mods/\(modID)/files/\(fileID)/download_link.json", query: q) as? [[String: Any]] else {
            throw NexusError.badResponse("download_link")
        }
        let urls = arr.compactMap { ($0["URI"] as? String).flatMap(URL.init(string:)) }
        guard !urls.isEmpty else { throw NexusError.badResponse("no download servers") }
        return urls
    }

    /// Identify a manually added archive by its MD5 (games/…/mods/md5_search/<md5>.json).
    public func identify(md5: String) async throws -> [(NexusModInfo, NexusFileInfo)] {
        let any: Any
        do { any = try await request("games/\(nexusGame)/mods/md5_search/\(md5).json") } catch NexusError.http(404, _) { return [] }
        guard let arr = any as? [[String: Any]] else { return [] }
        return arr.compactMap { e in
            guard let m = e["mod"] as? [String: Any], let f = e["file_details"] as? [String: Any] else { return nil }
            return (NexusModInfo(modID: m["mod_id"] as? Int ?? 0, name: m["name"] as? String ?? "", version: m["version"] as? String ?? "",
                                 summary: m["summary"] as? String ?? "", updatedTimestamp: m["updated_timestamp"] as? Int ?? 0), Self.fileInfo(f))
        }
    }

    /// Mods updated in the last period ("1d", "1w", "1m"): one cheap call instead of polling every mod.
    public func updated(period: String = "1w") async throws -> [Int: Int] {
        guard let arr = try await request("games/\(nexusGame)/mods/updated.json", query: ["period": period]) as? [[String: Any]] else { return [:] }
        var r: [Int: Int] = [:]
        for e in arr { if let id = e["mod_id"] as? Int { r[id] = e["latest_file_update"] as? Int ?? e["latest_mod_activity"] as? Int ?? 0 } }
        return r
    }
}

/// The API key lives in the user's login Keychain (never in files or logs).
public enum NexusKeychain {
    static let service = "SkyrimMT Nexus Mods API key"
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cached: String??
    /// Cached after the first read: macOS may show its "allow access" prompt on that read (always after an app update,
    /// since the signature changes), so callers on the main thread should use `loadInBackground` first.
    public static func load() -> String? {
        lock.lock(); if let c = cached { lock.unlock(); return c }; lock.unlock()
        let v = loadUncached()
        lock.lock(); cached = .some(v); lock.unlock()
        return v
    }
    public static func loadInBackground(_ done: @escaping (String?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { let v = load(); DispatchQueue.main.async { done(v) } }
    }
    /// Inside the app the stable helper owns the Keychain item (see app/KeyHelper); tests/CLI use the Keychain directly.
    static var helper: URL? {
        let u = URL(fileURLWithPath: Bundle.main.bundlePath).appendingPathComponent("Contents/Helpers/skyrimmt-keyhelper")
        return FileManager.default.isExecutableFile(atPath: u.path) ? u : nil
    }
    static func runHelper(_ cmd: String, input: String? = nil) -> (ok: Bool, out: String) {
        guard let h = helper else { return (false, "") }
        let p = Process(); p.executableURL = h; p.arguments = [cmd]
        let out = Pipe(), inp = Pipe(); p.standardOutput = out; p.standardInput = inp; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return (false, "") }
        if let input { inp.fileHandleForWriting.write(Data(input.utf8)) }
        try? inp.fileHandleForWriting.close()
        let d = out.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        return (p.terminationStatus == 0, String(decoding: d, as: UTF8.self))
    }
    static func loadUncached() -> String? {
        if helper != nil {
            let r = runHelper("get")
            if r.ok, !r.out.isEmpty { return r.out }
        }
        return directLoad()
    }
    static func directLoad() -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }
    @discardableResult public static func save(_ key: String) -> Bool {
        lock.lock(); cached = .some(key); lock.unlock()
        if helper != nil { return runHelper("set", input: key).ok }
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service] as CFDictionary)
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: "apikey", kSecValueData as String: Data(key.utf8)]
        return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
    }
    public static func delete() {
        lock.lock(); cached = .some(nil); lock.unlock()
        if helper != nil { _ = runHelper("delete"); return }
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service] as CFDictionary)
    }
}

/// Sidecar written next to every downloaded archive (PLAN §8.7).
public struct DownloadMeta: Codable, Equatable {
    public var modID: Int, fileID: Int
    public var modName: String, fileName: String, version: String
    public var md5: String?
    public var downloadedAt: Date
}

public func md5Hex(of url: URL) throws -> String {
    guard let h = FileHandle(forReadingAtPath: url.path) else { throw NexusError.badResponse("can't read \(url.lastPathComponent)") }
    defer { try? h.close() }
    var md5 = Insecure.MD5()
    while true {
        let d = h.readData(ofLength: 4 << 20)
        if d.isEmpty { break }
        md5.update(data: d)
    }
    return md5.finalize().map { String(format: "%02x", $0) }.joined()
}

/// Downloads into $SKYRIM_HOME/downloads: `<name>.part` while running (resumable with HTTP Range), MD5 check against
/// the API's file info when available, `<archive>.meta.json` sidecar. One download at a time for free accounts.
public final class NexusDownloader {
    public let client: NexusClient
    public let folder: URL
    public init(client: NexusClient, folder: URL) { self.client = client; self.folder = folder }

    /// The whole flow for one nxm link. `progress(bytes, total)` is called from a background thread.
    public func download(_ link: NxmLink, progress: @escaping (Int64, Int64?) -> Void = { _, _ in }) async throws -> URL {
        guard link.isSkyrimSE else { throw NexusError.wrongGame(link.game) }
        if link.isExpired { throw NexusError.linkExpired }
        let mod = try await client.mod(link.modID)
        let file = try await client.files(link.modID).first { $0.fileID == link.fileID }
        let urls = try await client.downloadURLs(modID: link.modID, fileID: link.fileID, key: link.key, expires: link.expires)
        let name = file?.fileName.isEmpty == false ? file!.fileName : urls[0].lastPathComponent
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let dst = folder.appendingPathComponent(name)
        try await fetch(urls[0], to: dst, expectedSize: file?.sizeBytes, progress: progress)
        if let want = file?.md5, !want.isEmpty, try md5Hex(of: dst) != want.lowercased() {
            try? FileManager.default.removeItem(at: dst); throw NexusError.checksum
        }
        let meta = DownloadMeta(modID: link.modID, fileID: link.fileID, modName: mod.name, fileName: file?.name ?? name,
                                version: file?.version ?? mod.version, md5: file?.md5, downloadedAt: Date())
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]; enc.dateEncodingStrategy = .iso8601
        try enc.encode(meta).write(to: dst.appendingPathExtension("meta.json"), options: .atomic)
        return dst
    }

    /// HTTP download with resume: an existing .part continues with a Range request.
    func fetch(_ url: URL, to dst: URL, expectedSize: Int64?, progress: @escaping (Int64, Int64?) -> Void) async throws {
        let part = dst.appendingPathExtension("part")
        let have = (try? FileManager.default.attributesOfItem(atPath: part.path)[.size] as? Int64) ?? 0
        var req = URLRequest(url: url, timeoutInterval: 60)
        req.setValue("\(client.appName)/\(client.appVersion) (macOS; Apple Silicon)", forHTTPHeaderField: "User-Agent")
        if have > 0 { req.setValue("bytes=\(have)-", forHTTPHeaderField: "Range") }
        // chunks from a data delegate straight into the file: the byte-by-byte async loop this replaces topped out at
        // ~69 MB/s (CPU-bound; curl on the same server: 1.9 GB/s) — too slow for 300 GB lists on fast connections
        let writer = ChunkWriter(part: part, have: have, expectedSize: expectedSize, progress: progress)
        let session = URLSession(configuration: client.session.configuration, delegate: writer, delegateQueue: writer.queue)
        defer { session.finishTasksAndInvalidate() }
        let task = session.dataTask(with: req)
        let got: Int64 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Int64, Error>) in
                writer.done = { r in c.resume(with: r) }
                task.resume()
            }
        } onCancel: { task.cancel() }
        if let e = expectedSize, e > 0, got != e { throw NexusError.badResponse("size \(got) ≠ \(e)") }
        try? FileManager.default.removeItem(at: dst)
        try FileManager.default.moveItem(at: part, to: dst)
    }
}

/// URLSession data delegate writing each received chunk to the .part file (resume-aware).
final class ChunkWriter: NSObject, URLSessionDataDelegate {
    let queue: OperationQueue = { let q = OperationQueue(); q.maxConcurrentOperationCount = 1; return q }()
    let part: URL, expectedSize: Int64?, progress: (Int64, Int64?) -> Void
    var have: Int64
    var out: FileHandle?
    var failure: Error?
    var done: ((Result<Int64, Error>) -> Void)?
    var lastReport = Date.distantPast

    init(part: URL, have: Int64, expectedSize: Int64?, progress: @escaping (Int64, Int64?) -> Void) {
        self.part = part; self.have = have; self.expectedSize = expectedSize; self.progress = progress
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let h = response as? HTTPURLResponse, h.statusCode == 200 || h.statusCode == 206 else {
            failure = NexusError.http((response as? HTTPURLResponse)?.statusCode ?? -1, "download"); completionHandler(.cancel); return
        }
        let fm = FileManager.default
        if h.statusCode == 200 { have = 0; fm.createFile(atPath: part.path, contents: nil) }   // server ignored Range: start over
        if !fm.fileExists(atPath: part.path) { fm.createFile(atPath: part.path, contents: nil) }
        do {
            let f = try FileHandle(forWritingTo: part)
            if have > 0 { try f.seekToEnd() } else { try f.truncate(atOffset: 0) }
            out = f
            completionHandler(.allow)
        } catch { failure = error; completionHandler(.cancel) }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let out, failure == nil else { return }
        do { try out.write(contentsOf: data); have += Int64(data.count) } catch { failure = error; dataTask.cancel(); return }
        let now = Date()
        if now.timeIntervalSince(lastReport) >= 0.25 { lastReport = now; progress(have, expectedSize) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        try? out?.close()
        progress(have, expectedSize)
        if let f = failure { done?(.failure(f)) }
        else if let e = error { done?(.failure((e as? URLError)?.code == .cancelled ? CancellationError() : e)) }
        else { done?(.success(have)) }
        done = nil
    }
}

extension ModKit {
    /// Mods with a Nexus id that Nexus reports as updated since they were installed (one updated.json call).
    public func modsWithUpdates(client: NexusClient, period: String = "1m") async throws -> [ModRecord] {
        let upd = try await client.updated(period: period)
        return mods.filter { m in
            guard let n = m.nexus, let ts = upd[n.modID] else { return false }
            return Date(timeIntervalSince1970: TimeInterval(ts)) > m.installedAt
        }
    }
}
