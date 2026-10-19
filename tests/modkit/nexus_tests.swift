// M6 tests: nxm parsing, API client against a stubbed URLSession (no network, no real key), downloader resume + MD5.
import Foundation
import CryptoKit

/// URLProtocol stub: routes requests to a handler that returns (status, headers, body).
final class StubProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, [String: String], Data))?
    nonisolated(unsafe) static var seen: [URLRequest] = []
    /// Simulated network time per request, without blocking the loading thread (parallel downloads stay parallel).
    nonisolated(unsafe) static var latency: ((URLRequest) -> TimeInterval)?
    nonisolated(unsafe) static var inFlight = 0, peakInFlight = 0
    static let lock = NSLock()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        StubProtocol.lock.lock(); StubProtocol.seen.append(request); StubProtocol.inFlight += 1
        StubProtocol.peakInFlight = max(StubProtocol.peakInFlight, StubProtocol.inFlight); StubProtocol.lock.unlock()
        let (code, headers, body) = StubProtocol.handler?(request) ?? (404, [:], Data())
        let finish = {
            let resp = HTTPURLResponse(url: self.request.url!, statusCode: code, httpVersion: "HTTP/1.1", headerFields: headers)!
            self.client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: body)
            self.client?.urlProtocolDidFinishLoading(self)
            StubProtocol.lock.lock(); StubProtocol.inFlight -= 1; StubProtocol.lock.unlock()
        }
        if let d = StubProtocol.latency?(request), d > 0 { DispatchQueue.global().asyncAfter(deadline: .now() + d, execute: finish) } else { finish() }
    }
    override func stopLoading() {}
}

func stubSession() -> URLSession {
    let c = URLSessionConfiguration.ephemeral; c.protocolClasses = [StubProtocol.self]; return URLSession(configuration: c)
}
func json(_ o: Any) -> Data { try! JSONSerialization.data(withJSONObject: o) }

func runAsync(_ body: @escaping () async -> Void) {
    let sem = DispatchSemaphore(value: 0)
    Task { await body(); sem.signal() }
    sem.wait()
}

func nexusTests() {
    section("nxm links")
    let l = NxmLink("nxm://skyrimspecialedition/mods/12604/files/35407?key=abc&expires=4102444800&user_id=7")
    check(l?.modID == 12604 && l?.fileID == 35407 && l?.key == "abc" && l?.expires == 4102444800 && l?.userID == 7, "nxm link parsed")
    check(l?.isSkyrimSE == true && l?.isExpired == false, "game + expiry")
    check(NxmLink("nxm://skyrimspecialedition/mods/1/files/2?key=x&expires=1")?.isExpired == true, "expired link detected")
    check(NxmLink("https://www.nexusmods.com/skyrimspecialedition/mods/1") == nil, "not an nxm link")
    check(NxmLink("nxm://skyrim/mods/1/files/2")?.isSkyrimSE == false, "other game recognised")

    section("collections: refs, collection.json, ordering")
    check(CollectionRef("https://www.nexusmods.com/games/skyrimspecialedition/collections/xk05aw") == CollectionRef("xk05aw"), "collection URL → slug")
    check(CollectionRef("https://next.nexusmods.com/skyrimspecialedition/collections/xk05aw/revisions/325")?.revision == 325, "revision from URL")
    check(CollectionRef("nxm://skyrimspecialedition/collections/xk05aw/revisions/325")?.slug == "xk05aw", "nxm collection link")
    check(CollectionRef("https://www.nexusmods.com/games/fallout4/collections/abcdef") == nil, "other game's collection refused")
    let cj = """
    {"info":{"name":"Test Collection","installInstructions":"Have fun"},
     "mods":[
      {"name":"Base","optional":false,"phase":0,"source":{"type":"nexus","modId":1,"fileId":10,"md5":"aa","logicalFilename":"Base"}},
      {"name":"Patch","optional":false,"phase":0,"source":{"type":"nexus","modId":2,"fileId":20,"md5":"bb","logicalFilename":"Patch"},
       "choices":{"type":"fomod","options":[{"name":"Main","groups":[{"name":"Variant","choices":[{"name":"Lite","idx":1}]}]}]}},
      {"name":"Late","optional":true,"phase":1,"source":{"type":"nexus","modId":3,"fileId":30,"md5":"cc"}},
      {"name":"Guide","optional":false,"phase":0,"source":{"type":"browse","url":"https://example.org/mod"}}],
     "modRules":[{"type":"before","source":{"logicalFileName":"Patch"},"reference":{"logicalFileName":"Base"}},
                 {"type":"after","source":{"fileMD5":"aa"},"reference":{"fileMD5":"bb"}}],
     "loadOrder":[{"id":"base.esp","name":"Base.esp","enabled":true},{"name":"Patch.esp","enabled":false}]}
    """
    let man = try! CollectionManifest.parse(Data(cj.utf8))
    check(man.name == "Test Collection" && man.mods.count == 4 && man.rules.count == 2, "collection.json parsed")
    check(man.mods[3].sourceType == "browse" && man.mods[3].url == "https://example.org/mod", "external source kept")
    check(CollectionManifest.fomodChoices(man.mods[1].choices) == ["Main/Variant": ["Lite"]], "FOMOD choices → step/group → options")
    check(man.loadOrder == [LoadOrderEntry(name: "Base.esp", active: true), LoadOrderEntry(name: "Patch.esp", active: false)], "plugin load order")
    check(man.ordered(man.mods).map(\.name) == ["Patch", "Base", "Guide", "Late"], "rules + phases ordering (\(man.ordered(man.mods).map(\.name)))")

    section("collection removal")
    let cf = Fixture("colremove")
    let cvan = snapshot(cf.game)
    _ = cf.addMod("Own mod", ["own.txt": "mine"])           // the player's Default setup
    try! cf.kit.deploy()
    let ownState = snapshot(cf.game)
    try! cf.kit.createProfile("Test Col")
    _ = try! cf.kit.switchProfile(to: "Test Col")
    let a = cf.addMod("Col A", ["SKSE/Plugins/a.dll": "a"]), b = cf.addMod("Col B", ["b.esp": "b"])
    try! cf.kit.saveCollections([InstalledCollection(slug: "abcdef", name: "Test Col", revision: 1, profile: "Test Col", previousProfile: "Default", modIDs: [a.id, b.id])])
    try! cf.kit.deploy()
    write(cf.game.appendingPathComponent("Data/SKSE/Plugins/a.ini"), "written while playing")
    try! cf.kit.removeCollection(slug: "abcdef")
    check(snapshot(cf.game) == ownState, "after removal the game is back to the player's previous profile")
    check(cf.kit.mod(a.id) == nil && cf.kit.mod(b.id) == nil && cf.kit.profile("Test Col") == nil && cf.kit.installedCollections().isEmpty,
          "collection's mods, profile and record removed")
    check(read(cf.home.appendingPathComponent("backups/removed-collections/abcdef/Data/SKSE/Plugins/a.ini")) == "written while playing", "files its mods wrote kept in backups")
    check(cf.kit.mods.map(\.name) == ["Own mod"], "the player's own mod untouched")
    _ = cvan

    section("collection profile: author's load order is authoritative")
    let lf = Fixture("colorder")
    try! pluginBytes(flags: 1, masters: []).write(to: lf.game.appendingPathComponent("Data/Skyrim.esm"))
    let lt = lf.home.appendingPathComponent("incoming/lo"); try! fm.createDirectory(at: lt, withIntermediateDirectories: true)
    for n in ["AIO.esp", "Single.esp"] { try! pluginBytes(flags: 0, masters: ["Skyrim.esm"]).write(to: lt.appendingPathComponent(n)) }
    _ = try! lf.kit.addMod(name: "Faces", from: lt)
    var lp = try! lf.kit.currentProfile(); lp.loadOrder = [LoadOrderEntry(name: "AIO.esp", active: true)]; try! lf.kit.saveProfile(lp)
    try! lf.kit.saveCollections([InstalledCollection(slug: "zzzzzz", name: "C", revision: 1, profile: lp.name, previousProfile: "Default", modIDs: [])])
    try! lf.kit.deploy()
    check(PluginsTxt.read(lf.kit.pluginsTxt) == [LoadOrderEntry(name: "AIO.esp", active: true), LoadOrderEntry(name: "Single.esp", active: false)],
          "plugin not in the collection's load order stays inactive (\(PluginsTxt.read(lf.kit.pluginsTxt)))")

    section("Nexus client (stubbed)")
    let archive = Data((0..<300_000).map { UInt8($0 % 251) })
    let md5 = Insecure.MD5.hash(data: archive).map { String(format: "%02x", $0) }.joined()
    StubProtocol.handler = { req in
        let p = req.url!.path, q = req.url!.query ?? ""
        if req.value(forHTTPHeaderField: "apikey") == "bad" { return (401, [:], json(["message": "Please provide a valid API Key"])) }
        let rl = ["X-RL-Daily-Remaining": "2499", "X-RL-Hourly-Remaining": "99"]
        switch true {
        case p.hasSuffix("/users/validate.json"): return (200, rl, json(["name": "Tester", "is_premium": false, "is_supporter": false]))
        case p.hasSuffix("/mods/12604.json"): return (200, rl, json(["name": "SkyUI", "version": "5.2SE", "summary": "UI", "updated_timestamp": 1700000000]))
        case p.hasSuffix("/mods/12604/files.json"):
            return (200, rl, json(["files": [["file_id": 35407, "name": "SkyUI", "file_name": "SkyUI_5_2_SE-12604-5-2SE.7z", "version": "5.2SE",
                                             "category_name": "MAIN", "size_in_bytes": archive.count, "md5": md5, "uploaded_timestamp": 1600000000]]]))
        case p.hasSuffix("/files/35407/download_link.json"):
            if !q.contains("key=abc") { return (403, [:], json(["message": "You don't have permission to get download links from the API without visting nexusmods.com - this is for premium users only."])) }
            return (200, rl, json([["name": "Nexus CDN", "short_name": "CDN", "URI": "https://cdn.example/skyui.7z"]]))
        case p.hasSuffix("/md5_search/\(md5).json"):
            return (200, rl, json([["mod": ["mod_id": 12604, "name": "SkyUI", "version": "5.2SE"], "file_details": ["file_id": 35407, "name": "SkyUI", "file_name": "SkyUI.7z", "md5": md5]]]))
        case p.hasSuffix("/mods/updated.json"): return (200, rl, json([["mod_id": 12604, "latest_file_update": 4102444800, "latest_mod_activity": 4102444800]]))
        case p == "/skyui.7z":
            if let r = req.value(forHTTPHeaderField: "Range"), r.hasPrefix("bytes=") {
                let from = Int(r.dropFirst(6).dropLast())!
                return (206, [:], archive.subdata(in: from..<archive.count))
            }
            return (200, [:], archive)
        default: return (404, [:], json(["message": "not found"]))
        }
    }
    let client = NexusClient(apiKey: "good", appVersion: "0.0-test", baseURL: URL(string: "https://api.test/v1/")!, session: stubSession())
    runAsync {
        do {
            let u = try await client.validate()
            check(u.name == "Tester" && !u.premium, "validate → user")
            let sent = StubProtocol.seen.last!
            check(sent.value(forHTTPHeaderField: "Application-Name") == "SkyrimMT" && sent.value(forHTTPHeaderField: "Application-Version") == "0.0-test",
                  "identification headers sent (AUP)")
            check(client.rateLimit == RateLimit(daily: 2499, hourly: 99), "rate limit headers read")
            do { _ = try await client.downloadURLs(modID: 12604, fileID: 35407, key: nil, expires: nil); check(false, "free user without nxm key must fail") }
            catch let e as NexusError { check(e == .premiumRequired, "free user without nxm key → premium required (\(e))") }
            let ids = try await client.identify(md5: md5)
            check(ids.first?.0.modID == 12604 && ids.first?.1.fileID == 35407, "md5 identify")
            let bad = NexusClient(apiKey: "bad", appVersion: "t", baseURL: URL(string: "https://api.test/v1/")!, session: stubSession())
            do { _ = try await bad.validate(); check(false, "bad key must fail") } catch let e as NexusError { check(e == .invalidKey, "bad key → invalidKey") }
            let none = NexusClient(apiKey: nil, appVersion: "t", session: stubSession())
            do { _ = try await none.validate(); check(false, "no key must fail") } catch let e as NexusError { check(e == .noKey, "no key → noKey") }
        } catch { check(false, "client: \(error)") }
    }

    section("downloads")
    let dl = freshDir("downloads")
    let d = NexusDownloader(client: client, folder: dl)
    runAsync {
        do {
            // a previous, interrupted download left 100 kB
            try archive.prefix(100_000).write(to: dl.appendingPathComponent("SkyUI_5_2_SE-12604-5-2SE.7z.part"))
            StubProtocol.seen = []
            let f = try await d.download(NxmLink("nxm://skyrimspecialedition/mods/12604/files/35407?key=abc&expires=4102444800")!)
            let got = try Data(contentsOf: f); check(got == archive, "download resumed and complete")
            check(StubProtocol.seen.contains { $0.value(forHTTPHeaderField: "Range") == "bytes=100000-" }, "resume used an HTTP Range request")
            let meta = try JSONDecoder.iso.decode(DownloadMeta.self, from: Data(contentsOf: f.appendingPathExtension("meta.json")))
            check(meta.modID == 12604 && meta.fileID == 35407 && meta.md5 == md5, "meta.json sidecar")
            do { _ = try await d.download(NxmLink("nxm://skyrim/mods/1/files/2?key=a&expires=4102444800")!); check(false, "wrong game") }
            catch let e as NexusError { check(e == .wrongGame("skyrim"), "wrong game refused") }
            do { _ = try await d.download(NxmLink("nxm://skyrimspecialedition/mods/12604/files/35407?key=abc&expires=1")!); check(false, "expired") }
            catch let e as NexusError { check(e == .linkExpired, "expired link refused before any request") }
            // update check: mod installed before the reported update
            let f2 = Fixture("updates")
            _ = f2.addMod("SkyUI", ["Interface/skyui.swf": "x"])
            var rec = f2.kit.mods[0]; rec.nexus = NexusRef(modID: 12604, fileID: 35407)
            f2.kit.replaceMod(at: 0, with: rec)
            let upd = try await f2.kit.modsWithUpdates(client: client)
            check(upd.map(\.name) == ["SkyUI"], "update check via updated.json")
        } catch { check(false, "downloads: \(error)") }
    }
}

extension JSONDecoder { static var iso: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d } }
