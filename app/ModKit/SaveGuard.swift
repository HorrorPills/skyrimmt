// Save guard: before a mod or plugin is turned off or removed, find the playthroughs that use it. A save keeps the
// plugin's records, scripts and quest state baked in; taking the plugin away mid-playthrough is the most common way
// long playthroughs break. Checked against the newest save of each character in the profile's own saves folder.
import Foundation

public struct PlaythroughRisk: Equatable {
    public var save: SaveInfo              // the character's newest save
    public var plugins: [String]           // plugins it uses that would be gone
}

/// Parsed saves by path + modification time (reading one decodes up to 1 MB: cheap, but the guard runs on every toggle).
final class SaveInfoCache {
    static let shared = SaveInfoCache()
    private var items: [String: (Date, SaveInfo)] = [:]
    private let lock = NSLock()
    func info(_ url: URL, modified: Date) -> SaveInfo? {
        lock.lock(); let hit = items[url.path]; lock.unlock()
        if let h = hit, h.0 == modified { return h.1 }
        guard let s = try? SaveReader.read(url) else { return nil }
        lock.lock(); items[url.path] = (modified, s); lock.unlock()
        return s
    }
}

extension ModKit {
    static let pluginExtensions: Set<String> = ["esp", "esm", "esl"]

    /// Plugins at the top of a mod's folder.
    func topPlugins(_ id: String) -> [String] {
        guard let m = mod(id) else { return [] }
        return ((try? FileManager.default.contentsOfDirectory(atPath: stagingFolder(m).path)) ?? [])
            .filter { ModKit.pluginExtensions.contains(($0 as NSString).pathExtension.lowercased()) }
    }

    /// Active plugins that would stop loading if these mods were off: no other enabled mod and not the game itself
    /// provides the same file.
    public func pluginsLost(disabling ids: Set<String>) -> [String] {
        guard let p = try? currentProfile() else { return [] }
        let active = Set(loadOrder().activeOrder.map { $0.lowercased() })
        var lost: [String: String] = [:]
        for id in ids { for f in topPlugins(id) where active.contains(f.lowercased()) { lost[f.lowercased()] = f } }
        guard !lost.isEmpty else { return [] }
        for pm in p.mods where pm.enabled && !ids.contains(pm.id) { for f in topPlugins(pm.id) { lost[f.lowercased()] = nil } }
        let baseline = Set(((try? String(contentsOf: deployer.layout.baselineURL, encoding: .utf8)) ?? "").split(separator: "\n").map { $0.lowercased() })
        for k in Array(lost.keys) where baseline.contains("data/" + k) { lost[k] = nil }   // the game's own copy stays
        return lost.values.sorted { $0.lowercased() < $1.lowercased() }
    }

    /// The newest save of each character in the current profile's saves folder, newest first.
    public func playthroughs(limit: Int = 8) -> [SaveInfo] {
        let fm = FileManager.default
        let dir = activeSavesFolder
        let files: [(URL, Date)] = ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])) ?? [])
            .filter { $0.pathExtension.lowercased() == "ess" }
            .map { ($0, (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
            .sorted { $0.1 > $1.1 }
        var seen = Set<String>(), out: [SaveInfo] = []
        for (u, d) in files {
            guard let s = SaveInfoCache.shared.info(u, modified: d), seen.insert(s.player).inserted else { continue }
            out.append(s)
            if out.count == limit { break }
        }
        return out
    }

    /// Playthroughs that use any of these plugins.
    public func playthroughRisks(plugins: [String]) -> [PlaythroughRisk] {
        guard !plugins.isEmpty else { return [] }
        let gone = Set(plugins.map { $0.lowercased() })
        return playthroughs().compactMap { s in
            let used = s.allPlugins.filter { gone.contains($0.lowercased()) }
            return used.isEmpty ? nil : PlaythroughRisk(save: s, plugins: used)
        }
    }
}
