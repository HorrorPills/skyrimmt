// Wabbajack gallery: the public list index (wabbajack-tools/mod-lists repositories.json → each author repository's
// modlists.json), Skyrim SE lists only, cached for a day in $SKYRIM_HOME/wabbajack/gallery.json.
import Foundation

public struct WabbajackGalleryEntry: Codable, Identifiable, Equatable {
    public var id: String { machineURL }
    public var title: String
    public var author: String
    public var version: String
    public var description: String
    public var nsfw: Bool
    public var machineURL: String        // namespaced "repository/list" (what the engine's -m takes)
    public var downloadSize: Int64
    public var installSize: Int64
    public var archives: Int
    public var readme: String?
    public var image: String?
}

extension ModKit {
    var galleryURL: URL { wabbajackDir.appendingPathComponent("gallery.json") }

    public func cachedGallery() -> [WabbajackGalleryEntry]? { readJSON(galleryURL, [WabbajackGalleryEntry].self) }

    /// Fetch the gallery (or the cached copy when younger than a day and `force` is false).
    public func loadWabbajackGallery(force: Bool = false) async throws -> [WabbajackGalleryEntry] {
        if !force, let d = try? galleryURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
           Date().timeIntervalSince(d) < 86400, let c = cachedGallery() { return c }
        let index = URL(string: "https://raw.githubusercontent.com/wabbajack-tools/mod-lists/master/repositories.json")!
        let (data, _) = try await URLSession.shared.data(from: index)
        guard let repos = try JSONSerialization.jsonObject(with: data) as? [String: String] else { throw WabbajackError.failed("gallery index unreadable") }
        let entries = await withTaskGroup(of: [WabbajackGalleryEntry].self) { group in
            for (repo, url) in repos {
                group.addTask {
                    guard let u = URL(string: url), let (d, _) = try? await URLSession.shared.data(from: u),
                          let lists = try? JSONSerialization.jsonObject(with: d) as? [[String: Any]] else { return [] }
                    return lists.compactMap { ModKit.galleryEntry($0, repo: repo) }
                }
            }
            var all: [WabbajackGalleryEntry] = []
            for await e in group { all += e }
            return all
        }
        let sorted = entries.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        try FileManager.default.createDirectory(at: wabbajackDir, withIntermediateDirectories: true)
        try writeJSON(sorted, to: galleryURL)
        return sorted
    }

    static func galleryEntry(_ m: [String: Any], repo: String) -> WabbajackGalleryEntry? {
        guard (m["game"] as? String)?.lowercased() == "skyrimspecialedition",
              let links = m["links"] as? [String: Any], let machine = links["machineURL"] as? String, !machine.isEmpty else { return nil }
        let meta = m["download_metadata"] as? [String: Any] ?? [:]
        func i64(_ v: Any?) -> Int64 { (v as? Int64) ?? (v as? Int).map(Int64.init) ?? (v as? Double).map { Int64($0) } ?? 0 }
        return WabbajackGalleryEntry(title: m["title"] as? String ?? machine, author: m["author"] as? String ?? repo,
                                     version: m["version"] as? String ?? "", description: m["description"] as? String ?? "",
                                     nsfw: m["nsfw"] as? Bool ?? false, machineURL: "\(repo)/\(machine)",
                                     downloadSize: i64(meta["SizeOfArchives"]), installSize: i64(meta["SizeOfInstalledFiles"]),
                                     archives: Int(i64(meta["NumberOfArchives"])),
                                     readme: links["readme"] as? String, image: links["image"] as? String)
    }

    /// Download only the .wabbajack file of a gallery list (to read its game version before installing).
    public func downloadWabbajackFile(_ e: WabbajackEngine, machineURL: String) throws -> URL {
        let dir = wabbajackDir.appendingPathComponent("list-files")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let out = dir.appendingPathComponent(ModKit.sanitize(machineURL.replacingOccurrences(of: "/", with: "_@@_")) + ".wabbajack")
        let p = Process()
        p.executableURL = e.engine
        p.currentDirectoryURL = e.engine.deletingLastPathComponent()
        p.arguments = ["download-wabbajack-file", "-m", machineURL, "-o", out.path]
        var env = ProcessInfo.processInfo.environment
        env["JACKIFY_DATA_DIR"] = wabbajackDir.appendingPathComponent("data").path
        p.environment = env
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try p.run(); p.waitUntilExit()
        guard p.terminationStatus == 0, FileManager.default.fileExists(atPath: out.path) else {
            throw WabbajackError.failed("couldn't download the list file for \(machineURL)")
        }
        return out
    }
}
