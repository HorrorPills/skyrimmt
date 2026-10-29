// SkyrimMT Mods — the mod manager window (PLAN §8.10). SwiftUI over ModKit (app/ModKit): Mods (priority, enable,
// conflicts, install from archive incl. the FOMOD wizard), Plugins (load order, flags, warnings, basic sort),
// Downloads (archives in $SKYRIM_HOME/downloads), Profiles. Nothing is deployed implicitly: "Deploy" applies changes
// (and Play never deploys, PLAN §4.8). Built with swiftc (no @State: ObservableObject + @Published).
import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ModRow: Identifiable, Equatable {
    let id: String
    var name: String
    var version: String
    var enabled: Bool
    var inProfile = true  // false: installed (for another profile), not part of this one — shown unchecked at the end
    var wins = 0          // files this mod provides that override another enabled mod
    var loses = 0         // files of this mod overridden by a later mod
    var files = 0
    var separator = false
    var category = ""
    var notes = ""
    var installed = Date.distantPast
    var plugins = 0
    var nexusID: Int?
    var collection = ""   // collection that installed it ("" = none)
    var priority = 0      // position in the profile (0 = lowest)
    var color = ""        // colour tag ("" = none)
}

struct PluginRow: Identifiable, Equatable {
    var id: String { name.lowercased() }
    var name: String
    var active: Bool
    var kind: String       // ESM / ESL / ESP / ESP-FE
    var masters: [String]
    var issues: [String]
    var implicit: Bool
    var author = ""
    var about = ""
    var ownerID: String?        // mod that deploys it (nil = game / not managed)
    var ownerName = ""
    var requiredBy: [String] = []
}

final class WizardState: ObservableObject {
    let installer: FomodInstaller
    let work: URL
    let layout: ModLayout
    let root: URL
    let name: String
    var archive: URL = URL(fileURLWithPath: "/")
    var rest: [URL] = []          // archives queued after this one
    var reinstallID: String?             // set: the wizard changes an installed mod's options (same entry, new files)
    var update: (fileID: Int?, version: String)?   // set with reinstallID: an update, its installer shown again
    @Published var position = 0          // index into installer.visibleSteps
    @Published var focus: (Int, Int)? = nil   // (group, option) shown in the description pane
    @Published var tick = 0              // bump to refresh after selection changes
    init(installer: FomodInstaller, work: URL, layout: ModLayout, root: URL, name: String) {
        self.installer = installer; self.work = work; self.layout = layout; self.root = root; self.name = name
    }
    var steps: [Int] { installer.visibleSteps }
    var step: Int { steps[min(position, steps.count - 1)] }
}

enum ModsSection: String, CaseIterable, Identifiable { case health = "Health", crashes = "Crashes", saves = "Saves", browse = "Browse", essentials = "Essentials", collections = "Collections", wabbajack = "Wabbajack", mods = "Mods", plugins = "Plugins", data = "Data", downloads = "Downloads", tools = "Tools", profiles = "Profiles", snapshots = "Snapshots", performance = "Performance"
    var id: String { rawValue }
    var icon: String { switch self { case .essentials: return "star"; case .health: return "stethoscope"; case .crashes: return "bolt.trianglebadge.exclamationmark"; case .saves: return "bookmark"; case .browse: return "magnifyingglass"; case .collections: return "square.stack.3d.up"; case .wabbajack: return "shippingbox.and.arrow.backward"; case .mods: return "shippingbox"; case .plugins: return "list.number"; case .data: return "folder"; case .downloads: return "arrow.down.circle"; case .tools: return "wrench.and.screwdriver"; case .profiles: return "person.2"; case .snapshots: return "clock.arrow.circlepath"; case .performance: return "gauge.with.dots.needle.33percent" } } }

@MainActor
final class ModManagerModel: ObservableObject {
    @Published var requirementIssues: [RequirementIssue] = []
    @Published var masterIssues: [MissingMaster] = []
    @Published var loadOrderIssueCount = 0
    @Published var healthStale: (bodySlide: Bool, pandora: Bool) = (false, false)
    @Published var healthChecking = false
    @Published var healthChecked: Date?
    @Published var showSuggestions = false
    @Published var updates: [String: ModUpdate] = [:]     // mod id → newer Nexus file
    @Published var updateChecking = false
    @Published var crashLogs: [URL] = []
    @Published var crashReport: CrashReport?
    @Published var snapshots: [Snapshot] = []
    @Published var sidebarOrder: [ModsSection] = ModManagerModel.loadSidebarOrder()
    var draggingSection: ModsSection?
    @Published var dataTree: DataNode?
    @Published var dataSearch = ""
    @Published var dataSelection: String?
    @Published var dataLoading = false
    @Published var perfCandidates: [PerfCandidate] = []
    @Published var perfSelected: Set<String> = []
    @Published var perfReportShown: PerfReport?
    @Published var perfHasSave = false
    @Published var crashFix: CrashFixTrial?
    @Published var crashFixOutcome: CrashFixOutcome = .waiting
    @Published var saves: [SaveInfo] = []
    @Published var saveSelected: SaveInfo?
    @Published var saveCheck: SaveCheck?
    @Published var savesLoading = false
    @Published var saveBackupList: [SaveBackup] = []
    @Published var iniEditor: IniEditorState?
    var recheckHealthAfterInstall = false
    var deployAfterInstall = false
    var pendingWizards: [WizardState] = []
    @Published var filePicker: FilePickerState?
    @Published var modSearch = ""
    @Published var modFilter: ModFilter = .all
    @Published var modCategory = ""              // "" = all categories
    @Published var modSort: ModSort = .priority
    @Published var modSortAscending = true
    @Published var collapsedGroups = Set(UserDefaults.standard.stringArray(forKey: "collapsedSeparators") ?? [])
    @Published var fileDetail: (wins: [ModFileConflict], loses: [ModFileConflict]) = ([], [])
    @Published var fileList: [String] = []
    @Published var detailTab = 0          // mod detail: 0 conflicts, 1 files
    @Published var fileFilter = ""

    func loadFileDetail(_ id: String) {
        let k = kit, plan = lastPlan
        Task.detached {
            let c = (try? k.fileConflicts(of: id, plan: plan)) ?? ([], [])
            let f = k.modFiles(id)
            await MainActor.run { if self.selected == id { self.fileDetail = c; self.fileList = f } }
        }
    }

    func setFileHidden(_ id: String, _ rel: String, _ hidden: Bool) {
        do { try kit.setFileHidden(id, rel, hidden: hidden) } catch { message = "\(error)" }
        lastPlan = nil; loadFileDetail(id); reload()   // the plan changed: rebuild once
    }
    @Published var pluginSearch = ""
    @Published var pluginFilter: PluginFilter = .all
    @Published var lockedPlugins: Set<String> = []
    @Published var lootRules: [String: [String]] = [:]
    @Published var lightCandidates: [LightCandidate] = []          // LOOT userlist: plugin → load after
    @Published var dirtyPlugins: [String: DirtyPlugin] = [:]     // LOOT: plugins worth cleaning (exact file)
    @Published var staleCleaned: [String] = []
    @Published var skseVersion: String?
    @Published var skseNeeds: SKSEPrerequisites?          // game version the deployed SKSE is built for
    var categoryTried = Set<String>()
    weak var undoManager: UndoManager?
    @Published var nexusDetails: [Int: NexusModDetails] = [:]
    @Published var showAdultPictures = UserDefaults.standard.bool(forKey: "showAdultPictures")
    @Published var endorsed: [Int: String] = [:]
    @Published var tracked: Set<Int> = []
    @Published var downloadJobs: [DownloadJob] = []
    @Published var browseQuery = ""
    @Published var browseSort: NexusSort = .endorsements
    @Published var browseHits: [NexusSearchHit] = []
    @Published var browseTotal = 0
    @Published var browseLoading = false
    @Published var wjCacheSize: Int64 = 0
    var downloadTasks: [UUID: Task<Void, Never>] = [:]          // Nexus mod id → "Endorsed" / "Abstained"
    var nexusDetailsLoaded = false
    var lastPlan: DeployPlan?            // from the last refresh: detail panes reuse it (rebuilding costs seconds on huge lists)
    @Published var downloadSearch = ""
    /// Case- and accent-insensitive substring match; every word of the query must appear.
    static func matches(_ text: String, _ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return true }
        return q.split(separator: " ").allSatisfy { text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }
    @Published var section: ModsSection? = .mods { didSet { if section != oldValue && busy == nil { message = nil } } }   // no stale status on another page
    @Published var mods: [ModRow] = []
    @Published var selectedIDs: Set<String> = []
    var selected: String? {   // the one selected mod (detail panel); nil for none or several
        get { selectedIDs.count == 1 ? selectedIDs.first : nil }
        set { selectedIDs = newValue.map { [$0] } ?? [] }
    }
    @Published var plugins: [PluginRow] = []
    @Published var selectedPlugin: String?
    @Published var profiles: [String] = []
    @Published var profile = "Default"
    @Published var dirty = false
    @Published var busy: String? { didSet { trackBusy(oldValue) } }
    @Published var message: String? { didSet { if let m = message, m != oldValue { trackMessage(m) } } }
    @Published var activity: [ActivityEntry] = []
    @Published var showActivity = false
    @Published var downloads: [URL] = []
    @Published var downloadEntries: [DownloadEntry] = []
    @Published var dlHideInstalled = false
    @Published var dlSelection: Set<String> = []
    @Published var wizard: WizardState?
    @Published var detail: (overrides: [String: Int], overriddenBy: [String: Int]) = ([:], [:])
    var pendingMeta: [String: DownloadMeta?] = [:]
    @Published var keyDraft = ""
    @Published var nexusUser: NexusUser?
    @Published var nexusKeyStored = false      // read in the background (the Keychain may ask first)
    @Published var nxmHandler = ""          // bundle id of the app that opens nxm:// links
    static weak var shared: ModManagerModel?
    var gameRunning: () -> Bool = { false }
    var gameVersion: () -> String = { "" }
    var kit: ModKit

    init() {
        kit = ModKit.standard(home: URL(fileURLWithPath: Paths.game))
        kit.cleanupStale()
        // interrupted work from a previous run: a profile swap (instant switching), a performance test
        try? kit.recoverSlotSwapIfNeeded()
        try? kit.finishPerfRestore()
        reload()
        reloadCollections()
        ModManagerModel.shared = self
        refreshHandler()
        refreshVersions()
        NexusKeychain.loadInBackground { [weak self] k in self?.nexusKeyStored = k != nil; if k != nil { self?.checkKey(); self?.autoCheckUpdates() } }
    }

    // MARK: Skyrim versions (scripts/versions.sh)

    @Published var versionCurrent = "steam"
    @Published var versionSteam = ""
    @Published var versionsInstalled: [String] = []
    @Published var versionsKnown: [String] = []
    @Published var versionDownloading: String?
    @Published var versionStep = ""
    @Published var versionProgress: Double?
    @Published var qrLines: [String] = []
    @Published var versionError: String?

    func refreshVersions() {
        Task.detached {
            let kv = keyValues(shell(["/bin/bash", Paths.script("versions.sh"), "status"]).output)
            await MainActor.run {
                self.versionCurrent = kv["current"] ?? "steam"
                self.versionSteam = (kv["steam_version"] ?? "").replacingOccurrences(of: #"\.0$"#, with: "", options: .regularExpression)
                self.versionsInstalled = (kv["installed"] ?? "").split(separator: " ").map(String.init)
                self.versionsKnown = (kv["known"] ?? "").split(separator: " ").map(String.init)
            }
        }
    }

    func label(forVersion v: String) -> String { v == "steam" ? "\(versionSteam.isEmpty ? "Steam" : versionSteam) (Steam, auto-updates)" : "\(v) (pinned)" }

    /// Download a pinned version (Steam depots under the player's account; first time: QR login in the Steam app).
    func downloadVersion(_ v: String) {
        guard versionDownloading == nil else { return }
        guard !gameRunning() else { message = localized("Quit Skyrim first."); return }
        versionDownloading = v; versionStep = localized("Starting…"); versionProgress = nil; qrLines = []; versionError = nil
        var collecting = false
        let ok = spawnDetached(["/bin/bash", Paths.script("versions.sh"), "download", v], env: scriptEnv(), onOutput: { line in
            Task { @MainActor in
                if line.hasPrefix("STEP ") { self.versionStep = String(line.dropFirst(5)) }
                else if line == "QRSTART" { collecting = true; self.qrLines = []; self.versionStep = localized("Scan the QR code with the Steam mobile app") }
                else if line.hasPrefix("QR ") { if collecting { self.qrLines.append(String(line.dropFirst(3))) } }
                else if line.hasPrefix("LOGGEDIN ") { collecting = false; self.qrLines = []; self.versionStep = localizedFormat("Signed in as %@. Downloading…", "\(line.dropFirst(9))") }
                else if line.hasPrefix("PROGRESS ") { collecting = false; if !self.qrLines.isEmpty { self.qrLines = [] }; self.versionProgress = Double(line.dropFirst(9)).map { $0 / 100 } }
                else if line.hasPrefix("FAIL ") { self.versionError = String(line.dropFirst(5)) }
                else if line.hasPrefix("DONE ") { self.versionStep = String(line.dropFirst(5)) }
            }
        }, onExit: { code in
            Task { @MainActor in
                let v = self.versionDownloading ?? ""
                self.versionDownloading = nil; self.qrLines = []
                self.refreshVersions()
                if code == 0 { self.message = localizedFormat("Skyrim %@ is ready.", v); self.selectVersion(v) }
                else { self.message = localizedFormat("Skyrim %@: %@", v, self.versionError ?? localized("download failed")) }
            }
        })
        if !ok { versionDownloading = nil; message = localized("Couldn't start the download.") }
    }

    /// Use another game folder for the current profile: mods leave the old folder and are deployed into the new one.
    func selectVersion(_ v: String, then: (() -> Void)? = nil) {
        guard v != versionCurrent || kit.gameVersionKey != v else { then?(); return }
        guard !gameRunning() else { message = localized("Quit Skyrim before switching versions."); return }
        busy = localizedFormat("Switching to Skyrim %@…", v == "steam" ? versionSteam : v)
        let old = kit
        Task.detached {
            do {
                try old.purge()                                      // the old game folder goes back to vanilla
                let r = shell(["/bin/bash", Paths.script("versions.sh"), "select", v])
                guard r.status == 0 else { throw ModKitError.invalid(r.output.trimmingCharacters(in: .whitespacesAndNewlines)) }
                let k = ModKit.standard(home: URL(fileURLWithPath: Paths.game))
                var p = try k.currentProfile(); p.gameVersion = v == "steam" ? nil : v; try k.saveProfile(p)
                try k.deploy(p)
                let pname = p.name
                await MainActor.run { self.kit = k; self.busy = nil; self.message = localizedFormat("Now using Skyrim %@ for “%@”.", v == "steam" ? self.versionSteam : v, pname); self.reload(); self.refreshVersions(); then?() }
            } catch {
                await MainActor.run { self.busy = nil; self.message = localizedFormat("Version switch failed: %@", "\(error)"); self.reloadKit(); self.refreshVersions() }
            }
        }
    }

    // MARK: collections

    @Published var colText = ""
    @Published var colInfo: CollectionInfo?
    @Published var colItems: [CollectionMod] = []
    @Published var colStates: [CollectionItemState] = []
    @Published var colOptional: Set<Int> = []        // fileIDs of optional mods the player ticked
    @Published var colRunning = false
    @Published var colInstalled: [InstalledCollection] = []
    @Published var colLatest: [String: CollectionInfo] = [:]   // slug → newer revision
    var colLatestChecked = Date.distantPast
    @Published var colWaiting: CollectionMod?            // free accounts: the mod whose download click we wait for
    var colCancelled = false
    var nxmWaiters: [String: CheckedContinuation<NxmLink?, Never>] = [:]

    func reloadCollections() {
        colInstalled = kit.installedCollections()
        if !colInstalled.isEmpty, Date().timeIntervalSince(colLatestChecked) > 6 * 3600 { checkCollectionUpdates() }
    }

    /// Newer revisions of installed collections (one GraphQL request each, no login needed).
    func checkCollectionUpdates() {
        colLatestChecked = Date()
        let c = client(), installed = colInstalled
        Task.detached {
            var found: [String: CollectionInfo] = [:]
            for col in installed {
                if let ref = CollectionRef(col.slug), let info = try? await c.collection(ref), info.revision > col.revision { found[col.slug] = info }
            }
            let f = found
            await MainActor.run { self.colLatest = f }
        }
    }

    /// Update a collection to its newest revision: same profile, optional mods chosen before stay chosen.
    func updateCollection(_ col: InstalledCollection) {
        guard let latest = colLatest[col.slug] else { return }
        let had = Set(col.modIDs.compactMap { kit.mod($0)?.nexus?.modID })
        colInfo = latest; colItems = []; colStates = []
        colOptional = Set(latest.files.filter { $0.optional && had.contains($0.modID) }.map(\.fileID))
        colText = "https://www.nexusmods.com/games/skyrimspecialedition/collections/\(col.slug)"
        if col.profile == profile { kit.backupSaves(reason: "before updating \(col.name)"); autoSnapshot("Before updating \(col.name)") }
        installCollection()
        if colRunning { colLatest[col.slug] = nil }
    }

    func lookUpCollection(_ text: String? = nil) {
        guard let ref = CollectionRef(text ?? colText) else { message = localized("Paste a Skyrim Special Edition collection link from nexusmods.com."); return }
        if let t = text { colText = t }
        colInfo = nil; colItems = []; colStates = []; colOptional = []
        busy = localized("Looking up the collection…")
        let c = client()
        Task {
            do { colInfo = try await c.collection(ref); busy = nil; section = .collections }
            catch { busy = nil; message = "\(error)" }
        }
    }

    var gameVersionMismatch: Bool {
        guard let info = colInfo, !info.gameVersions.isEmpty else { return false }
        let ours = gameVersion()
        return !ours.isEmpty && !info.gameVersions.contains { $0.hasPrefix(ours) }
    }

    func installCollection() {
        guard let info = colInfo, !colRunning else { return }
        guard !gameRunning() else { message = localized("Quit Skyrim before installing a collection."); return }
        guard nexusKeyStored else { section = .downloads; message = localized("Add your Nexus Mods API key first."); return }
        let free = !(nexusUser?.premium ?? true)
        if free {
            // Nexus rule: free accounts start every download on the website. SkyrimMT opens each file's page in turn and
            // continues by itself when the link arrives (files already downloaded are reused without a click).
            if !isNxmHandler { becomeNxmHandler(); guard isNxmHandler else { message = localized("Free accounts need SkyrimMT to receive “Mod Manager Download” links."); return } }
            let a = NSAlert(); a.messageText = localizedFormat("Install %@ with a free Nexus account", info.name)
            a.informativeText = localizedFormat("Nexus asks free members to start each download on its website. SkyrimMT opens the page for each of the %ld mods in turn. Click “Slow download” there, and SkyrimMT downloads, installs and opens the next one. Files you already have are skipped. You can skip a mod or stop any time.", info.files.count)
            a.addButton(withTitle: localized("Start")); a.addButton(withTitle: localized("Cancel"))
            guard a.runModal() == .alertFirstButtonReturn else { return }
        }
        colCancelled = false
        Notify.prepare()
        colRunning = true
        busy = localized("Downloading the collection's details…")
        // installers see the version the collection is made for (it gets pinned to it), not Steam's current one
        let target = info.gameVersions.compactMap { g in self.versionsKnown.first { g.hasPrefix($0) } }.first
        let k = kit, c = client(), optional = colOptional
        let gv = (target != nil && !info.gameVersions.contains { $0.hasPrefix(self.gameVersion()) }) ? target! : gameVersion()
        Task.detached {
            do {
                let work = k.home.appendingPathComponent("cache/collection-\(info.slug)")
                try? FileManager.default.removeItem(at: work)
                try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
                let manifest = try await c.downloadBundle(info, into: work)
                let items = manifest.mods.filter { !$0.optional || ($0.fileID.map { optional.contains($0) } ?? false) }
                await MainActor.run { self.colItems = items; self.colStates = items.map { _ in .queued }; self.busy = localizedFormat("Installing %@…", info.name) }
                let prof = try await k.installCollection(info: info, manifest: manifest, items: items, client: c, gameVersion: gv, progress: { i, st in
                    Task { @MainActor in if i < self.colStates.count { self.colStates[i] = st } }
                }, nxmFor: free ? { item in await self.waitForNxm(item) } : nil)
                try? FileManager.default.removeItem(at: work)
                await MainActor.run {
                    self.colRunning = false; self.busy = nil
                    let failed = self.colStates.filter { if case .failed = $0 { return true }; return false }.count
                    let skipped = self.colStates.filter { if case .skipped = $0 { return true }; return false }.count
                    self.message = localizedFormat("Installed %@ into profile “%@” and deployed.", info.name, prof)
                        + (failed > 0 ? " " + localizedFormat("%ld failed.", failed) : "")
                        + (skipped > 0 ? " " + localizedFormat("%ld need manual steps.", skipped) : "")
                    Notify.send(localizedFormat("%@ is installed", info.name), failed > 0 ? localizedFormat("%ld mods failed — open SkyrimMT to repair.", failed) : localized("Ready to play."))
                    self.reload(); self.reloadCollections()
                    let rec = self.kit.installedCollections().first { $0.slug == info.slug }
                    if let failed = rec?.failed, !failed.isEmpty {
                        self.message = localizedFormat("Installed %@ — %ld mods failed: %@. Use Repair to retry.", info.name, failed.count, failed.prefix(5).joined(separator: ", ") + (failed.count > 5 ? "…" : ""))
                    }
                    // the version the collection really runs on: the SKSE it ships, else its metadata
                    let detected = rec?.gameVersion.flatMap { v in self.versionsKnown.first { v.hasPrefix($0) } ?? (v == self.versionSteam ? "steam" : nil) }
                    if let want = detected ?? info.gameVersions.compactMap({ g in self.versionsKnown.first { g.hasPrefix($0) } }).first,
                       want != "steam", want != self.kit.gameVersionKey {
                        if self.versionsInstalled.contains(want) { self.selectVersion(want) }
                        else { self.message = localizedFormat("%@ is made for Skyrim %@. Game tab → Skyrim version → Download %@, and SkyrimMT moves the collection there.", info.name, want, want) }
                    }
                }
            } catch {
                await MainActor.run { self.colRunning = false; self.busy = nil; self.message = localizedFormat("Collection: %@", "\(error)"); self.reload(); self.reloadCollections()
                    Notify.send(localized("Collection install stopped"), "\(error)") }
            }
        }
    }

    /// Free accounts: open the file's page and wait for its nxm link (handleNxm resumes us). nil = skipped / stopped.
    func waitForNxm(_ item: CollectionMod) async -> NxmLink? {
        guard !colCancelled, let mid = item.modID, let fid = item.fileID else { return nil }
        colWaiting = item
        busy = localizedFormat("Waiting for you: click “Slow download” for %@ on the page that opened", item.name)
        openFilePage(item)
        let link = await withCheckedContinuation { (c: CheckedContinuation<NxmLink?, Never>) in nxmWaiters["\(mid):\(fid)"] = c }
        colWaiting = nil
        if !colCancelled { busy = localized("Installing the collection…") }
        return link
    }

    func openFilePage(_ item: CollectionMod) {
        guard let mid = item.modID, let fid = item.fileID else { return }
        NSWorkspace.shared.open(URL(string: "https://www.nexusmods.com/\(nexusGame)/mods/\(mid)?tab=files&file_id=\(fid)&nmm=1")!)
    }

    func skipWaiting(stopAll: Bool) {
        if stopAll { colCancelled = true }
        let w = nxmWaiters; nxmWaiters = [:]
        for c in w.values { c.resume(returning: nil) }
    }

    func collectionDiffText(_ c: InstalledCollection, _ l: CollectionInfo) -> String {
        let d = kit.collectionDiff(slug: c.slug, latest: l)
        var t = "Revision \(d.fromRevision) → \(d.toRevision)"
        if !d.added.isEmpty { t += "\n\nNew: " + d.added.prefix(15).joined(separator: ", ") + (d.added.count > 15 ? "…" : "") }
        if !d.changed.isEmpty { t += "\n\nUpdated: " + d.changed.prefix(15).joined(separator: ", ") + (d.changed.count > 15 ? "…" : "") }
        if !d.removed.isEmpty { t += "\n\nRemoved: " + d.removed.prefix(15).joined(separator: ", ") + (d.removed.count > 15 ? "…" : "") }
        return t
    }

    func removeCollection(_ c: InstalledCollection) {
        guard !gameRunning() else { message = localized("Quit Skyrim first."); return }
        let a = NSAlert(); a.messageText = localizedFormat("Remove the collection “%@”?", c.name)
        a.informativeText = localizedFormat("Removes its profile and the mods only it uses, then switches back to “%@”.", c.previousProfile)
        a.addButton(withTitle: "Remove"); a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let k = kit
        busy = localizedFormat("Removing %@…", c.name)
        Task.detached {
            do { try k.removeCollection(slug: c.slug); await MainActor.run { self.busy = nil; self.message = localizedFormat("Removed %@.", c.name); self.reload(); self.reloadCollections() } }
            catch { await MainActor.run { self.busy = nil; self.message = "\(error)"; self.reload(); self.reloadCollections() } }
        }
    }

    // MARK: tools

    @Published var tools: [ToolEntry] = []
    @Published var toolRunning: String?
    @Published var detectedTools: [String: URL] = [:]

    func reloadTools() { tools = kit.tools() }

    func addTool(preset: ToolPreset? = nil) {
        var exe: URL? = preset.flatMap { kit.findTool($0.exe) }
        if exe == nil {
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [UTType(filenameExtension: "exe") ?? .data]
            panel.message = preset.map { localizedFormat("Find %@ (install the tool as a mod first, or pick it anywhere)", $0.exe) } ?? localized("Choose a Windows tool (.exe)")
            guard panel.runModal() == .OK else { return }
            exe = panel.url
        }
        guard let e = exe else { return }
        do { var t = kit.tools(); t.append(try kit.toolEntry(preset: preset, exe: e)); try kit.saveTools(t) } catch { message = "\(error)" }
        reloadTools()
    }

    func detectTools() {
        let k = kit
        Task.detached { let d = k.detectTools(toolPresets); await MainActor.run { self.detectedTools = d } }
    }

    func addDetectedTool(_ name: String, _ exe: URL) {
        guard let p = toolPresets.first(where: { $0.name == name }) else { return }
        do { var t = kit.tools(); t.append(try kit.toolEntry(preset: p, exe: exe)); try kit.saveTools(t) } catch { message = "\(error)" }
        reloadTools()
    }

    func removeTool(_ id: String) { var t = kit.tools(); t.removeAll { $0.id == id }; try? kit.saveTools(t); reloadTools() }

    /// Run a tool with the current deploy in place; afterwards its output is captured into the Overwrite mod.
    func runTool(_ t: ToolEntry) {
        guard !gameRunning() else { message = localized("Quit Skyrim before running tools."); return }
        guard toolRunning == nil else { return }
        if (try? kit.isDirty()) == true { message = localized("Deploy your changes first, so the tool sees your current mods."); return }
        let k = kit
        let snap: CaptureSnapshot, toolArgs: [String]
        do { (snap, toolArgs) = try k.beginToolRun(t) } catch { message = "\(error)"; return }
        toolRunning = t.name
        Session.ensureHelper()
        let args = [Paths.script("run-exe.sh"), "--wait", t.exe] + toolArgs
        Task.detached {
            let r = SessionRunner.runSync(args)
            let (captured, output) = (try? k.finishToolRunCounting(snap)) ?? ([], 0)
            await MainActor.run {
                self.toolRunning = nil
                self.message = r.status == 0 || !captured.isEmpty
                    ? (output > 0 ? localizedFormat("%@ closed. %ld file(s) in “%@” deployed.", t.name, output, t.outputMod ?? "")
                       : captured.isEmpty ? localizedFormat("%@ closed. No new files.", t.name) : localizedFormat("%@ closed. %ld file(s) captured into Overwrite.", t.name, captured.count))
                    : localizedFormat("%@: %@", t.name, r.output.trimmingCharacters(in: .whitespacesAndNewlines))
                self.reload()
            }
        }
    }

    // MARK: Nexus Mods

    var appVersion: String { (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "dev" }
    func client() -> NexusClient { NexusClient(apiKey: NexusKeychain.load(), appVersion: appVersion) }

    func refreshHandler() {
        nxmHandler = (LSCopyDefaultHandlerForURLScheme("nxm" as CFString)?.takeRetainedValue() as String?) ?? ""
    }
    var isNxmHandler: Bool { nxmHandler.lowercased() == (Bundle.main.bundleIdentifier ?? "").lowercased() }

    /// Asked, never silent (PLAN §8.7): another mod manager may own nxm links.
    func becomeNxmHandler() {
        let a = NSAlert(); a.messageText = localized("Open Nexus “Mod Manager Download” links with SkyrimMT?")
        a.informativeText = nxmHandler.isEmpty ? localized("No app handles these links yet.") : localizedFormat("They currently open in %@. You can switch back from that app.", nxmHandler)
        a.addButton(withTitle: localized("Use SkyrimMT")); a.addButton(withTitle: localized("Cancel"))
        guard a.runModal() == .alertFirstButtonReturn, let id = Bundle.main.bundleIdentifier else { return }
        LSSetDefaultHandlerForURLScheme("nxm" as CFString, id as CFString)
        refreshHandler()
        message = isNxmHandler ? localized("SkyrimMT now opens Nexus Mod Manager Download links.") : localized("macOS didn’t change the handler.")
    }

    func saveKey(_ key: String) {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !k.isEmpty else { return }
        busy = localized("Checking the API key…")
        let c = NexusClient(apiKey: k, appVersion: appVersion)
        Task {
            do {
                let u = try await c.validate()
                NexusKeychain.save(k)
                nexusUser = u; nexusKeyStored = true; busy = nil
                message = u.premium ? localizedFormat("Signed in to Nexus Mods as %@ (Premium).", u.name) : localizedFormat("Signed in to Nexus Mods as %@.", u.name)
            } catch { busy = nil; message = "\(error)" }
        }
    }

    func forgetKey() { NexusKeychain.delete(); nexusKeyStored = false; nexusUser = nil; message = localized("API key removed from the Keychain.") }

    func checkKey() {
        guard nexusKeyStored, nexusUser == nil else { return }
        Task { if let u = try? await client().validate() { nexusUser = u } }
    }

    /// nxm:// link from the website's "Mod Manager Download" button.
    func handleNxm(_ url: URL) {
        if url.absoluteString.contains("/collections/"), CollectionRef(url.absoluteString) != nil {
            section = .collections; lookUpCollection(url.absoluteString); return
        }
        guard let link = NxmLink(url.absoluteString) else { message = localizedFormat("Not a Nexus download link: %@", url.absoluteString); return }
        if let c = nxmWaiters.removeValue(forKey: "\(link.modID):\(link.fileID)") { c.resume(returning: link); return }   // a guided collection install waits for it
        guard nexusKeyStored else { section = .downloads; message = localized("Add your Nexus Mods API key (Downloads) to download from Nexus."); return }
        let d = NexusDownloader(client: client(), folder: kit.home.appendingPathComponent("downloads"))
        let job = beginDownload("Nexus mod \(link.modID), file \(link.fileID)")
        busy = localized("Downloading from Nexus Mods…")
        downloadTasks[job] = Task {
            do {
                let f = try await d.download(link) { got, total in
                    let pct = total.map { $0 > 0 ? " \(Int(Double(got) * 100 / Double($0))) %" : "" } ?? ""
                    Task { @MainActor in self.busy = localizedFormat("Downloading from Nexus Mods…%@", pct); self.downloadProgress(job, got, total) }
                }
                endDownload(job)
                if let i = downloadJobs.firstIndex(where: { $0.id == job }) { downloadJobs[i].name = f.deletingPathExtension().lastPathComponent }
                busy = nil; reload()
                let meta = (try? Data(contentsOf: URL(fileURLWithPath: f.path + ".meta.json"))).flatMap { try? JSONDecoder().decode(DownloadMeta.self, from: $0) }
                let title = meta.map { $0.version.isEmpty ? $0.modName : "\($0.modName) \($0.version)" } ?? f.lastPathComponent
                let a = NSAlert(); a.messageText = localizedFormat("Downloaded %@", title); a.informativeText = localized("Install it now?")
                a.addButton(withTitle: "Install"); a.addButton(withTitle: "Later")
                if a.runModal() == .alertFirstButtonReturn { install([f]) } else { message = localized("Saved in Downloads.") }
            } catch { endDownload(job, error: error); busy = nil; message = error is CancellationError ? "Download stopped." : "\(error)" }
        }
    }

    /// Nexus update check (ModKit/Updates.swift): file update chains, recently changed mods first. `quiet`: automatic
    /// check (once a day) — no status message unless something is found.
    func checkUpdates(quiet: Bool = false) {
        guard nexusKeyStored else { if !quiet { message = localized("Add your Nexus Mods API key to check for updates.") }; return }
        guard !updateChecking else { return }
        updateChecking = true
        if !quiet { busy = localized("Checking Nexus Mods for updates…") }
        let k = kit, c = client()
        Task.detached {
            let recent = Set(((try? await c.updated(period: "1m")) ?? [:]).keys)
            let ups = await k.findUpdates(recentlyChanged: recent) { try await c.filesWithUpdates($0) }
            await MainActor.run {
                UserDefaults.standard.set(Date(), forKey: "lastUpdateCheck")
                self.updateChecking = false
                if !quiet { self.busy = nil }
                self.updates = Dictionary(uniqueKeysWithValues: ups.map { ($0.modRecordID, $0) })
                let mine = self.updatableByHand.count
                if !ups.isEmpty { self.message = localizedFormat(ups.count == 1 ? "%ld mod update on Nexus" : "%ld mod updates on Nexus", ups.count) + (mine < ups.count ? localizedFormat(" (%ld pinned by a collection)", ups.count - mine) : "") + localized(". Filter “Update available”.") }
                else if !quiet { self.message = localized("All Nexus mods are up to date.") }
            }
        }
    }

    func autoCheckUpdates() {
        let last = UserDefaults.standard.object(forKey: "lastUpdateCheck") as? Date ?? .distantPast
        if Date().timeIntervalSince(last) > 86400 { checkUpdates(quiet: true) }
    }

    /// Update in place: download the newer file (Premium) and swap the mod's files, keeping its place, state and installer
    /// choices. Free accounts: open the file pages (the downloaded archive then installs as usual).
    /// Updates of mods not pinned by a collection (what "Update all" does).
    var updatableByHand: [String] { mods.filter { updates[$0.id] != nil && $0.collection.isEmpty }.map(\.id) }

    static func versionText(_ u: ModUpdate) -> String {
        u.newVersion.isEmpty || u.newVersion == u.currentVersion ? "newer file “\(u.newFileName)”" : "\(u.currentVersion.isEmpty ? "?" : u.currentVersion) → \(u.newVersion)"
    }

    func updateMods(_ ids: [String]) {
        let items = ids.compactMap { updates[$0] }
        guard !items.isEmpty else { return }
        let pinned = mods.filter { r in items.contains { $0.modRecordID == r.id } && !r.collection.isEmpty }
        if !pinned.isEmpty {
            let a = NSAlert()
            a.messageText = pinned.count == 1 ? localizedFormat("%@ comes from %@", pinned[0].name, pinned[0].collection) : localizedFormat("%ld of these mods come from a collection", pinned.count)
            a.informativeText = localized("Collections pin tested versions. A newer version may require a newer game or conflict with the collection’s patches. A snapshot is taken first.")
            a.addButton(withTitle: localized("Update anyway")); a.addButton(withTitle: localized("Cancel"))
            guard a.runModal() == .alertFirstButtonReturn else { return }
        }
        autoSnapshot(localizedFormat("Before updating %@", ModManagerModel.listNames(items.map(\.modName))), mods: items.map(\.modRecordID))
        guard nexusUser?.premium ?? false else {
            for u in items.prefix(5) { NSWorkspace.shared.open(URL(string: "https://www.nexusmods.com/skyrimspecialedition/mods/\(u.nexusModID)?tab=files")!) }
            message = localized("Free Nexus accounts download through the website. Click “Mod Manager Download” on the new file of each page that opened.")
            return
        }
        let k = kit, c = client(), folder = kit.home.appendingPathComponent("downloads"), gv = gameVersion()
        kit.backupSaves(reason: "before updating \(items.count) mod\(items.count == 1 ? "" : "s")")
        busy = items.count == 1 ? localizedFormat("Updating %ld mod…", items.count) : localizedFormat("Updating %ld mods…", items.count)
        Task.detached {
            var done = 0, failed: [String] = []
            for (i, u) in items.enumerated() {
                await MainActor.run { self.busy = localizedFormat("Updating %@ to %@ (%ld/%ld)…", u.modName, u.newVersion, i + 1, items.count) }
                do {
                    let job = await MainActor.run { self.beginDownload("\(u.modName) \(u.newVersion)") }
                    let a: URL
                    do {
                        a = try await NexusDownloader(client: c, folder: folder).downloadFile(modID: u.nexusModID, fileID: u.newFileID, fileName: u.newFileName,
                                                                                             md5: u.md5, size: u.size, modName: u.modName, version: u.newVersion) { got, total in
                            Task { @MainActor in self.downloadProgress(job, got, total) }
                        }
                        await MainActor.run { self.endDownload(job) }
                    } catch { await MainActor.run { self.endDownload(job, error: error) }; throw error }
                    // unpacking stays off the main thread, like install(); installers are shown afterwards, one by one
                    let p = try k.prepareUpdate(u.modRecordID, archive: a, gameVersion: gv)
                    if let f = p.fomod, !f.visibleSteps.isEmpty {
                        let w = WizardState(installer: f, work: p.work, layout: p.layout, root: a, name: u.modName)
                        w.archive = a; w.reinstallID = u.modRecordID; w.update = (u.newFileID, u.newVersion)
                        await MainActor.run { self.pendingWizards.append(w) }
                    } else {
                        defer { try? FileManager.default.removeItem(at: p.work) }
                        try k.finishUpdate(u.modRecordID, work: p.work, layout: p.layout, fomod: p.fomod, archive: a, nexusFileID: u.newFileID, version: u.newVersion)
                    }
                    done += 1
                } catch { failed.append("\(u.modName) (\(error))") }
            }
            let ok = done, bad = failed
            await MainActor.run {
                self.busy = nil
                self.updates = Dictionary(uniqueKeysWithValues: k.cachedUpdates().map { ($0.modRecordID, $0) })
                self.message = (ok > 0 ? (ok == 1 ? localizedFormat("Updated %ld mod. Deploy to use the new files. ", ok) : localizedFormat("Updated %ld mods. Deploy to use the new files. ", ok)) : "") + (bad.isEmpty ? "" : localized("Couldn’t update: ") + bad.joined(separator: "; "))
                self.reload(); self.reloadDownloads()
                if ok > 0 { self.checkHealth() }
                self.showNextWizard()
            }
        }
    }

    func copyModList() {
        let gv = kit.gameVersionKey == "steam" ? versionSteam : kit.gameVersionKey
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(kit.modListMarkdown(gameVersion: gv), forType: .string)
        message = localized("Mod list copied. Paste it into your post (Markdown).")
    }

    func reloadKit() { kit = ModKit.standard(home: URL(fileURLWithPath: Paths.game)); reload() }

    func reload() {
        let k = kit
        Task.detached {
            let p = (try? k.currentProfile()) ?? Profile(name: "Default")
            let plan = (try? k.plan(p)) ?? DeployPlan()
            await MainActor.run { self.lastPlan = plan }
            var wins: [String: Int] = [:], loses: [String: Int] = [:]
            for (w, losers) in plan.conflicts { for (l, n) in losers { wins[w, default: 0] += n; loses[l, default: 0] += n } }
            var counts: [String: Int] = [:], plugins: [String: Int] = [:]
            for (_, f) in plan.files {
                counts[f.modID, default: 0] += 1
                let l = f.rel.lowercased()
                if l.hasPrefix("data/"), l.dropFirst(5).firstIndex(of: "/") == nil, l.hasSuffix(".esp") || l.hasSuffix(".esm") || l.hasSuffix(".esl") { plugins[f.modID, default: 0] += 1 }
            }
            var fromCollection: [String: String] = [:]
            for c in k.installedCollections() { for id in c.modIDs { fromCollection[id] = c.name } }
            let rows0 = p.mods.enumerated().compactMap { (i, pm) -> ModRow? in
                guard let m = k.mod(pm.id) else { return nil }
                return ModRow(id: m.id, name: m.name, version: m.version, enabled: pm.enabled, wins: wins[m.id] ?? 0, loses: loses[m.id] ?? 0,
                              files: counts[m.id] ?? 0, separator: m.isSeparator, category: m.category ?? "", notes: m.notes,
                              installed: m.installedAt, plugins: plugins[m.id] ?? 0, nexusID: m.nexus?.modID,
                              collection: fromCollection[m.id] ?? "", priority: i, color: m.color ?? "")
            }
            // every installed mod is listed (MO2): those of other profiles unchecked at the end; generated output that
            // belongs to another profile (its Overwrite, Pandora/BodySlide output) stays with it
            let listed = Set(p.mods.map(\.id))
            let others = k.mods.filter { m in !listed.contains(m.id) && !m.isSeparator && !ModKit.isOverwrite(m.id) && !ModKit.isPandoraOutput(m.id) && !ModKit.isBodySlideOutput(m.id) }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                .enumerated().map { (j, m) in
                    ModRow(id: m.id, name: m.name, version: m.version, enabled: false, inProfile: false, files: 0, separator: false, category: m.category ?? "",
                           notes: m.notes, installed: m.installedAt, plugins: 0, nexusID: m.nexus?.modID, collection: fromCollection[m.id] ?? "",
                           priority: p.mods.count + j, color: m.color ?? "")
                }
            let rows = rows0 + others
            let lo = k.loadOrder()
            let issues = lo.validate()
            var byPlugin: [String: [String]] = [:]
            for i in issues where !i.plugin.isEmpty { byPlugin[i.plugin.lowercased(), default: []].append(i.detail) }
            func kind(_ n: String) -> String {
                guard let h = lo.headers[n.lowercased()] else { return "?" }
                if h.isLight { return h.isMaster ? "ESL" : "ESP-FE" }
                return h.isMaster ? "ESM" : "ESP"
            }
            var owner: [String: String] = [:]
            for (key, f) in plan.files where key.hasPrefix("data/") && key.dropFirst(5).firstIndex(of: "/") == nil { owner[String(key.dropFirst(5))] = f.modID }
            var dependents: [String: [String]] = [:]
            for e in lo.entries where e.active { for m in lo.headers[e.name.lowercased()]?.masters ?? [] { dependents[m.lowercased(), default: []].append(e.name) } }
            func enrich(_ r: PluginRow) -> PluginRow {
                var r = r
                let h = lo.headers[r.name.lowercased()]
                r.author = h?.author ?? ""; r.about = h?.description ?? ""
                r.ownerID = owner[r.name.lowercased()]; r.ownerName = r.ownerID.flatMap { k.mod($0)?.name } ?? ""
                r.requiredBy = dependents[r.name.lowercased()] ?? []
                return r
            }
            let prow = (lo.implicit.map { PluginRow(name: $0, active: true, kind: kind($0), masters: lo.headers[$0.lowercased()]?.masters ?? [], issues: [], implicit: true) }
                + lo.entries.map { PluginRow(name: $0.name, active: $0.active, kind: kind($0.name), masters: lo.headers[$0.name.lowercased()]?.masters ?? [],
                                             issues: byPlugin[$0.name.lowercased()] ?? [], implicit: false) }).map(enrich)
            let dirty = (try? k.isDirty(plan: plan)) ?? false
            let locks = Set(p.lockedPlugins ?? [])
            let rules = k.lootRules()
            let names = k.profileNames()
            let dl = ((try? FileManager.default.contentsOfDirectory(at: k.home.appendingPathComponent("downloads"), includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
                .filter { ["7z", "zip", "rar", "gz", "tgz", "tar"].contains($0.pathExtension.lowercased()) }
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            let ups = k.cachedUpdates()
            await MainActor.run {
                self.mods = rows; self.plugins = prow; self.dirty = dirty; self.lockedPlugins = locks; self.lootRules = rules
                self.fillCategoriesIfNeeded()
                self.loadNexusDetailsIfNeeded()
                self.updates = Dictionary(uniqueKeysWithValues: ups.map { ($0.modRecordID, $0) })
                self.profiles = names.isEmpty ? [p.name] : names; self.profile = p.name; self.downloads = dl
                self.downloadEntries = k.downloadEntries()
                self.refreshWabbajackCacheSize()
                self.refreshDetail()
            }
        }
    }

    /// Re-read everything from disk (files changed outside SkyrimMT, e.g. downloads deleted in Finder).
    func refreshAll() {
        lastRefresh = Date()
        reload(); reloadCollections(); reloadTools(); refreshPandora(); refreshBodySlide(); refreshVersions()
    }
    private var lastRefresh = Date.distantPast
    /// Coming back to the window: refresh, at most every few seconds.
    func refreshIfStale() { if Date().timeIntervalSince(lastRefresh) > 3 && busy == nil { refreshAll() } }

    // Downloads folder watcher: the list follows files added or removed outside SkyrimMT right away.
    private var downloadsWatch: DispatchSourceFileSystemObject?
    func watchDownloads() {
        downloadsWatch?.cancel(); downloadsWatch = nil
        let dir = kit.home.appendingPathComponent("downloads")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fd = open(dir.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .delete, .rename], queue: .main)
        src.setEventHandler { [weak self] in self?.reloadDownloads() }
        src.setCancelHandler { close(fd) }
        src.resume()
        downloadsWatch = src
    }
    func deleteDownloads(_ ids: Set<String>) {
        let items = downloadEntries.filter { ids.contains($0.id) }
        guard !items.isEmpty else { return }
        let size = ByteCountFormatter.string(fromByteCount: items.reduce(Int64(0)) { $0 + $1.size }, countStyle: .file)
        let a = NSAlert(); a.messageText = items.count == 1 ? localizedFormat("Delete archive “%@”?", items[0].url.lastPathComponent) : localizedFormat("Delete %ld archives (%@)?", items.count, size)
        a.informativeText = localized("Installed mods are not affected. Archives are only needed to reinstall or change installer options.")
        a.addButton(withTitle: localized("Delete")); a.addButton(withTitle: localized("Cancel")); a.buttons.first?.hasDestructiveAction = true
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let freed = kit.deleteDownloads(items.map(\.url))
        dlSelection = []
        let freedText = ByteCountFormatter.string(fromByteCount: freed, countStyle: .file)
        message = items.count == 1 ? localizedFormat("Deleted %ld archive; %@ freed.", items.count, freedText) : localizedFormat("Deleted %ld archives; %@ freed.", items.count, freedText)
        reloadDownloads()
    }

    func reloadDownloads() {
        let dir = kit.home.appendingPathComponent("downloads")
        let dl = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { ["7z", "zip", "rar", "gz", "tgz", "tar"].contains($0.pathExtension.lowercased()) }.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        if dl != downloads { downloads = dl }
        let k = kit
        Task.detached { let e = k.downloadEntries(); await MainActor.run { self.downloadEntries = e } }
    }

    func refreshDetail() {
        guard let id = selected, let plan = try? kit.plan() else { detail = ([:], [:]); return }
        let name = { (i: String) in self.kit.mod(i)?.name ?? i }
        var o: [String: Int] = [:], ob: [String: Int] = [:]
        for (l, n) in plan.conflicts[id] ?? [:] { o[name(l)] = n }
        for (w, losers) in plan.conflicts { if let n = losers[id] { ob[name(w)] = n } }
        detail = (o, ob)
    }

    // MARK: mods

    private func editProfile(_ name: String = "Change Mods", _ change: (inout Profile) -> Void) {
        undoable(name) {
            guard var p = try? kit.currentProfile() else { return }
            change(&p)
            do { try kit.saveProfile(p) } catch { message = "\(error)" }
        }
        reload()
    }

    func setEnabled(_ id: String, _ on: Bool) {
        if !on, guardPlaythroughs(kit.pluginsLost(disabling: [id]), action: localized("Turn Off")) == .cancelled { reload(); return }
        editProfile { p in
            if let i = p.mods.firstIndex(where: { $0.id == id }) { p.mods[i].enabled = on }
            else if on { ModManagerModel.addToProfile(&p, [id]) }
        }
    }

    /// Mods installed for other profiles join this one before its Overwrite (MO2: every mod is in every profile).
    static func addToProfile(_ p: inout Profile, _ ids: [String]) {
        let at = p.mods.firstIndex { ModKit.isOverwrite($0.id) } ?? p.mods.count
        p.mods.insert(contentsOf: ids.filter { id in !p.mods.contains { $0.id == id } }.map { ProfileMod(id: $0, enabled: true) }, at: at)
    }

    enum PlaythroughAnswer { case noRisk, accepted, cancelled }

    /// Before plugins go away: the playthroughs (newest save per character) that use them, and the choice to continue —
    /// with the saves backed up first.
    func guardPlaythroughs(_ lost: [String], action: String) -> PlaythroughAnswer {
        let risks = kit.playthroughRisks(plugins: lost)
        guard !risks.isEmpty else { return .noRisk }
        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = risks.count == 1 ? localizedFormat("%@’s save uses this mod", risks[0].save.player) : localizedFormat("%ld characters’ saves use this mod", risks.count)
        var lines = risks.prefix(4).map { r in
            localizedFormat("• %@, level %ld (saved %@): %@", r.save.player, r.save.level, r.save.saved.formatted(.relative(presentation: .named)), r.plugins.joined(separator: ", "))
        }
        if risks.count > 4 { lines.append(localizedFormat("and %ld more", risks.count - 4)) }
        a.informativeText = localized("Saves store a mod’s records, scripts and quest progress. Removing it mid-playthrough can cause missing items, broken quests or crashes on load.") + "\n\n"
            + lines.joined(separator: "\n") + "\n\n" + localized("Saves are backed up before continuing.")
        a.addButton(withTitle: localized("Cancel"))
        a.addButton(withTitle: localizedFormat("%@ Anyway", action))
        a.buttons[1].hasDestructiveAction = true
        guard a.runModal() == .alertSecondButtonReturn else { return .cancelled }
        _ = kit.backupSaves(reason: "before \(action.lowercased()): \(lost.joined(separator: ", "))")
        return .accepted
    }

    func moveMods(_ from: IndexSet, _ to: Int) {
        var rows = mods; rows.move(fromOffsets: from, toOffset: to); mods = rows
        editProfile { p in
            let order = rows.map(\.id)
            p.mods.sort { (order.firstIndex(of: $0.id) ?? 0) < (order.firstIndex(of: $1.id) ?? 0) }
        }
    }

    func remove(_ id: String) {
        guard let m = kit.mod(id) else { return }
        let risk = guardPlaythroughs(kit.pluginsLost(disabling: [id]), action: localized("Remove"))
        if risk == .cancelled { return }
        if risk == .noRisk {
            let a = NSAlert(); a.messageText = localizedFormat("Remove “%@”?", m.name); a.informativeText = localized("Its files are removed from SkyrimMT. Deploy to remove it from the game.")
            a.addButton(withTitle: localized("Remove")); a.addButton(withTitle: localized("Cancel"))
            guard a.runModal() == .alertFirstButtonReturn else { return }
        }
        autoSnapshot(localizedFormat("Before removing %@", m.name), mods: [id])
        do { try kit.removeMod(id); selectedIDs = [] } catch { message = "\(error)" }
        reload()
    }

    func createEmptyMod() {
        guard let name = ask(localized("Create empty mod"), localized("Mod name"), "") else { return }
        do {
            let m = try kit.createEmptyMod(name: name)
            selectedIDs = [m.id]; section = .mods
            message = localizedFormat("Created “%@”. Add files to its folder, then deploy.", m.name)
            NSWorkspace.shared.open(kit.stagingFolder(m))
        } catch { message = "\(error)" }
        reload()
    }

    func openFolder(_ id: String) { if let m = kit.mod(id) { NSWorkspace.shared.open(kit.stagingFolder(m)) } }

    // MARK: install

    func chooseArchives() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = ["7z", "zip", "rar", "gz", "tgz"].compactMap { UTType(filenameExtension: $0) }
        panel.message = localized("Choose mod archives (downloaded from Nexus Mods or elsewhere)")
        guard panel.runModal() == .OK else { return }
        install(panel.urls)
    }

    func install(_ urls: [URL]) {
        guard let url = urls.first else { return }
        let rest = Array(urls.dropFirst())
        let k = kit
        // a downloaded update of an installed mod (free accounts get updates through the website) → update in place
        if let meta = try? JSONDecoder.isoDates.decode(DownloadMeta.self, from: Data(contentsOf: url.appendingPathExtension("meta.json"))),
           let u = updates.values.first(where: { $0.nexusModID == meta.modID && $0.newFileID == meta.fileID }) {
            let gv = gameVersion()
            busy = localizedFormat("Updating %@ to %@…", u.modName, u.newVersion)
            Task.detached {
                do {
                    let p = try k.prepareUpdate(u.modRecordID, archive: url, gameVersion: gv)
                    if let f = p.fomod, !f.visibleSteps.isEmpty {
                        await MainActor.run {
                            self.busy = nil
                            let w = WizardState(installer: f, work: p.work, layout: p.layout, root: url, name: u.modName)
                            w.archive = url; w.reinstallID = u.modRecordID; w.update = (u.newFileID, u.newVersion); w.rest = rest
                            self.wizard = w
                        }
                        return
                    }
                    defer { try? FileManager.default.removeItem(at: p.work) }
                    try k.finishUpdate(u.modRecordID, work: p.work, layout: p.layout, fomod: p.fomod, archive: url, nexusFileID: u.newFileID, version: u.newVersion)
                    await MainActor.run { self.busy = nil; self.message = localizedFormat("Updated %@ to %@. Deploy to use the new files.", u.modName, u.newVersion); self.reload(); self.install(rest) }
                } catch {
                    await MainActor.run { self.busy = nil; self.message = localizedFormat("Couldn’t update %@: %@", u.modName, "\(error)"); self.reload(); self.install(rest) }
                }
            }
            return
        }
        busy = localizedFormat("Unpacking %@…", url.lastPathComponent)
        Task.detached {
            do {
                let (work, layout) = try k.beginInstall(archive: url)
                let meta = try? JSONDecoder.isoDates.decode(DownloadMeta.self, from: Data(contentsOf: url.appendingPathExtension("meta.json")))
                let name = meta?.modName ?? Self.modName(from: url)
                await MainActor.run { self.pendingMeta[url.path] = meta }
                if case .fomod(let root, let cfg) = layout {
                    let config = try FomodParser.load(cfg)
                    let ctx = await MainActor.run { k.fomodContext(gameVersion: self.gameVersion()) }
                    let inst = FomodInstaller(config: config, context: ctx)
                    if let s = inst.visibleSteps.first { inst.applyDefaults(step: s) }
                    await MainActor.run {
                        self.busy = nil
                        if inst.visibleSteps.isEmpty { self.finish(work: work, layout: layout, name: config.moduleName.isEmpty ? name : config.moduleName, fomod: inst, archive: url, then: rest) }
                        else {
                            let w = WizardState(installer: inst, work: work, layout: layout, root: root, name: config.moduleName.isEmpty ? name : config.moduleName)
                            w.archive = url; w.rest = rest; self.wizard = w
                        }
                    }
                    return
                }
                if case .unknown = layout {
                    let ok = await MainActor.run { () -> Bool in
                        let a = NSAlert(); a.messageText = localized("Unusual mod layout")
                        a.informativeText = localizedFormat("No plugins or game folders found in %@. Install its files into Data as they are?", url.lastPathComponent)
                        a.addButton(withTitle: localized("Install as is")); a.addButton(withTitle: localized("Cancel"))
                        return a.runModal() == .alertFirstButtonReturn
                    }
                    if !ok { try? FileManager.default.removeItem(at: work); await MainActor.run { self.busy = nil; self.install(rest) }; return }
                }
                await MainActor.run { self.finish(work: work, layout: layout, name: name, fomod: nil, archive: url, then: rest) }
            } catch {
                await MainActor.run { self.busy = nil; self.message = "\(url.lastPathComponent): \(error)"; self.install(rest) }
            }
        }
    }

    func finish(work: URL, layout: ModLayout, name: String, fomod: FomodInstaller?, archive: URL, then rest: [URL]) {
        let k = kit
        busy = localizedFormat("Installing %@…", name)
        Task.detached {
            do {
                let meta = await MainActor.run { self.pendingMeta.removeValue(forKey: archive.path) ?? nil }
                try k.finishInstall(work: work, layout: layout, name: name, version: meta?.version ?? "", fomod: fomod,
                                    source: SourceArchive(path: archive.path, md5: meta?.md5),
                                    nexus: meta.map { NexusRef(modID: $0.modID, fileID: $0.fileID) })
                await MainActor.run {
                    self.busy = nil; self.message = localizedFormat("Installed %@. Deploy to use it in the game.", name); self.reload(); self.install(rest)
                    if rest.isEmpty && self.recheckHealthAfterInstall { self.recheckHealthAfterInstall = false; self.checkHealth() }
                    if rest.isEmpty && self.deployAfterInstall { self.deployAfterInstall = false; self.deploy() }
                }
            } catch {
                await MainActor.run { self.busy = nil; self.message = "\(name): \(error)"; self.reload(); self.install(rest) }
            }
        }
    }

    nonisolated static func modName(from url: URL) -> String {
        // "SkyUI_5_2_SE-12604-5-2SE.7z" → "SkyUI 5 2 SE" (Nexus file names end in -<modid>-<version>-<timestamp>)
        var n = url.deletingPathExtension().lastPathComponent
        if let r = n.range(of: #"-\d+(-[\d-]+)*$"#, options: .regularExpression) { n.removeSubrange(r) }
        return n.replacingOccurrences(of: "_", with: " ").trimmingCharacters(in: .whitespaces)
    }

    /// MO2-style Reinstall: the installer runs again with the saved choices preselected; Finish replaces the files of
    /// the same mod entry (place, state, notes stay). Mods without an installer are simply unpacked again.
    func reinstall(_ id: String) {
        guard let m = kit.mod(id) else { return }
        guard let archive = kit.sourceArchive(of: id) else {
            message = localizedFormat("The archive %@ was installed from is gone. Download it again from its Nexus page, then choose Reinstall.", m.name); return
        }
        autoSnapshot(localizedFormat("Before reinstalling %@", m.name), mods: [id])
        let k = kit, gv = gameVersion()
        busy = localizedFormat("Unpacking %@…", m.name)
        Task.detached {
            do {
                let (work, layout) = try k.beginInstall(archive: archive)
                if case .fomod(let root, let cfg) = layout {
                    let inst = FomodInstaller(config: try FomodParser.load(cfg), context: await MainActor.run { k.fomodContext(gameVersion: gv) })
                    if let saved = m.installChoices { inst.replay(saved) }
                    if let s = inst.visibleSteps.first, inst.selections[s] == nil { inst.applyDefaults(step: s) }
                    await MainActor.run {
                        self.busy = nil
                        let w = WizardState(installer: inst, work: work, layout: layout, root: root, name: m.name)
                        w.archive = archive; w.reinstallID = id; self.wizard = w
                    }
                } else {
                    try k.reinstallMod(id, work: work, layout: layout, fomod: nil)
                    await MainActor.run { self.busy = nil; self.message = localizedFormat("Reinstalled %@. Deploy to use it.", m.name); self.reload() }
                }
            } catch { await MainActor.run { self.busy = nil; self.message = "\(m.name): \(error)" } }
        }
    }

    func cancelWizard() {
        let rest = wizard?.rest ?? []
        if let w = wizard { try? FileManager.default.removeItem(at: w.work) }
        wizard = nil
        install(rest)   // skipping one mod doesn't drop the rest of the queue
        showNextWizard()
    }

    /// Installers waiting their turn (a batch of updates): shown one at a time.
    func showNextWizard() {
        guard wizard == nil, !pendingWizards.isEmpty else { return }
        wizard = pendingWizards.removeFirst()
    }

    func finishWizard() {
        guard let w = wizard else { return }
        wizard = nil
        if let id = w.reinstallID, let up = w.update {
            let k = kit
            busy = localizedFormat("Updating %@…", w.name)
            Task.detached {
                let err: String? = { do { try k.finishUpdate(id, work: w.work, layout: w.layout, fomod: w.installer, archive: w.archive, nexusFileID: up.fileID, version: up.version); return nil } catch { return "\(error)" } }()
                try? FileManager.default.removeItem(at: w.work)
                await MainActor.run {
                    self.busy = nil
                    self.message = err.map { "\(w.name): \($0)" } ?? localizedFormat("Updated %@ to %@. Deploy to use the new files.", w.name, up.version)
                    self.reload(); self.install(w.rest); self.showNextWizard()
                }
            }
            return
        }
        if let id = w.reinstallID {
            let k = kit
            busy = localizedFormat("Reinstalling %@…", w.name)
            Task.detached {
                let err: String? = { do { try k.reinstallMod(id, work: w.work, layout: w.layout, fomod: w.installer); return nil } catch { return "\(error)" } }()
                await MainActor.run { self.busy = nil; self.message = err.map { "\(w.name): \($0)" } ?? localizedFormat("Reinstalled %@ with the new options. Deploy to use them.", w.name); self.reload() }
            }
            return
        }
        finish(work: w.work, layout: w.layout, name: w.name, fomod: w.installer, archive: w.archive, then: w.rest)   // the queue continues
    }

    // MARK: deploy

    func deploy() {
        guard !gameRunning() else { message = localized("Quit Skyrim before deploying."); return }
        let k = kit
        busy = localized("Deploying…")
        Task.detached {
            do {
                let r = try k.deploy()
                var m = localizedFormat("Deployed in %@ s.", String(format: "%.1f", r.seconds))
                if !r.keptModified.isEmpty { m += " " + localizedFormat("%ld file(s) changed outside SkyrimMT were left in place.", r.keptModified.count) }
                m += await self.runStaleGenerators(k) { t in await MainActor.run { self.busy = t } }
                let done = m
                await MainActor.run { self.busy = nil; self.message = done; self.reload(); self.refreshPandora(); self.refreshBodySlide() }
            } catch { await MainActor.run { self.busy = nil; self.message = localizedFormat("Deploy failed: %@", "\(error)"); self.reload() } }
        }
    }

    func purge() {
        guard !gameRunning() else { message = localized("Quit Skyrim first."); return }
        let a = NSAlert(); a.messageText = localized("Remove all mods from the game folder?")
        a.informativeText = localized("Restores the game folder to its unmodded state. Installed mods stay in SkyrimMT; Deploy adds them back.")
        a.addButton(withTitle: localized("Remove from game")); a.addButton(withTitle: localized("Cancel"))
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let k = kit
        busy = localized("Removing mods from the game…")
        Task.detached {
            do { let r = try k.purge(); await MainActor.run { self.busy = nil; self.message = localizedFormat("Removed %ld files, restored %ld.", r.removed, r.restored); self.reload() } }
            catch { await MainActor.run { self.busy = nil; self.message = localizedFormat("Purge failed: %@", "\(error)"); self.reload() } }
        }
    }

    // MARK: plugins

    private func writeLoadOrder(_ rows: [PluginRow], undo name: String = "Change Load Order") {
        undoable(name) { writeLoadOrderNow(rows) }
    }
    private func writeLoadOrderNow(_ rows: [PluginRow]) {
        var lo = kit.loadOrder()
        lo.entries = rows.filter { !$0.implicit }.map { LoadOrderEntry(name: $0.name, active: $0.active) }
        do {
            try lo.write(to: kit.pluginsTxt)
            var p = try kit.currentProfile(); p.loadOrder = lo.entries; try kit.saveProfile(p)
        } catch { message = "\(error)" }
        reload()
    }

    func setPluginActive(_ name: String, _ on: Bool) {
        if !on, guardPlaythroughs([name], action: localized("Turn Off")) == .cancelled { reload(); return }
        writeLoadOrder(plugins.map { $0.name == name ? PluginRow(name: $0.name, active: on, kind: $0.kind, masters: $0.masters, issues: [], implicit: $0.implicit) : $0 },
                       undo: on ? localizedFormat("Activate %@", name) : localizedFormat("Deactivate %@", name))
    }

    func movePlugins(_ from: IndexSet, _ to: Int) {
        let fixed = plugins.filter(\.implicit).count
        guard from.allSatisfy({ $0 >= fixed }), to >= fixed else { message = localized("Bethesda’s own plugins always load first."); return }
        var rows = plugins; rows.move(fromOffsets: from, toOffset: to); plugins = rows
        writeLoadOrder(rows, undo: localized("Move Plugin"))
    }

    @Published var lootMessages: [String: [LootMessage]] = [:]
    @Published var lootGeneral: [LootMessage] = []
    var lootHelper: URL { URL(fileURLWithPath: Bundle.main.bundlePath + "/Contents/Helpers/skyrimmt-loot") }
    var hasLoot: Bool { FileManager.default.isExecutableFile(atPath: lootHelper.path) }

    /// LOOT's userlist (load-after rules, also editable on the Plugins page) in the default text editor.
    func openLootRules() {
        let u = kit.home.appendingPathComponent("config/modkit/loot-userlist.yaml")
        if !FileManager.default.fileExists(atPath: u.path) {
            try? FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? "# LOOT userlist (https://loot-api.readthedocs.io/en/latest/metadata/introduction.html)\nplugins: []\n".write(to: u, atomically: true, encoding: .utf8)
        }
        NSWorkspace.shared.open([u], withApplicationAt: URL(fileURLWithPath: "/System/Applications/TextEdit.app"), configuration: NSWorkspace.OpenConfiguration())
    }

    func lootSort() {
        guard !gameRunning() else { message = localized("Quit Skyrim first."); return }
        let k = kit, h = lootHelper, before = try? kit.currentProfile()
        autoSnapshot(localized("Before sorting with LOOT"))
        busy = localized("Sorting with LOOT…")
        Task.detached {
            do {
                let r = try k.lootSort(helper: h)
                await MainActor.run {
                    self.busy = nil; self.lootMessages = r.plugins.reduce(into: [:]) { $0[$1.key.lowercased()] = $1.value }
                    self.lootGeneral = r.general.filter { $0.type != "say" }
                    let warns = r.plugins.values.flatMap { $0 }.filter { $0.type != "say" }.count
                    self.message = localizedFormat("LOOT sorted %ld plugins (%ld moved)", r.sorted.count, r.moved) + (warns > 0 ? localizedFormat("; %ld warnings. Hover over the icons.", warns) : ".")
                    self.commitUndo(localized("Sort with LOOT"), before: before)
                    self.reload()
                }
            } catch {
                await MainActor.run {
                    self.busy = nil
                    let e = "\(error)"
                    // "sort: found a cycle: A --[Hardcoded]-> B --[User Load After]-> A"
                    if let r = e.range(of: "found a cycle: ") {
                        let chain = e[r.upperBound...].replacingOccurrences(of: #"--\[([^\]]+)\]->"#, with: "→", options: .regularExpression)
                        self.message = localizedFormat("LOOT can’t sort: the rules contradict each other (%@). Remove one of your “Load after” rules on the Plugins page.", "\(chain)")
                    } else { self.message = e }
                }
            }
        }
    }

    // MARK: Pandora (animation behaviours, native macOS build)

    @Published var pandoraInstalled = false
    @Published var pandoraStale = false
    @Published var pandoraLastRun: String?

    /// Prebuilt tools published with the release (config/release.conf).
    nonisolated static var toolPackages: [String: ToolPackage] { ModKit.toolPackages(conf: URL(fileURLWithPath: Paths.releaseConf)) }
    nonisolated static func toolAvailable(_ k: ModKit, _ folder: String) -> Bool {
        toolPackages[folder] != nil   // installed, or downloaded when first needed
    }
    /// Download a prebuilt tool the first time it's needed.
    nonisolated func ensureTool(_ k: ModKit, _ folder: String, status: (String) async -> Void) async throws {
        guard let p = ModManagerModel.toolPackages[folder], !k.toolInstalled(p) else { return }
        await status(localizedFormat("Downloading %@…", p.name))
        try k.installToolPackage(p)
    }

    func refreshPandora() {
        let k = kit
        Task.detached {
            let inst = k.pandoraInstalled || ModManagerModel.toolAvailable(k, "pandora"), stale = inst && k.pandoraNeedsRun()
            await MainActor.run { self.pandoraInstalled = inst; self.pandoraStale = stale }
        }
    }

    /// Pandora's own window on this profile's animation mods; the result becomes its Pandora Output when closed.
    func openPandora() {
        guard !gameRunning() else { message = localized("Quit Skyrim first."); return }
        let k = kit
        busy = localized("Pandora is open. Close its window when done.")
        Task.detached {
            do {
                try await self.ensureTool(k, "pandora") { t in await MainActor.run { self.busy = t } }
                await MainActor.run { self.busy = localized("Pandora is open. Close its window when done.") }
                let r = try k.runPandora(interactive: true)
                await MainActor.run {
                    self.busy = nil
                    self.message = r.files == 0 ? localized("Pandora closed. No changes.") : localizedFormat("Pandora output saved (%ld files).", r.files)
                    self.reload(); self.refreshPandora()
                }
            } catch { await MainActor.run { self.busy = nil; self.message = "\(error)"; self.reload(); self.refreshPandora() } }
        }
    }

    func runPandora(then: (() -> Void)? = nil) {
        guard !gameRunning() else { message = localized("Quit Skyrim first."); return }
        let k = kit
        busy = localized("Generating animations (Pandora)…")
        Task.detached {
            do {
                try await self.ensureTool(k, "pandora") { t in await MainActor.run { self.busy = t } }
                await MainActor.run { self.busy = localized("Generating animations (Pandora)…") }
                let r = try k.runPandora()
                await MainActor.run {
                    self.busy = nil
                    self.pandoraLastRun = r.files == 0 ? localized("No animation mods need Pandora.")
                        : localizedFormat("%ld files in %@ s", r.files, String(format: "%.1f", r.seconds)) + (r.errors.isEmpty ? "" : localizedFormat(" · %ld errors (logs/pandora-engine.log)", r.errors.count))
                    self.message = r.files == 0 ? localized("No animation mods need Pandora.") : localizedFormat("Animations generated (%ld files).", r.files)
                    self.reload(); self.refreshPandora(); then?()
                }
            } catch { await MainActor.run { self.busy = nil; self.message = "\(error)"; self.reload(); self.refreshPandora() } }
        }
    }

    /// Generated mods whose inputs changed (body/outfit projects → BodySlide, animation mods → Pandora) are rebuilt;
    /// returns a short summary for the status line.
    nonisolated func runStaleGenerators(_ k: ModKit, status: (String) async -> Void) async -> String {
        var m = ""
        let bodySlide = k.autoBodySlide, pandora = k.autoPandora   // the profile's "Run automatically"
        if bodySlide && !k.bodySlideInstalled && k.bodySlideNeedsRun() { do { try await ensureTool(k, "bodyslide", status: status) } catch { m += " \(error)" } }
        if pandora && !k.pandoraInstalled && k.pandoraNeedsRun() { do { try await ensureTool(k, "pandora", status: status) } catch { m += " \(error)" } }
        if bodySlide && k.bodySlideInstalled && k.bodySlideNeedsRun() {
            await status(localized("Building bodies and outfits (BodySlide)…"))
            do { let r = try k.runBodySlide(); m += r.files > 0 ? " " + localizedFormat("Bodies built (%ld outfits%@).", r.outfits, r.failed.isEmpty ? "" : localizedFormat(", %ld failed", r.failed.count)) : "" }
            catch { m += " \(error)" }
        }
        if pandora && k.pandoraInstalled && k.pandoraNeedsRun() {
            await status(localized("Generating animations (Pandora)…"))
            do { let p = try k.runPandora(); m += p.files > 0 ? " " + localized("Animations regenerated.") : "" }
            catch { m += " \(error)" }
        }
        return m
    }

    /// Before Play: rebuild generated mods whose inputs changed since their last run, then start the game.
    func prepareForPlay(status: @escaping (String) -> Void, _ play: @escaping () -> Void) {
        guard !gameRunning() else { play(); return }
        let k = kit
        Task.detached {
            let stale = (k.autoBodySlide && (k.bodySlideInstalled || ModManagerModel.toolAvailable(k, "bodyslide")) && k.bodySlideNeedsRun())
                || (k.autoPandora && (k.pandoraInstalled || ModManagerModel.toolAvailable(k, "pandora")) && k.pandoraNeedsRun())
            guard stale else { await MainActor.run { play() }; return }
            let m = await self.runStaleGenerators(k) { t in await MainActor.run { self.busy = t; status(t) } }
            await MainActor.run {
                self.busy = nil; if !m.isEmpty { self.message = m.trimmingCharacters(in: .whitespaces) }
                self.reload(); self.refreshPandora(); self.refreshBodySlide(); play()
            }
        }
    }

    // MARK: Wabbajack lists (native engine) and MO2 import

    @Published var wjGallery: [WabbajackGalleryEntry] = []
    @Published var wjSearch = ""
    @Published var wjShowNSFW = false
    @Published var wjRunning: String?          // list being installed
    @Published var wjStatus = ""
    @Published var wjFraction: Double?
    @Published var wjFailure: WabbajackFailure?
    @Published var wjInstalled2: [InstalledWabbajackList] = []     // lists SkyrimMT installed (updates)
    var wjPhase = ""                              // "Hashing downloads", "Installing files"… (engine section headers)
    @Published var wjLoading = false
    private var wjProcess: Process?

    var wjEngine: WabbajackEngine {
        WabbajackEngine(engine: kit.home.appendingPathComponent("tools/wabbajack/jackify-engine"),
                        wine: URL(fileURLWithPath: Paths.wine), shim: URL(fileURLWithPath: Paths.script("wabbajack-wine.sh")))
    }
    var wjInstalled: Bool { FileManager.default.isExecutableFile(atPath: wjEngine.engine.path) }

    func loadGallery(force: Bool = false) {
        wjInstalled2 = kit.installedWabbajackLists()
        if !force, let c = kit.cachedGallery(), wjGallery.isEmpty { wjGallery = c }
        let k = kit
        wjLoading = true
        Task {
            do { let g = try await k.loadWabbajackGallery(force: force); self.wjGallery = g }
            catch { self.message = localizedFormat("Wabbajack gallery: %@", "\(error)") }
            self.wjLoading = false
        }
    }

    func installWabbajack(_ entry: WabbajackGalleryEntry) { startWabbajack(title: entry.title, machine: entry.machineURL, file: nil,
                                                                             sizes: (entry.downloadSize, entry.installSize)) }

    func installWabbajackFile() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [UTType(filenameExtension: "wabbajack") ?? .data]; panel.allowsMultipleSelection = false
        panel.message = localized("Choose a .wabbajack file")
        guard panel.runModal() == .OK, let u = panel.url else { return }
        startWabbajack(title: u.deletingPathExtension().lastPathComponent, machine: nil, file: u, sizes: nil)
    }

    private func startWabbajack(title: String, machine: String?, file: URL?, sizes: (Int64, Int64)?, skipConfirm: Bool = false) {
        guard wjRunning == nil else { return }
        if !wjInstalled {
            guard ModManagerModel.toolPackages["wabbajack"] != nil else { message = WabbajackError.notInstalled.description; return }
            let k = kit
            busy = localized("Downloading the Wabbajack engine…")
            Task.detached {
                let err: String? = await { do { try await self.ensureTool(k, "wabbajack") { _ in }; return nil } catch { return "\(error)" } }()
                await MainActor.run {
                    self.busy = nil
                    if let err { self.message = err } else { self.startWabbajack(title: title, machine: machine, file: file, sizes: sizes, skipConfirm: skipConfirm) }
                }
            }
            return
        }
        guard nexusKeyStored else { section = .downloads; message = localized("Add your Nexus Mods API key first (Downloads)."); return }
        guard nexusUser?.premium ?? true else {
            message = localized("Wabbajack downloads Nexus files automatically only for Premium accounts (Nexus rule)."); return
        }
        let free = (try? kit.home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage).map { Int64($0) } ?? 0
        let fmt = { (b: Int64) in ByteCountFormatter.string(fromByteCount: b, countStyle: .file) }
        let a = NSAlert(); a.messageText = localizedFormat("Install “%@”?", title)
        a.informativeText = (sizes.map { localizedFormat("Downloads %@, installs %@. About %@ needed; %@ free.\n\n", fmt($0.0), fmt($0.1), fmt($0.0 + $0.1), fmt(free)) } ?? "")
            + localized("Wabbajack downloads every mod from Nexus with your Premium account, builds the list exactly as its author made it, and SkyrimMT then imports it as a new profile. You can keep playing while it runs; it never touches the game folder.")
        a.addButton(withTitle: localized("Install")); a.addButton(withTitle: localized("Cancel"))
        if let s = sizes, s.0 + s.1 > free { a.informativeText += "\n\n" + localized("⚠︎ Not enough free disk space.") }
        guard skipConfirm || a.runModal() == .alertFirstButtonReturn else { return }
        let k = kit, e = wjEngine, key = NexusKeychain.load(), steamV = versionSteam
        wjFailure = nil; wjPhase = ""
        Notify.prepare()
        wjRunning = title; wjStatus = localized("Getting the list…"); wjFraction = nil
        Task.detached {
            do {
                let listFile = try file ?? k.downloadWabbajackFile(e, machineURL: machine!)
                let info = try ModKit.wabbajackInfo(listFile)
                // the list's Skyrim version decides the game folder; the engine reads a vanilla view of it
                let target = try k.gameDirFor(listVersion: info.gameVersion, steamGameDir: ModKit.steamGameDir(k.home), steamVersion: steamV)
                let key2 = target.path.contains("/versions/") ? target.lastPathComponent : "steam"
                await MainActor.run { self.wjStatus = localizedFormat("Preparing the game files (Skyrim %@)…", info.gameVersion ?? steamV) }
                let vanilla = k.wabbajackDir.appendingPathComponent("vanilla-\(key2)")
                try k.kit(forVersionKey: key2).deployer.makeVanillaView(at: vanilla)
                let existing = k.installedWabbajackLists().first { $0.machineURL == (machine ?? "") && !(machine ?? "").isEmpty }
                if let ex = existing, ex.profile == k.currentProfileName { k.backupSaves(reason: "before updating \(title)") }
                let r = try k.installWabbajackList(e, source: listFile.path, info: info, gameDir: vanilla, nexusKey: key,
                                                   onStart: { p in Task { @MainActor in self.wjProcess = p } },
                                                   profileName: existing.flatMap { k.profile($0.profile) != nil ? $0.profile : nil }) { line, frac in
                    Task { @MainActor in
                        self.wjStatus = line; if let frac { self.wjFraction = frac }
                        if line.hasPrefix("===") { self.wjPhase = line.trimmingCharacters(in: CharacterSet(charactersIn: "= ")) }
                    }
                }
                k.recordWabbajackInstall(InstalledWabbajackList(machineURL: machine ?? "", title: title, version: info.version, profile: r.profile, installedAt: Date()))
                await MainActor.run {
                    self.wjRunning = nil; self.wjProcess = nil
                    self.wjInstalled2 = k.installedWabbajackLists()
                    self.message = localizedFormat("Installed “%@” as profile “%@” (%ld mods, %ld plugins). Switch to it in Profiles.", title, r.profile, r.mods, r.plugins)
                        + (r.missing.isEmpty ? "" : " " + localizedFormat("%ld mods were missing.", r.missing.count))
                    Notify.send(localizedFormat("%@ is installed", title), localizedFormat("%ld mods in profile “%@”. Switch to it in SkyrimMT to play.", r.mods, r.profile))
                    self.reload()
                }
            } catch {
                await MainActor.run {
                    let cancelled = "\(error)".contains("cancelled")
                    if !cancelled {
                        self.wjFailure = WabbajackFailure(title: title, machine: machine, file: file, sizes: sizes, error: "\(error)", step: self.wjPhase.isEmpty ? self.wjStatus : self.wjPhase,
                                                          log: k.home.appendingPathComponent("logs/wabbajack-\(ModKit.sanitize(title)).log"))
                    }
                    self.wjRunning = nil; self.wjProcess = nil
                    if !cancelled { Notify.send(localizedFormat("Installing %@ stopped", title), localized("Open SkyrimMT → Wabbajack for the reason and Retry.")) }
                    self.message = cancelled ? localizedFormat("Stopped installing %@. Downloads are kept; installation continues where it stopped.", title) : localizedFormat("Installing %@ stopped. See the Wabbajack page.", title)
                    self.reload()
                }
            }
        }
    }

    func refreshWabbajackCacheSize() {
        let k = kit
        Task.detached { let n = ModKit.folderSize(k.wabbajackDownloadsDir); await MainActor.run { self.wjCacheSize = n } }
    }

    func clearWabbajackCache() {
        let a = NSAlert(); a.messageText = localized("Delete Wabbajack’s download cache?")
        a.informativeText = localizedFormat("Installed lists keep working. Updating a list later downloads its files again (%@).", ByteCountFormatter.string(fromByteCount: wjCacheSize, countStyle: .file))
        a.addButton(withTitle: localized("Delete")); a.addButton(withTitle: localized("Cancel")); a.buttons.first?.hasDestructiveAction = true
        guard a.runModal() == .alertFirstButtonReturn else { return }
        do { let n = try kit.clearWabbajackDownloads(); message = localizedFormat("Freed %@.", ByteCountFormatter.string(fromByteCount: n, countStyle: .file)) } catch { message = "\(error)" }
        refreshWabbajackCacheSize()
    }

    func retryWabbajack() {
        guard let f = wjFailure else { return }
        startWabbajack(title: f.title, machine: f.machine, file: f.file, sizes: f.sizes, skipConfirm: true)
    }

    func cancelWabbajack() { wjProcess?.terminate() }

    /// Import a Mod Organizer 2 instance (folder with ModOrganizer.ini) as a new profile.
    func importMO2() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.message = localized("Choose a Mod Organizer 2 folder (the one with ModOrganizer.ini)")
        guard panel.runModal() == .OK, let u = panel.url else { return }
        do {
            let inst = try MO2Instance.open(u)
            guard let prof = inst.selectedProfile.flatMap({ inst.profiles.contains($0) ? $0 : nil }) ?? inst.profiles.first else { message = localized("That MO2 folder has no profiles."); return }
            let k = kit, name = u.lastPathComponent
            busy = localizedFormat("Importing %@ (%ld mods)…", name, inst.modlist(prof).count)
            Task.detached {
                do {
                    let vanilla = k.wabbajackDir.appendingPathComponent("vanilla-\(k.gameVersionKey)")
                    try k.deployer.makeVanillaView(at: vanilla)
                    let r = try k.importMO2(inst, profile: prof, as: name, vanillaGame: vanilla, gameVersion: nil) { i, n, mod in
                        Task { @MainActor in self.busy = localizedFormat("Importing %@ (%ld/%ld)…", mod, i + 1, n) }
                    }
                    await MainActor.run { self.busy = nil; self.message = localizedFormat("Imported “%@” as profile “%@”: %ld mods, %ld plugins.", name, r.profile, r.mods, r.plugins); self.reload() }
                } catch { await MainActor.run { self.busy = nil; self.message = "\(error)"; self.reload() } }
            }
        } catch { message = "\(error)" }
    }

    // MARK: BodySlide (bodies and outfits, native macOS build)

    @Published var bodySlideInstalled = false
    @Published var bodySlideStale = false
    @Published var bodySlideScan: BodySlideScan?
    @Published var bodySlideSettings = BodySlideSettings()
    @Published var bodySlideLastRun: String?

    func refreshBodySlide() {
        let k = kit
        Task.detached {
            let inst = k.bodySlideInstalled || ModManagerModel.toolAvailable(k, "bodyslide"), scan = try? k.bodySlideScan(), st = k.bodySlideSettings()
            let stale = inst && k.bodySlideNeedsRun()
            await MainActor.run { self.bodySlideInstalled = inst; self.bodySlideScan = scan; self.bodySlideSettings = st; self.bodySlideStale = stale }
        }
    }

    func setBodySlide(_ s: BodySlideSettings) {
        do { try kit.setBodySlideSettings(s) } catch { message = "\(error)" }
        refreshBodySlide()
    }

    func runBodySlide() {
        guard !gameRunning() else { message = localized("Quit Skyrim first."); return }
        let k = kit
        busy = localized("Building bodies and outfits (BodySlide)…")
        Task.detached {
            do {
                try await self.ensureTool(k, "bodyslide") { t in await MainActor.run { self.busy = t } }
                await MainActor.run { self.busy = localized("Building bodies and outfits (BodySlide)…") }
                let r = try k.runBodySlide()
                await MainActor.run {
                    self.busy = nil
                    self.bodySlideLastRun = r.outfits == 0 ? localized("Nothing to build.") : localizedFormat("%ld outfits → %ld files in %@ s", r.outfits, r.files, String(format: "%.1f", r.seconds))
                        + (r.failed.isEmpty ? "" : localizedFormat(" · %ld failed (logs/bodyslide.log)", r.failed.count))
                    self.message = r.outfits == 0 ? localized("BodySlide: nothing to build for this profile.") : localizedFormat("Bodies and outfits built (%ld).", r.outfits)
                    self.reload(); self.refreshBodySlide()
                }
            } catch { await MainActor.run { self.busy = nil; self.message = "\(error)"; self.reload(); self.refreshBodySlide() } }
        }
    }

    /// Open the native BodySlide window on this profile's projects (sliders/presets by hand); builds go to its output mod.
    func openBodySlide() {
        let k = kit
        if !k.bodySlideInstalled {
            busy = localized("Downloading BodySlide…")
            Task.detached {
                let err: String? = await { do { try await self.ensureTool(k, "bodyslide") { _ in }; return nil } catch { return "\(error)" } }()
                await MainActor.run { self.busy = nil; if let err { self.message = err } else { self.openBodySlide() } }
            }
            return
        }
        guard !gameRunning() else { message = localized("Quit Skyrim first."); return }
        busy = localized("Deploying, then opening BodySlide…")
        Task.detached {
            do {
                _ = try k.prepareBodySlideWindow()
                let p = Process(); p.executableURL = k.bodySlideDir.appendingPathComponent("BodySlide"); p.currentDirectoryURL = k.bodySlideDir
                try p.run()
                await MainActor.run { self.busy = nil; self.message = localized("BodySlide builds from its window go to the “Overwrite” mod. Deploy afterwards."); self.reload() }
            } catch { await MainActor.run { self.busy = nil; self.message = localizedFormat("Couldn’t open BodySlide: %@", "\(error)"); self.reload() } }
        }
    }

    func basicSort() {
        let before = try? kit.currentProfile()
        defer { commitUndo(localized("Sort Plugins"), before: before) }
        do {
            try kit.basicSortKeepingLocks()
            message = localized("Sorted: masters first, every plugin after its masters.")
        } catch { message = "\(error)" }
        reload()
    }

    // MARK: profiles

    func switchProfile(_ name: String) {
        guard name != profile else { return }
        guard !gameRunning() else { message = localized("Quit Skyrim before switching profiles."); return }
        // collection/list profiles keep their version even if never stored; "1.7.104" = Steam's install when it is that
        let want = ModKit.versionKey(kit.effectiveGameVersion(name), steamVersion: versionSteam, installed: versionsInstalled)
        if want != kit.gameVersionKey {
            // the profile is pinned to another Skyrim version: clear the old game folder, then switch inside the new one
            guard want == "steam" || versionsInstalled.contains(want) else { message = localizedFormat("Profile %@ needs Skyrim %@. Download it in the Game tab.", name, want); return }
            busy = localizedFormat("Switching to %@ (Skyrim %@)…", name, want)
            let old = kit
            Task.detached {
                do {
                    try old.purge()
                    _ = shell(["/bin/bash", Paths.script("versions.sh"), "select", want])
                    let k = ModKit.standard(home: URL(fileURLWithPath: Paths.game))
                    _ = try k.switchProfile(to: name)
                    await MainActor.run { self.kit = k; self.busy = nil; self.message = localizedFormat("Profile %@ active (Skyrim %@).", name, want); self.reload(); self.refreshVersions() }
                } catch { await MainActor.run { self.busy = nil; self.message = "\(error)"; self.reloadKit(); self.refreshVersions() } }
            }
            return
        }
        let k = kit
        busy = localizedFormat("Switching to %@…", name)
        Task.detached {
            let t0 = Date()
            do {
                _ = try k.switchProfile(to: name)
                let secs = Date().timeIntervalSince(t0)
                await MainActor.run { self.busy = nil; self.message = localizedFormat("Profile %@ active (%@ s).", name, String(format: "%.1f", secs)); self.reload() }
            }
            catch { await MainActor.run { self.busy = nil; self.message = "\(error)"; self.reload() } }
        }
    }

    /// Re-download the installed revision's collection.json and re-apply the author's load order (mods untouched).
    func restoreCollectionLoadOrder(_ c: InstalledCollection) {
        guard !gameRunning() else { message = localized("Quit Skyrim first."); return }
        guard nexusKeyStored else { section = .downloads; message = localized("Add your Nexus Mods API key first."); return }
        guard c.profile != profile || ModKit.versionKey(kit.effectiveGameVersion(c.profile), steamVersion: versionSteam, installed: versionsInstalled) == kit.gameVersionKey else {
            message = localizedFormat("Switch “%@” to Skyrim %@ first (Game tab).", c.profile, kit.effectiveGameVersion(c.profile)); return
        }
        let k = kit, client = client()
        busy = localizedFormat("Restoring the load order of %@…", c.name)
        Task.detached {
            do {
                guard let ref = CollectionRef("https://www.nexusmods.com/games/skyrimspecialedition/collections/\(c.slug)/revisions/\(c.revision)") else { throw ModKitError.invalid("bad collection") }
                let info = try await client.collection(ref)
                let work = k.home.appendingPathComponent("cache/collection-\(c.slug)-lo")
                try? FileManager.default.removeItem(at: work)
                try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
                let manifest = try await client.downloadBundle(info, into: work)
                try k.applyCollectionLoadOrder(slug: c.slug, manifest: manifest)
                try? FileManager.default.removeItem(at: work)
                let n = manifest.loadOrder.filter(\.active).count
                await MainActor.run { self.busy = nil; self.message = localizedFormat("Load order of “%@” restored from %@ rev %@ (%ld active plugins).", c.profile, c.name, c.revision, n); self.reload() }
            } catch { await MainActor.run { self.busy = nil; self.message = localizedFormat("Restore failed: %@", "\(error)"); self.reload() } }
        }
    }

    @Published var historyFor: String?

    /// "Skyrim 1.6.1170 · 412 of 430 mods · own game settings · from collection"
    func profileInfo(_ name: String) -> String {
        guard let p = kit.profile(name) else { return "" }
        let version = kit.effectiveGameVersion(name)
        var parts = [version == "steam"
                         ? (versionSteam.isEmpty ? localized("Skyrim (Steam)") : localizedFormat("Skyrim %@ (Steam)", versionSteam))
                         : localizedFormat("Skyrim %@", version),
                     localizedFormat("%ld of %ld mods", p.mods.filter(\.enabled).count, p.mods.count)]
        if kit.hasOwnINIs(name) { parts.append(localized("own game settings")) }
        if p.separateSaves { parts.append(localized("own saves")) }
        if let c = kit.installedCollections().first(where: { $0.profile == name }) { parts.append(localizedFormat("collection “%@”", c.name)) }
        if let d = kit.lastPlayed()[name] { parts.append(localizedFormat("played %@", d.formatted(.relative(presentation: .named)))) }
        if instantSwitching && kit.parkedProfiles().contains(name) { parts.append(localized("instant switch ready")) }
        return parts.joined(separator: " · ")
    }

    @Published var instantSwitching = false
    func refreshInstantSwitching() { instantSwitching = kit.instantSwitching }

    /// Off discards every parked Data folder (only clones and the backups they own: nothing of the player's).
    func setInstantSwitching(_ on: Bool) {
        let k = kit
        busy = on ? localized("Enabling instant switching…") : localized("Disabling instant switching…")
        Task.detached {
            do {
                try k.setInstantSwitching(on)
                await MainActor.run {
                    self.busy = nil; self.instantSwitching = on
                    self.message = on ? localized("Instant switching enabled.") : localized("Instant switching disabled.")
                }
            } catch { await MainActor.run { self.busy = nil; self.message = "\(error)"; self.refreshInstantSwitching() } }
        }
    }

    /// The current profile's "Run automatically" for Pandora / BodySlide (manual Generate/Build always work).
    func setAutoGenerate(pandora: Bool? = nil, bodySlide: Bool? = nil) {
        do { try kit.setAutoGenerate(profile, pandora: pandora, bodySlide: bodySlide); refreshPandora(); refreshBodySlide() }
        catch { message = "\(error)" }
    }

    func setSeparateSaves(_ name: String, _ on: Bool) {
        guard !(name == profile && gameRunning()) else { message = localized("Quit Skyrim first."); return }
        do {
            try kit.setSeparateSaves(name, on)
            message = on ? localizedFormat("“%@” now keeps its own saves (Saves/SkyrimMT/%@). Saves made before stay in the shared folder.", name, name)
                         : localizedFormat("“%@” uses the shared Saves folder again.", name)
            reload()
        } catch { message = "\(error)" }
    }

    func renameProfile(_ name: String) {
        let a = NSAlert(); a.messageText = localizedFormat("Rename “%@”", name)
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24)); field.stringValue = name
        a.accessoryView = field; a.addButton(withTitle: localized("Rename")); a.addButton(withTitle: localized("Cancel"))
        guard a.runModal() == .alertFirstButtonReturn, !field.stringValue.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        do { try kit.renameProfile(name, to: field.stringValue); message = localizedFormat("Renamed to “%@”.", ModKit.sanitize(field.stringValue)); reload(); reloadCollections() }
        catch { message = "\(error)" }
    }

    func restoreProfile(_ name: String, _ snap: ProfileSnapshot) {
        guard !(name == profile && gameRunning()) else { message = localized("Quit Skyrim first."); return }
        let k = kit
        busy = localizedFormat("Restoring “%@”…", name)
        Task.detached {
            do { try k.restoreProfile(name, from: snap); await MainActor.run { self.busy = nil; self.message = localizedFormat("“%@” restored to %@.", name, snap.date.formatted(date: .abbreviated, time: .shortened)); self.reload() } }
            catch { await MainActor.run { self.busy = nil; self.message = "\(error)"; self.reload() } }
        }
    }

    func exportProfile(_ name: String) {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "\(name).skyrimmt-profile.json"
        guard panel.runModal() == .OK, let u = panel.url else { return }
        do { try kit.exportProfile(name).write(to: u); message = localizedFormat("Exported “%@”.", name) } catch { message = "\(error)" }
    }

    func importProfile() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let u = panel.url else { return }
        do {
            let missing = try kit.importProfile(Data(contentsOf: u))
            message = missing.isEmpty ? localized("Profile imported.") : localizedFormat("Profile imported. %ld mods aren’t installed: %@%@", missing.count, missing.prefix(5).map(\.name).joined(separator: ", "), missing.count > 5 ? "…" : "")
            reload()
        } catch { message = "\(error)" }
    }

    func deleteProfile(_ name: String) {
        guard name != profile else { message = localizedFormat("Switch to another profile first. “%@” is active.", name); return }
        let only = kit.modsOnlyIn(name)
        let a = NSAlert(); a.messageText = localizedFormat("Delete profile “%@”?", name)
        a.informativeText = localized("Deletes its mod list, load order and generated output. Saves are not affected.")
            + (kit.installedCollections().contains { $0.profile == name } ? " " + localized("It came from a collection; the collection entry is removed too.") : "")
        let box = NSButton(checkboxWithTitle: only.count == 1 ? localizedFormat("Also uninstall the %ld mod only this profile uses", only.count) : localizedFormat("Also uninstall the %ld mods only this profile uses", only.count), target: nil, action: nil)
        box.state = .off
        if !only.isEmpty { a.accessoryView = box }
        a.addButton(withTitle: localized("Delete")); a.addButton(withTitle: localized("Cancel"))
        a.buttons.first?.hasDestructiveAction = true
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let removeMods = !only.isEmpty && box.state == .on
        do {
            try kit.deleteProfile(name, removeUnusedMods: removeMods)
            message = removeMods ? localizedFormat("Profile “%@” deleted with %ld mods.", name, only.count) : localizedFormat("Profile “%@” deleted.", name)
            reload(); reloadCollections()
        } catch { message = "\(error)" }
    }

    func newProfile(clone: Bool) {
        let a = NSAlert(); a.messageText = clone ? localizedFormat("Copy profile “%@”", profile) : localized("New empty profile")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24)); field.placeholderString = localized("Profile name")
        a.accessoryView = field; a.addButton(withTitle: localized("Create")); a.addButton(withTitle: localized("Cancel"))
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let name = ModKit.sanitize(field.stringValue)
        do { try kit.createProfile(name, cloneFrom: clone ? profile : nil); message = localizedFormat("Profile %@ created.", name); reload() }
        catch { message = "\(error)" }
    }
}

// MARK: - views

struct ModManagerView: View {
    @ObservedObject var model: ModManagerModel

    var body: some View {
        content.modifier(UndoManagerBridge(model: model))
            .sheet(item: $model.iniEditor) { st in IniEditorView(state: st, kit: model.kit) { model.iniEditor = nil } }
    }

    private var content: some View {
        // Plain sidebar + content instead of NavigationSplitView: with the selection living in the shared model, the
        // split view redrew its columns blank after some clicks (owner report). Buttons have no selection binding.
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(model.sidebarOrder) { s in
                    let on = (model.section ?? .mods) == s
                    Button { model.section = s } label: {
                        Label {
                            Text(localized(s.rawValue))
                        } icon: {
                            Image(systemName: s.icon)
                        }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(on ? Color.accentColor.opacity(0.25) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    // drag to reorder; the order is kept (and ⌘1–⌘9 follow it)
                    .onDrag { model.draggingSection = s; return NSItemProvider(object: s.rawValue as NSString) }
                    .onDrop(of: [.text], delegate: SidebarDrop(target: s, model: model))
                    .contextMenu {
                        Button("Move Up") { model.moveSidebar(s, by: -1) }.disabled(model.sidebarOrder.first == s)
                        Button("Move Down") { model.moveSidebar(s, by: 1) }.disabled(model.sidebarOrder.last == s)
                        Divider()
                        Button("Reset Order") { model.resetSidebarOrder() }
                    }
                }
                Spacer()
            }
            .padding(10)
            .frame(width: 180)
            .frame(maxHeight: .infinity)
            .background(.ultraThinMaterial)
            Divider()
            VStack(spacing: 0) {
                Group {
                switch model.section ?? .mods {
                case .essentials: essentialsView
                case .collections: collectionsView
                case .mods: modsView
                case .plugins: pluginsView
                case .downloads: downloadsView
                case .tools: toolsView
                case .wabbajack: wabbajackView
                case .health: HealthPage(model: model)
                case .crashes: CrashPage(model: model)
                case .saves: SavesPage(model: model)
                case .browse: BrowsePage(model: model)
                case .profiles: profilesView
                case .snapshots: SnapshotsPage(model: model)
                case .data: DataPage(model: model)
                case .performance: PerfPage(model: model)
                }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)   // pages fill the window (split views otherwise centre at their ideal height)
                footer
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .toolbar {
            ToolbarItemGroup {
                Picker("Profile", selection: Binding(get: { model.profile }, set: { model.switchProfile($0) })) {
                    ForEach(model.profiles, id: \.self) { Text($0).tag($0) }
                }
                .frame(width: 160)
                Button { model.refreshAll() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .keyboardShortcut("r").help("Re-read mods, plugins, downloads and tools from disk (⌘R)")
                    .disabled(model.busy != nil)
                Button { model.chooseArchives() } label: { Label("Install…", systemImage: "plus") }
                Button { model.deploy() } label: { Label("Deploy", systemImage: "arrow.down.to.line") }
                    .disabled(!model.dirty || model.busy != nil)
                Menu {
                    Button("Create empty mod…") { model.createEmptyMod() }
                    Button("Show mods folder in Finder") { NSWorkspace.shared.open(model.kit.modsDir) }
                    Divider()
                    Button("Check Nexus for updates") { model.checkUpdates() }
                    Button("Copy mod list (for asking for help)") { model.copyModList() }
                    Button("Remove all mods from the game…") { model.purge() }
                } label: { Label("More", systemImage: "ellipsis.circle") }
            }
        }
        .sheet(item: $model.filePicker) { _ in FilePickerView(model: model) }
        .sheet(item: Binding(get: { model.wizard.map { WizardBox(state: $0) } }, set: { if $0 == nil { model.cancelWizard() } })) { box in
            FomodWizardView(state: box.state, onCancel: { model.cancelWizard() }, onInstall: { model.finishWizard() })
        }
        .frame(minWidth: 1040, minHeight: 560)
        .onAppear { model.watchDownloads() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in model.refreshIfStale() }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            var urls: [URL] = []
            let group = DispatchGroup()
            for p in providers {
                group.enter()
                _ = p.loadObject(ofClass: URL.self) { u, _ in if let u { urls.append(u) }; group.leave() }
            }
            group.notify(queue: .main) { model.install(urls) }
            return true
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button { model.showActivity.toggle() } label: {
                Image(systemName: model.activity.contains { $0.failed && $0.ended.map { Date().timeIntervalSince($0) < 600 } ?? false } ? "exclamationmark.circle" : "clock.arrow.circlepath")
            }
            .buttonStyle(.plain).help("Activity: everything SkyrimMT did in this session").accessibilityLabel("Activity")
            .popover(isPresented: $model.showActivity, arrowEdge: .top) { ActivityView(model: model) }
            if let b = model.busy { ProgressView().controlSize(.small); Text(b) }
            else if let m = model.message { Text(m).lineLimit(2) }
            Spacer()
            if model.dirty { Label("Changes not deployed", systemImage: "circle.fill").foregroundStyle(.orange).font(.caption) }
        }
        .font(.callout).foregroundStyle(.secondary)
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(.bar)
    }

    private var modsView: some View { ModsPage(model: model) }

    private var pluginsView: some View { PluginsPage(model: model) }

    private var nexusBox: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Nexus Mods").font(.headline)
                Spacer()
                if let u = model.nexusUser { Text(u.premium ? localizedFormat("%@ · Premium", u.name) : u.name).foregroundStyle(.secondary) }
            }
            if model.nexusKeyStored {
                HStack {
                    Text("API key saved in your Keychain.").foregroundStyle(.secondary)
                    Spacer()
                    Button("Check for updates") { model.checkUpdates() }
                    Button("Remove key") { model.forgetKey() }
                }
            } else {
                HStack {
                    SecureField("Personal API key (nexusmods.com → Account → API Keys)", text: $model.keyDraft)
                    Button("Save") { model.saveKey(model.keyDraft); model.keyDraft = "" }
                    Button("Get key…") { NSWorkspace.shared.open(URL(string: "https://www.nexusmods.com/users/myaccount?tab=api")!) }
                }
                Text("Downloads use your Nexus account. Free accounts start each download with “Mod Manager Download” on the mod's Files page.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Text(model.isNxmHandler
                     ? localized("“Mod Manager Download” links open in SkyrimMT.")
                     : localizedFormat("“Mod Manager Download” links open in: %@", model.nxmHandler.isEmpty ? localized("nothing yet") : model.nxmHandler))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if !model.isNxmHandler { Button("Use SkyrimMT for these links…") { model.becomeNxmHandler() } }
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
        .padding(10)
        .onAppear { model.checkKey(); model.refreshHandler() }
    }

    private var downloadsView: some View {
        let all = model.downloadEntries
        let shown = all.filter { (!model.dlHideInstalled || $0.installedModID == nil) && ModManagerModel.matches($0.name + " " + $0.url.lastPathComponent, model.downloadSearch) }
        let installedBytes = all.filter { $0.installedModID != nil }.reduce(Int64(0)) { $0 + $1.size }
        let fmt = { (b: Int64) in ByteCountFormatter.string(fromByteCount: b, countStyle: .file) }
        return VStack(alignment: .leading, spacing: 0) {
            nexusBox
            DownloadQueueView(model: model)
            if model.wjCacheSize > 0 {
                HStack {
                    Image(systemName: "shippingbox.and.arrow.backward").foregroundStyle(.secondary)
                    Text(localizedFormat("Wabbajack download cache: %@ — kept so list updates only download what changed.", ByteCountFormatter.string(fromByteCount: model.wjCacheSize, countStyle: .file)))
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Delete…") { model.clearWabbajackCache() }.controlSize(.small).disabled(model.wjRunning != nil)
                }
                .padding(.horizontal, 12).padding(.vertical, 4)
            }
            HStack(spacing: 8) {
                SearchField(prompt: "Search downloads", text: $model.downloadSearch, count: shown.count, total: all.count)
                Toggle("Hide installed", isOn: $model.dlHideInstalled).toggleStyle(.checkbox)
                Button("Open folder") {
                    try? FileManager.default.createDirectory(at: model.kit.downloadsDir, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(model.kit.downloadsDir)
                }
            }.padding(.trailing, 10)
            List(selection: $model.dlSelection) {
                ForEach(shown) { d in
                    HStack(spacing: 8) {
                        Image(systemName: "doc.zipper").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(d.name + (d.version.isEmpty ? "" : "  \(d.version)")).lineLimit(1)
                            Text(d.url.lastPathComponent).font(.caption2).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        if d.installedModID != nil { Text("Installed").font(.caption.weight(.semibold)).foregroundStyle(.green) }
                        Text(fmt(d.size)).font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 70, alignment: .trailing)
                        Text(d.date == .distantPast ? "" : d.date.formatted(.dateTime.day().month(.abbreviated))).font(.caption).foregroundStyle(.secondary).frame(width: 52, alignment: .trailing)
                        Button(d.installedModID == nil ? "Install" : "Reinstall") { model.install([d.url]) }.controlSize(.small)
                    }
                    .tag(d.id)
                    .contextMenu {
                        Button("Install") { model.install([d.url]) }
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([d.url]) }
                        if let n = d.nexus?.modID { Button("Open on Nexus Mods") { model.openNexus(n) } }
                        Divider()
                        Button("Delete…") { model.deleteDownloads(model.dlSelection.contains(d.id) ? model.dlSelection : [d.id]) }
                    }
                }
            }
            .onDeleteCommand { model.deleteDownloads(model.dlSelection) }
            .overlay { if all.isEmpty { Text("No downloads. Nexus downloads appear here; archives can also be dropped on this window.").foregroundStyle(.secondary).padding() } }
            HStack {
                Text(localizedFormat("%ld archives · %@", all.count, fmt(all.reduce(Int64(0)) { $0 + $1.size }))).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if !model.dlSelection.isEmpty { Button(localizedFormat("Delete %ld selected…", model.dlSelection.count)) { model.deleteDownloads(model.dlSelection) } }
                Button(localizedFormat("Delete installed archives (%@)…", fmt(installedBytes))) { model.deleteDownloads(Set(all.filter { $0.installedModID != nil }.map(\.id))) }
                    .disabled(installedBytes == 0)
                    .help("Installed mods are not affected. The archive is only needed to reinstall.")
            }.padding(10)
        }
    }

    private var collectionsView: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("Collection link from nexusmods.com", text: $model.colText).textFieldStyle(.roundedBorder)
                    .onSubmit { model.lookUpCollection() }
                Button("Look up") { model.lookUpCollection() }.disabled(model.colRunning)
            }
            if let info = model.colInfo {
                VStack(alignment: .leading, spacing: 4) {
                    Text(info.name).font(.title3.bold())
                    let revisionSummary = localizedFormat("Revision %ld · %ld mods · %@", info.revision, info.files.count, ByteCountFormatter.string(fromByteCount: info.totalSize, countStyle: .file))
                    Text(info.gameVersions.isEmpty
                         ? revisionSummary
                         : revisionSummary + localizedFormat(" · for Skyrim %@", info.gameVersions.joined(separator: ", ")))
                        .foregroundStyle(.secondary)
                    if model.gameVersionMismatch {
                        Label(localizedFormat("Made for a different game version (yours: %@). Some SKSE plugins may not load.", model.gameVersion()), systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                    Text(localizedFormat("Installs into a new profile, “%@”. Other profiles are not changed.", ModKit.sanitize(info.name))).font(.caption).foregroundStyle(.secondary)
                }
                if let w = model.colWaiting {
                    HStack(spacing: 10) {
                        Image(systemName: "hand.point.up.left.fill").foregroundStyle(.blue)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(localizedFormat("Click “Slow download” for %@", w.name)).fontWeight(.medium)
                            let done = model.colStates.filter { if case .done = $0 { return true }; if case .reused = $0 { return true }; return false }.count
                            Text(localizedFormat("Nexus page opened in your browser · %ld of %ld mods ready", done, model.colItems.count)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Open page again") { model.openFilePage(w) }
                        Button("Skip") { model.skipWaiting(stopAll: false) }
                        Button("Stop") { model.skipWaiting(stopAll: true) }
                    }
                    .padding(10).background(Color.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                }
                List {
                    if !model.colItems.isEmpty {
                        ForEach(Array(model.colItems.enumerated()), id: \.offset) { i, item in
                            HStack {
                                Text(item.name)
                                Spacer()
                                stateView(i < model.colStates.count ? model.colStates[i] : .queued)
                            }
                        }
                    } else {
                        ForEach(info.files, id: \.fileID) { f in
                            HStack {
                                if f.optional {
                                    Toggle("", isOn: Binding(get: { model.colOptional.contains(f.fileID) },
                                                             set: { on in if on { model.colOptional.insert(f.fileID) } else { model.colOptional.remove(f.fileID) } }))
                                        .labelsHidden()
                                } else { Image(systemName: "checkmark").foregroundStyle(.secondary).frame(width: 20) }
                                VStack(alignment: .leading) {
                                    Text(f.modName); Text(f.fileName + (f.optional ? " · optional" : "")).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(ByteCountFormatter.string(fromByteCount: f.size, countStyle: .file)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                HStack {
                    Spacer()
                    Button(model.colRunning ? "Installing…" : "Install collection") { model.installCollection() }
                        .keyboardShortcut(.defaultAction).disabled(model.colRunning)
                }
            } else {
                Text("Paste a collection link, or use its download button on nexusmods.com. Premium accounts install automatically.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if !model.colInstalled.isEmpty {
                Divider()
                Text("Installed collections").font(.headline)
                ForEach(model.colInstalled, id: \.slug) { c in
                    HStack {
                        Text(c.name)
                        Text(c.gameVersion.map { localizedFormat("rev %ld · profile “%@” · Skyrim %@", c.revision, c.profile, $0) }
                             ?? localizedFormat("rev %ld · profile “%@”", c.revision, c.profile)).foregroundStyle(.secondary)
                        if let f = c.failed, !f.isEmpty { Label(localizedFormat("%ld failed", f.count), systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).help(f.joined(separator: "\n")) }
                        Spacer()
                        if let l = model.colLatest[c.slug] {
                            Label(localizedFormat("Revision %ld: %@", l.revision, model.kit.collectionDiff(slug: c.slug, latest: l).summary), systemImage: "arrow.up.circle.fill")
                                .foregroundStyle(.green).help(model.collectionDiffText(c, l))
                            Button("Update") { model.updateCollection(c) }.disabled(model.colRunning || model.busy != nil)
                                .help("Installs revision \(l.revision) into the same profile. Mods you added yourself are kept.")
                        }
                        Button("Restore load order") { model.restoreCollectionLoadOrder(c) }
                            .help("Restores the author's plugin order and active plugins. Mods are not changed.")
                        Button("Repair…") { model.lookUpCollection("https://www.nexusmods.com/games/skyrimspecialedition/collections/\(c.slug)") }
                            .help("Checks the collection again. Installed mods are reused; only missing ones are added.")
                            .disabled(model.colRunning)
                        Button("Remove…") { model.removeCollection(c) }.disabled(model.colRunning)
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { model.reloadCollections(); model.checkKey() }
    }

    @ViewBuilder private func stateView(_ s: CollectionItemState) -> some View {
        switch s {
        case .queued: Text("waiting").foregroundStyle(.secondary)
        case .downloading(let p): HStack(spacing: 6) { ProgressView(value: p ?? 0).frame(width: 80); Text("download").foregroundStyle(.secondary) }
        case .installing: HStack(spacing: 6) { ProgressView().controlSize(.small); Text("installing").foregroundStyle(.secondary) }
        case .done: Label("installed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .reused: Label("already installed", systemImage: "checkmark.circle").foregroundStyle(.green)
        case .skipped(let why): Label("manual", systemImage: "hand.raised").foregroundStyle(.orange).help(why)
        case .failed(let why): Label("failed", systemImage: "xmark.octagon.fill").foregroundStyle(.red).help(why)
        }
    }

    private var essentialsView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("The standard base for a modded game. Install all downloads and installs them. Free Nexus accounts confirm each download on the website.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !model.nexusKeyStored {
                HStack {
                    Image(systemName: "key").foregroundStyle(.orange)
                    SecureField("Nexus Mods personal API key", text: $model.keyDraft)
                    Button("Save") { model.saveKey(model.keyDraft); model.keyDraft = "" }
                    Button("Get key…") { NSWorkspace.shared.open(URL(string: "https://www.nexusmods.com/users/myaccount?tab=api")!) }
                }
            }
            let missing = model.missingEssentials.count
            HStack {
                Button(missing == 0 ? "All installed" : localizedFormat("Install all (%ld)", missing)) { model.installEssentials() }
                    .buttonStyle(.borderedProminent).disabled(missing == 0 || model.busy != nil || !model.nexusKeyStored)
                if model.busy != nil && !model.nxmWaiters.isEmpty { Button("Stop") { model.skipWaiting(stopAll: true) } }
                Spacer()
            }
            ForEach(essentials) { e in
                let ok = model.kit.isInstalled(e)
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: ok ? "checkmark.circle.fill" : "circle.dashed").font(.title3).foregroundStyle(ok ? .green : .secondary)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(e.name).fontWeight(.medium)
                        Text(e.why).font(.callout)
                        Text(e.note(for: model.gameVersion())).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(ok ? "Page" : "Get on Nexus") { NSWorkspace.shared.open(e.filesURL) }
                }
                .padding(10)
                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
            }
            Spacer()
        }
        .padding(14)
        .id(model.mods.count)   // re-evaluate after installs
    }

    private var toolsView: some View {
        VStack(alignment: .leading, spacing: 10) {
            GroupBox {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "list.number").font(.title2).frame(width: 28)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("LOOT (native)").font(.headline)
                        Text(model.hasLoot ? "Sorts the load order with the LOOT masterlist and your own rules. Messages appear on the Plugins page."
                                           : "Not included in this build.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        if !model.lootRules.isEmpty { Text(localizedFormat(model.lootRules.count == 1 ? "%ld custom rule" : "%ld custom rules", model.lootRules.count)).font(.caption).foregroundStyle(.secondary) }
                    }
                    Spacer()
                    if model.hasLoot {
                        VStack(alignment: .trailing, spacing: 6) {
                            Button("Sort now") { model.lootSort() }.disabled(model.busy != nil)
                            HStack {
                                Button("Plugins") { model.section = .plugins }
                                Button("Rules file") { model.openLootRules() }
                            }
                        }
                    }
                }
                .padding(4)
            }
            GroupBox {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "figure.run").font(.title2).frame(width: 28)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Pandora Behaviour Engine (native)").font(.headline)
                        Text(model.pandoraInstalled
                             ? "Builds animation behaviours for Nemesis, Pandora and FNIS mods. Patches whose mod isn't installed stay off."
                             : "Not installed in this build.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        if let r = model.pandoraLastRun { Text(localizedFormat("Last run: %@", r)).font(.caption).foregroundStyle(.secondary) }
                        if model.pandoraInstalled {
                            Toggle("Run automatically when animation mods change", isOn: Binding(get: { model.kit.autoPandora }, set: { model.setAutoGenerate(pandora: $0) }))
                                .toggleStyle(.checkbox).font(.caption)
                                .help("This profile only. Off for profiles installed from a collection, like Vortex.")
                        }
                    }
                    Spacer()
                    if model.pandoraInstalled {
                        if model.pandoraStale { Text("out of date").font(.caption).foregroundStyle(.orange) }
                        else { Text("up to date").font(.caption).foregroundStyle(.green) }
                        VStack(alignment: .trailing, spacing: 6) {
                            Button("Generate now") { model.runPandora() }.disabled(model.busy != nil)
                            Button("Open Pandora…") { model.openPandora() }.disabled(model.busy != nil)
                        }
                    }
                }
                .padding(4)
            }
            bodySlideBox
            Text("Windows tools run in Skyrim's Wine environment with your mods deployed. Their output is captured in the “Overwrite” mod; TexGen, DynDOLOD and xLODGen each get their own output mod (run TexGen first).")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            List(model.tools) { t in
                HStack {
                    Image(systemName: "wrench.and.screwdriver")
                    VStack(alignment: .leading) { Text(t.name); Text(t.exe).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
                    Spacer()
                    if model.toolRunning == t.name { ProgressView().controlSize(.small); Text("running…").foregroundStyle(.secondary) }
                    else { Button("Run") { model.runTool(t) }.disabled(model.toolRunning != nil) }
                }
                .contextMenu { Button("Remove") { model.removeTool(t.id) } }
            }
            .overlay { if model.tools.isEmpty && model.detectedTools.isEmpty { Text("No tools added. Install a tool such as SSEEdit like a mod, then add it here.").foregroundStyle(.secondary).padding() } }
            let fresh = model.detectedTools.filter { d in !model.tools.contains { $0.exe == d.value.path } }.sorted { $0.key < $1.key }
            if !fresh.isEmpty {
                HStack {
                    Text("Found in your mods:").font(.caption).foregroundStyle(.secondary)
                    ForEach(fresh, id: \.key) { name, url in
                        Button(localizedFormat("Add %@", name)) { model.addDetectedTool(name, url) }.controlSize(.small)
                    }
                    Spacer()
                }
            }
            HStack {
                Menu("Add known tool") {
                    ForEach(toolPresets, id: \.name) { p in Button(p.name) { model.addTool(preset: p) }.help(p.note) }
                }
                .frame(width: 180)
                Button("Add .exe…") { model.addTool() }
            }
        }
        .padding(14)
        .onAppear { model.reloadTools(); model.refreshPandora(); model.refreshBodySlide(); model.detectTools() }
    }

    private var bodySlideBox: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "figure.stand").font(.title2).frame(width: 28)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("BodySlide (native)").font(.headline)
                        Text(model.bodySlideInstalled
                             ? "Builds bodies and outfits for your body mod."
                             : "Not installed in this build.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        if let r = model.bodySlideLastRun { Text(localizedFormat("Last run: %@", r)).font(.caption).foregroundStyle(.secondary) }
                        if model.bodySlideInstalled {
                            Toggle("Run automatically when body or outfit mods change", isOn: Binding(get: { model.kit.autoBodySlide }, set: { model.setAutoGenerate(bodySlide: $0) }))
                                .toggleStyle(.checkbox).font(.caption)
                                .help("This profile only. Off for profiles installed from a collection, like Vortex.")
                        }
                    }
                    Spacer()
                    if model.bodySlideInstalled {
                        VStack(alignment: .trailing, spacing: 6) {
                            HStack(spacing: 8) {
                                if model.bodySlideStale { Text("out of date").font(.caption).foregroundStyle(.orange) }
                                else { Text("up to date").font(.caption).foregroundStyle(.green) }
                                Button("Build now") { model.runBodySlide() }.disabled(model.busy != nil)
                            }
                            Button("Open BodySlide…") { model.openBodySlide() }.disabled(model.busy != nil)
                        }
                    }
                }
                if model.bodySlideInstalled, let scan = model.bodySlideScan {
                    if scan.outfits.isEmpty {
                        Text("No BodySlide projects in this profile.").font(.caption).foregroundStyle(.secondary).padding(.leading, 38)
                    } else {
                        let st = model.bodySlideSettings
                        let family = st.family ?? scan.detectedFamily
                        HStack(spacing: 16) {
                            Picker("Body", selection: Binding(get: { st.family ?? "" }, set: { v in var n = st; n.family = v.isEmpty ? nil : v; model.setBodySlide(n) })) {
                                Text(scan.detectedFamily.map { localizedFormat("Automatic (%@)", BodySlide.familyNames[$0] ?? $0) } ?? localized("Automatic (none found)")).tag("")
                                ForEach(BodySlide.familyOrder.filter { scan.familyCounts[$0] != nil || scan.detectedFamily == $0 }, id: \.self) { f in
                                    Text(localizedFormat("%@ · %ld outfits", BodySlide.familyNames[f] ?? f, scan.familyCounts[f] ?? 0)).tag(f)
                                }
                            }
                            .frame(maxWidth: 330)
                            .help("Only one body can provide the body meshes. Automatic uses the installed body project.")
                            Picker("Preset", selection: Binding(get: { st.preset ?? "" }, set: { v in var n = st; n.preset = v.isEmpty ? nil : v; model.setBodySlide(n) })) {
                                Text("Slider defaults").tag("")
                                ForEach(scan.presets(for: family).map(\.name).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }, id: \.self) { Text($0).tag($0) }
                            }
                            .frame(maxWidth: 260)
                            Toggle("Morphs", isOn: Binding(get: { st.triMorphs ?? scan.hasRaceMenu }, set: { v in var n = st; n.triMorphs = v; model.setBodySlide(n) }))
                                .help("Builds .tri morph files for RaceMenu/OBody sliders. Automatic enables this when RaceMenu is installed.")
                        }
                        .font(.callout).padding(.leading, 38)
                    }
                }
            }
            .padding(4)
        }
    }

    private var wabbajackView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Installs Wabbajack modlists with the native Wabbajack engine and imports them as a profile. Requires Nexus Premium.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let running = model.wjRunning {
                GroupBox {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(localizedFormat("Installing %@…", running)).font(.headline)
                        if let f = model.wjFraction { ProgressView(value: f) } else { ProgressView().progressViewStyle(.linear) }
                        HStack {
                            Text(model.wjStatus).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Button("Cancel") { model.cancelWabbajack() }
                        }
                    }.padding(4)
                }
            }
            if let f = model.wjFailure, model.wjRunning == nil {
                GroupBox {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.title2)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(localizedFormat("Installing %@ stopped", f.title)).font(.headline)
                            Text(f.plainReason).font(.callout).fixedSize(horizontal: false, vertical: true)
                            Text("Your game and profiles are unchanged. Downloads are kept, and Retry resumes.")
                                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            Text(f.error).font(.caption2.monospaced()).foregroundStyle(.tertiary).lineLimit(2).textSelection(.enabled)
                        }
                        Spacer()
                        VStack(alignment: .trailing) {
                            Button("Retry") { model.retryWabbajack() }.keyboardShortcut(.defaultAction)
                            Button("Show log") { NSWorkspace.shared.open(f.log) }
                            Button("Dismiss") { model.wjFailure = nil }.buttonStyle(.plain).foregroundStyle(.secondary)
                        }
                    }.padding(4)
                }
            }
            HStack {
                SearchField(prompt: "Search Wabbajack lists", text: $model.wjSearch,
                            count: wjVisible.count, total: model.wjGallery.filter { model.wjShowNSFW || !$0.nsfw }.count)
                Toggle("NSFW", isOn: $model.wjShowNSFW).toggleStyle(.checkbox)
                Button { model.loadGallery(force: true) } label: { Image(systemName: "arrow.clockwise") }.help("Reload the gallery").accessibilityLabel("Reload the gallery").disabled(model.wjLoading)
            }
            List(wjVisible) { e in
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(e.title).fontWeight(.medium)
                            if e.nsfw { Text("NSFW").font(.caption2.bold()).foregroundStyle(.orange) }
                        }
                        Text(localizedFormat("%@ · %@ · %@ download, %@ installed · %ld archives", e.author, e.version, ByteCountFormatter.string(fromByteCount: e.downloadSize, countStyle: .file), ByteCountFormatter.string(fromByteCount: e.installSize, countStyle: .file), e.archives))
                            .font(.caption).foregroundStyle(.secondary)
                        if !e.description.isEmpty { Text(e.description).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                    }
                    Spacer()
                    if let r = e.readme, let u = URL(string: r) { Button("Readme") { NSWorkspace.shared.open(u) } }
                    if let i = model.wjInstalled2.first(where: { $0.machineURL == e.machineURL }) {
                        if i.version.compare(e.version, options: .numeric) == .orderedAscending {
                            Button(localizedFormat("Update to %@…", e.version)) { model.installWabbajack(e) }.disabled(model.wjRunning != nil).buttonStyle(.borderedProminent)
                                .help("Installed: \(i.version) (profile “\(i.profile)”). Existing downloads and your added mods are kept.")
                        } else {
                            Label("Installed", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.callout).help("Version \(i.version) · profile “\(i.profile)”")
                        }
                    } else {
                        Button("Install…") { model.installWabbajack(e) }.disabled(model.wjRunning != nil)
                    }
                }
                .padding(.vertical, 2)
            }
            .overlay { if model.wjGallery.isEmpty { Text(model.wjLoading ? "Loading the gallery…" : "No lists loaded.").foregroundStyle(.secondary) } }
            HStack {
                Button("Install from .wabbajack file…") { model.installWabbajackFile() }.disabled(model.wjRunning != nil)
                Button("Import Mod Organizer 2 folder…") { model.importMO2() }.disabled(model.busy != nil)
                    .help("Imports a Mod Organizer 2 setup (mods, order, plugins, INIs) as a profile.")
                Spacer()
                if !model.wjInstalled && ModManagerModel.toolPackages["wabbajack"] == nil { Text("Engine not available in this build.").font(.caption).foregroundStyle(.orange) }
            }
        }
        .padding(14)
        .onAppear { model.loadGallery() }
    }

    private var wjVisible: [WabbajackGalleryEntry] {
        model.wjGallery.filter { (model.wjShowNSFW || !$0.nsfw) && ModManagerModel.matches($0.title + " " + $0.author, model.wjSearch) }
    }

    private var profilesView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("A profile holds a mod list, load order, game version and optional game settings. Every change is kept in its history.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            List(model.profiles, id: \.self) { p in
                let info = model.profileInfo(p)
                HStack(spacing: 10) {
                    Image(systemName: p == model.profile ? "checkmark.circle.fill" : "circle").foregroundStyle(p == model.profile ? .green : .secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(p).fontWeight(p == model.profile ? .semibold : .regular)
                        Text(info).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if p == model.profile { Text("active").font(.caption).foregroundStyle(.secondary) }
                    else { Button("Switch") { model.switchProfile(p) }.disabled(model.busy != nil) }
                    Menu {
                        Button("Rename…") { model.renameProfile(p) }
                        Button("History…") { model.historyFor = p }
                        Button("Export…") { model.exportProfile(p) }
                        Button("Game settings (INI)…") { model.iniEditor = IniEditorState(profile: p) }
                        Toggle("Separate saves", isOn: Binding(get: { model.kit.profile(p)?.separateSaves ?? false }, set: { model.setSeparateSaves(p, $0) }))
                        Divider()
                        Button("Delete…", role: .destructive) { model.deleteProfile(p) }.disabled(p == model.profile)
                    } label: { Image(systemName: "ellipsis.circle") }.accessibilityLabel("Profile actions")
                    .menuStyle(.borderlessButton).frame(width: 34)
                }
                .padding(.vertical, 2)
                .contextMenu {
                    if p != model.profile { Button(localizedFormat("Switch to “%@”", p)) { model.switchProfile(p) } }
                    Button("Rename…") { model.renameProfile(p) }
                    Button("History…") { model.historyFor = p }
                    Button("Export…") { model.exportProfile(p) }
                    Divider()
                    Button(localizedFormat("Delete “%@”…", p)) { model.deleteProfile(p) }.disabled(p == model.profile)
                }
            }
            HStack(alignment: .firstTextBaseline) {
                Toggle("Instant switching", isOn: Binding(get: { model.instantSwitching }, set: { model.setInstantSwitching($0) }))
                    .toggleStyle(.switch).disabled(model.busy != nil)
                Text("Each profile keeps a prepared game folder (APFS clones, minimal disk use). Switching takes about a second after the first time.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .onAppear { model.refreshInstantSwitching() }
            HStack {
                Button("New empty profile…") { model.newProfile(clone: false) }
                Button("Copy current profile…") { model.newProfile(clone: true) }
                Button("Import profile…") { model.importProfile() }
                Spacer()
            }
        }
        .padding(14)
        .sheet(item: Binding(get: { model.historyFor.map { HistoryTarget(name: $0) } }, set: { model.historyFor = $0?.name })) { t in
            ProfileHistoryView(model: model, name: t.name)
        }
    }
}

struct HistoryTarget: Identifiable { let name: String; var id: String { name } }

/// Earlier versions of a profile; Restore puts one back (the current version stays in the history).
struct ProfileHistoryView: View {
    @ObservedObject var model: ModManagerModel
    let name: String
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        let snaps = model.kit.profileHistory(name)
        VStack(alignment: .leading, spacing: 10) {
            Text(localizedFormat("History of “%@”", name)).font(.title3.bold())
            Text("Every change is listed here. Restoring a version keeps the current one in the list.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            List(snaps) { s in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s.date.formatted(date: .abbreviated, time: .standard))
                        let status = localizedFormat("%ld of %ld mods enabled · %ld of %ld plugins active", s.enabledMods, s.mods, s.activePlugins, s.plugins)
                        Text(s.gameVersion.map { status + localizedFormat(" · Skyrim %@", $0) } ?? status)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Restore") { model.restoreProfile(name, s); dismiss() }.disabled(model.busy != nil)
                }
            }
            .overlay { if snaps.isEmpty { Text("No earlier versions yet.").foregroundStyle(.secondary) } }
            HStack { Spacer(); Button("Close") { dismiss() }.keyboardShortcut(.cancelAction) }
        }
        .padding(18).frame(width: 560, height: 460)
    }
}

/// Filter field above a long list: magnifier, clear button, "n of N" while filtering.
struct SearchField: View {
    let prompt: String
    @Binding var text: String
    let count: Int
    let total: Int
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(localized(prompt), text: $text).textFieldStyle(.plain)
            if !text.isEmpty {
                Text(localizedFormat("%ld of %ld", count, total)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.accessibilityLabel("Clear search")
                    .buttonStyle(.plain).help("Clear search")
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
        .padding(.horizontal, 10).padding(.vertical, 6)
    }
}

extension JSONDecoder { static var isoDates: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d } }

struct WizardBox: Identifiable { let state: WizardState; var id: ObjectIdentifier { ObjectIdentifier(state) } }

/// The FOMOD wizard: one page per visible install step, groups with radio buttons (one-of) or checkboxes.
struct FomodWizardView: View {
    @ObservedObject var state: WizardState
    let onCancel: () -> Void
    let onInstall: () -> Void

    var body: some View {
        let inst = state.installer
        let s = state.step
        let step = inst.config.steps[s]
        let flags = inst.flags(before: s)
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading) {
                    Text(state.name).font(.title3.bold())
                    Text(localizedFormat("%@ · step %ld of %ld", step.name, state.position + 1, state.steps.count)).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(16)
            Divider()
            HSplitView {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(Array(step.groups.enumerated()), id: \.offset) { gi, g in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(g.name).font(.headline)
                                Text(hint(g.type)).font(.caption).foregroundStyle(.secondary)
                                ForEach(Array(g.options.enumerated()), id: \.offset) { oi, o in
                                    let t = inst.type(of: o, flags: flags)
                                    let on = inst.selections[s]?[gi]?.contains(oi) ?? false
                                    Button {
                                        toggle(gi, oi, g.type, t)
                                    } label: {
                                        HStack(spacing: 8) {
                                            Image(systemName: radio(g.type) ? (on ? "largecircle.fill.circle" : "circle") : (on ? "checkmark.square.fill" : "square"))
                                            Text(o.name)
                                            if t == .recommended { Text("recommended").font(.caption).foregroundStyle(.green) }
                                            if t == .required { Text("required").font(.caption).foregroundStyle(.secondary) }
                                            if t == .notUsable { Text("not usable").font(.caption).foregroundStyle(.red) }
                                        }
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(t == .notUsable || t == .required || g.type == .all)
                                    .onHover { if $0 { state.focus = (gi, oi) } }
                                }
                                if let p = inst.problem(step: s, group: gi) { Text(p).font(.caption).foregroundStyle(.orange) }
                            }
                        }
                    }
                    .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minWidth: 340)
                description(step).frame(minWidth: 280, maxWidth: 420)
            }
            Divider()
            HStack {
                Button("Cancel", action: onCancel)
                Spacer()
                Button("Back") { state.position -= 1; state.focus = nil }.disabled(state.position == 0)
                if state.position + 1 < state.steps.count {
                    Button("Next") {
                        state.position += 1
                        if inst.selections[state.step] == nil { inst.applyDefaults(step: state.step) }
                        state.focus = nil; state.tick += 1
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(step.groups.indices.contains { inst.problem(step: s, group: $0) != nil })
                } else {
                    Button("Install", action: onInstall).keyboardShortcut(.defaultAction).disabled(!inst.problems().isEmpty)
                }
            }
            .padding(16)
        }
        .frame(width: 820, height: 560)
        .id(state.tick)
    }

    private func radio(_ t: FomodGroupType) -> Bool { t == .exactlyOne || t == .atMostOne }
    private func hint(_ t: FomodGroupType) -> String {
        switch t { case .exactlyOne: return "Choose one."; case .atMostOne: return "Choose one or none."
        case .atLeastOne: return "Choose at least one."; case .all: return "All of these are installed."; case .any: return "Choose any." }
    }
    private func toggle(_ gi: Int, _ oi: Int, _ type: FomodGroupType, _ t: FomodPluginType) {
        let s = state.step
        var sel = state.installer.selections[s]?[gi] ?? []
        if radio(type) { sel = sel.contains(oi) && type == .atMostOne ? [] : [oi] }
        else if sel.contains(oi) { sel.remove(oi) } else { sel.insert(oi) }
        if state.installer.selections[s] == nil { state.installer.selections[s] = [:] }
        state.installer.selections[s]?[gi] = sel
        state.focus = (gi, oi); state.tick += 1
    }

    @ViewBuilder private func description(_ step: FomodStep) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if let (gi, oi) = state.focus, gi < step.groups.count, oi < step.groups[gi].options.count {
                    let o = step.groups[gi].options[oi]
                    if let img = o.image, let u = CaseIndex(state.root).resolve(normalize(img)), let ns = NSImage(contentsOf: u) {
                        Image(nsImage: ns).resizable().aspectRatio(contentMode: .fit).frame(maxHeight: 240)
                    }
                    Text(o.name).font(.headline)
                    Text(o.description.isEmpty ? "No description." : o.description).font(.callout)
                } else {
                    Text("Hover an option to see its description.").foregroundStyle(.secondary)
                }
            }
            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A Wabbajack install that stopped: shown on the page with a plain reason, Retry and the log.
struct WabbajackFailure {
    let title: String, machine: String?, file: URL?, sizes: (Int64, Int64)?
    let error: String, step: String, log: URL
    var plainReason: String {
        let e = error.lowercased(), st = step.lowercased()
        if e.contains("api key") || e.contains("oauth") || e.contains("401") { return localized("Nexus Mods didn't accept your API key. Check it on the Downloads page, then Retry.") }
        if e.contains("premium") { return localized("Nexus only allows automatic downloads for Premium accounts.") }
        if e.contains("no space") || e.contains("disk full") || e.contains("not enough space") { return localized("The disk ran out of space. Free some space, then Retry.") }
        if e.contains("timed out") || e.contains("network") || e.contains("connection") { return localized("The connection dropped while downloading. Retry continues the downloads.") }
        if e.contains("hash") || e.contains("checksum") { return localized("A downloaded file didn't match what the list expects (it may have changed on Nexus). Retry downloads it again; if it keeps failing, the list needs an update from its author.") }
        if st.contains("download") { return localizedFormat("It stopped while downloading (%@).", String(step.prefix(60))) }
        if st.contains("hash") { return localized("It stopped while checking the downloaded files.") }
        if st.contains("install") || st.contains("extract") { return localized("It stopped while building the list.") }
        return localizedFormat("It stopped at: %@.", step.isEmpty ? localized("the start") : String(step.prefix(80)))
    }
}


// MARK: sidebar order (the player's own)

extension ModManagerModel {
    static let sidebarOrderKey = "sidebarOrder"
    /// Saved order; sections added in later versions join at the end.
    static func loadSidebarOrder() -> [ModsSection] {
        let saved = (UserDefaults.standard.stringArray(forKey: sidebarOrderKey) ?? []).compactMap(ModsSection.init(rawValue:))
        return saved + ModsSection.allCases.filter { !saved.contains($0) }
    }
    func saveSidebarOrder() { UserDefaults.standard.set(sidebarOrder.map(\.rawValue), forKey: ModManagerModel.sidebarOrderKey) }
    func moveSidebar(_ s: ModsSection, by d: Int) {
        guard let i = sidebarOrder.firstIndex(of: s) else { return }
        let j = max(0, min(sidebarOrder.count - 1, i + d))
        sidebarOrder.remove(at: i); sidebarOrder.insert(s, at: j); saveSidebarOrder()
    }
    func resetSidebarOrder() { sidebarOrder = ModsSection.allCases; UserDefaults.standard.removeObject(forKey: ModManagerModel.sidebarOrderKey) }
}

/// Live reorder while dragging a sidebar item over another.
struct SidebarDrop: DropDelegate {
    let target: ModsSection
    let model: ModManagerModel
    func dropEntered(info: DropInfo) {
        guard let from = model.draggingSection, from != target,
              let i = model.sidebarOrder.firstIndex(of: from), let j = model.sidebarOrder.firstIndex(of: target) else { return }
        withAnimation(.easeInOut(duration: 0.15)) {
            model.sidebarOrder.remove(at: i)
            model.sidebarOrder.insert(from, at: j)
        }
    }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func performDrop(info: DropInfo) -> Bool { model.draggingSection = nil; model.saveSidebarOrder(); return true }
}
