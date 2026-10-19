// One-click crash fix: the Crashes page ranks suspects; this turns them off one at a time and lets the game decide.
// SkyrimMT turns off the top suspect (saves backed up first), the player plays to where it crashed, and the next
// session's outcome is read automatically:
//   same crash again      → that mod wasn't it: back on, the next suspect is offered
//   a different crash     → the player decides (look at it, keep, or undo)
//   no crash, ≥ 5 minutes → most likely the culprit: keep it off or turn it back on
// Sessions come from SkyrimMT's launch log (Play) and game-exit log (the launcher notices the game ending).
import Foundation

public struct CrashFixTrial: Codable, Equatable {
    public var profile: String
    public var crashLog: String            // the crash being fixed
    public var signature: String           // what "the same crash" means (CrashFix.signature)
    public var candidates: [String]        // mod ids, strongest suspect first (all enabled at the start)
    public var index: Int                  // candidates[index] is off for the current attempt
    public var attemptStarted: Date
    public var keptOff: [String] = []      // earlier candidates the player chose to keep off (different crash)
}

public enum CrashFixOutcome: Equatable {
    case waiting                           // no finished test session yet
    case sameCrash(URL)                    // crashed the same way: the current suspect isn't it
    case differentCrash(URL)
    case noCrash(minutes: Int)
    case tooShort(minutes: Int)            // quit too early to tell
}

public enum CrashFix {
    /// Fault location (module+offset, the address without ASLR) plus the first mod on the call stack.
    public static func signature(_ r: CrashReport) -> String {
        let firstMod = r.stackModules.first { !CrashLogParser.isSystem($0) } ?? ""
        return "\(r.faultModule)+\(r.faultOffset)|\(firstMod)|\(r.cppException)".lowercased()
    }
    public static let minimumMinutes = 5
}

extension ModKit {
    var crashFixURL: URL { stateDir.appendingPathComponent("crash-fix.json") }
    var gameExitLogURL: URL { stateDir.appendingPathComponent("game-exits.tsv") }

    public func crashFixTrial() -> CrashFixTrial? { readJSON(crashFixURL, CrashFixTrial.self) }

    /// The launcher calls this when the game process ends.
    public func recordGameExit(at date: Date = Date()) {
        var lines = ((try? String(contentsOf: gameExitLogURL, encoding: .utf8)) ?? "").components(separatedBy: "\n").filter { !$0.isEmpty }
        lines.append(ISO8601DateFormatter().string(from: date))
        try? FileManager.default.createDirectory(at: gameExitLogURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? (lines.suffix(500).joined(separator: "\n") + "\n").write(to: gameExitLogURL, atomically: true, encoding: .utf8)
    }

    private func dates(_ url: URL) -> [Date] {
        let f = ISO8601DateFormatter()
        return ((try? String(contentsOf: url, encoding: .utf8)) ?? "").components(separatedBy: "\n")
            .compactMap { $0.components(separatedBy: "\t").first.flatMap { f.date(from: $0) } }.sorted()
    }

    /// Mods worth testing: managed, enabled in the profile that crashed (= the current one).
    public func crashFixCandidates(_ r: CrashReport) -> [String] {
        guard let p = try? currentProfile() else { return [] }
        let enabled = Set(p.mods.filter(\.enabled).map(\.id))
        return r.suspects.compactMap(\.modID).filter { enabled.contains($0) && mod($0)?.isSeparator == false && !ModKit.isOverwrite($0) }
    }

    /// Turn off the strongest suspect (saves backed up first). Returns its mod id, nil when nothing can be tested.
    @discardableResult
    public func startCrashFix(_ r: CrashReport, at now: Date = Date()) throws -> String? {
        if let p = r.profile, p != currentProfileName { throw ModKitError.invalid("switch to profile “\(p)” first: the crash happened there") }
        let c = crashFixCandidates(r)
        guard let first = c.first else { return nil }
        _ = backupSaves(reason: "crash fix: before testing without \(mod(first)?.name ?? first)")
        try setModsEnabled([first], false)
        try writeJSON(CrashFixTrial(profile: currentProfileName, crashLog: r.url.path, signature: CrashFix.signature(r), candidates: c, index: 0,
                                    attemptStarted: now), to: crashFixURL)
        return first
    }

    /// What the game sessions since the current attempt started say: the first crash among them decides; without a
    /// crash, their play time adds up (quitting early and playing again later counts).
    public func evaluateCrashFix(now: Date = Date()) -> CrashFixOutcome {
        guard let t = crashFixTrial() else { return .waiting }
        let launches = dates(launchLogURL).filter { $0 >= t.attemptStarted }
        guard let firstLaunch = launches.first else { return .waiting }
        // Crash Logger writes its log as the game dies: the earliest one since the first test launch
        let crash = crashLogs().last { u in
            let d = (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return d >= firstLaunch && u.path != t.crashLog
        }
        if let u = crash {
            guard let r = analyzeCrash(u) else { return .differentCrash(u) }
            return CrashFix.signature(r) == t.signature ? .sameCrash(u) : .differentCrash(u)
        }
        let exits = dates(gameExitLogURL)
        var seconds = 0.0, playing = false
        for (i, l) in launches.enumerated() {
            let next = i + 1 < launches.count ? launches[i + 1] : .distantFuture
            if let e = exits.first(where: { $0 >= l && $0 < next }) { seconds += e.timeIntervalSince(l) } else if i == launches.count - 1 { playing = true }
        }
        let minutes = Int(seconds / 60)
        if minutes >= CrashFix.minimumMinutes { return .noCrash(minutes: minutes) }
        return playing ? .waiting : .tooShort(minutes: minutes)
    }

    /// The current suspect wasn't it: back on, the next one off. Returns the next mod id; nil = none left (trial over,
    /// everything it turned off is back on except what the player chose to keep off).
    @discardableResult
    public func nextCrashFixSuspect(at now: Date = Date()) throws -> String? {
        guard var t = crashFixTrial() else { return nil }
        try setModsEnabled([t.candidates[t.index]], true)
        t.index += 1
        guard t.index < t.candidates.count else { try? FileManager.default.removeItem(at: crashFixURL); return nil }
        let next = t.candidates[t.index]
        try setModsEnabled([next], false)
        t.attemptStarted = now
        try writeJSON(t, to: crashFixURL)
        return next
    }

    /// Different crash, keep testing: the current suspect stays off, the next one is tried as well.
    @discardableResult
    public func keepOffAndContinueCrashFix(at now: Date = Date()) throws -> String? {
        guard var t = crashFixTrial() else { return nil }
        t.keptOff.append(t.candidates[t.index])
        try writeJSON(t, to: crashFixURL)
        try setModsEnabled([t.candidates[t.index]], true)   // nextCrashFixSuspect turns the current one back on…
        let next = try nextCrashFixSuspect(at: now)
        try setModsEnabled(t.keptOff, false)                 // …the kept ones stay off
        return next
    }

    /// End the trial. keepOff: the current suspect stays off (it was the culprit); otherwise everything the trial
    /// turned off is turned back on.
    public func endCrashFix(keepOff: Bool) throws {
        guard let t = crashFixTrial() else { return }
        let current = t.index < t.candidates.count ? [t.candidates[t.index]] : []
        if !keepOff { try setModsEnabled(current + t.keptOff, true) }
        try? FileManager.default.removeItem(at: crashFixURL)
    }

    func setModsEnabled(_ ids: [String], _ on: Bool) throws {
        guard !ids.isEmpty else { return }
        var p = try currentProfile()
        let set = Set(ids)
        for i in p.mods.indices where set.contains(p.mods[i].id) { p.mods[i].enabled = on }
        try saveProfile(p)
    }
}
