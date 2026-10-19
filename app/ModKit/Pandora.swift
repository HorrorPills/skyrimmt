// ModKit Pandora (PLAN §8.11): runs the native macOS build of Pandora Behaviour Engine+ (GPL-3.0, a separate program;
// pinned source + macos.patch in tools/pandora) against the deployed game and keeps what it generates as a managed mod
// per profile ("Pandora Output"), so the game folder stays fully managed and a purge still returns it to vanilla.
// A rerun is needed when the deployed animation inputs change: Nemesis/Pandora patches, FNIS lists and behaviours.
import Foundation

public struct PandoraResult { public var files = 0; public var seconds = 0.0; public var warnings = 0; public var errors: [String] = [] }

public enum PandoraError: Error, CustomStringConvertible {
    case notInstalled, failed(String)
    public var description: String {
        switch self {
        case .notInstalled: return "Pandora isn't installed (tools/pandora/build.sh)."
        case .failed(let m): return "Pandora: \(m)"
        }
    }
}

struct PandoraState: Codable { var fingerprints: [String: String] = [:] }   // profile → inputs fingerprint of its output

extension ModKit {
    public var pandoraBinary: URL { home.appendingPathComponent("tools/pandora/Pandora Behaviour Engine+") }
    public var pandoraInstalled: Bool { FileManager.default.isExecutableFile(atPath: pandoraBinary.path) }
    var pandoraStateURL: URL { stateDir.appendingPathComponent("pandora.json") }

    public static func pandoraOutputID(_ profile: String) -> String { "pandora-output:\(profile)" }
    public static func isPandoraOutput(_ id: String) -> Bool { id.hasPrefix("pandora-output:") }

    /// Files Pandora reads: engine patches (Nemesis_Engine/mod, Pandora_Engine/mod) and FNIS lists + behaviours.
    static func isPandoraInput(_ rel: String) -> Bool {
        let l = rel.lowercased()
        if l.hasPrefix("data/nemesis_engine/mod/") || l.hasPrefix("data/pandora_engine/mod/") { return true }
        guard l.hasPrefix("data/meshes/") else { return false }
        let name = (l as NSString).lastPathComponent
        return name.hasPrefix("fnis_") && (name.hasSuffix("_list.txt") || name.hasSuffix("_behavior.hkx"))
    }

    /// Fingerprint of the deployed Pandora inputs (Pandora's own output excluded) and of the Pandora build.
    public func pandoraInputs() throws -> (fingerprint: String, count: Int) {
        let build = (try? String(contentsOf: home.appendingPathComponent("tools/pandora/.skyrimmt-pandora"), encoding: .utf8)) ?? ""
        return try deployedInputs(excluding: ModKit.isPandoraOutput, ModKit.isPandoraInput, extra: [build])
    }

    /// True when the profile's Pandora output is missing or stale (or exists although nothing needs it any more).
    public func pandoraNeedsRun() -> Bool {
        guard let p = try? currentProfile(), let inputs = try? pandoraInputs() else { return false }
        let hasOutput = p.mods.contains { $0.id == ModKit.pandoraOutputID(p.name) && $0.enabled }
        if inputs.count == 0 { return hasOutput }
        let saved = readJSON(pandoraStateURL, PandoraState.self)?.fingerprints[p.name]
        return !hasOutput || saved != inputs.fingerprint
    }

    /// Run Pandora for the current profile: deploy without the old output, generate into a fresh folder, then make that
    /// the profile's "Pandora Output" mod (above every mod except Overwrite) and deploy again.
    @discardableResult
    /// `interactive`: Pandora's own window opens (patch choices by hand); its output is kept when the player closes it.
    public func runPandora(interactive: Bool = false) throws -> PandoraResult {
        let fm = FileManager.default
        var profile = try currentProfile()
        let outID = ModKit.pandoraOutputID(profile.name)
        var without = profile; without.mods.removeAll { $0.id == outID }
        try deploy(without)
        let inputs = try pandoraInputs()
        var state = readJSON(pandoraStateURL, PandoraState.self) ?? PandoraState()
        var result = PandoraResult()

        if inputs.count == 0 {   // nothing to generate: drop a stale output
            try removeGeneratedOutput(id: outID, profile: &profile)
            state.fingerprints[profile.name] = nil; try writeJSON(state, to: pandoraStateURL)
            return result
        }
        guard pandoraInstalled else { try deploy(profile); throw PandoraError.notInstalled }

        let t0 = Date()
        let out = home.appendingPathComponent("cache/pandora-run-\(Int(t0.timeIntervalSince1970))")
        try? fm.removeItem(at: out)
        try fm.createDirectory(at: out, withIntermediateDirectories: true)
        let p = Process()
        p.executableURL = pandoraBinary
        p.currentDirectoryURL = pandoraBinary.deletingLastPathComponent()
        p.arguments = ["--tesv", gameDir.path, "-o", out.path] + (interactive ? [] : ["--auto_run", "--auto_close"])
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { try deploy(profile); throw PandoraError.failed("couldn't start (\(error.localizedDescription))") }
        p.waitUntilExit()
        result.seconds = Date().timeIntervalSince(t0)

        // keep Pandora's log for diagnostics; its run bookkeeping holds paths of the temporary folder
        let log = out.appendingPathComponent("Engine.log")
        let logs = home.appendingPathComponent("logs"); try? fm.createDirectory(at: logs, withIntermediateDirectories: true)
        let keptLog = logs.appendingPathComponent("pandora-engine.log")
        try? fm.removeItem(at: keptLog); try? fm.moveItem(at: log, to: keptLog)
        try? fm.removeItem(at: out.appendingPathComponent("Pandora_Engine/PreviousOutput.txt"))
        if let text = try? String(contentsOf: keptLog, encoding: .utf8) {
            for line in text.split(separator: "\n") {
                if line.hasPrefix("ERROR") || line.hasPrefix("FATAL") { result.errors.append(String(line)) }
                else if line.hasPrefix("WARN") { result.warnings += 1 }
            }
        }
        let behaviours = out.appendingPathComponent("meshes")
        if interactive && !fm.fileExists(atPath: behaviours.path) {   // closed without generating: nothing changes
            try? fm.removeItem(at: out); try deploy(profile); return result
        }
        guard p.terminationStatus == 0, fm.fileExists(atPath: behaviours.path) else {
            try? fm.removeItem(at: out); try deploy(profile)
            throw PandoraError.failed("it stopped with code \(p.terminationStatus)\(result.errors.first.map { ": \($0)" } ?? "") — see logs/pandora-engine.log")
        }
        result.files = (fm.enumerator(at: out, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }.count

        // the new output replaces the old one
        try installGeneratedOutput(id: outID, name: "Pandora Output (\(profile.name))",
                                   folder: "Pandora Output - \(ModKit.profileFolderName(profile.name))", from: out, profile: &profile)
        state.fingerprints[profile.name] = inputs.fingerprint
        try writeJSON(state, to: pandoraStateURL)
        return result
    }
}
