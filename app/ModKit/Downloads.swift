// Downloads folder index (docs/MODMANAGER.md §3D): each archive with its Nexus metadata (.meta.json sidecar), size, date
// and the installed mod it belongs to (same archive path, else same Nexus file), plus deletion with the sidecar.
import Foundation

public struct DownloadEntry: Identifiable, Equatable {
    public var id: String { url.path }
    public let url: URL
    public var name: String               // mod name from metadata, else the file name
    public var version: String
    public var size: Int64
    public var date: Date
    public var nexus: NexusRef?
    public var installedModID: String?    // the mod installed from this archive
}

extension ModKit {
    public var downloadsDir: URL { home.appendingPathComponent("downloads") }
    static let archiveExtensions: Set<String> = ["7z", "zip", "rar", "gz", "tgz", "tar", "bsa", "fomod"]

    public func downloadEntries() -> [DownloadEntry] {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: downloadsDir, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])) ?? []
        let byPath = Dictionary(mods.compactMap { m in m.source.map { ($0.path, m.id) } }, uniquingKeysWith: { a, _ in a })
        let byFile = Dictionary(mods.compactMap { m in m.nexus?.fileID.map { ($0, m.id) } }, uniquingKeysWith: { a, _ in a })
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return files.filter { ModKit.archiveExtensions.contains($0.pathExtension.lowercased()) }.map { u in
            let v = try? u.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let meta = (try? Data(contentsOf: u.appendingPathExtension("meta.json"))).flatMap { try? dec.decode(DownloadMeta.self, from: $0) }
            let nexus = meta.map { NexusRef(modID: $0.modID, fileID: $0.fileID) }
            return DownloadEntry(url: u, name: meta?.modName ?? u.deletingPathExtension().lastPathComponent, version: meta?.version ?? "",
                                 size: Int64(v?.fileSize ?? 0), date: v?.contentModificationDate ?? .distantPast, nexus: nexus,
                                 installedModID: byPath[u.path] ?? meta.flatMap { byFile[$0.fileID] })
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Delete archives (and their .meta.json). Installed mods keep working; only a reinstall would need the archive again.
    @discardableResult
    public func deleteDownloads(_ urls: [URL]) -> Int64 {
        var freed: Int64 = 0
        for u in urls where u.deletingLastPathComponent().standardizedFileURL == downloadsDir.standardizedFileURL {
            freed += Int64((try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            try? FileManager.default.removeItem(at: u)
            try? FileManager.default.removeItem(at: u.appendingPathExtension("meta.json"))
        }
        return freed
    }
}

extension ModKit {
    /// Wabbajack's archive cache (kept so a list update only downloads what changed).
    public var wabbajackDownloadsDir: URL { wabbajackDir.appendingPathComponent("downloads") }

    /// Bytes of a folder's files (allocated size; APFS clones count fully).
    public static func folderSize(_ url: URL) -> Int64 {
        guard let en = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey]) else { return 0 }
        var n: Int64 = 0
        for case let u as URL in en {
            let v = try? u.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey])
            if v?.isRegularFile == true { n += Int64(v?.totalFileAllocatedSize ?? 0) }
        }
        return n
    }

    /// Empty Wabbajack's archive cache (the lists stay installed; an update downloads again).
    public func clearWabbajackDownloads() throws -> Int64 {
        let d = wabbajackDownloadsDir, size = ModKit.folderSize(d)
        let fm = FileManager.default
        for f in (try? fm.contentsOfDirectory(at: d, includingPropertiesForKeys: nil)) ?? [] { try fm.removeItem(at: f) }
        return size
    }
}
