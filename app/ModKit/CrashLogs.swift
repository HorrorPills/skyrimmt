// Crash detective (docs/MODMANAGER.md §3G): reads Crash Logger SSE logs (My Games/…/SKSE/crash-*.log) and names the
// mods most likely involved, in plain language, with the evidence. Format taken from real logs (CrashLoggerSSE 1.15):
//   Unhandled exception "EXCEPTION_ACCESS_VIOLATION" at 0x… Module.dll+0123456
//   PROBABLE CALL STACK:  [ 4] 0x… ImprovedCameraSE.dll+0095263 …
//   REGISTERS: / STACK:   object dumps with  File: "X.esp"  and  Modified by: A.esm -> B.esp
//   SKSE PLUGINS: / PLUGINS:
// Scoring: the module that faulted ≫ mod DLLs high in the call stack ≫ plugins that last touched the objects in play
// ≫ DLLs/files merely mentioned on the stack. Everything is mapped back to the mod that deploys it.
import Foundation

public struct CrashSuspect: Identifiable, Equatable {
    public var id: String { modID ?? "file:" + evidence.first! }
    public var modID: String?         // nil = not from a managed mod (game, Wine, a mod installed by hand)
    public var modName: String
    public var score: Double
    public var evidence: [String]     // plain-language reasons, strongest first
}

public struct CrashReport: Identifiable, Equatable {
    public var id: String { url.path }
    public var url: URL
    public var date: Date
    public var gameVersion: String
    public var exception: String          // EXCEPTION_ACCESS_VIOLATION …
    public var faultModule: String        // SkyrimSE.exe, ImprovedCameraSE.dll, "" (no module: jumped to garbage)
    public var faultAddress: String
    public var faultOffset = ""           // "0C1234" from "SkyrimSE.exe+0C1234" (stable across runs, unlike the address)
    public var stackModules: [String]     // probable call stack, in order, duplicates removed
    public var plugins: [String: Int]     // plugin → how often it appears as File/Modified by in the object dumps
    public var objects: [String]          // names of game objects in play ("Player", "HairMaleDarkElf03")
    public var meshes: [String]           // .nif/.hkx paths mentioned
    public var cppException = ""          // Crash Logger 1.25+: "DX::com_exception: HRESULT 0x80004002 (E_NOINTERFACE)"
    public var functions: [String: String] = [:]   // module → first function of it in the call stack (from PDB info)
    public var summary: String            // one plain sentence
    public var hints: [String]            // known patterns
    public var suspects: [CrashSuspect] = []
    public var profile: String?           // the profile that was running (from SkyrimMT's launch log)
}

public enum CrashLogParser {
    /// System and runtime modules: never the "culprit" by themselves.
    static let systemModules: Set<String> = [
        "skyrimse.exe", "ntdll.dll", "kernel32.dll", "kernelbase.dll", "user32.dll", "win32u.dll", "gdi32.dll", "ucrtbase.dll",
        "msvcrt.dll", "msvcp140.dll", "vcruntime140.dll", "vcruntime140_1.dll", "d3d11.dll", "dxgi.dll", "d3dcompiler_47.dll",
        "winmm.dll", "dinput8.dll", "xinput1_3.dll", "xinput1_4.dll", "xaudio2_7.dll", "combase.dll", "ole32.dll", "rpcrt4.dll",
        "opengl32.dll", "winevulkan.dll", "skse64_loader.exe", "tbbmalloc.dll", "tbb.dll", "steam_api64.dll", "gameoverlayrenderer64.dll",
    ]
    public static func isSystem(_ m: String) -> Bool {
        let l = m.lowercased()
        return systemModules.contains(l) || l.hasPrefix("skse64_") || l.hasPrefix("api-ms-win") || l.hasPrefix("msvcp") || l.hasPrefix("vcruntime")
    }
    /// The game plugins every setup has: not useful as suspects.
    static let basePlugins: Set<String> = ["skyrim.esm", "update.esm", "dawnguard.esm", "hearthfires.esm", "dragonborn.esm"]

    public static func parse(_ text: String, url: URL, date: Date) -> CrashReport? {
        let lines = text.components(separatedBy: .newlines)
        guard lines.contains(where: { $0.hasPrefix("Unhandled exception") }) else { return nil }
        var r = CrashReport(url: url, date: date, gameVersion: "", exception: "", faultModule: "", faultAddress: "", stackModules: [],
                            plugins: [:], objects: [], meshes: [], summary: "", hints: [])
        var section = ""
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if !raw.hasPrefix("\t") && raw.hasSuffix(":") && !raw.isEmpty {
                // "PROBABLE CALL STACK:" (≤1.15) / "CALL STACK ([P]robable / [S]tack scan):" (1.25)
                let head = String(raw.dropLast()).components(separatedBy: " (").first ?? ""
                if head == head.uppercased() { section = head == "CALL STACK" ? "PROBABLE CALL STACK" : head; continue }
            }
            if section == "C++ EXCEPTION" {
                if line.hasPrefix("Type: ") { r.cppException = line.dropFirst(6).trimmingCharacters(in: CharacterSet(charactersIn: "()*")) }
                if line.hasPrefix("Info: ") { r.cppException += (r.cppException.isEmpty ? "" : ": ") + line.dropFirst(6) }
            }
            if raw.hasPrefix("Skyrim SSE v") || raw.hasPrefix("Skyrim VR v") { r.gameVersion = String(raw.split(separator: "v", maxSplits: 1).last ?? "") }
            if raw.hasPrefix("Unhandled exception") {
                let parts = raw.components(separatedBy: "\"")
                if parts.count >= 3 { r.exception = parts[1] }
                if let at = raw.range(of: " at ") {
                    let rest = raw[at.upperBound...].split(separator: " ", omittingEmptySubsequences: true)
                    r.faultAddress = rest.first.map(String.init) ?? ""
                    if rest.count > 1, let m = moduleName(String(rest[1])) {
                        r.faultModule = m
                        if let plus = rest[1].lastIndex(of: "+") { r.faultOffset = String(rest[1][rest[1].index(after: plus)...].prefix { $0.isHexDigit }) }
                    }
                }
            }
            switch section {
            case "PROBABLE CALL STACK":
                // [ 4] 0x6FFFE5625263 ImprovedCameraSE.dll+0095263	…
                // 1.25 marks frames [P]robable or [S]tack scan; scan hits are mostly stale return addresses
                if line.contains("][S]") { break }
                let f = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
                if f.count >= 3, line.hasPrefix("["), let m = f.dropFirst().first(where: { $0.contains(".") && $0.contains("+") }).flatMap({ moduleName(String($0)) }) {
                    if !r.stackModules.contains(m) { r.stackModules.append(m) }
                    // "| D:\…\DX12SwapChain.cpp:13 void DX12SwapChain::CreateD3D12Device(IDXGIAdapter *) [?…"
                    if r.functions[m] == nil, let bar = line.range(of: "|  ") ?? line.range(of: "| ") {
                        let sym = line[bar.upperBound...].components(separatedBy: " [?").first ?? ""
                        if let fn = sym.split(separator: " ").first(where: { $0.contains("::") || $0.contains("(") }) {
                            r.functions[m] = String(fn.prefix { $0 != "(" })
                        }
                    }
                }
            case "REGISTERS", "STACK":
                if line.hasPrefix("File: \"") { add(quoted(line), to: &r.plugins) }
                else if line.hasPrefix("Modified by: ") {
                    for p in line.dropFirst("Modified by: ".count).components(separatedBy: " -> ") { add(p.trimmingCharacters(in: .whitespaces), to: &r.plugins) }
                } else if line.hasPrefix("Name: \"") || line.hasPrefix("Full Name: \"") {
                    let n = quoted(line)
                    if !n.isEmpty && n != "???" && !r.objects.contains(n) && r.objects.count < 12 { r.objects.append(n) }
                }
                for word in line.split(whereSeparator: { $0 == "\"" || $0 == " " || $0 == "\t" || $0 == "(" || $0 == ")" }) {
                    let w = word.lowercased()
                    if (w.hasSuffix(".nif") || w.hasSuffix(".hkx") || w.hasSuffix(".tri")) && !r.meshes.contains(String(word)) && r.meshes.count < 20 { r.meshes.append(String(word)) }
                }
            default: break
            }
        }
        r.hints = hints(r)
        r.summary = summary(r)
        return r
    }

    static func moduleName(_ s: String) -> String? {
        // "ImprovedCameraSE.dll+0095263" → ImprovedCameraSE.dll
        guard let plus = s.firstIndex(of: "+") else { return nil }
        let m = String(s[..<plus])
        return m.contains(".") ? m : nil
    }
    static func quoted(_ s: String) -> String { let p = s.components(separatedBy: "\""); return p.count >= 2 ? p[1] : "" }
    static func add(_ p: String, to d: inout [String: Int]) {
        let l = p.lowercased()
        guard l.hasSuffix(".esp") || l.hasSuffix(".esm") || l.hasSuffix(".esl"), !basePlugins.contains(l) else { return }
        d[p, default: 0] += 1
    }

    static func hints(_ r: CrashReport) -> [String] {
        var h: [String] = []
        let a = r.faultAddress.lowercased().replacingOccurrences(of: "0x", with: "")
        let trimmed = a.drop { $0 == "0" }
        if r.faultModule.isEmpty && trimmed.hasPrefix("ffff") && trimmed.count == 8 {
            h.append("Two plugins that hook the game window conflicted. If this repeats, update or remove the first DLL in the call stack.")
        }
        let fns = r.functions.values.joined(separator: " ").lowercased()
        if r.cppException.contains("E_NOINTERFACE") || fns.contains("d3d12") || fns.contains("dx12") {
            if fns.contains("d3d12") || fns.contains("dx12") {
                h.append("A graphics mod requested Direct3D 12, which is not available on macOS. Disable its Direct3D 12 feature (frame generation or upscaling) or the mod."
                         + (fns.contains("upscal") || r.stackModules.contains { $0.lowercased() == "communityshaders.dll" } ? " SkyrimMT now excludes Community Shaders Upscaling automatically. Deploy again to fix this crash." : ""))
            } else {
                h.append("A mod requested a graphics feature that is not available (E_NOINTERFACE), usually Direct3D 12.")
            }
        }
        if r.objects.contains(where: { $0.lowercased().hasPrefix("hair") }) || r.meshes.contains(where: { $0.lowercased().contains("hair") }) {
            h.append("A hair or head mesh was being drawn. These crashes usually come from a broken or mismatched hair/head mesh, or from a character (often the player) changed by several mods.")
        }
        return h
    }

    static func summary(_ r: CrashReport) -> String {
        let firstMod = r.stackModules.first { !isSystem($0) }
        if let m = firstMod, let fn = r.functions[m], isSystem(r.faultModule) || r.faultModule.isEmpty {
            return "\(m) stopped the game in \(fn)" + (r.cppException.isEmpty ? "." : " (\(r.cppException)).")
        }
        if !r.faultModule.isEmpty && !isSystem(r.faultModule) { return "The crash happened inside \(r.faultModule)." }
        if r.faultModule.isEmpty { return "The game jumped to an invalid address" + (firstMod.map { ", right after \($0) ran." } ?? ".") }
        if let m = firstMod { return "The crash happened in \(r.faultModule), called from \(m)." }
        return "The crash happened inside the game (\(r.faultModule)) while it handled " + (r.objects.prefix(2).isEmpty ? "game data." : r.objects.prefix(2).joined(separator: " and ") + ".")
    }
}

extension ModKit {
    /// Crash Logger's folder: My Games/Skyrim Special Edition/SKSE.
    public var crashLogDir: URL { myGamesDir.appendingPathComponent("SKSE") }

    /// Newest first.
    public func crashLogs(limit: Int = 30) -> [URL] {
        let fm = FileManager.default
        let all = (try? fm.contentsOfDirectory(at: crashLogDir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return all.filter { let n = $0.lastPathComponent.lowercased(); return n.hasPrefix("crash-") && n.hasSuffix(".log") }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
            .prefix(limit).map { $0 }
    }

    /// Parse a log and rank the mods involved, using what the current profile deploys.
    public func analyzeCrash(_ url: URL) -> CrashReport? {
        guard let d = try? Data(contentsOf: url) else { return nil }
        let text = String(decoding: d, as: UTF8.self)
        let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
        guard var r = CrashLogParser.parse(text, url: url, date: date) else { return nil }
        // the profile that was running when it crashed (Play records each launch), else the current one
        r.profile = profileActive(at: date)
        let crashProfile = r.profile.flatMap { profile($0) } ?? (try? currentProfile())
        let plan = crashProfile.flatMap { try? self.plan($0) } ?? DeployPlan()
        // file name (lowercased) → owning mod, for DLLs, plugins and meshes
        var byName: [String: String] = [:], byRel: [String: String] = [:]
        for (key, f) in plan.files {
            let name = (key as NSString).lastPathComponent
            let l = name.lowercased()
            if l.hasSuffix(".dll") || l.hasSuffix(".esp") || l.hasSuffix(".esm") || l.hasSuffix(".esl") { byName[l] = f.modID }
            if l.hasSuffix(".nif") || l.hasSuffix(".hkx") || l.hasSuffix(".tri") { byRel[key.hasPrefix("data/") ? String(key.dropFirst(5)) : key] = f.modID }
        }
        // names the profile doesn't deploy (crash from another profile, mod disabled since): any installed mod's
        // plugins (staging root) and SKSE DLLs (SKSE/Plugins) — cheap, two directory listings per mod
        let wanted = Set(([r.faultModule] + r.stackModules + Array(r.plugins.keys)).map { $0.lowercased() }).subtracting(byName.keys)
        if !wanted.isEmpty {
            let fm = FileManager.default
            for m in mods where !m.isSeparator {
                let root = stagingFolder(m)
                var dirs = [root]
                if let skse = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil))?.first(where: { $0.lastPathComponent.lowercased() == "skse" }),
                   let pl = (try? fm.contentsOfDirectory(at: skse, includingPropertiesForKeys: nil))?.first(where: { $0.lastPathComponent.lowercased() == "plugins" }) { dirs.append(pl) }
                for d in dirs { for f in (try? fm.contentsOfDirectory(atPath: d.path)) ?? [] where wanted.contains(f.lowercased()) && byName[f.lowercased()] == nil { byName[f.lowercased()] = m.id } }
            }
        }
        var acc: [String: (score: Double, ev: [(Double, String)])] = [:]
        func credit(_ file: String, _ mod: String?, _ s: Double, _ why: String) {
            let k = mod ?? "file:" + file
            var e = acc[k] ?? (0, []); e.score += s; e.ev.append((s, why)); acc[k] = e
        }
        if !r.faultModule.isEmpty && !CrashLogParser.isSystem(r.faultModule) {
            credit(r.faultModule, byName[r.faultModule.lowercased()], 100, "The crash happened inside \(r.faultModule).")
        }
        var rank = 0
        for m in r.stackModules where !CrashLogParser.isSystem(m) {
            let fn = r.functions[m].map { " (\($0))" } ?? ""
            credit(m, byName[m.lowercased()], max(60 - Double(rank) * 12, 12), rank == 0 ? "\(m) is the first mod code in the call stack\(fn)." : "\(m) is in the call stack\(fn).")
            rank += 1
        }
        let total = max(r.plugins.values.reduce(0, +), 1)
        for (p, n) in r.plugins.sorted(by: { $0.value > $1.value }).prefix(8) {
            credit(p, byName[p.lowercased()], 30 * Double(n) / Double(total) + 5, "\(p) changed game objects in use when it crashed (\(n)×).")
        }
        for m in r.meshes {
            var rel = m.replacingOccurrences(of: "\\", with: "/").lowercased()
            rel = rel.split(separator: "/").joined(separator: "/")
            if let (k, id) = byRel.first(where: { rel.hasSuffix($0.key) || $0.key.hasSuffix(rel) }) { credit(k, id, 15, "Its mesh \(m) was in use.") }
        }
        r.suspects = acc.map { k, v in
            let id = k.hasPrefix("file:") ? nil : k
            return CrashSuspect(modID: id, modName: id.flatMap { mod($0)?.name } ?? String(k.dropFirst(5)) + " (not managed by SkyrimMT)",
                                score: v.score, evidence: v.ev.sorted { $0.0 > $1.0 }.map(\.1))
        }.sorted { $0.score > $1.score }
        return r
    }
}

extension ModKit {
    var launchLogURL: URL { stateDir.appendingPathComponent("launches.tsv") }

    /// Play calls this: which profile the game ran with (crash analysis, save checks).
    public func recordLaunch(at date: Date = Date()) {
        let line = "\(ISO8601DateFormatter().string(from: date))\t\(currentProfileName)\t\(gameVersionKey)\n"
        var lines = ((try? String(contentsOf: launchLogURL, encoding: .utf8)) ?? "").components(separatedBy: "\n").filter { !$0.isEmpty }
        lines.append(String(line.dropLast()))
        try? FileManager.default.createDirectory(at: launchLogURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? (lines.suffix(500).joined(separator: "\n") + "\n").write(to: launchLogURL, atomically: true, encoding: .utf8)
    }

    /// The profile of the last launch before `date` (within a day — older launches don't explain a crash).
    public func profileActive(at date: Date) -> String? {
        let f = ISO8601DateFormatter()
        let launches = ((try? String(contentsOf: launchLogURL, encoding: .utf8)) ?? "").components(separatedBy: "\n").compactMap { l -> (Date, String)? in
            let p = l.components(separatedBy: "\t"); guard p.count >= 2, let d = f.date(from: p[0]) else { return nil }; return (d, p[1])
        }
        return launches.filter { $0.0 <= date && date.timeIntervalSince($0.0) < 86400 }.max { $0.0 < $1.0 }?.1
    }
}

extension ModKit {
    /// When each profile was last started from SkyrimMT (launch log).
    public func lastPlayed() -> [String: Date] {
        let f = ISO8601DateFormatter()
        var out: [String: Date] = [:]
        for l in ((try? String(contentsOf: launchLogURL, encoding: .utf8)) ?? "").components(separatedBy: "\n") {
            let p = l.components(separatedBy: "\t"); guard p.count >= 2, let d = f.date(from: p[0]) else { continue }
            if (out[p[1]] ?? .distantPast) < d { out[p[1]] = d }
        }
        return out
    }
}
