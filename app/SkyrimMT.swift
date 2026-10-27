// SkyrimMT launcher — Skyrim Special Edition / Anniversary Edition on Apple Silicon (native SwiftUI, built by
// app/build.sh). Port of tf2mt's launcher (~/Code/tf2mt/tools/launcher/TF2Launcher.swift).
// Self-contained: the SkyrimMT scripts/configs/patch tools are bundled in Resources/skyrimmt (a dev build without them
// falls back to ~/Code/skyrimmt). No Bethesda or Valve content is bundled: Skyrim's art is loaded at runtime from the
// user's own Steam library cache. All game work is done by the bundled shell scripts; the app passes options as
// environment variables (SKYRIM_HOME, SKYRIMMT_*) and launch arguments.
import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - paths & shell

func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: path) }

enum Paths {
    static let home = FileManager.default.homeDirectoryForCurrentUser.path
    static var repo: String {
        let bundled = (Bundle.main.resourcePath ?? "") + "/skyrimmt"
        return exists(bundled + "/scripts/play.sh") ? bundled : home + "/Code/skyrimmt"
    }
    /// `-gameHome <dir>` on the command line (NSArgumentDomain, not persisted) or the folder chosen in Setup.
    static var game: String { UserDefaults.standard.string(forKey: "gameHome") ?? home + "/Games/skyrim" }
    static var script: (String) -> String { { repo + "/scripts/" + $0 } }
    static var mousePatch: String { repo + "/tools/wine-patches/winemac_warp_nodiscard.sh" }
    static var dxmtPatch: String { repo + "/tools/wine-patches/dxmt_purevirtual_return.sh" }
    static var releaseConf: String { repo + "/config/release.conf" }
    static var logs: String { game + "/logs" }
    static var wine: String { game + "/wine/bin/wine" }
    static var prefix: String { game + "/prefix" }
    static var steamDir: String { prefix + "/drive_c/Program Files (x86)/Steam" }
    static var steamExe: String { steamDir + "/steam.exe" }
    static var skyrimDir: String { steamDir + "/steamapps/common/Skyrim Special Edition" }
    static var skyrimManifest: String { steamDir + "/steamapps/appmanifest_489830.acf" }
    static var art: String { steamDir + "/appcache/librarycache/489830" }
    static var connectionLog: String { steamDir + "/logs/connection_log.txt" }
    static var userDir: String { prefix + "/drive_c/users/" + NSUserName() }
    static var myGames: String { userDir + "/Documents/My Games/Skyrim Special Edition" }
    static var mods: String { game + "/mods" }
    /// Keizaal Online's launcher (Electron, installed per Windows user in the prefix): scripts/keizaal.sh
    static var keizaalExe: String { userDir + "/AppData/Local/Programs/skyrim-rp-launcher/keizaal-online.exe" }
    static let rosetta = "/Library/Apple/usr/libexec/oah/libRosettaRuntime"
}

/// Environment for every script: the caller's environment plus the configured game folder.
func scriptEnv(_ extra: [String: String] = [:], removing: [String] = []) -> [String: String] {
    var env = ProcessInfo.processInfo.environment
    env["SKYRIM_HOME"] = Paths.game
    removing.forEach { env.removeValue(forKey: $0) }
    extra.forEach { env[$0.key] = $0.value }
    return env
}

/// Start a process in its own session (survives the launcher quitting). Output lines go to `onOutput` (if given),
/// `onExit` gets the exit code. Returns false if it could not be started.
@discardableResult
func spawnDetached(_ args: [String], env: [String: String]? = nil,
                   onOutput: ((String) -> Void)? = nil, onExit: ((Int32) -> Void)? = nil) -> Bool {
    var fds: [Int32] = [0, 0]
    let capture = onOutput != nil
    if capture && pipe(&fds) != 0 { return false }
    var fa: posix_spawn_file_actions_t? = nil
    posix_spawn_file_actions_init(&fa)
    posix_spawn_file_actions_addopen(&fa, 0, "/dev/null", O_RDONLY, 0)
    if capture {
        posix_spawn_file_actions_adddup2(&fa, fds[1], 1); posix_spawn_file_actions_adddup2(&fa, fds[1], 2)
        posix_spawn_file_actions_addclose(&fa, fds[0]); posix_spawn_file_actions_addclose(&fa, fds[1])
    } else {
        posix_spawn_file_actions_addopen(&fa, 1, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addopen(&fa, 2, "/dev/null", O_WRONLY, 0)
    }
    var attr: posix_spawnattr_t? = nil
    posix_spawnattr_init(&attr)
    posix_spawnattr_setflags(&attr, Int16(0x0400))   // POSIX_SPAWN_SETSID
    let environment = env ?? scriptEnv()
    var argv: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) } + [nil]
    var envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
    var pid: pid_t = 0
    let rc = posix_spawn(&pid, args[0], &fa, &attr, &argv, &envp)
    argv.forEach { free($0) }; envp.forEach { free($0) }
    posix_spawn_file_actions_destroy(&fa); posix_spawnattr_destroy(&attr)
    if capture { close(fds[1]) }
    guard rc == 0 else { if capture { close(fds[0]) }; return false }
    let readFD = capture ? fds[0] : -1
    DispatchQueue.global(qos: .utility).async {
        if readFD >= 0, let onOutput {
            let h = FileHandle(fileDescriptor: readFD, closeOnDealloc: true)
            var pending = ""
            while true {
                let d = h.availableData
                if d.isEmpty { break }
                pending += String(decoding: d, as: UTF8.self)
                while let nl = pending.firstIndex(of: "\n") {
                    let line = String(pending[..<nl]); pending = String(pending[pending.index(after: nl)...])
                    if !line.isEmpty { onOutput(line) }
                }
            }
            if !pending.isEmpty { onOutput(pending) }
        }
        var status: Int32 = 0
        while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
        onExit?((status & 0x7f) == 0 ? (status >> 8) & 0xff : -1)
    }
    return true
}

/// Run a command in its own session (POSIX_SPAWN_SETSID) and wait for it; stdout + stderr captured.
@discardableResult
func shell(_ args: [String], env: [String: String]? = nil) -> (status: Int32, output: String) {
    var fds: [Int32] = [0, 0]
    guard pipe(&fds) == 0 else { return (-1, "pipe failed") }
    var fa: posix_spawn_file_actions_t? = nil
    posix_spawn_file_actions_init(&fa)
    posix_spawn_file_actions_addopen(&fa, 0, "/dev/null", O_RDONLY, 0)
    posix_spawn_file_actions_adddup2(&fa, fds[1], 1)
    posix_spawn_file_actions_adddup2(&fa, fds[1], 2)
    posix_spawn_file_actions_addclose(&fa, fds[0])
    posix_spawn_file_actions_addclose(&fa, fds[1])
    var attr: posix_spawnattr_t? = nil
    posix_spawnattr_init(&attr)
    posix_spawnattr_setflags(&attr, Int16(0x0400))   // POSIX_SPAWN_SETSID (sys/spawn.h)
    let environment = env ?? scriptEnv()
    var argv: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) } + [nil]
    var envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
    defer {
        argv.forEach { free($0) }; envp.forEach { free($0) }
        posix_spawn_file_actions_destroy(&fa); posix_spawnattr_destroy(&attr)
    }
    var pid: pid_t = 0
    let rc = posix_spawn(&pid, args[0], &fa, &attr, &argv, &envp)
    close(fds[1])
    let reader = FileHandle(fileDescriptor: fds[0], closeOnDealloc: true)
    guard rc == 0 else { return (-1, "spawn failed: \(String(cString: strerror(rc)))") }
    let data = reader.readDataToEndOfFile()
    var status: Int32 = 0
    while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
    let code: Int32 = (status & 0x7f) == 0 ? (status >> 8) & 0xff : -1
    return (code, String(decoding: data, as: UTF8.self))
}

/// "a=1 b=2\nc=3" -> [a: 1, b: 2, c: 3] (values without spaces; "steam_pids=1 2 3" keeps the rest of its line)
func keyValues(_ text: String) -> [String: String] {
    var r: [String: String] = [:]
    for line in text.split(separator: "\n") {
        if line.hasPrefix("steam_pids=") || line.hasPrefix("game_pids=") {
            let p = line.split(separator: "=", maxSplits: 1); r[String(p[0])] = p.count > 1 ? String(p[1]) : ""; continue
        }
        if line.contains("game_pids=") {   // "game=1 game_pids=12 34"
            let parts = line.components(separatedBy: " game_pids=")
            r["game_pids"] = parts.count > 1 ? parts[1] : ""
            for kv in parts[0].split(separator: " ") { let p = kv.split(separator: "=", maxSplits: 1); if p.count == 2 { r[String(p[0])] = String(p[1]) } }
            continue
        }
        for kv in line.split(separator: " ") {
            let p = kv.split(separator: "=", maxSplits: 1)
            if p.count == 2 { r[String(p[0])] = String(p[1]) } else if p.count == 1, line.hasSuffix("=") { r[String(p[0])] = "" }
        }
    }
    return r
}

// MARK: - Steam art from the user's install (never bundled)

func gameArt(_ name: String) -> NSImage? {
    let path = Paths.art + "/" + name
    return exists(path) ? NSImage(contentsOfFile: path) : nil
}

var displayRefreshHz: Int { max(NSScreen.main?.maximumFramesPerSecond ?? 60, 30) }
var displayName: String { NSScreen.main?.localizedName ?? "Display" }

// MARK: - model

enum SteamState { case stopped, starting, online }
enum PatchState { case applied, original, unknown }

struct SetupCheck: Identifiable {
    let id: String
    let title: String
    let ok: Bool
    let fix: String
}

/// What scripts/settings.sh reports about the game's configuration and the modding basics.
struct GameSettings: Equatable {
    var pacing = "60"              // "60" (Skyrim's own lock) | "unlocked"
    var preset = "none"            // low | medium | high | ultra | custom | none
    var gameVersion = ""           // 1.7.104.0
    var skse = false
    var skseFor = ""               // game version the installed SKSE dll targets (1.7.104)
    var displayTweaks = false
    var pluginsActive = 0
    var gamepad = false            // SkyrimPrefs [Main] bGamepadEnable
    var shortVersion: String { gameVersion.hasSuffix(".0") ? String(gameVersion.dropLast(2)) : gameVersion }
    /// SKSE installed but built for another game version (Steam updated the game): the version guard (PLAN §8.9)
    var skseMismatch: Bool { skse && !skseFor.isEmpty && !shortVersion.isEmpty && skseFor != shortVersion }
}

@MainActor
final class Launcher: ObservableObject {
    @Published var steam: SteamState = .stopped
    @Published var gameRunning = false
    @Published var loaderRunning = false
    @Published var keizaalInstalled = false
    @Published var keizaalRunning = false
    @Published var otherSteam = false          // tf2mt's Steam is running (same account)
    @Published var deploying = false
    @Published var steamWindow = false         // a Steam window is on screen (Show / Hide Steam button)
    private var steamPIDs: [pid_t] = []        // steam.exe and steamwebhelper.exe (each Wine process is its own Mac app)
    private var gamePIDs: [pid_t] = []
    private var steamToggled = Date.distantPast
    @Published var launching = false
    @Published var launchingKeizaal = false   // the launch in progress is Keizaal Online's launcher, not Play
    @Published var mouseFix: PatchState = .unknown
    @Published var crashFix: PatchState = .unknown
    @Published var checksKnown = false   // the patch checks finished (until then they read as "not applied")
    @Published var settings = GameSettings()
    @Published var checks: [SetupCheck] = []
    @Published var message: String?
    @Published var setupRunning = false
    @Published var setupLog: [String] = []
    @Published var artVersion = 0

    private var timer: Timer?
    private var ticks = 0

    /// Everything required to play (the mouse fix is recommended, not required).
    var readyToPlay: Bool { !checks.isEmpty && checks.filter { $0.id != "mouse" }.allSatisfy(\.ok) }
    var setupComplete: Bool { !checks.isEmpty && checks.allSatisfy(\.ok) }
    var everLoggedIn: Bool { ((try? String(contentsOfFile: Paths.connectionLog, encoding: .utf8)) ?? "").contains("Logged On") }
    var skyrimInstalled: Bool {
        let manifest = (try? String(contentsOfFile: Paths.skyrimManifest, encoding: .utf8)) ?? ""
        return manifest.range(of: #""StateFlags"\s+"4""#, options: .regularExpression) != nil
    }

    init() {
        Session.markLauncherRunning()
        Task.detached { Session.ensureHelper() }
        refresh()
        refreshPatches(); refreshSettings()
        refreshChecks()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.refresh(); self.ticks += 1
                self.continueSetup()
                if self.ticks % 15 == 0 { self.refreshSettings() }   // the player may change files in Finder
            }
        }
    }

    func refresh() {
        Task.detached {
            let kv = keyValues(shell(["/bin/bash", Paths.script("status.sh")]).output)
            let pids = (kv["steam_pids"] ?? "").split(separator: " ").compactMap { pid_t($0) }
            let games = (kv["game_pids"] ?? "").split(separator: " ").compactMap { pid_t($0) }
            // Steam's window on screen? CGWindowList gives owner, layer and size without Screen Recording permission
            let windows = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
            let shown = windows.contains { w in
                guard let pid = w[kCGWindowOwnerPID as String] as? pid_t, pids.contains(pid),
                      (w[kCGWindowLayer as String] as? Int) == 0,
                      let b = w[kCGWindowBounds as String] as? [String: CGFloat] else { return false }
                return (b["Width"] ?? 0) >= 300 && (b["Height"] ?? 0) >= 200   // not tray menus or tooltips
            }
            await MainActor.run {
                self.gameRunning = kv["game"] == "1"
                self.loaderRunning = kv["loader"] == "1"
                self.keizaalInstalled = exists(Paths.keizaalExe)
                let keizaal = kv["keizaal"] == "1"
                if self.keizaalRunning && !keizaal && self.message?.hasPrefix(Launcher.keizaalOpenMessage) == true { self.message = nil }   // closed: back to the initial state
                self.keizaalRunning = keizaal
                self.otherSteam = kv["other_steam"] == "1"
                self.deploying = kv["deploy_lock"] == "1"
                self.steamPIDs = pids; self.gamePIDs = games
                if Date().timeIntervalSince(self.steamToggled) > 4 { self.steamWindow = shown }
                self.steam = kv["steam"] == "1" ? (kv["online"] == "1" ? .online : .starting) : .stopped
                if self.message == "Starting Steam…" && self.steam == .online { self.message = "Steam is online." }
                if self.gameRunning { self.launching = false }
            }
        }
    }

    func refreshSettings() {
        Task.detached {
            let kv = keyValues(shell(["/bin/bash", Paths.script("settings.sh"), "status"]).output)
            var s = GameSettings()
            s.pacing = kv["pacing"] ?? "60"
            s.preset = kv["preset"] ?? "none"
            s.gameVersion = kv["game_version"] ?? ""
            s.skse = kv["skse"] == "1"
            s.skseFor = kv["skse_for"] ?? ""
            s.displayTweaks = kv["displaytweaks"] == "1"
            s.pluginsActive = Int(kv["plugins_active"] ?? "") ?? 0
            s.gamepad = kv["gamepad"] == "1"
            let settings = s
            await MainActor.run { if self.settings != settings { self.settings = settings } }
        }
    }

    func refreshPatches() {
        Task.detached {
            func state(_ tool: String) -> PatchState {
                guard exists(tool), exists(Paths.wine) else { return .unknown }
                let out = shell(["/bin/bash", tool, "status"]).output
                // "upstream": the DXMT build fixes it itself (dxmt_purevirtual_return.sh), as good as applied
                return out.hasPrefix("patched") || out.hasPrefix("upstream") ? .applied : out.hasPrefix("original") ? .original : .unknown
            }
            let m = state(Paths.mousePatch), c = state(Paths.dxmtPatch)
            await MainActor.run { self.mouseFix = m; self.crashFix = c; self.refreshChecks(); self.checksKnown = true }
        }
    }

    /// DXMT build pinned in config/release.conf (scripts/dxmt.sh installs it); nil: the runtime's own.
    static var pinnedDXMT: String? {
        let conf = (try? String(contentsOfFile: Paths.releaseConf, encoding: .utf8)) ?? ""
        return conf.split(separator: "\n").first { $0.hasPrefix("DXMT_VERSION=") }
            .map { String($0.dropFirst("DXMT_VERSION=".count)).trimmingCharacters(in: CharacterSet(charactersIn: "\"' ")) }?.nonEmpty
    }
    /// The pinned DXMT is the one installed (wine/.dxmt-build, written by scripts/dxmt.sh).
    var dxmtCurrent: Bool {
        guard let pinned = Launcher.pinnedDXMT else { return true }
        return (try? String(contentsOfFile: Paths.game + "/wine/.dxmt-build", encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) == pinned
    }

    func refreshChecks() {
        checks = [
            SetupCheck(id: "rosetta", title: "Rosetta 2", ok: exists(Paths.rosetta),
                       fix: "Click “Run setup” (or: softwareupdate --install-rosetta --agree-to-license)."),
            SetupCheck(id: "wine", title: "Wine runtime", ok: exists(Paths.wine),
                       fix: "Click “Run setup” — downloads the runtime (Wine 10 + DXMT, ~230 MB)."),
            SetupCheck(id: "prefix", title: "Wine environment", ok: exists(Paths.prefix + "/system.reg"),
                       fix: "Created by “Run setup”."),
            SetupCheck(id: "crashfix", title: "Skyrim fix for the Metal renderer", ok: crashFix == .applied,
                       fix: "Applied by “Run setup” (without it Skyrim quits after the logo)."),
            SetupCheck(id: "dxmt", title: "Metal renderer (DXMT \(Launcher.pinnedDXMT ?? "runtime"))", ok: dxmtCurrent,
                       fix: "Click “Run setup” with Skyrim and Steam closed: updates DXMT (no more black shadows on 1.6.1170)."),
            SetupCheck(id: "steam", title: "Steam for Windows", ok: exists(Paths.steamExe),
                       fix: "Installed by “Run setup” (official Valve installer)."),
            SetupCheck(id: "login", title: "Logged in to Steam", ok: everLoggedIn,
                       fix: "Click “Log in to Steam” and sign in once (Steam Guard as usual)."),
            SetupCheck(id: "skyrim", title: "Skyrim Special Edition installed", ok: skyrimInstalled,
                       fix: "Click “Install Skyrim” (needs a Steam account that owns it; ≈16 GB)."),
            SetupCheck(id: "mouse", title: "Smooth mouse fix", ok: mouseFix == .applied,
                       fix: mouseFix == .unknown ? "Needs the SkyrimMT runtime (the patch matches that exact Wine build)."
                                                 : "Turn on “Smooth mouse fix” in the Game tab or click “Run setup”."),
        ]
    }

    // MARK: setup

    // MARK: window size (scripts/skyrim.sh applies it before every launch)

    @Published var windowSize: String = (try? String(contentsOfFile: Paths.game + "/config/window-size", encoding: .utf8))?
        .trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? "fit"
    func setWindowSize(_ v: String) {
        windowSize = v
        try? FileManager.default.createDirectory(atPath: Paths.game + "/config", withIntermediateDirectories: true)
        try? (v + "\n").write(toFile: Paths.game + "/config/window-size", atomically: true, encoding: .utf8)
        message = v == "keep" ? "Window size: the profile's own setting." : "Window size applies at the next launch."
    }

    @Published var audioMixRate: String = (try? String(contentsOfFile: Paths.game + "/config/audio-mix-rate", encoding: .utf8))?
        .trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? "96000"
    func setAudioMixRate(_ v: String) {
        audioMixRate = v
        try? FileManager.default.createDirectory(atPath: Paths.game + "/config", withIntermediateDirectories: true)
        try? (v + "\n").write(toFile: Paths.game + "/config/audio-mix-rate", atomically: true, encoding: .utf8)
        message = "Audio mix rate applies at the next launch."
    }

    // MARK: one-click setup: runtime + Wine + Steam (setup.sh) → Steam sign-in → Skyrim install, continuing by itself

    @Published var autoSetup = false
    private var autoLoginStarted = false, autoInstallStarted = false

    func setUpEverything() {
        autoSetup = true; autoLoginStarted = false; autoInstallStarted = false
        let base = ["rosetta", "wine", "prefix", "crashfix", "steam"]
        if checks.filter({ base.contains($0.id) }).allSatisfy(\.ok) { continueSetup() } else { runSetupInteractive() }
    }

    /// Next step of the one-click setup (called after setup.sh and on every status tick).
    func continueSetup() {
        guard autoSetup, !setupRunning else { return }
        refreshChecks()
        guard exists(Paths.steamExe) else { autoSetup = false; return }               // setup.sh stopped: its log says why
        if !everLoggedIn {
            if !autoLoginStarted { autoLoginStarted = true; loginSteam() }
            message = "Sign in to Steam in the window that opened. Setup continues automatically."
            return
        }
        if !skyrimInstalled {
            guard steam == .online else { if !autoLoginStarted { autoLoginStarted = true; startSteam() }; message = "Starting Steam…"; return }
            if !autoInstallStarted { autoInstallStarted = true; installSkyrim() }
            message = "Confirm the install in Steam's window. Skyrim downloads in the background (about 16 GB)."
            return
        }
        autoSetup = false
        refreshPatches(); refreshSettings()
        message = "Setup complete. Install the essential mods next (Mods → Essentials)."
        NotificationCenter.default.post(name: .openModManagerEssentials, object: nil)
    }

    func runSetup(runtimeFile: String? = nil) {
        Session.ensureHelper()
        guard !setupRunning else { return }
        setupRunning = true
        setupLog = []
        var args = [Paths.script("setup.sh")]
        if let runtimeFile { args += ["--runtime", runtimeFile] }
        let started = SessionRunner.run(args, env: scriptEnv(), onOutput: { line in
            Task { @MainActor in self.setupLog.append(line) }
        }, onExit: { code in
            Task { @MainActor in
                self.setupRunning = false
                self.message = code == 0 ? "Setup finished." : "Setup stopped. See the log above."
                if code != 0 { self.autoSetup = false }
                self.artVersion += 1
                self.refreshPatches(); self.refreshSettings(); self.refresh()
            }
        })
        if !started { setupRunning = false; setupLog = ["FAIL couldn't start setup.sh"] }
    }

    var runtimeURLConfigured: Bool {
        let conf = (try? String(contentsOfFile: Paths.releaseConf, encoding: .utf8)) ?? ""
        return conf.range(of: #"RUNTIME_URL="https?://"#, options: .regularExpression) != nil
    }

    func runSetupInteractive() {
        if exists(Paths.wine) || runtimeURLConfigured { runSetup(); return }
        let panel = NSOpenPanel()
        panel.message = "Choose the runtime (tf2mt-runtime-*.tar.xz) downloaded from the release page"
        panel.allowedContentTypes = [UTType(filenameExtension: "xz") ?? .data]
        if panel.runModal() == .OK, let url = panel.url { runSetup(runtimeFile: url.path) }
    }

    func loginSteam() {
        guard !otherSteam else { message = "Close tf2mt's Steam first (same account)."; return }
        Session.ensureHelper()
        message = "Opening Steam — sign in, then come back here."
        Task.detached { SessionRunner.runSync([Paths.script("steam.sh"), "--login"], env: scriptEnv(removing: ["MTL_HUD_ENABLED"])) }
    }

    func installSkyrim() {
        Session.ensureHelper()
        Task.detached {
            let r = SessionRunner.runSync([Paths.script("install-skyrim.sh")])
            await MainActor.run { self.message = r.output.trimmingCharacters(in: .whitespacesAndNewlines) }
        }
    }

    func chooseGameFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.message = "Choose where SkyrimMT keeps Wine, Steam and Skyrim (needs ~25 GB, more with mods)"
        if panel.runModal() == .OK, let url = panel.url { switchGameFolder(to: url.path) }
    }

    /// Game folders to switch between: the ones used before, the current one and SkyrimMT installs found in ~/Games.
    static func gameFolders() -> [String] {
        let games = Paths.home + "/Games"
        let found = ((try? FileManager.default.contentsOfDirectory(atPath: games)) ?? []).map { games + "/" + $0 }
            .filter { exists($0 + "/prefix/system.reg") && exists($0 + "/config/modkit") }   // not tf2mt's (same layout)
        let used = UserDefaults.standard.stringArray(forKey: "gameHomes") ?? []
        return Set(used + found + [Paths.game]).filter { exists($0) }
            .sorted { ($0 as NSString).lastPathComponent.localizedStandardCompare(($1 as NSString).lastPathComponent) == .orderedAscending }
    }

    /// "keizaal — Keizaal Online": the folder's name and its active Mod Manager profile.
    static func gameFolderLabel(_ path: String) -> String {
        let profile = (try? String(contentsOfFile: path + "/config/modkit/current-profile", encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        return (path as NSString).lastPathComponent + (profile.map { " — \($0)" } ?? "")
    }

    /// Switch game folders: everything running from the current one closes (Skyrim included: a switch is never an
    /// accident), then SkyrimMT restarts on the new folder, with the Mod Manager if it was open (ModKit, the session
    /// helper and the status polling all follow the folder they started with).
    func switchGameFolder(to path: String) {
        guard path != Paths.game else { return }
        message = "Closing Skyrim and Steam…"
        let reopenMods = NSApp.windows.contains { $0.title == "SkyrimMT Mods" && $0.isVisible }
        Task.detached {
            _ = shell(["/bin/bash", Paths.script("session-end.sh"), "--force"])   // still the current folder's environment
            await MainActor.run {
                var used = UserDefaults.standard.stringArray(forKey: "gameHomes") ?? []
                for p in [Paths.game, path] where !used.contains(p) { used.append(p) }
                UserDefaults.standard.set(used, forKey: "gameHomes")
                UserDefaults.standard.set(path, forKey: "gameHome")
                UserDefaults.standard.set(reopenMods, forKey: "reopenModManager")
                let pid = ProcessInfo.processInfo.processIdentifier
                _ = spawnDetached(["/bin/bash", "-c", "while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done; open \"$1\"", "relaunch", Bundle.main.bundlePath])
                NSApp.terminate(nil)
            }
        }
    }

    /// Debug → "Load .exe…": run a Windows program in Skyrim's Wine environment (scripts/run-exe.sh).
    func loadExe() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        if let exe = UTType(filenameExtension: "exe") { panel.allowedContentTypes = [exe] }
        panel.message = "Choose a Windows program to run in Skyrim's Wine environment"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let name = url.lastPathComponent
        message = "Starting \(name)…"
        Session.ensureHelper()
        Task.detached {
            let r = SessionRunner.runSync([Paths.script("run-exe.sh"), url.path])
            await MainActor.run {
                self.message = r.status == 0 ? "Started \(name) (output: logs/run-exe.log)"
                                             : "Couldn't start \(name): " + r.output.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
    }

    // MARK: settings

    func setMouseFix(_ on: Bool) {
        Task.detached {
            let r = shell(["/bin/bash", Paths.mousePatch, on ? "apply" : "revert"], env: scriptEnv())
            await MainActor.run {
                self.message = r.status == 0
                    ? (on ? "Mouse fix applied — takes effect on next launch." : "Mouse fix removed — takes effect on next launch.")
                    : "Mouse fix: " + r.output.trimmingCharacters(in: .whitespacesAndNewlines)
                self.refreshPatches()
            }
        }
    }

    func setGamepad(_ on: Bool) {
        guard on != settings.gamepad else { return }
        Task.detached {
            let r = shell(["/bin/bash", Paths.script("settings.sh"), "gamepad", on ? "on" : "off"])
            await MainActor.run {
                self.message = r.status == 0 ? "Saved — applies on next launch." : r.output.trimmingCharacters(in: .whitespacesAndNewlines)
                self.refreshSettings()
            }
        }
    }

    func setPacing(_ p: String) {
        guard p != settings.pacing else { return }
        Task.detached {
            let r = shell(["/bin/bash", Paths.script("settings.sh"), "pacing", p])
            await MainActor.run {
                let out = r.output.trimmingCharacters(in: .whitespacesAndNewlines)
                self.message = r.status == 0 ? (self.gameRunning ? "Saved — restart Skyrim to apply." : "Saved — applies on next launch.")
                                             : "Frame pacing: " + out
                self.refreshSettings()
            }
        }
    }

    func setPreset(_ p: String) {
        guard p != settings.preset, ["low", "medium", "high", "ultra"].contains(p) else { return }
        guard !gameRunning else { message = "Quit Skyrim first — it rewrites its settings on exit."; return }
        Task.detached {
            let r = shell(["/bin/bash", Paths.script("settings.sh"), "preset", p])
            await MainActor.run {
                self.message = r.status == 0 ? "\(p.capitalized) settings applied." : r.output.trimmingCharacters(in: .whitespacesAndNewlines)
                self.refreshSettings()
            }
        }
    }

    // MARK: play & control

    func play(hud: Bool, frameLog: Bool, skse: Bool, extraArgs: String) {
        guard !launching, !gameRunning else { return }
        refreshChecks()
        guard readyToPlay else { message = "Setup incomplete — see the Setup tab."; return }
        guard !otherSteam else { message = "tf2mt's Steam is running with the same account — close it first."; return }
        launching = true
        let mk = ModKit.standard(home: URL(fileURLWithPath: Paths.game))
        mk.recordLaunch()                 // crash analysis knows the profile
        mk.restoreDriftedBinaries()       // plugin DLLs that came back changed from the last run (Wine) → mod's copy
        Session.ensureHelper()
        message = steam == .online ? "Starting Skyrim…" : "Starting Steam — waiting for login…"
        var extra: [String: String] = ["SKYRIMMT_USE_SKSE": skse ? "1" : "0"]
        if hud { extra["SKYRIMMT_METAL_HUD"] = "1" }
        if frameLog {
            let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"
            extra["SKYRIMMT_FRAMETRACE"] = Paths.logs + "/frametimes-\(f.string(from: Date())).csv"
        }
        let env = scriptEnv(extra, removing: ["MTL_HUD_ENABLED"])
        let args = [Paths.script("play.sh")] + extraArgs.split(separator: " ").map(String.init)
        Task.detached {
            try? FileManager.default.createDirectory(atPath: Paths.logs, withIntermediateDirectories: true)
            let r = SessionRunner.runSync(args, env: env)
            let logURL = URL(fileURLWithPath: Paths.logs + "/launcher.log")
            if let h = try? FileHandle(forWritingTo: logURL) {
                h.seekToEndOfFile(); h.write(Data(("=== SkyrimMT launcher \(Date())\n" + r.output + "\n").utf8)); try? h.close()
            } else {
                try? r.output.write(to: logURL, atomically: true, encoding: .utf8)
            }
            await MainActor.run {
                self.launching = false
                self.message = r.status == 0 ? "Have fun!" : "Launch failed — " + (r.output.split(separator: "\n").last.map(String.init) ?? "open Logs for details.")
                self.refresh()
            }
        }
    }

    static let keizaalOpenMessage = "Keizaal Online's launcher is open — press Play there."

    /// Keizaal Online: its launcher logs in, updates its files and starts the game itself (scripts/keizaal.sh). Before
    /// it opens, the deployed files are listed the way Vortex does, so its updater leaves SkyrimMT's files alone.
    func playKeizaal() {
        guard !launching, !gameRunning else { return }
        refreshChecks()
        guard readyToPlay else { message = "Setup incomplete — see the Setup tab."; return }
        guard !otherSteam else { message = "tf2mt's Steam is running with the same account — close it first."; return }
        launching = true; launchingKeizaal = true
        let mk = ModKit.standard(home: URL(fileURLWithPath: Paths.game))
        mk.recordLaunch()
        mk.restoreDriftedBinaries()
        do { try mk.writeVortexDeployment() } catch { message = "Couldn't list the deployed files for Keizaal: \(error)" }
        Session.ensureHelper()
        message = steam == .online ? "Opening Keizaal Online…" : "Starting Steam — waiting for login…"
        Task.detached {
            let r = SessionRunner.runSync([Paths.script("keizaal.sh")])
            let logURL = URL(fileURLWithPath: Paths.logs + "/launcher.log")
            if let h = try? FileHandle(forWritingTo: logURL) {
                h.seekToEndOfFile(); h.write(Data(("=== Keizaal Online \(Date())\n" + r.output + "\n").utf8)); try? h.close()
            }
            await MainActor.run {
                self.launching = false; self.launchingKeizaal = false
                let warning = r.output.split(separator: "\n").last { $0.hasPrefix("warning: ") }?.dropFirst(9)
                self.message = r.status == 0 ? warning.map { Launcher.keizaalOpenMessage + "\n" + $0 } ?? Launcher.keizaalOpenMessage
                    : "Keizaal Online didn't open — " + (r.output.split(separator: "\n").last.map(String.init) ?? "open Logs for details.")
                self.refresh()
            }
        }
    }

    func quitSkyrim() {
        for pid in gamePIDs { kill(pid, SIGTERM) }
        message = "Skyrim closed."
        refresh()
    }

    func closeOtherSteam() {
        message = "Closing tf2mt's Steam…"
        Task.detached {
            let r = shell(["/bin/bash", Paths.script("close-other.sh")])
            await MainActor.run { self.message = r.output.trimmingCharacters(in: .whitespacesAndNewlines); self.refresh() }
        }
    }

    func startSteam() {
        guard !otherSteam else { message = "Close tf2mt's Steam first (same account)."; return }
        Session.ensureHelper()
        if !everLoggedIn { loginSteam(); return }
        message = "Starting Steam…"
        Task.detached { SessionRunner.runSync([Paths.script("steam.sh")], env: scriptEnv(removing: ["MTL_HUD_ENABLED"])) }
    }

    func showSteam() {
        Session.ensureHelper()
        for pid in steamPIDs { NSRunningApplication(processIdentifier: pid)?.unhide() }   // after Hide Steam
        steamWindow = true; steamToggled = Date()
        Task.detached { _ = SessionRunner.runSync([Paths.script("steam.sh"), "--show"], env: scriptEnv(removing: ["MTL_HUD_ENABLED"])) }
    }

    /// Hides Steam like ⌘H: only Steam's own Wine processes, so Skyrim (a separate process) stays as it is. hide()'s
    /// result isn't reliable (it reported failure while Steam did hide), so the button follows the screen again after 4 s.
    func hideSteam() {
        for pid in steamPIDs { NSRunningApplication(processIdentifier: pid)?.hide() }
        steamWindow = false; steamToggled = Date()
    }

    /// Steam's F12 screenshots of Skyrim SE (app 489830), for the Steam account that took the latest ones.
    func openScreenshots() {
        let users = Paths.steamDir + "/userdata"
        let dirs = ((try? FileManager.default.contentsOfDirectory(atPath: users)) ?? [])
            .map { users + "/" + $0 + "/760/remote/489830/screenshots" }.filter(exists)
        let mtime = { (p: String) in (try? FileManager.default.attributesOfItem(atPath: p)[.modificationDate] as? Date) ?? .distantPast }
        guard let dir = dirs.max(by: { mtime($0) < mtime($1) }) else { message = "No screenshots yet — press F12 in game."; return }
        NSWorkspace.shared.open(URL(fileURLWithPath: dir))
    }

    func open(_ path: String) {
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }
}

// MARK: - session lifetime
// Steam and Wine must never outlive a play session. The launcher starts scripts/session-helper.sh (bundled; runs only
// while a session exists) before any Steam/Skyrim action and on start. The helper ends the session when Skyrim has
// exited, or when the launcher is gone and no game runs. The launcher itself never blocks on quit (tf2mt v0.3.1 design).
enum Session {
    static var runDir: String { Paths.game + "/run" }
    static var launcherPidFile: String { runDir + "/launcher.pid" }
    static func markLauncherRunning() {
        try? FileManager.default.createDirectory(atPath: runDir, withIntermediateDirectories: true)
        try? "\(ProcessInfo.processInfo.processIdentifier)".write(toFile: launcherPidFile, atomically: true, encoding: .utf8)
    }
    static func markLauncherGone() {
        // only remove our own pid (a second launcher instance may have taken over)
        if let s = try? String(contentsOfFile: launcherPidFile, encoding: .utf8),
           s.trimmingCharacters(in: .whitespacesAndNewlines) == "\(ProcessInfo.processInfo.processIdentifier)" {
            try? FileManager.default.removeItem(atPath: launcherPidFile)
        }
    }
    /// Start the session helper unless one is running. Returns at once.
    static func ensureHelper() {
        guard exists(Paths.script("session-helper.sh")) else { return }
        SessionRunner.runSync([Paths.script("session-helper.sh"), "--spawn"])
    }
}

/// Runs SkyrimMT scripts through the invisible "SkyrimMT Session" app (Contents/Helpers), opened via LaunchServices.
/// macOS 27 attributes processes to the app that started them; started by the Session app (which exits right after
/// its script), Steam/Wine/Skyrim belong to no visible app, so quitting SkyrimMT really quits it.
enum SessionRunner {
    static var appPath: String { Bundle.main.bundlePath + "/Contents/Helpers/SkyrimMT Session.app" }
    static var available: Bool { exists(appPath + "/Contents/MacOS/skyrimmt-session") }

    @discardableResult
    static func run(_ scriptArgs: [String], env: [String: String] = scriptEnv(),
                    onOutput: ((String) -> Void)? = nil, onExit: ((Int32) -> Void)? = nil) -> Bool {
        guard available else {   // dev build without the helper app
            return spawnDetached(["/bin/bash"] + scriptArgs, env: env, onOutput: onOutput ?? { _ in }, onExit: onExit)
        }
        let dir = Session.runDir
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let out = dir + "/req-\(UUID().uuidString).log"
        FileManager.default.createFile(atPath: out, contents: nil)
        var openArgs = ["/usr/bin/open", "-n", "-g", "-j"]
        var e = env.filter { k, _ in ["SKYRIM", "MTL_", "WINE", "MVK", "DYLD", "DXMT", "TF2_HOME"].contains { k.hasPrefix($0) } }
        e["SKYRIMMT_OUT"] = out
        e["SKYRIM_HOME"] = Paths.game
        for (k, v) in e { openArgs += ["--env", "\(k)=\(v)"] }
        openArgs += [appPath, "--args"] + scriptArgs
        guard shell(openArgs).status == 0 else { try? FileManager.default.removeItem(atPath: out); return false }
        DispatchQueue.global(qos: .utility).async {
            guard let h = FileHandle(forReadingAtPath: out) else { onExit?(-1); return }
            var pending = ""
            func drain() {
                let d = h.readDataToEndOfFile()
                guard !d.isEmpty else { return }
                pending += String(decoding: d, as: UTF8.self)
                while let nl = pending.firstIndex(of: "\n") {
                    let line = String(pending[..<nl]); pending = String(pending[pending.index(after: nl)...])
                    if !line.isEmpty { onOutput?(line) }
                }
            }
            let deadline = Date().addingTimeInterval(4 * 3600)
            while !exists(out + ".status") && Date() < deadline { drain(); usleep(200_000) }
            drain(); if !pending.isEmpty { onOutput?(pending) }
            let code = Int32(((try? String(contentsOfFile: out + ".status", encoding: .utf8)) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1
            try? h.close()
            try? FileManager.default.removeItem(atPath: out); try? FileManager.default.removeItem(atPath: out + ".status")
            onExit?(code)
        }
        return true
    }

    /// Same, waiting for the result (call off the main thread).
    static func runSync(_ scriptArgs: [String], env: [String: String] = scriptEnv()) -> (status: Int32, output: String) {
        let done = DispatchSemaphore(value: 0)
        var lines: [String] = []; var code: Int32 = -1
        let lock = NSLock()
        guard run(scriptArgs, env: env, onOutput: { l in lock.lock(); lines.append(l); lock.unlock() },
                  onExit: { c in code = c; done.signal() }) else { return (-1, "couldn't start \(scriptArgs.first ?? "")") }
        done.wait()
        return (code, lines.joined(separator: "\n"))
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// nxm:// links (Nexus "Mod Manager Download"): handed to the mod manager, whose window opens.
    func application(_ application: NSApplication, open urls: [URL]) {
        // skyrim-rp:// (Keizaal Online's Discord login coming back from the browser): to its launcher in the prefix
        for u in urls where u.scheme?.lowercased() == "skyrim-rp" {
            Task.detached { _ = shell(["/bin/bash", Paths.script("keizaal.sh"), u.absoluteString]) }
        }
        for u in urls where u.scheme?.lowercased() == "nxm" {
            Task { @MainActor in
                ModManagerModel.shared?.handleNxm(u)
                NotificationCenter.default.post(name: .openModManager, object: nil)
            }
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // hand the session to the helper and quit immediately (Dock Quit, Cmd-Q, closing the window, updater)
        Session.markLauncherGone()
        Session.ensureHelper()
        return .terminateNow
    }
}

// MARK: - auto-update (GitHub releases; tf2mt's Updater with SkyrimMT names)
// Checks the latest GitHub release, downloads SkyrimMT-app.zip, verifies it against the SHA-256 digest GitHub
// publishes for the asset, checks the unpacked bundle (identifier, version, code signature) and swaps it in place after
// the launcher quits (old copy kept until the swap succeeds, then relaunch). Never while Skyrim is running.
// Test hooks: defaults key "updateFeedURL" overrides the API URL (file:// works); env SKYRIMMT_UPDATE_AUTOINSTALL=1.

struct UpdateError: Error { let message: String }
struct ReleaseInfo { let tag: String; let notes: String; let page: String; let zipURL: URL; let digest: String?; let size: Int }

func versionParts(_ v: String) -> [Int] {
    // "v0.3.0", "0.3.0", "v0.2.0-4-gabc123" -> [0,3,0]
    var core = v.hasPrefix("v") ? String(v.dropFirst()) : v
    if let dash = core.firstIndex(of: "-") { core = String(core[..<dash]) }
    return core.split(separator: ".").map { Int($0) ?? 0 }
}
func isNewer(_ a: String, than b: String) -> Bool {
    let x = versionParts(a), y = versionParts(b)
    for i in 0..<max(x.count, y.count) {
        let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
        if l != r { return l > r }
    }
    return false
}

enum UpdateState: Equatable {
    case idle, checking, upToDate, noReleases, available(String), downloading, installing, failed(String)
}

final class Updater: ObservableObject {
    static let repo = "HorrorPills/skyrimmt"
    static let assetName = "SkyrimMT-app.zip"
    @Published var state: UpdateState = .idle
    @Published var latest: ReleaseInfo?
    @Published var lastChecked: Date?
    let current: String = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "dev"
    private var timer: Timer?

    var feedURL: URL {
        if let s = UserDefaults.standard.string(forKey: "updateFeedURL"), let u = URL(string: s) { return u }
        return URL(string: "https://api.github.com/repos/\(Updater.repo)/releases/latest")!
    }

    func startAutomaticChecks() {
        check()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in self?.check() }
    }

    func check() {
        if state == .checking || state == .downloading || state == .installing { return }
        state = .checking
        var req = URLRequest(url: feedURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("SkyrimMT-launcher/\(current)", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: req) { data, resp, err in
            let result: Result<ReleaseInfo?, UpdateError> = {
                if let err = err { return .failure(UpdateError(message: "Couldn't reach GitHub: \(err.localizedDescription)")) }
                if let h = resp as? HTTPURLResponse, h.statusCode == 404 { return .success(nil) }   // no release (or repo) yet
                if let h = resp as? HTTPURLResponse, h.statusCode != 200 { return .failure(UpdateError(message: "GitHub answered HTTP \(h.statusCode).")) }
                guard let data = data, let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let tag = j["tag_name"] as? String else { return .failure(UpdateError(message: "Unexpected reply from GitHub.")) }
                if (j["draft"] as? Bool) == true || (j["prerelease"] as? Bool) == true { return .success(nil) }
                let assets = j["assets"] as? [[String: Any]] ?? []
                guard let a = assets.first(where: { ($0["name"] as? String) == Updater.assetName }),
                      let s = a["browser_download_url"] as? String, let u = URL(string: s) else { return .success(nil) }
                return .success(ReleaseInfo(tag: tag, notes: j["body"] as? String ?? "", page: j["html_url"] as? String ?? "",
                                            zipURL: u, digest: a["digest"] as? String, size: a["size"] as? Int ?? 0))
            }()
            DispatchQueue.main.async {
                self.lastChecked = Date()
                switch result {
                case .failure(let e): self.state = .failed(e.message)
                case .success(let r):
                    self.latest = r
                    if let r = r, isNewer(r.tag, than: self.current) {
                        self.state = .available(r.tag)
                        if ProcessInfo.processInfo.environment["SKYRIMMT_UPDATE_AUTOINSTALL"] == "1" { self.install(gameRunning: false) }
                    } else { self.state = r == nil ? .noReleases : .upToDate }
                }
            }
        }.resume()
    }

    func install(gameRunning: Bool) {
        guard case .available = state, let r = latest else { return }
        if gameRunning { state = .failed("Quit Skyrim before updating."); return }
        let dest = Bundle.main.bundlePath
        guard FileManager.default.isWritableFile(atPath: (dest as NSString).deletingLastPathComponent) else {
            state = .failed("No permission to replace \(dest)."); return
        }
        guard let digest = r.digest, digest.hasPrefix("sha256:") else {
            state = .failed("Release has no checksum; download it from GitHub instead."); return
        }
        state = .downloading
        URLSession.shared.downloadTask(with: r.zipURL) { tmp, resp, err in
            func fail(_ m: String) { DispatchQueue.main.async { self.state = .failed(m) } }
            if let err = err { return fail("Download failed: \(err.localizedDescription)") }
            if let h = resp as? HTTPURLResponse, h.statusCode != 200 { return fail("Download failed: HTTP \(h.statusCode).") }
            guard let tmp = tmp else { return fail("Download failed.") }
            let work = NSTemporaryDirectory() + "skyrimmt-update-\(UUID().uuidString)"
            let zip = work + "/" + Updater.assetName
            do {
                try FileManager.default.createDirectory(atPath: work, withIntermediateDirectories: true)
                try FileManager.default.moveItem(atPath: tmp.path, toPath: zip)
            } catch { return fail("Couldn't store the download: \(error.localizedDescription)") }
            DispatchQueue.main.async { self.state = .installing }
            let sum = shell(["/usr/bin/shasum", "-a", "256", zip]).output.split(separator: " ").first.map(String.init) ?? ""
            if "sha256:" + sum != digest { return fail("Checksum mismatch; the update was not installed.") }
            if shell(["/usr/bin/ditto", "-x", "-k", zip, work + "/new"]).status != 0 { return fail("Couldn't unpack the update.") }
            let app = work + "/new/SkyrimMT.app"
            let info = NSDictionary(contentsOfFile: app + "/Contents/Info.plist")
            guard info?["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier,
                  let v = info?["CFBundleShortVersionString"] as? String, versionParts(v) == versionParts(r.tag) else {
                return fail("The downloaded app doesn't look like SkyrimMT \(r.tag).")
            }
            if shell(["/usr/bin/codesign", "--verify", "--deep", app]).status != 0 { return fail("The downloaded app's signature is broken.") }
            shell(["/usr/bin/xattr", "-dr", "com.apple.quarantine", app])
            let helper = work + "/swap.sh"
            let script = """
            #!/bin/bash
            while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done
            DEST="$1"; NEW="$2"; OLD="$DEST.previous"
            rm -rf "$OLD"
            if mv "$DEST" "$OLD" && mv "$NEW" "$DEST"; then rm -rf "$OLD"; else [ -d "$OLD" ] && [ ! -d "$DEST" ] && mv "$OLD" "$DEST"; fi
            /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST" >/dev/null 2>&1
            open "$DEST"
            rm -rf "\(work)"
            """
            do { try script.write(toFile: helper, atomically: true, encoding: .utf8) } catch { return fail("Couldn't prepare the update.") }
            if !spawnDetached(["/bin/bash", helper, dest, app]) { return fail("Couldn't start the update helper.") }
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }.resume()
    }
}

// MARK: - style

extension Notification.Name {
    static let openModManager = Notification.Name("SkyrimMT.openModManager")
    static let openModManagerEssentials = Notification.Name("SkyrimMT.openModManagerEssentials")
}

extension Color {
    static let skGold = Color(red: 0.78, green: 0.66, blue: 0.42)        // muted gold accent
    static let skGoldLight = Color(red: 0.90, green: 0.79, blue: 0.55)
    static let skCream = Color(red: 0.91, green: 0.89, blue: 0.84)
    static let skDark = Color(red: 0.07, green: 0.075, blue: 0.08)
    static let skPanel = Color(red: 0.13, green: 0.135, blue: 0.145)
    static let skRed = Color(red: 0.74, green: 0.27, blue: 0.22)
    static let skGreen = Color(red: 0.48, green: 0.70, blue: 0.42)
}

extension Font {
    static func title(_ size: CGFloat) -> Font { .system(size: size, weight: .semibold, design: .serif) }
    static func body(_ size: CGFloat) -> Font { .system(size: size, weight: .regular, design: .default) }
}

struct Card<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !title.isEmpty {
                Text(title.uppercased()).font(.title(14)).foregroundStyle(Color.skGoldLight).tracking(2)
            }
            content
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.skPanel.opacity(0.92), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.skGold.opacity(0.14)))
    }
}

struct RowText: View {
    let title: String
    let detail: String
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.body(14)).foregroundStyle(Color.skCream)
            Text(detail).font(.system(size: 11)).foregroundStyle(Color.skCream.opacity(0.55))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct OptionRow: View {
    let title: String
    let detail: String
    @Binding var isOn: Bool
    var body: some View {
        Toggle(isOn: $isOn) { RowText(title: title, detail: detail) }
            .toggleStyle(.switch).tint(.skGold)
    }
}

struct StatusRow: View {
    let label: String
    let value: String
    let color: Color
    var body: some View {
        HStack {
            Circle().fill(color).frame(width: 9, height: 9).shadow(color: color.opacity(0.8), radius: 4)
            Text(label).font(.body(13)).foregroundStyle(Color.skCream.opacity(0.75))
            Spacer()
            Text(value).font(.body(13)).foregroundStyle(Color.skCream)
        }
    }
}

struct PlayButtonStyle: ButtonStyle {
    let enabled: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.title(30)).tracking(4)
            .lineLimit(1).minimumScaleFactor(0.5).padding(.horizontal, 16)   // "Start Keizaal Online" is wider than PLAY
            .foregroundStyle(enabled ? Color.skDark : Color.skCream.opacity(0.6))
            .frame(maxWidth: .infinity, minHeight: 70)
            .background(
                LinearGradient(colors: enabled ? [.skGoldLight, .skGold] : [.gray.opacity(0.45), .gray.opacity(0.3)],
                               startPoint: .top, endPoint: .bottom),
                in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.white.opacity(0.25), lineWidth: 1))
            .shadow(color: enabled ? Color.skGold.opacity(0.45) : .clear, radius: configuration.isPressed ? 4 : 14, y: 4)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Play or Start Keizaal Online: whichever is the folder's main launch gets the big gold button.
struct LaunchButtonStyle: ButtonStyle {
    let big: Bool
    let enabled: Bool
    @ViewBuilder func makeBody(configuration: Configuration) -> some View {
        if big { PlayButtonStyle(enabled: enabled).makeBody(configuration: configuration) }
        else { SmallButtonStyle().makeBody(configuration: configuration) }
    }
}

struct SmallButtonStyle: ButtonStyle {
    var prominent = false
    func makeBody(configuration: Configuration) -> some View { SmallButtonBody(configuration: configuration, prominent: prominent) }
}

private struct SmallButtonBody: View {
    let configuration: ButtonStyle.Configuration
    let prominent: Bool
    @Environment(\.isEnabled) private var isEnabled   // disabled buttons must look disabled
    var body: some View {
        configuration.label
            .font(.body(13))
            .foregroundStyle(prominent ? Color.skDark : Color.skCream)
            .padding(.vertical, 8).frame(maxWidth: .infinity)
            .background((prominent ? Color.skGold : Color.white.opacity(0.08)).opacity(configuration.isPressed ? 0.7 : 1),
                        in: RoundedRectangle(cornerRadius: 8))
            .opacity(isEnabled ? 1 : 0.4)
    }
}

struct TabButton: View {
    let title: String
    let selected: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title.uppercased()).font(.title(13)).tracking(1.6).lineLimit(1).fixedSize()
                .foregroundStyle(selected ? Color.skDark : Color.skCream.opacity(0.55))
                .padding(.horizontal, 14).padding(.vertical, 7)
                .background(selected ? Color.skGold : Color.clear, in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - views

enum Tab: String, CaseIterable { case game = "Game", mods = "Mods", setup = "Setup", debug = "Debug" }

struct ContentView: View {
    @ObservedObject var mods: ModManagerModel
    @StateObject private var pads = ControllerMonitor()
    @Environment(\.openWindow) private var openWindow
    @StateObject private var launcher = Launcher()
    @StateObject private var updater = Updater()
    @AppStorage("autoUpdateCheck") private var autoUpdateCheck = true
    @AppStorage("metalHUD") private var metalHUD = false
    @AppStorage("frameLog") private var frameLog = false
    @AppStorage("extraArgs") private var extraArgs = ""
    @FocusState private var argsFocused: Bool
    @AppStorage("useSKSE") private var useSKSE = true
    @AppStorage("tab") private var tabRaw = Tab.game.rawValue   // (@State needs the Xcode macro plugin)
    @AppStorage("folderSwitchChoice") private var folderChoice = ""   // Setup → game folder picked to switch to
    private var tab: Tab { Tab(rawValue: tabRaw) ?? .game }

    var body: some View {
        ZStack(alignment: .top) {
            Color.skDark.ignoresSafeArea()
            VStack(spacing: 0) {
                hero
                HStack(alignment: .top, spacing: 18) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 6) {
                            ForEach(Tab.allCases, id: \.self) { t in
                                TabButton(title: t.rawValue, selected: tab == t) { tabRaw = t.rawValue }
                            }
                            Spacer()
                            if !launcher.setupComplete && tab != .setup {
                                Button { tabRaw = Tab.setup.rawValue } label: {
                                    Label("Setup incomplete", systemImage: "exclamationmark.triangle.fill")
                                        .font(.body(13)).foregroundStyle(Color.skGoldLight)
                                }.buttonStyle(.plain)
                            }
                        }
                        ScrollView {
                            switch tab {
                            case .game: gameTab
                            case .mods: modsTab
                            case .setup: setup
                            case .debug: debug
                            }
                        }
                        .scrollIndicators(.visible)   // long pages (Setup) must show that there is more below
                        .frame(height: 340)
                    }
                    VStack(spacing: 12) {
                        status
                        launchOptions
                        updateControl
                        if launcher.keizaalInstalled { keizaalButton }   // the folder is for Keizaal: plain Play goes under it
                        playButton
                        HStack(spacing: 10) {
                            Button("Quit Skyrim") { launcher.quitSkyrim() }.disabled(!launcher.gameRunning)
                            if launcher.steam == .online {
                                Button(launcher.steamWindow ? "Hide Steam" : "Show Steam") {
                                    launcher.steamWindow ? launcher.hideSteam() : launcher.showSteam()
                                }
                            } else {
                                Button("Start Steam") { launcher.startSteam() }
                                    .disabled(launcher.steam != .stopped || !exists(Paths.steamExe) || launcher.otherSteam)
                            }
                            Button("Logs") { launcher.open(Paths.logs) }
                        }
                        .buttonStyle(SmallButtonStyle())
                        if let m = launcher.message {
                            Text(m).font(.body(13)).foregroundStyle(Color.skCream.opacity(0.7))
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: .infinity, alignment: .center).transition(.opacity)
                        }
                    }
                    .frame(width: 330)
                    .padding(.top, 40)
                }
                .padding(.horizontal, 24).padding(.bottom, 20).padding(.top, 2)
            }
            .frame(width: 980, height: 722 + keizaalRow, alignment: .top)   // full window incl. the hidden title bar strip
            .ignoresSafeArea(edges: .top)
        }
        .frame(width: 980, height: 690 + keizaalRow)          // window adds the 32 pt title-bar inset on top
        .animation(.easeInOut(duration: 0.2), value: launcher.message)
        .onReceive(NotificationCenter.default.publisher(for: .openModManager)) { _ in openWindow(id: "mods") }
        .onReceive(NotificationCenter.default.publisher(for: .openModManagerEssentials)) { _ in
            if !mods.missingEssentials.isEmpty { mods.section = .essentials; openWindow(id: "mods") }
        }
        .overlay { if mods.versionDownloading != nil { VersionDownloadView(mods: mods) } }
        .onChange(of: mods.versionCurrent) { _ in launcher.refreshSettings() }
        .onChange(of: launcher.checksKnown) { known in if known && !launcher.setupComplete { tabRaw = Tab.setup.rawValue } }
        .onAppear {
            if UserDefaults.standard.bool(forKey: "reopenModManager") {   // restarted by a game folder switch
                UserDefaults.standard.removeObject(forKey: "reopenModManager"); openWindow(id: "mods")
            }
            if autoUpdateCheck { updater.startAutomaticChecks() }
            if launcher.checksKnown && !launcher.setupComplete { tabRaw = Tab.setup.rawValue }   // first run: guide through Setup
            mods.gameRunning = { [weak launcher] in launcher?.gameRunning ?? false }
            mods.gameVersion = { [weak launcher] in launcher?.settings.shortVersion ?? "" }
        }
    }

    /// Update offer, right above Play (tf2mt layout lesson).
    @ViewBuilder private var updateControl: some View {
        switch updater.state {
        case .available(let tag):
            HStack(spacing: 8) {
                Button { updater.install(gameRunning: launcher.gameRunning) } label: {
                    Label(launcher.gameRunning ? "Quit Skyrim to update to \(tag)" : "Update to \(tag)",
                          systemImage: "arrow.down.circle.fill").lineLimit(1)
                }
                .buttonStyle(SmallButtonStyle(prominent: true))
                .disabled(launcher.gameRunning)
                if let page = updater.latest?.page, let u = URL(string: page) {
                    Button { NSWorkspace.shared.open(u) } label: { Text("What's new").lineLimit(1) }
                        .buttonStyle(SmallButtonStyle()).frame(width: 100)
                }
            }
        case .downloading, .installing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(updater.state == .downloading ? "Downloading update…" : "Installing update…")
                    .font(.body(13)).foregroundStyle(Color.skCream).lineLimit(1).fixedSize()
            }
        default: EmptyView()
        }
    }

    private var updateStatusText: String {
        switch updater.state {
        case .idle: return "Installed: \(updater.current)"
        case .checking: return "Checking…"
        case .upToDate: return "\(updater.current) is the latest version."
        case .noReleases: return "No published release yet (installed: \(updater.current))."
        case .available(let t): return "\(t) is available (installed: \(updater.current))."
        case .downloading: return "Downloading…"
        case .installing: return "Installing…"
        case .failed(let m): return m
        }
    }

    private var updatesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                RowText(title: "Updates", detail: updateStatusText)
                Button("Check now") { updater.check() }.buttonStyle(SmallButtonStyle()).frame(width: 100)
                    .disabled(updater.state == .checking || updater.state == .downloading || updater.state == .installing)
            }
            OptionRow(title: "Check for updates automatically", detail: "On launch and every 6 hours; you choose when to install.",
                      isOn: $autoUpdateCheck)
        }
    }

    private var headerLine: String {
        var s = "\(displayName)  ·  \(displayRefreshHz) Hz  ·  SkyrimMT \(updater.current)"
        if !launcher.settings.shortVersion.isEmpty {
            s += "  ·  Skyrim \(launcher.settings.shortVersion)" + (launcher.settings.skse ? (launcher.settings.skseMismatch ? " (SKSE ⚠︎)" : " (SKSE ✓)") : "")
        }
        return s
    }

    private var hero: some View {
        ZStack(alignment: .bottomLeading) {
            if let img = gameArt("library_hero.jpg") {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                    .frame(width: 980, height: 300).clipped()
                    .id(launcher.artVersion)
            } else {
                // before Skyrim is installed: a cold, misty backdrop instead of Bethesda art
                LinearGradient(colors: [Color(red: 0.16, green: 0.19, blue: 0.23), Color(red: 0.36, green: 0.40, blue: 0.44), Color(red: 0.10, green: 0.11, blue: 0.13)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                    .frame(width: 980, height: 300)
            }
            LinearGradient(colors: [.clear, .skDark.opacity(0.45), .skDark], startPoint: .center, endPoint: .bottom)
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 4) {
                    if let logo = gameArt("logo.png") {
                        Image(nsImage: logo).resizable().aspectRatio(contentMode: .fit).frame(height: 64)
                            .shadow(color: .black.opacity(0.6), radius: 8, y: 3)
                    } else {
                        Text("SKYRIM").font(.title(44)).tracking(6).foregroundStyle(Color.skCream)
                            .shadow(color: .black.opacity(0.6), radius: 8, y: 3)
                    }
                    Text("SKYRIMMT  ·  FOR APPLE SILICON")
                        .font(.title(14)).tracking(2.5).foregroundStyle(Color.skGoldLight)
                        .shadow(color: .black, radius: 3)
                }
                Spacer()
                Text(headerLine)
                    .font(.body(12)).foregroundStyle(Color.skCream.opacity(0.75)).shadow(color: .black, radius: 3)
                    .lineLimit(1)
            }
            .padding(.horizontal, 28).padding(.bottom, 12)
        }
        .frame(height: 300)
        .ignoresSafeArea(edges: .top)
    }

    private static let presets = ["low", "medium", "high", "ultra"]

    private var controllersDetail: String {
        if pads.pads.isEmpty {
            if let p = pads.pairedOff.first { return "\(p) is paired but off — press its PS/Xbox/Home button to connect." }
            return "No controller connected. Pair one in System Settings › Bluetooth or plug it in."
        }
        guard let slots = pads.gameSlots else { return pads.checking ? "Checking what Skyrim sees…" : "Not checked yet." }
        if let e = pads.probeError { return "Couldn't check: \(e)" }
        if slots.isEmpty { return "macOS sees it, Skyrim doesn't yet — reconnect the controller, then Check." }
        return "Skyrim sees \(slots.count == 1 ? "it" : "\(slots.count) controllers") (XInput slot \(slots.map(String.init).joined(separator: ", ")))."
            + (launcher.settings.gamepad ? "" : " Turn on “Use in Skyrim”.")
    }

    private var controllersRow: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 5) {
                RowText(title: "Controllers", detail: controllersDetail)
                ForEach(pads.pads) { p in
                    HStack(spacing: 6) {
                        Image(systemName: "gamecontroller.fill").foregroundStyle(Color.skGoldLight)
                        Text(p.name).font(.body(12)).foregroundStyle(Color.skCream)
                        Text([p.transport.isEmpty ? nil : p.transport,
                              p.battery.map { "\($0) %\(p.charging ? " ⚡︎" : "")" }].compactMap { $0 }.joined(separator: " · "))
                            .font(.system(size: 11)).foregroundStyle(Color.skCream.opacity(0.55))
                        if let s = pads.gameSlots, !s.isEmpty { Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.skGreen).help("Skyrim sees a controller") }
                    }
                }
            }
            VStack(alignment: .trailing, spacing: 6) {
                Toggle("Use in Skyrim", isOn: Binding(get: { launcher.settings.gamepad }, set: { launcher.setGamepad($0) }))
                    .toggleStyle(.switch).tint(.skGold).font(.body(12)).foregroundStyle(Color.skCream)
                    .disabled(launcher.gameRunning)
                    .help("Skyrim's own controller switch (SkyrimPrefs.ini bGamepadEnable, also in Settings › Gameplay).")
                Button(pads.checking ? "Checking…" : "Check") { pads.refresh(probeAfter: 0) }
                    .buttonStyle(SmallButtonStyle()).frame(width: 100).disabled(pads.checking)
            }
            .frame(width: 230, alignment: .trailing)
        }
    }

    private var gameTab: some View {
        Card(title: "") {
            HStack {
                RowText(title: "Graphics",
                        detail: launcher.settings.preset == "custom" ? "Your own settings. Picking a preset replaces them."
                                                                     : "Bethesda's presets. On Apple Silicon even Ultra costs little.")
                Picker("", selection: Binding(get: { launcher.settings.preset }, set: { launcher.setPreset($0) })) {
                    if launcher.settings.preset == "custom" || launcher.settings.preset == "none" {
                        Text(launcher.settings.preset == "custom" ? "Custom (your settings)" : "Not set yet").tag(launcher.settings.preset)
                        Divider()
                    }
                    ForEach(Self.presets, id: \.self) { Text($0.capitalized).tag($0) }
                }
                .labelsHidden().frame(width: 230)
                .disabled(launcher.gameRunning || !launcher.skyrimInstalled)
            }
            Divider().overlay(Color.white.opacity(0.06))
            HStack {
                RowText(title: "Frame rate",
                        detail: launcher.settings.displayTweaks
                            ? "Above 60 fps is safe with SSE Display Tweaks installed."
                            : "Skyrim's physics breaks above 60 fps without SSE Display Tweaks (Mods tab).")
                Picker("", selection: Binding(get: { launcher.settings.pacing }, set: { launcher.setPacing($0) })) {
                    Text("60 fps (Skyrim default)").tag("60")
                    Text("Up to \(displayRefreshHz) fps").tag("unlocked")
                        .disabled(!launcher.settings.displayTweaks)
                }
                .labelsHidden().frame(width: 230)
            }
            Divider().overlay(Color.white.opacity(0.06))
            HStack {
                let screen = NSScreen.main?.frame.size ?? CGSize(width: 1920, height: 1080)
                RowText(title: "Window size",
                        detail: "Borderless window. Applied at every launch, for every profile.")
                Picker("", selection: Binding(get: { launcher.windowSize }, set: { launcher.setWindowSize($0) })) {
                    Text("Fit screen (\(Int(screen.width))×\(Int(screen.height)))").tag("fit")
                    ForEach(["1280x720", "1600x900", "1920x1080", "2560x1440", "3840x2160"].filter { s in
                        let p = s.split(separator: "x").compactMap { Double($0) }
                        return p.count == 2 && p[0] <= screen.width && p[1] <= screen.height && !(p[0] == screen.width && p[1] == screen.height)
                    }, id: \.self) { s in Text(s.replacingOccurrences(of: "x", with: "×")).tag(s) }
                    Text("Use profile settings").tag("keep")
                }
                .labelsHidden().frame(width: 230)
            }
            Divider().overlay(Color.white.opacity(0.06))
            HStack {
                RowText(title: "Audio mix rate",
                        detail: "96 kHz fixes crackling on most Macs. Your audio device keeps its own rate.")
                Picker("", selection: Binding(get: { launcher.audioMixRate }, set: { launcher.setAudioMixRate($0) })) {
                    Text("96 kHz (recommended)").tag("96000")
                    Text("48 kHz").tag("48000")
                    Text("Device rate").tag("device")
                }
                .labelsHidden().frame(width: 230)
            }
            Divider().overlay(Color.white.opacity(0.06))
            HStack {
                RowText(title: "Skyrim version",
                        detail: mods.versionCurrent == "steam" ? "Steam's current version. Pin an older one for mods that need it."
                                                               : "Pinned: Steam updates can't break it. Per profile.")
                Picker("", selection: Binding(get: { mods.versionCurrent }, set: { v in
                    if v.hasPrefix("download:") { mods.downloadVersion(String(v.dropFirst(9))) } else { mods.selectVersion(v) }
                })) {
                    Text(mods.label(forVersion: "steam")).tag("steam")
                    ForEach(mods.versionsInstalled, id: \.self) { Text(mods.label(forVersion: $0)).tag($0) }
                    let missing = mods.versionsKnown.filter { !mods.versionsInstalled.contains($0) }
                    if !missing.isEmpty {
                        Divider()
                        ForEach(missing, id: \.self) { Text("Download Skyrim \($0)…").tag("download:\($0)") }
                    }
                }
                .labelsHidden().frame(width: 230)
                .disabled(launcher.gameRunning || mods.versionDownloading != nil)
            }
            Divider().overlay(Color.white.opacity(0.06))
            OptionRow(title: "Smooth mouse fix",
                      detail: launcher.mouseFix == .unknown ? "Run Setup first."
                                                            : "Camera follows every mouse movement (Wine patch).",
                      isOn: Binding(get: { launcher.mouseFix == .applied }, set: { launcher.setMouseFix($0) }))
                .disabled(launcher.mouseFix == .unknown)
            Divider().overlay(Color.white.opacity(0.06))
            controllersRow
            Divider().overlay(Color.white.opacity(0.06))
            HStack {
                RowText(title: "Renderer", detail: "DXMT: Direct3D 11 → Metal, with SkyrimMT's Skyrim fix.")
                Text(launcher.crashFix == .applied ? "Metal (DXMT)" : "Needs setup")
                    .font(.body(13)).foregroundStyle(launcher.crashFix == .applied ? Color.skCream : Color.skGoldLight)
            }
            Divider().overlay(Color.white.opacity(0.06))
            HStack {
                RowText(title: "Screenshots", detail: "F12 in game (Steam). Kept inside this folder's Wine prefix.")
                Button("Open") { launcher.openScreenshots() }.buttonStyle(SmallButtonStyle()).frame(width: 110)
            }
        }
        .onAppear { launcher.refreshSettings(); mods.refreshVersions() }
    }

    private var modsTab: some View {
        Card(title: "") {
            let s = launcher.settings
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: s.skse ? (s.skseMismatch ? "exclamationmark.triangle.fill" : "checkmark.circle.fill") : "circle.dashed")
                    .font(.system(size: 17)).foregroundStyle(s.skse ? (s.skseMismatch ? Color.skGoldLight : Color.skGreen) : Color.skCream.opacity(0.5))
                    .frame(width: 22)
                RowText(title: s.skse ? (s.skseMismatch ? "SKSE is for Skyrim \(s.skseFor) — game is \(s.shortVersion)" : "SKSE \(s.skseFor.isEmpty ? "" : "for \(s.skseFor) ")installed")
                                      : "SKSE not installed",
                        detail: s.skseMismatch ? "SKSE mods only load on the game version they were built for."
                                               : "Script Extender: needed by SkyUI, Display Tweaks and most big mods.")
                if s.skseMismatch, mods.versionsKnown.contains(s.skseFor) || mods.versionsInstalled.contains(s.skseFor) {
                    Button(mods.versionsInstalled.contains(s.skseFor) ? "Use \(s.skseFor)" : "Get \(s.skseFor)") {
                        if mods.versionsInstalled.contains(s.skseFor) { mods.selectVersion(s.skseFor) { launcher.refreshSettings() } }
                        else { mods.downloadVersion(s.skseFor) }
                    }
                    .buttonStyle(SmallButtonStyle(prominent: true)).frame(width: 110)
                    .disabled(mods.versionDownloading != nil || launcher.gameRunning)
                }
            }
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: s.displayTweaks ? "checkmark.circle.fill" : "circle.dashed")
                    .font(.system(size: 17)).foregroundStyle(s.displayTweaks ? Color.skGreen : Color.skCream.opacity(0.5)).frame(width: 22)
                RowText(title: s.displayTweaks ? "SSE Display Tweaks installed" : "SSE Display Tweaks not installed",
                        detail: "Makes frame rates above 60 safe for physics.")
            }
            if s.skse {
                OptionRow(title: "Launch with SKSE",
                          detail: s.skseMismatch ? "Off automatically until SKSE matches the game version." : "Play starts Skyrim through skse64_loader.exe.",
                          isOn: $useSKSE)
            }
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "list.bullet").font(.system(size: 15)).foregroundStyle(Color.skCream.opacity(0.6)).frame(width: 22)
                RowText(title: "Profile: \(mods.profile)",
                        detail: "\(mods.mods.filter(\.enabled).count) of \(mods.mods.count) mods enabled · \(s.pluginsActive) plugins active"
                            + (mods.dirty ? " · changes not deployed" : ""))
                Button("Open Mod Manager") { openWindow(id: "mods"); NSApp.activate(ignoringOtherApps: true) }
                    .buttonStyle(SmallButtonStyle(prominent: true)).frame(width: 150)
            }
            Divider().overlay(Color.white.opacity(0.06))
            HStack(spacing: 10) {
                Button { launcher.open(Paths.myGames + "/Saves") } label: { Label("Saves", systemImage: "folder") }
                    .disabled(!exists(Paths.myGames))
            }
            .buttonStyle(SmallButtonStyle())
        }
        .onAppear { launcher.refreshSettings(); mods.reload(); mods.refreshVersions() }
    }

    private var launchOptions: some View {   // right column, between Status and Play
        VStack(alignment: .leading, spacing: 6) {
            Text("Extra launch options").font(.body(14)).foregroundStyle(Color.skCream)
            TextField("passed to SkyrimSE.exe", text: $extraArgs)
                .focused($argsFocused)
                .onAppear { DispatchQueue.main.async { argsFocused = false } }   // not focused at launch (caret over the placeholder)
                .textFieldStyle(.plain).font(.system(size: 13, design: .monospaced))
                .padding(8).background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 7))
                .foregroundStyle(Color.skCream)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var debug: some View {
        Card(title: "") {
            OptionRow(title: "Metal performance HUD", detail: "Apple's FPS and frame-time overlay.", isOn: $metalHUD)
            Divider().overlay(Color.white.opacity(0.06))
            OptionRow(title: "Record frame times", detail: "Writes logs/frametimes-<date>.csv (Present timing).", isOn: $frameLog)
            Divider().overlay(Color.white.opacity(0.06))
            HStack {
                RowText(title: "Run a Windows program",
                        detail: "Runs an .exe in Skyrim's Wine environment (same prefix and runtime) — e.g. modding tools.")
                Button("Load .exe…") { launcher.loadExe() }
                    .buttonStyle(SmallButtonStyle()).frame(width: 100)
                    .disabled(!exists(Paths.wine))
            }
        }
    }

    private var setup: some View {
        Card(title: "") {
            Text("SkyrimMT includes its own Wine runtime. Steam and Skyrim are downloaded from Valve into your own folder.")
                .font(.system(size: 12)).foregroundStyle(Color.skCream.opacity(0.7))
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button(launcher.setupRunning || launcher.autoSetup ? "Setting up…" : launcher.setupComplete ? "Check setup" : "Set up everything") { launcher.setUpEverything() }
                    .buttonStyle(SmallButtonStyle(prominent: true)).disabled(launcher.setupRunning || launcher.autoSetup)
                Button("Log in to Steam") { launcher.loginSteam() }
                    .buttonStyle(SmallButtonStyle()).disabled(!exists(Paths.steamExe) || launcher.otherSteam)
                Button("Install Skyrim") { launcher.installSkyrim() }
                    .buttonStyle(SmallButtonStyle()).disabled(launcher.steam == .stopped)
            }
            if !launcher.setupLog.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(launcher.setupLog.suffix(14).enumerated()), id: \.offset) { _, line in
                        Text(line).font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(line.hasPrefix("FAIL") ? Color.skRed : line.hasPrefix("==>") ? Color.skGoldLight : Color.skCream.opacity(0.75))
                    }
                }
                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 7))
            }
            ForEach(Array(launcher.checks.enumerated()), id: \.element.id) { i, c in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: c.ok ? "checkmark.circle.fill" : "\(i + 1).circle")
                        .font(.system(size: 17)).foregroundStyle(c.ok ? Color.skGreen : Color.skGoldLight)
                        .frame(width: 22)
                    RowText(title: c.title, detail: c.ok ? "Ready." : c.fix)
                }
            }
            HStack(spacing: 10) {
                RowText(title: "Game folder", detail: Paths.game)
                let target = folderChoice.isEmpty || !exists(folderChoice) ? Paths.game : folderChoice
                Picker("", selection: Binding(get: { target }, set: { v in
                    if v == "\u{0}other" { launcher.chooseGameFolder() } else { folderChoice = v }
                })) {
                    ForEach(Launcher.gameFolders(), id: \.self) { Text(Launcher.gameFolderLabel($0)).tag($0) }
                    Divider()
                    Text("Other folder…").tag("\u{0}other")
                }
                .labelsHidden().controlSize(.large).fixedSize()   // Switch's height; its own width keeps the 10 pt gap
                .help("SkyrimMT installs found in ~/Games and folders used before")
                Button("Switch") { launcher.switchGameFolder(to: target) }
                    .buttonStyle(SmallButtonStyle()).frame(width: 76).disabled(target == Paths.game)
                    .help("Closes Skyrim and Steam, then restarts SkyrimMT on this folder")
            }
            Button("Re-check") { launcher.refreshPatches(); launcher.refreshSettings(); launcher.refresh() }.buttonStyle(SmallButtonStyle())
            Divider().overlay(Color.white.opacity(0.06))
            updatesSection
        }
    }

    /// Play's own launch in progress (not Keizaal Online's launcher)
    private var launchingPlay: Bool { launcher.launching && !launcher.launchingKeizaal }

    private var status: some View {
        Card(title: "Status") {
            StatusRow(label: "Steam",
                      value: launcher.steam == .online ? "Online" : launcher.steam == .starting ? "Logging in…" : "Not running",
                      color: launcher.steam == .online ? .green : launcher.steam == .starting ? .yellow : .gray)
            StatusRow(label: "Skyrim",
                      value: launcher.gameRunning ? "Running" : launcher.loaderRunning ? "Starting…" : launchingPlay ? "Launching…" : "Not running",
                      color: launcher.gameRunning ? .green : (launchingPlay || launcher.loaderRunning) ? .yellow : .gray)
            if launcher.keizaalInstalled {
                StatusRow(label: "Keizaal Online",
                          value: launcher.keizaalRunning ? "Open" : launcher.launchingKeizaal ? "Starting…" : "Not running",
                          color: launcher.keizaalRunning ? .green : launcher.launchingKeizaal ? .yellow : .gray)
            }
            if launcher.otherSteam {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.skGoldLight)
                    Text("tf2mt's Steam is running (same account).").font(.body(12)).foregroundStyle(Color.skCream.opacity(0.8))
                    Spacer()
                    Button("Close it") { launcher.closeOtherSteam() }.buttonStyle(SmallButtonStyle()).frame(width: 76)
                }
            }
        }
    }

    /// Room for the Keizaal Online button under Play (the window is fixed-size).
    private var keizaalRow: CGFloat { launcher.keizaalInstalled ? 58 : 0 }   // button + its Status row

    /// Keizaal Online installed in this prefix: its launcher (login, updates) starts the game; same preparation as Play.
    private var keizaalButton: some View {
        let canStart = !launcher.gameRunning && !launcher.launching && launcher.readyToPlay && !launcher.otherSteam
        return Button {
            mods.prepareForPlay(status: { launcher.message = $0 }) { launcher.playKeizaal() }
        } label: {
            HStack(spacing: 12) {
                if launcher.launchingKeizaal { ProgressView().controlSize(.small) }
                Text(launcher.launchingKeizaal ? "Starting…" : launcher.keizaalRunning ? "Keizaal is open" : "Start Keizaal Online")
                    .tracking(0.5)   // PLAY's wide spacing makes this long label too wide
            }
        }
        .buttonStyle(LaunchButtonStyle(big: true, enabled: canStart))
        .disabled(!canStart)
        .keyboardShortcut(.defaultAction)
        .help("Opens Keizaal Online's launcher (Discord login, updates): press Play there.")
    }

    private var playButton: some View {
        let canPlay = !launcher.gameRunning && !launcher.launching && launcher.readyToPlay && !launcher.otherSteam
        let big = !launcher.keizaalInstalled
        return Button {
            let (h, f, sk, x) = (metalHUD, frameLog, useSKSE, extraArgs)
            mods.prepareForPlay(status: { launcher.message = $0 }) { launcher.play(hud: h, frameLog: f, skse: sk, extraArgs: x) }
        } label: {
            HStack(spacing: big ? 12 : 8) {
                if launchingPlay { ProgressView().controlSize(.small) }
                Text(big ? (launcher.gameRunning ? "RUNNING" : launchingPlay ? "LAUNCHING" : launcher.readyToPlay ? "PLAY" : "SET UP")
                         : (launcher.gameRunning ? "Skyrim is running" : launchingPlay ? "Launching Skyrim…" : launcher.readyToPlay ? "Play Skyrim" : "Set up"))
            }.frame(maxWidth: .infinity)
        }
        .buttonStyle(LaunchButtonStyle(big: big, enabled: canPlay))
        .disabled(!canPlay)
        .keyboardShortcut(big ? .defaultAction : nil)
    }
}

/// Progress card for a version download; shows Steam's QR code (parsed from DepotDownloader's text QR) for the
/// one-time login in the Steam mobile app.
struct VersionDownloadView: View {
    @ObservedObject var mods: ModManagerModel
    var body: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
            VStack(spacing: 14) {
                Text("Getting Skyrim \(mods.versionDownloading ?? "")").font(.title(20)).foregroundStyle(Color.skCream)
                Text(mods.versionStep).font(.body(13)).foregroundStyle(Color.skCream.opacity(0.8)).multilineTextAlignment(.center)
                if !mods.qrLines.isEmpty {
                    QRView(lines: mods.qrLines).frame(width: 240, height: 240)
                    Text("In the Steam mobile app, open Steam Guard and scan the code.")
                        .font(.system(size: 11)).foregroundStyle(Color.skCream.opacity(0.6)).multilineTextAlignment(.center).frame(width: 320)
                } else if let p = mods.versionProgress {
                    ProgressView(value: p).frame(width: 320).tint(.skGold)
                    Text("\(Int(p * 100)) %").font(.body(12)).foregroundStyle(Color.skCream.opacity(0.7))
                } else {
                    ProgressView().controlSize(.small)
                }
                if let e = mods.versionError { Text(e).font(.body(12)).foregroundStyle(Color.skRed) }
                Text("Files are downloaded from Steam with your account.")
                    .font(.system(size: 11)).foregroundStyle(Color.skCream.opacity(0.5))
            }
            .padding(26)
            .background(Color.skPanel, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.skGold.opacity(0.3)))
        }
    }
}

/// Renders QRCoder's ASCII QR (each module = 2 characters, dark = non-space) as a crisp black-on-white code.
struct QRView: View {
    let lines: [String]
    var body: some View {
        let rows: [[Bool]] = lines.map { line in
            let chars = Array(line)
            return stride(from: 0, to: chars.count - 1, by: 2).map { chars[$0] != " " }
        }
        let n = max(rows.map(\.count).max() ?? 1, rows.count)
        Canvas { ctx, size in
            let quiet = 4.0, cell = min(size.width, size.height) / (Double(n) + 2 * quiet)
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white))
            for (y, row) in rows.enumerated() {
                for (x, dark) in row.enumerated() where dark {
                    ctx.fill(Path(CGRect(x: (Double(x) + quiet) * cell, y: (Double(y) + quiet) * cell, width: cell + 0.5, height: cell + 0.5)), with: .color(.black))
                }
            }
        }
    }
}

@main
struct SkyrimMTApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var mods = ModManagerModel()
    var body: some Scene {
        WindowGroup("SkyrimMT") {
            ContentView(mods: mods).preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        Window("SkyrimMT Mods", id: "mods") {
            ModManagerView(model: mods)
        }
        .defaultSize(width: 1240, height: 760)
        .commands { ModsCommands(model: mods) }
    }
}

/// Menu bar "Mods": every page and the main actions from the keyboard (⌘1…⌘9 follow the sidebar order).
struct ModsCommands: Commands {
    @ObservedObject var model: ModManagerModel
    var body: some Commands {
        CommandMenu("Mods") {
            ForEach(Array(model.sidebarOrder.prefix(9).enumerated()), id: \.offset) { i, s in
                Button(s.rawValue) { go(s) }.keyboardShortcut(KeyEquivalent(Character(String(i + 1))))
            }
            ForEach(Array(model.sidebarOrder.dropFirst(9)), id: \.self) { s in Button(s.rawValue) { go(s) } }
            Divider()
            Button("Install from Archive…") { go(nil); model.chooseArchives() }.keyboardShortcut("o")
            Button("Create Empty Mod…") { go(nil); model.createEmptyMod() }.keyboardShortcut("n", modifiers: [.command, .shift])
            Button("Deploy") { model.deploy() }.keyboardShortcut("d").disabled(!model.dirty || model.busy != nil)
            Button("Check Nexus for Updates") { model.checkUpdates() }.keyboardShortcut("u", modifiers: [.command, .shift])
            Button("Copy Mod List") { model.copyModList() }
        }
    }
    private func go(_ s: ModsSection?) {
        NotificationCenter.default.post(name: .openModManager, object: nil)
        if let s { model.section = s }
    }
}

extension String { var nonEmpty: String? { isEmpty ? nil : self } }
