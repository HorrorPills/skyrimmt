// Mod Manager → Crashes: Crash Logger logs explained (ModKit/CrashLogs.swift) — what happened in one sentence, the
// mods most likely involved with the evidence, and one-click actions (disable, update, show in the list, Nexus page).
import SwiftUI
import AppKit

extension ModManagerModel {
    func loadCrashes() {
        let k = kit
        Task.detached {
            let logs = k.crashLogs()
            let first = logs.first.flatMap { k.analyzeCrash($0) }
            let trial = k.crashFixTrial(), outcome = k.evaluateCrashFix()
            await MainActor.run {
                self.crashFix = trial; self.crashFixOutcome = outcome
                self.crashLogs = logs
                if self.crashReport == nil || !logs.contains(where: { $0 == self.crashReport?.url }) { self.crashReport = first }
            }
        }
    }

    func selectCrash(_ url: URL) {
        let k = kit
        Task.detached {
            let r = k.analyzeCrash(url)
            await MainActor.run { self.crashReport = r }
        }
    }

    // MARK: one-click crash fix (ModKit/CrashFix.swift)

    private func crashFixStep(_ what: String, _ body: @escaping (ModKit) throws -> String?) {
        guard !gameRunning() else { message = localized("Quit Skyrim first."); return }
        let k = kit
        busy = what
        Task.detached {
            do {
                let note = try body(k)
                _ = try k.deploy()
                let trial = k.crashFixTrial(), outcome = k.evaluateCrashFix()
                await MainActor.run { self.busy = nil; self.crashFix = trial; self.crashFixOutcome = outcome; self.message = note; self.reload() }
            } catch { await MainActor.run { self.busy = nil; self.message = "\(error)"; self.reload(); self.loadCrashes() } }
        }
    }
    func modName(_ id: String) -> String { kit.mod(id)?.name ?? id }

    func startCrashFix(_ r: CrashReport) {
        crashFixStep(localized("Disabling the top suspect…")) { k in
            guard let id = try k.startCrashFix(r) else { return localized("No installed mod to test for this crash.") }
            return localizedFormat("%@ is disabled and saves are backed up. Play to where the crash happened, then quit.", k.mod(id)?.name ?? id)
        }
    }
    func nextCrashSuspect() {
        crashFixStep(localized("Testing the next suspect…")) { k in
            let before = k.crashFixTrial().map { $0.candidates[$0.index] }
            guard let id = try k.nextCrashFixSuspect() else { return localized("No suspect caused the crash. All are re-enabled. Use Copy for help to ask for support.") }
            return localizedFormat("%@ is re-enabled; %@ is disabled. Play again to test.", before.flatMap { k.mod($0)?.name } ?? localized("The last suspect"), k.mod(id)?.name ?? id)
        }
    }
    func keepOffAndContinueCrashFix() {
        crashFixStep(localized("Testing the next suspect…")) { k in
            guard let id = try k.keepOffAndContinueCrashFix() else { return localized("No suspects left. Mods you kept disabled stay disabled.") }
            return localizedFormat("%@ is also disabled. Play again to test.", k.mod(id)?.name ?? id)
        }
    }
    func endCrashFix(keepOff: Bool) {
        crashFixStep(localized(keepOff ? "Saving…" : "Reverting…")) { k in
            let cur = k.crashFixTrial().map { $0.candidates[$0.index] }
            try k.endCrashFix(keepOff: keepOff)
            return keepOff ? localizedFormat("%@ stays disabled. Check its Nexus page for an update.", cur.flatMap { k.mod($0)?.name } ?? localized("The mod")) : localized("Crash test ended. All changes were reverted.")
        }
    }

    /// For Health: the newest crash since the player last looked at the Crashes page.
    var unseenCrash: URL? {
        guard let u = crashLogs.first else { return nil }
        let seen = UserDefaults.standard.string(forKey: "lastSeenCrash") ?? ""
        return u.lastPathComponent > seen ? u : nil
    }
    func markCrashesSeen() { if let u = crashLogs.first { UserDefaults.standard.set(u.lastPathComponent, forKey: "lastSeenCrash") } }

    static func crashTitle(_ u: URL) -> String {
        // crash-2026-10-18-09-00-18.log → 18 Oct 2026, 09:00
        let p = u.deletingPathExtension().lastPathComponent.dropFirst("crash-".count).split(separator: "-").compactMap { Int($0) }
        guard p.count >= 5, let d = Calendar.current.date(from: DateComponents(year: p[0], month: p[1], day: p[2], hour: p[3], minute: p[4])) else { return u.lastPathComponent }
        return d.formatted(date: .abbreviated, time: .shortened)
    }
}

struct CrashPage: View {
    @ObservedObject var model: ModManagerModel
    var body: some View {
        HSplitView {
            List(selection: Binding(get: { model.crashReport?.url }, set: { if let u = $0 { model.selectCrash(u) } })) {
                ForEach(model.crashLogs, id: \.self) { u in
                    Text(ModManagerModel.crashTitle(u)).tag(u)
                }
            }
            .frame(minWidth: 170, idealWidth: 190, maxWidth: 240)
            .overlay {
                if model.crashLogs.isEmpty {
                    VStack(spacing: 6) {
                        Image(systemName: "checkmark.seal").font(.system(size: 30)).foregroundStyle(.green)
                        Text("No crashes recorded").foregroundStyle(.secondary)
                    }
                }
            }
            ScrollView { detail.padding(16).frame(maxWidth: .infinity, alignment: .leading) }
                .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { model.loadCrashes(); model.markCrashesSeen() }
    }

    /// The running crash test: what happened in the last session and the next click.
    @ViewBuilder private func crashFixCard(_ t: CrashFixTrial) -> some View {
        let cur = model.modName(t.candidates[t.index])
        let left = t.candidates.count - t.index - 1
        VStack(alignment: .leading, spacing: 8) {
            Label(localizedFormat("Crash test %ld of %ld", t.index + 1, t.candidates.count), systemImage: "stethoscope").font(.headline)
            switch model.crashFixOutcome {
            case .waiting:
                Text(localizedFormat("Testing without **%@**. Play to where the crash happened, then quit. The result is detected automatically.", cur))
                HStack { Spacer(); Button("Stop test") { model.endCrashFix(keepOff: false) } }
            case .sameCrash:
                Text(localizedFormat("Same crash without **%@**. It is not the cause.", cur))
                HStack {
                    Spacer()
                    Button("Stop test") { model.endCrashFix(keepOff: false) }
                    Button(left > 0 ? localizedFormat("Test next: %@", model.modName(t.candidates[t.index + 1])) : localized("Re-enable (no suspects left)")) { model.nextCrashSuspect() }
                        .keyboardShortcut(.defaultAction)
                }
            case .differentCrash(let u):
                Text(localizedFormat("Without **%@** the game crashed differently. The original crash may be fixed, or a new problem occurred first.", cur))
                HStack {
                    Button("View new crash") { model.selectCrash(u) }
                    Spacer()
                    Button("Re-enable") { model.endCrashFix(keepOff: false) }
                    if left > 0 { Button("Keep disabled, test next") { model.keepOffAndContinueCrashFix() } }
                    Button("Keep disabled") { model.endCrashFix(keepOff: true) }
                }
            case .noCrash(let m):
                Text(localizedFormat("No crash in %ld minutes without **%@**. It is most likely the cause.", m, cur))
                HStack {
                    Spacer()
                    Button("Re-enable") { model.endCrashFix(keepOff: false) }
                    Button("Keep disabled") { model.endCrashFix(keepOff: true) }.keyboardShortcut(.defaultAction)
                }
            case .tooShort(let m):
                Text(localizedFormat(m == 1 ? "%ld minute played without a crash. Play at least %ld minutes in total to confirm." : "%ld minutes played without a crash. Play at least %ld minutes in total to confirm.", m, CrashFix.minimumMinutes))
                HStack { Spacer(); Button("Stop test") { model.endCrashFix(keepOff: false) } }
            }
        }
        .padding(10).background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .disabled(model.busy != nil)
    }

    @ViewBuilder private var detail: some View {
        if let t = model.crashFix { crashFixCard(t) }
        if let r = model.crashReport {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(localizedFormat("Crash on %@", ModManagerModel.crashTitle(r.url))).font(.title3.bold())
                    Text(localizedFormat("Skyrim %@ · %@", r.gameVersion, r.exception.replacingOccurrences(of: "EXCEPTION_", with: "").replacingOccurrences(of: "_", with: " ").lowercased()))
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let p = r.profile, p != model.profile {
                    HStack {
                        Image(systemName: "person.2").foregroundStyle(.secondary)
                        Text(localizedFormat("This crash happened in profile “%@”.", p)).font(.callout)
                        Spacer()
                        Button("Switch to it") { model.switchProfile(p) }.disabled(model.busy != nil)
                    }.padding(8).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                }
                Text(r.summary).font(.body)
                ForEach(r.hints, id: \.self) { h in
                    Label { Text(h).fixedSize(horizontal: false, vertical: true) } icon: { Image(systemName: "lightbulb.fill").foregroundStyle(.yellow) }
                        .font(.callout).padding(8).background(Color.yellow.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
                }
                if model.crashFix == nil, r.profile == nil || r.profile == model.profile, let top = model.kit.crashFixCandidates(r).first {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "wand.and.stars").font(.title2).foregroundStyle(Color.accentColor)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Find the cause").font(.headline)
                            Text(localizedFormat("Turns off %@ for a test session. If the same crash returns, it is re-enabled and the next suspect is tested. Saves are backed up first.", model.modName(top)))
                                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        Button("Start") { model.startCrashFix(r) }.disabled(model.busy != nil)
                    }
                    .padding(10).background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                }
                Text(r.suspects.isEmpty ? "No mod stands out in this log." : "Most likely involved").font(.headline)
                ForEach(Array(r.suspects.prefix(6).enumerated()), id: \.element.id) { i, s in suspectRow(s, top: i == 0, best: r.suspects[0].score) }
                if !r.objects.isEmpty {
                    Text(localizedFormat("In use when it crashed: %@", r.objects.prefix(6).joined(separator: ", "))).font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button("Open log") { NSWorkspace.shared.open(r.url) }
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([r.url]) }
                    Button("Copy for help") {
                        let gv = model.kit.gameVersionKey == "steam" ? model.versionSteam : model.kit.gameVersionKey
                        var t = "**Crash on \(ModManagerModel.crashTitle(r.url))** — \(r.summary)\n"
                        if !r.cppException.isEmpty { t += "Exception: \(r.cppException)\n" }
                        t += "Call stack mods: \(r.stackModules.filter { !CrashLogParser.isSystem($0) }.joined(separator: ", "))\n"
                        t += "Most likely involved: \(r.suspects.prefix(3).map(\.modName).joined(separator: ", "))\n\n"
                        t += model.kit.modListMarkdown(gameVersion: gv)
                        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(t, forType: .string)
                        model.message = localized("Crash summary + mod list copied. Attach the log file itself too (Show in Finder).")
                    }.help("Crash summary and your mod list, ready to paste into a help request")
                    Spacer()
                }
                Text("Logs are written by Crash Logger (Essentials). Scores combine the crash location, mod code on the call stack and plugins that modified objects in use. Changes can be undone in Profiles → History.")
                    .font(.caption).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            }
        } else {
            Text(model.crashLogs.isEmpty ? "When the game crashes, Crash Logger (Essentials) writes a log and SkyrimMT explains it here." : "Select a crash.")
                .foregroundStyle(.secondary)
        }
    }

    private func suspectRow(_ s: CrashSuspect, top: Bool, best: Double) -> some View {
        let row = s.modID.flatMap { id in model.mods.first { $0.id == id } }
        return HStack(alignment: .top, spacing: 10) {
            Gauge(value: min(s.score / max(best, 1), 1)) { EmptyView() }.gaugeStyle(.accessoryCircularCapacity).scaleEffect(0.55).frame(width: 26, height: 26)
                .tint(top ? .red : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(s.modName).fontWeight(top ? .semibold : .regular)
                ForEach(s.evidence.prefix(3), id: \.self) { e in Text(e).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
            if let r = row {
                if model.updates[r.id] != nil { Button("Update") { model.updateMods([r.id]) }.disabled(model.busy != nil) }
                if r.enabled { Button("Disable") { model.setEnabled([r.id], false) }.disabled(model.busy != nil) }
                else { Text("disabled").font(.caption).foregroundStyle(.secondary) }
                Button { model.modSearch = ""; model.modFilter = .all; model.section = .mods; model.selectedIDs = [r.id]; model.refreshDetail() } label: { Image(systemName: "arrow.right.circle") }.accessibilityLabel("Show in the mod list")
                    .buttonStyle(.plain).help("Show in the mod list")
                if let n = r.nexusID { Button { model.openNexus(n) } label: { Image(systemName: "safari") }.accessibilityLabel("Open on Nexus Mods").buttonStyle(.plain).help("Open on Nexus Mods") }
            }
        }
        .padding(8).background(top ? Color.red.opacity(0.06) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
    }
}
