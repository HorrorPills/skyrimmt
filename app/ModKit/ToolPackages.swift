// Prebuilt native tools (Pandora, BodySlide, the Wabbajack engine) published with each SkyrimMT release. Downloaded
// the first time a profile needs one, checksum-verified, unpacked into $SKYRIM_HOME/tools/<folder>. URLs and
// checksums come from config/release.conf (<NAME>_URL / <NAME>_SHA256). Sources: tools/<name>/build.sh + patch.
import Foundation
import CryptoKit

public struct ToolPackage: Equatable {
    public let name: String          // shown to the player
    public let folder: String        // tools/<folder>
    public let executable: String    // relative to the folder: present = installed
    public let url: URL
    public let sha256: String
}

public enum ToolPackageError: Error, CustomStringConvertible {
    case download(String), checksum(String), unpack(String)
    public var description: String {
        switch self {
        case .download(let n): return "couldn't download \(n)"
        case .checksum(let n): return "\(n) download is damaged (checksum mismatch)"
        case .unpack(let n): return "couldn't unpack \(n)"
        }
    }
}

extension ModKit {
    /// Known packages, from release.conf (shell syntax: KEY="value").
    public static func toolPackages(conf: URL) -> [String: ToolPackage] {
        var kv: [String: String] = [:]
        for line in ((try? String(contentsOf: conf, encoding: .utf8)) ?? "").split(whereSeparator: \.isNewline) {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard !t.hasPrefix("#"), let eq = t.firstIndex(of: "=") else { continue }
            kv[String(t[..<eq])] = String(t[t.index(after: eq)...]).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
        let defs: [(key: String, name: String, folder: String, exe: String)] = [
            ("PANDORA", "Pandora Behaviour Engine", "pandora", "Pandora Behaviour Engine+"),
            ("BODYSLIDE", "BodySlide", "bodyslide", "BodySlide"),
            ("WABBAJACK", "Wabbajack engine", "wabbajack", "jackify-engine"),
        ]
        var out: [String: ToolPackage] = [:]
        for d in defs {
            guard let u = kv[d.key + "_URL"].flatMap(URL.init(string:)), let sum = kv[d.key + "_SHA256"], !sum.isEmpty else { continue }
            out[d.folder] = ToolPackage(name: d.name, folder: d.folder, executable: d.exe, url: u, sha256: sum.lowercased())
        }
        return out
    }

    public func toolInstalled(_ p: ToolPackage) -> Bool {
        FileManager.default.isExecutableFile(atPath: home.appendingPathComponent("tools/\(p.folder)/\(p.executable)").path)
    }

    /// Download, verify and unpack a package (no-op when installed). The archive holds one top folder `<folder>/`.
    public func installToolPackage(_ p: ToolPackage) throws {
        guard !toolInstalled(p) else { return }
        let fm = FileManager.default
        let cache = home.appendingPathComponent("cache/tools"), tools = home.appendingPathComponent("tools")
        try fm.createDirectory(at: cache, withIntermediateDirectories: true)
        try fm.createDirectory(at: tools, withIntermediateDirectories: true)
        let archive = cache.appendingPathComponent(p.url.lastPathComponent)
        if !fm.fileExists(atPath: archive.path) || (try? ModKit.sha256(of: archive)) != p.sha256 {
            let sem = DispatchSemaphore(value: 0)
            var tmp: URL?, failure: Error?
            URLSession.shared.downloadTask(with: p.url) { u, r, e in
                if let u, (r as? HTTPURLResponse).map({ $0.statusCode == 200 }) ?? true {   // (file:// in tests)
                    let keep = cache.appendingPathComponent(".dl-\(UUID().uuidString)")
                    do { try fm.moveItem(at: u, to: keep); tmp = keep } catch { failure = error }
                } else { failure = e ?? ToolPackageError.download(p.name) }
                sem.signal()
            }.resume()
            sem.wait()
            guard let t = tmp, failure == nil else { throw ToolPackageError.download(p.name) }
            try? fm.removeItem(at: archive)
            try fm.moveItem(at: t, to: archive)
        }
        guard (try? ModKit.sha256(of: archive)) == p.sha256 else { try? fm.removeItem(at: archive); throw ToolPackageError.checksum(p.name) }
        let work = tools.appendingPathComponent(".unpack-\(UUID().uuidString)")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        let (code, _) = Installer.run("/usr/bin/tar", ["-xJf", archive.path, "-C", work.path])
        let unpacked = work.appendingPathComponent(p.folder)
        guard code == 0, fm.fileExists(atPath: unpacked.path) else { throw ToolPackageError.unpack(p.name) }
        _ = Installer.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", unpacked.path])
        let dst = tools.appendingPathComponent(p.folder)
        if fm.fileExists(atPath: dst.path) { try fm.moveItem(at: dst, to: tools.appendingPathComponent(".old-\(UUID().uuidString)")) }
        try fm.moveItem(at: unpacked, to: dst)
        for n in (try? fm.contentsOfDirectory(atPath: tools.path)) ?? [] where n.hasPrefix(".old-") { Installer.forceRemove(tools.appendingPathComponent(n)) }
        try? fm.removeItem(at: archive)   // unpacked: the archive isn't needed any more
        guard toolInstalled(p) else { throw ToolPackageError.unpack(p.name) }
    }

    static func sha256(of url: URL) throws -> String {
        let h = try FileHandle(forReadingFrom: url); defer { try? h.close() }
        var hasher = SHA256()
        while let d = try h.read(upToCount: 8 << 20), !d.isEmpty { hasher.update(data: d) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
