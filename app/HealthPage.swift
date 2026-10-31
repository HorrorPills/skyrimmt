// Mod Manager → Health: everything that is wrong with the current profile in one place, each with a one-click fix
// (docs/MODMANAGER.md §3H "Doctor"). v1: missing/disabled Nexus requirements (install all missing in one click),
// missing plugin masters, load-order problems, stale generated output (BodySlide/Pandora), undeployed changes.
import SwiftUI
import AppKit

struct HealthItem: Identifiable {
    enum Severity: Int { case problem = 0, warning = 1, info = 2 }
    let id: String
    let severity: Severity
    let title: String
    let detail: String
    let fix: String?
    let action: (() -> Void)?
}

extension ModManagerModel {
    func checkHealth() {
        let k = kit, c = client()
        healthChecking = true
        Task.detached {
            let reqs = (try? await k.checkRequirements { try await c.requirements(modID: $0) }) ?? []
            let masters = k.missingMasters()
            let loIssues = k.loadOrder().validate()
            let bsStale = k.autoBodySlide && k.bodySlideInstalled && k.bodySlideNeedsRun()   // off: the player chose not to
            let pdStale = k.autoPandora && k.pandoraInstalled && k.pandoraNeedsRun()
            let dirty = (try? k.isDirty()) ?? false
            let helper = await MainActor.run { self.lootHelper }
            let dirtyPlugins = ModManagerModel.dirtyPlugins(k, helper: helper)
            let stale = k.staleCleanedPlugins()
            let skse = k.deployedSKSEVersion()
            let needs = k.sksePrerequisites()
            let logs = k.crashLogs(), crash = logs.first.flatMap { k.analyzeCrash($0) }
            await MainActor.run {
                self.crashLogs = logs; if self.crashReport == nil { self.crashReport = crash }
                self.requirementIssues = reqs; self.masterIssues = masters; self.loadOrderIssueCount = loIssues.count
                self.healthStale = (bsStale, pdStale); self.dirty = dirty
                self.dirtyPlugins = dirtyPlugins; self.staleCleaned = stale; self.skseVersion = skse; self.skseNeeds = needs
                self.healthChecking = false; self.healthChecked = Date()
            }
        }
    }

    var healthItems: [HealthItem] {
        var out: [HealthItem] = []
        let missing = requirementIssues.filter { $0.state == .missing && !$0.requirement.conditional }
        for r in requirementIssues where !r.requirement.conditional {
            let by = r.requiredBy.prefix(3).joined(separator: ", ") + (r.requiredBy.count > 3 ? localizedFormat(" and %ld more", r.requiredBy.count - 3) : "")
            switch r.state {
            case .missing:
                out.append(HealthItem(id: r.id, severity: r.requirement.conditional ? .warning : .problem,
                                      title: localizedFormat("%@ is missing", r.requirement.name),
                                      detail: localizedFormat("Needed by %@.", by) + (r.requirement.notes.isEmpty ? "" : localizedFormat(" Author's note: “%@”", r.requirement.notes)),
                                      fix: localized("Install"), action: { self.installRequirements([r]) }))
            case .disabled(let id):
                out.append(HealthItem(id: r.id, severity: r.requirement.conditional ? .warning : .problem,
                                      title: localizedFormat("%@ is installed but disabled", r.requirement.name),
                                      detail: localizedFormat("Needed by %@.", by), fix: localized("Enable"), action: { self.setEnabled([id], true); self.checkHealth() }))
            }
        }
        if missing.count > 1 {
            out.insert(HealthItem(id: "all-missing", severity: .problem, title: localizedFormat("%ld required mods are missing", missing.count),
                                  detail: missing.map(\.requirement.name).prefix(6).joined(separator: ", ") + (missing.count > 6 ? "…" : ""),
                                  fix: localized("Install all"), action: { self.installRequirements(missing) }), at: 0)
        }
        for m in masterIssues {
            out.append(HealthItem(id: "master:" + m.master, severity: .problem, title: localizedFormat("%@ is missing", m.master),
                                  detail: localizedFormat("Plugins that need it: %@. The game crashes on start while they are active.", m.neededBy.prefix(3).joined(separator: ", ")),
                                  fix: localized("Search Nexus"), action: {
                                      let q = m.master.replacingOccurrences(of: ".esp", with: "").replacingOccurrences(of: ".esm", with: "").replacingOccurrences(of: ".esl", with: "")
                                      NSWorkspace.shared.open(URL(string: "https://www.nexusmods.com/skyrimspecialedition/search/?gsearch=\(q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? q)")!)
                                  }))
        }
        if loadOrderIssueCount > 0 {
            out.append(HealthItem(id: "lo", severity: .warning, title: localizedFormat(loadOrderIssueCount == 1 ? "%ld load-order problem" : "%ld load-order problems", loadOrderIssueCount),
                                  detail: localized("Plugins that load before their masters or need an inactive master."), fix: localized("Sort with LOOT"),
                                  action: { self.section = .plugins; self.lootSort() }))
        }
        if healthStale.bodySlide { out.append(HealthItem(id: "bs", severity: .warning, title: localized("Bodies and outfits need rebuilding"), detail: localized("Body or outfit mods changed since the last BodySlide build."), fix: localized("Build now"), action: { self.runBodySlide() })) }
        if healthStale.pandora { out.append(HealthItem(id: "pd", severity: .warning, title: localized("Animations need regenerating"), detail: localized("Animation mods changed since Pandora last ran."), fix: localized("Generate"), action: { self.runPandora() })) }
        for c in colInstalled { if let l = colLatest[c.slug] {
            out.append(HealthItem(id: "col:" + c.slug, severity: .info, title: localizedFormat("%@ has a new revision (%@)", c.name, l.revision),
                                  detail: localizedFormat("What changes: %@. Your own additions to its profile stay.", kit.collectionDiff(slug: c.slug, latest: l).summary),
                                  fix: localized("Update"), action: { self.section = .collections; self.updateCollection(c) }))
        } }
        for (i, g) in kit.wabbajackUpdates(gallery: wjGallery.isEmpty ? (kit.cachedGallery() ?? []) : wjGallery) {
            out.append(HealthItem(id: "wj:" + i.machineURL, severity: .info, title: localizedFormat("%@ %@ is out (you have %@)", i.title, g.version, i.version),
                                  detail: localizedFormat("Updating reuses everything already downloaded and keeps the mods you added to “%@”.", i.profile),
                                  fix: localized("Update"), action: { self.section = .wabbajack; self.installWabbajack(g) }))
        }
        let dups = kit.duplicateMods().filter { !$0.unused.isEmpty }
        if !dups.isEmpty {
            let n = dups.reduce(0) { $0 + $1.unused.count }
            out.append(HealthItem(id: "dups", severity: .info, title: localizedFormat(n == 1 ? "%ld unused duplicate mod" : "%ld unused duplicate mods", n),
                                  detail: dups.prefix(4).map(\.name).joined(separator: ", ") + (dups.count > 4 ? "…" : "") + localized(". Extra copies are not used by any profile."),
                                  fix: localized("Remove extra copies"), action: { self.run { k in for d in dups { for id in d.unused { try k.removeMod(id) } } }; self.checkHealth() }))
        }
        let shared = kit.duplicateMods().filter { $0.unused.isEmpty }
        if !shared.isEmpty {
            out.append(HealthItem(id: "dups-shared", severity: .info, title: localizedFormat(shared.count == 1 ? "%ld mod is installed in several profiles" : "%ld mods are installed in several profiles", shared.count),
                                  detail: shared.prefix(3).map(\.name).joined(separator: ", ") + (shared.count > 3 ? "…" : "") + localized(". Identical copies can be shared to save space."),
                                  fix: localized("Share identical copies"), action: { self.mergeDuplicates() }))
        }
        if let pre = skseNeeds, pre.pluginDLLs > 0 {
            if !pre.hasSKSE {
                out.append(HealthItem(id: "no-skse", severity: .problem, title: localizedFormat("%ld mods need the Script Extender (SKSE), which isn't installed", pre.pluginDLLs),
                                      detail: localized("These mods do not load without SKSE."),
                                      fix: localized("Show Essentials"), action: { self.section = .essentials }))
            } else if !pre.hasAddressLibrary {
                out.append(HealthItem(id: "no-addrlib", severity: .warning, title: localized("Address Library for SKSE Plugins is missing"),
                                      detail: localizedFormat("Most of the profile's %ld SKSE plugins require it.", pre.pluginDLLs),
                                      fix: localized("Show Essentials"), action: { self.section = .essentials }))
            }
        }
        // Steam updated the game but SKSE is for the old version: mods that need SKSE won't load
        if let skse = skseVersion, !skse.isEmpty {
            let game = kit.gameVersionKey == "steam" ? versionSteam : kit.gameVersionKey
            if !game.isEmpty, game != skse {
                let canPin = versionsKnown.contains(skse)
                out.append(HealthItem(id: "skse-mismatch", severity: .problem, title: localizedFormat("SKSE is for Skyrim %@, but the game is %@", skse, game),
                                      detail: kit.isGOG ? localizedFormat("SKSE mods will not load until SKSE matches. Install the GOG build of SKSE for %@.", game)
                                        : kit.gameVersionKey == "steam"
                                        ? localized("Steam updated Skyrim. SKSE mods will not load until SKSE matches. ") + (canPin ? localizedFormat("This profile can run on Skyrim %@ instead (a separate copy Steam does not update).", skse) : localizedFormat("Install SKSE for %@ when available.", game))
                                        : localizedFormat("Reinstall the SKSE build for %@.", game),
                                      fix: canPin ? localizedFormat("Use Skyrim %@", skse) : localized("SKSE on Nexus"),
                                      action: canPin ? { self.selectVersion(skse) } : { NSWorkspace.shared.open(URL(string: "https://www.nexusmods.com/skyrimspecialedition/mods/30379?tab=files")!) }))
            }
        }
        if let c = unseenCrash {
            out.append(HealthItem(id: "crash", severity: .warning, title: localizedFormat("The game crashed (%@)", ModManagerModel.crashTitle(c)),
                                  detail: crashReport?.url == c ? crashReport!.summary + (crashReport!.suspects.first.map { localizedFormat(" Most likely involved: %@.", $0.modName) } ?? "") : localized("Crash Logger wrote a log."),
                                  fix: localized("Explain"), action: { self.section = .crashes }))
        }
        let cleanable = dirtyPlugins.filter(\.value.autoCleanable).keys.sorted()
        if !cleanable.isEmpty {
            let itm = cleanable.reduce(0) { $0 + (dirtyPlugins[$1]?.itm ?? 0) }, udr = cleanable.reduce(0) { $0 + (dirtyPlugins[$1]?.udr ?? 0) }
            out.append(HealthItem(id: "clean", severity: .info, title: localizedFormat(cleanable.count == 1 ? "%ld plugin can be cleaned" : "%ld plugins can be cleaned", cleanable.count),
                                  detail: localizedFormat("%ld identical-to-master records and %ld deleted references in ", itm, udr) + cleanable.prefix(4).joined(separator: ", ")
                                    + (cleanable.count > 4 ? "…" : "") + localized(". Cleaned copies are stored separately; originals are not changed."),
                                  fix: localized("Clean"), action: { self.cleanPlugins(cleanable) }))
        }
        let staleLight = kit.staleLightFlagged()
        if !staleLight.isEmpty {
            out.append(HealthItem(id: "stale-light", severity: .warning, title: localizedFormat(staleLight.count == 1 ? "%ld light-flagged copy is out of date" : "%ld light-flagged copies are out of date", staleLight.count),
                                  detail: staleLight.joined(separator: ", ") + localized(" changed since they were flagged. The old copies would override the new versions."),
                                  fix: localized("Remove old copies"), action: { try? self.kit.removeLightFlagged(staleLight); self.reload(); self.checkHealth() }))
        }
        if !staleCleaned.isEmpty {
            out.append(HealthItem(id: "stale-clean", severity: .warning, title: localizedFormat(staleCleaned.count == 1 ? "%ld cleaned plugin is out of date" : "%ld cleaned plugins are out of date", staleCleaned.count),
                                  detail: staleCleaned.joined(separator: ", ") + localized(" changed since cleaning (a mod or game update). The old cleaned copy would hide the new version."),
                                  fix: localized("Remove old copies"), action: { self.removeStaleCleaned(self.staleCleaned) }))
        }
        if dirty { out.append(HealthItem(id: "deploy", severity: .info, title: localized("Changes not deployed yet"), detail: localized("The game still has the previous set of mods."), fix: localized("Deploy"), action: { self.deploy() })) }
        return out.sorted { $0.severity.rawValue < $1.severity.rawValue }
    }

    /// Optional requirements ("optional", "if you use…", "recommended"): offered, never counted as problems.
    var suggestionItems: [HealthItem] {
        requirementIssues.filter(\.requirement.conditional).map { r in
            let by = r.requiredBy.prefix(2).joined(separator: ", ")
            if case .disabled(let id) = r.state {
                return HealthItem(id: r.id, severity: .info, title: localizedFormat("%@ (installed, disabled)", r.requirement.name), detail: localizedFormat("Suggested by %@: “%@”", by, r.requirement.notes),
                                  fix: localized("Enable"), action: { self.setEnabled([id], true); self.checkHealth() })
            }
            return HealthItem(id: r.id, severity: .info, title: r.requirement.name, detail: localizedFormat("Suggested by %@: “%@”", by, r.requirement.notes),
                              fix: localized("Install"), action: { self.installRequirements([r]) })
        }
    }

    /// Download (Premium) and install the main file of each missing requirement; FOMOD wizards appear one by one.
    func installRequirements(_ items: [RequirementIssue]) {
        guard nexusKeyStored else { section = .downloads; message = localized("Add your Nexus Mods API key first (Downloads)."); return }
        guard nexusUser?.premium ?? false else {
            // free accounts: Nexus requires the website's download button for each file
            for r in items.prefix(5) { NSWorkspace.shared.open(URL(string: "https://www.nexusmods.com/skyrimspecialedition/mods/\(r.requirement.modID)?tab=files")!) }
            message = localized("Free Nexus accounts download through the website: click “Mod Manager Download” on each page that opened. SkyrimMT installs them.")
            return
        }
        let c = client(), folder = kit.home.appendingPathComponent("downloads")
        busy = localizedFormat(items.count == 1 ? "Getting %ld required mod…" : "Getting %ld required mods…", items.count)
        Task.detached {
            var archives: [URL] = [], failed: [String] = []
            for (i, r) in items.enumerated() {
                await MainActor.run { self.busy = localizedFormat("Downloading %@ (%ld/%ld)…", r.requirement.name, i + 1, items.count) }
                do {
                    guard let f = try await c.mainFile(modID: r.requirement.modID) else { failed.append(r.requirement.name); continue }
                    let job = await MainActor.run { self.beginDownload("\(r.requirement.name) \(f.version)") }
                    let a: URL
                    do {
                        a = try await NexusDownloader(client: c, folder: folder).downloadFile(modID: r.requirement.modID, fileID: f.fileID, fileName: f.fileName,
                                                                                             md5: f.md5, size: f.sizeBytes,
                                                                                             modName: r.requirement.name, version: f.version) { got, total in
                            Task { @MainActor in self.downloadProgress(job, got, total) }
                        }
                        await MainActor.run { self.endDownload(job) }
                    } catch { await MainActor.run { self.endDownload(job, error: error) }; throw error }
                    archives.append(a)
                } catch { failed.append(r.requirement.name) }
            }
            let got = archives, failedNames = failed
            await MainActor.run {
                self.busy = nil
                if !failedNames.isEmpty { self.message = localizedFormat("Couldn't get: %@.", failedNames.joined(separator: ", ")) }
                self.recheckHealthAfterInstall = true
                self.install(got)          // FOMOD wizards appear in turn; Health re-checks after the last one
                self.reloadDownloads()
            }
        }
    }
}

struct HealthPage: View {
    @ObservedObject var model: ModManagerModel
    var body: some View {
        let items = model.healthItems
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(items.isEmpty ? "Everything looks good" : localizedFormat(items.count == 1 ? "%ld thing to look at" : "%ld things to look at", items.count)).font(.title3.bold())
                    Text(model.healthChecking ? "Checking requirements on Nexus Mods…"
                         : model.healthChecked.map { localizedFormat("Checked %@ · profile “%@”", $0.formatted(date: .omitted, time: .shortened), model.profile) } ?? "Not checked yet")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if model.healthChecking { ProgressView().controlSize(.small) }
                Button("Check again") { model.checkHealth() }.disabled(model.healthChecking)
            }
            List {
                ForEach(items) { it in healthRow(it) }
                let sug = model.suggestionItems
                if !sug.isEmpty {
                    Section {
                        if model.showSuggestions { ForEach(sug) { it in healthRow(it) } }
                    } header: {
                        Button { model.showSuggestions.toggle() } label: {
                            Label(localizedFormat("Optional suggestions from mod authors (%ld)", sug.count), systemImage: model.showSuggestions ? "chevron.down" : "chevron.right")
                        }.buttonStyle(.plain)
                    }
                }
            }
            .overlay {
                if items.isEmpty && !model.healthChecking && !model.showSuggestions {
                    VStack(spacing: 6) {
                        Image(systemName: "checkmark.seal.fill").font(.system(size: 38)).foregroundStyle(.green)
                        Text("No missing requirements or masters. Load order and generated files are up to date.").foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(14)
        .onAppear { if model.healthChecked == nil { model.checkHealth() } }
    }

    private func healthRow(_ it: HealthItem) -> some View {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: it.severity == .problem ? "xmark.octagon.fill" : it.severity == .warning ? "exclamationmark.triangle.fill" : "info.circle.fill")
                        .foregroundStyle(it.severity == .problem ? .red : it.severity == .warning ? .orange : .blue).font(.title3)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(it.title).fontWeight(.medium)
                        Text(it.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    if let fix = it.fix, let a = it.action { Button(fix, action: a).disabled(model.busy != nil) }
                }
                .padding(.vertical, 3)
    }
}
