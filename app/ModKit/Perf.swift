// "What does each mod cost me in FPS?" — measured, not guessed. The unattended benchmark (tools/bench/bench.sh: fixed
// save, fixed camera pan, standing still; frame times from the frametrace proxy) runs once as the profile is, then
// once with each candidate mod turned off, then the full profile again (the two full runs give the noise). A mod's cost
// is the mean frame time it adds. Mods are turned off together with everything that needs their plugins (missing
// masters would stop the game). The player's profile is restored afterwards — also after a crash (perf-restore.json).
import Foundation

public struct PerfSample: Codable, Equatable {
    public var frames: Int
    public var seconds: Double
    public var meanMs: Double        // mean frame time
    public var p99Ms: Double
    public var fps: Double { meanMs > 0 ? 1000 / meanMs : 0 }
    public init(frames: Int, seconds: Double, meanMs: Double, p99Ms: Double) { self.frames = frames; self.seconds = seconds; self.meanMs = meanMs; self.p99Ms = p99Ms }
}

public struct PerfCandidate: Codable, Equatable, Identifiable {
    public var id: String { modID }
    public var modID: String
    public var name: String
    public var assetBytes: Int64          // textures + meshes it deploys
    public var together: [String]         // mods turned off with it (they need its plugins)
}

public struct PerfResult: Codable, Equatable, Identifiable {
    public var id: String { candidate.modID }
    public var candidate: PerfCandidate
    public var without: PerfSample
    public var costMs: Double             // mean frame time with it − without it
}

public struct PerfReport: Codable, Equatable {
    public var date: Date
    public var profile: String
    public var baseline: PerfSample       // average of the two full runs
    public var noiseMs: Double            // |full run 1 − full run 2| mean frame time
    public var results: [PerfResult]      // most expensive first
}

public enum PerfError: Error, CustomStringConvertible {
    case measurement(String)
    public var description: String { switch self { case .measurement(let m): return m } }
}

/// Frame times from a frametrace CSV ("frame,t_us,dt_us,present_us[,sync]") between two bench marks
/// (marks.txt: "<name> <csv line count> <unix time>"), like tools/bench/analyze.py's "total" segment.
public enum FrameTrace {
    public static func sample(csv: URL, marks: URL, from a: String = "start", to b: String = "end") throws -> PerfSample {
        var m: [String: Int] = [:]
        for line in (try String(contentsOf: marks, encoding: .utf8)).split(whereSeparator: \.isNewline) {
            let f = line.split(separator: " "); if f.count >= 2, let n = Int(f[1]) { m[String(f[0])] = n - 2 }   // line count → frame index
        }
        guard let lo = m[a], let hi = m[b] else { throw PerfError.measurement("bench marks \(a)/\(b) missing") }
        var t: [Int64] = [], dt: [Double] = []
        for (i, line) in (try String(contentsOf: csv, encoding: .utf8)).split(whereSeparator: \.isNewline).enumerated() where i > 0 {
            let f = line.split(separator: ",")
            guard f.count >= 4, let idx = Int(f[0]), let ts = Int64(f[1]), let d = Double(f[2]), idx > lo, idx <= hi else { continue }
            t.append(ts); dt.append(d / 1000)
        }
        guard dt.count >= 30, let first = t.first, let last = t.last, last > first else { throw PerfError.measurement("too few frames measured (\(dt.count))") }
        let secs = Double(last - first) / 1e6
        let sorted = dt.sorted()
        return PerfSample(frames: dt.count, seconds: secs, meanMs: secs * 1000 / Double(dt.count - 1), p99Ms: sorted[min(sorted.count - 1, sorted.count * 99 / 100)])
    }
}

extension ModKit {
    var perfReportURL: URL { stateDir.appendingPathComponent("perf-report.json") }
    var perfRestoreURL: URL { stateDir.appendingPathComponent("perf-restore.json") }

    public func perfReport() -> PerfReport? { readJSON(perfReportURL, PerfReport.self) }

    public static let benchSaveName = "SkyrimMTBench"
    /// The benchmark save: the profile's own saves folder first, else the shared one.
    public func benchSave() -> URL? {
        [activeSavesFolder, savesDir].map { $0.appendingPathComponent(ModKit.benchSaveName + ".ess") }.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Mods worth measuring: enabled, deploying textures/meshes/shaders, largest first; each with the mods that need its
    /// plugins. Frameworks nothing visual depends on directly are left to the player's choice.
    /// `save`: plugins the benchmark save uses — a mod whose plugins (or its dependents') are in it can't be turned
    /// off for the test (Skyrim would stop at a "missing content" question).
    public func perfCandidates(limit: Int = 8, save: SaveInfo? = nil) throws -> [PerfCandidate] {
        let p = try currentProfile()
        let inSave = Set((save?.allPlugins ?? []).map { $0.lowercased() })
        let plan = try self.plan(p)
        var bytes: [String: Int64] = [:]
        for (k, f) in plan.files where k.hasPrefix("data/textures/") || k.hasPrefix("data/meshes/") || k.hasPrefix("data/shaders/") || k.hasSuffix(".bsa") {   // shaders: Community Shaders
            bytes[f.modID, default: 0] += (lstatPath(f.source)?.size ?? 0)
        }
        return p.mods.filter(\.enabled).compactMap { pm -> PerfCandidate? in
            guard let m = mod(pm.id), !m.isSeparator, !ModKit.isOverwrite(m.id), let b = bytes[m.id], b > 0 else { return nil }
            let together = perfDependents(of: m.id, in: p)
            if ([m.id] + together).contains(where: { topPlugins($0).contains { inSave.contains($0.lowercased()) } }) { return nil }
            return PerfCandidate(modID: m.id, name: m.name, assetBytes: b, together: together)
        }.sorted { $0.assetBytes > $1.assetBytes }.prefix(limit).map { $0 }
    }

    /// Enabled mods whose plugins need (directly or indirectly) a plugin of `id`.
    public func perfDependents(of id: String, in p: Profile) -> [String] {
        let lo = loadOrder()
        var owner: [String: String] = [:]   // plugin (lowercased) → enabled mod providing it
        for pm in p.mods where pm.enabled { for f in topPlugins(pm.id) { owner[f.lowercased()] = pm.id } }
        var off = Set([id]), changed = true
        while changed {
            changed = false
            let gone = Set(owner.filter { off.contains($0.value) }.map(\.key))
            for (plugin, modID) in owner where !off.contains(modID) {
                if let h = lo.headers[plugin], h.masters.contains(where: { gone.contains($0.lowercased()) }) { off.insert(modID); changed = true }
            }
        }
        off.remove(id)
        return p.mods.map(\.id).filter { off.contains($0) }
    }

    /// Run the measurement. `measure(label)` runs one benchmark with the deployed game and returns its sample (the app
    /// runs tools/bench/bench.sh). The profile is restored at the end, whatever happens.
    public func runPerfTest(_ candidates: [PerfCandidate], measure: (String) throws -> PerfSample,
                            progress: (String) -> Void = { _ in }) throws -> PerfReport {
        let original = try currentProfile()
        try writeJSON(original, to: perfRestoreURL)
        defer { try? finishPerfRestore() }
        progress("Measuring your setup as it is…")
        try deploy(original)
        let full1 = try measure("full-1")
        var results: [PerfResult] = []
        for (i, c) in candidates.enumerated() {
            progress("Measuring without \(c.name) (\(i + 1) of \(candidates.count))…")
            var p = original
            let off = Set([c.modID] + c.together)
            for j in p.mods.indices where off.contains(p.mods[j].id) { p.mods[j].enabled = false }
            try saveProfile(p)
            try deploy(p)
            let s = try measure("without-\(i + 1)")
            results.append(PerfResult(candidate: c, without: s, costMs: 0))
        }
        progress("Measuring your setup again (noise check)…")
        try saveProfile(original)
        try deploy(original)
        let full2 = try measure("full-2")
        let base = PerfSample(frames: full1.frames + full2.frames, seconds: full1.seconds + full2.seconds,
                              meanMs: (full1.meanMs + full2.meanMs) / 2, p99Ms: max(full1.p99Ms, full2.p99Ms))
        for i in results.indices { results[i].costMs = base.meanMs - results[i].without.meanMs }
        let report = PerfReport(date: Date(), profile: original.name, baseline: base, noiseMs: abs(full1.meanMs - full2.meanMs),
                                results: results.sorted { $0.costMs > $1.costMs })
        try writeJSON(report, to: perfReportURL)
        return report
    }

    /// Put the player's profile back after a measurement (also called at start-up: a crash mid-test leaves the file).
    public func finishPerfRestore() throws {
        guard let p = readJSON(perfRestoreURL, Profile.self) else { return }
        if p.name == currentProfileName {
            try saveProfile(p)
            try deploy(p)
        }
        try FileManager.default.removeItem(at: perfRestoreURL)
    }
}
