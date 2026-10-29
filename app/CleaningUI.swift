// Plugin cleaning in the Mod Manager (ModKit/Cleaning.swift): Health finds dirty plugins (LOOT's data for the exact
// file) and stale cleaned copies; one click cleans with xEdit Quick Auto Clean, unattended, into "Cleaned Plugins".
import SwiftUI
import AppKit

extension ModManagerModel {
    /// LOOT's dirty data without sorting (dry run, 0.3 s) — Health uses it.
    nonisolated static func dirtyPlugins(_ k: ModKit, helper: URL) -> [String: DirtyPlugin] {
        guard FileManager.default.isExecutableFile(atPath: helper.path), let r = try? k.lootSort(helper: helper, apply: false) else { return [:] }
        return r.dirty
    }

    func cleanPlugins(_ names: [String]) {
        guard !gameRunning() else { message = localized("Quit Skyrim before cleaning plugins."); return }
        guard busy == nil else { return }
        guard let xedit = kit.xeditForCleaning() else {
            let a = NSAlert(); a.messageText = localized("Cleaning needs SSEEdit")
            a.informativeText = localized("Cleaning uses SSEEdit. Install it from Nexus Mods like any other mod; SkyrimMT finds and runs it.")
            a.addButton(withTitle: localized("Open SSEEdit on Nexus")); a.addButton(withTitle: localized("Cancel"))
            if a.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(URL(string: "https://www.nexusmods.com/skyrimspecialedition/mods/164?tab=files")!) }
            return
        }
        if (try? kit.isDirty()) == true { message = localized("Deploy your changes first, so xEdit cleans the plugins the game will load."); return }
        let k = kit
        busy = localizedFormat(names.count == 1 ? "Cleaning %ld plugin with xEdit…" : "Cleaning %ld plugins with xEdit…", names.count)
        Session.ensureHelper()
        Task.detached {
            var done: [CleaningResult] = [], failed: [String] = []
            for (i, n) in names.enumerated() {
                await MainActor.run { self.busy = localizedFormat("Cleaning %@ (%ld/%ld)…", n, i + 1, names.count) }
                do {
                    let job = try k.prepareCleaning(plugin: n, xedit: xedit)
                    let r = SessionRunner.runSync([Paths.script("run-exe.sh"), "--wait", xedit.path] + job.arguments)
                    let res = try k.finishCleaning(job)
                    if res.changed { done.append(res) } else if r.status != 0 { failed.append(n) }
                } catch { failed.append("\(n) (\(error))") }
            }
            let ok = done, bad = failed
            await MainActor.run {
                self.busy = nil
                let itm = ok.reduce(0) { $0 + $1.removedITMs }, udr = ok.reduce(0) { $0 + $1.undeletedRefs }
                let summary = ok.isEmpty
                    ? localized("Nothing needed cleaning.")
                    : localizedFormat(ok.count == 1 ? "Cleaned %ld plugin (%ld identical-to-master records removed, %ld deleted references fixed). Deploy to use it." : "Cleaned %ld plugins (%ld identical-to-master records removed, %ld deleted references fixed). Deploy to use them.", ok.count, itm, udr)
                self.message = summary + (bad.isEmpty ? "" : " " + localizedFormat("Couldn't clean: %@", bad.joined(separator: ", ")))
                self.reload(); self.checkHealth()
            }
        }
    }

    func mergeDuplicates() {
        guard busy == nil else { return }
        autoSnapshot(localized("Before merging duplicate copies"), mods: kit.duplicateMods().flatMap(\.mods))
        let k = kit
        busy = localized("Comparing duplicate copies…")
        Task.detached {
            let r = Result { try k.mergeIdenticalDuplicates() }
            await MainActor.run {
                self.busy = nil
                switch r {
                case .success(let n): self.message = n == 0
                    ? localized("No identical copies. The duplicates differ because of installer choices, so each stays.")
                    : localizedFormat(n == 1 ? "Shared %ld identical copy; profiles are unchanged otherwise." : "Shared %ld identical copies; profiles are unchanged otherwise.", n)
                case .failure(let e): self.message = "\(e)"
                }
                self.reload(); self.checkHealth()
            }
        }
    }

    func removeStaleCleaned(_ names: [String]) {
        do { try kit.removeCleaned(names); message = localizedFormat(names.count == 1 ? "Removed %ld outdated cleaned copy. Deploy, then clean again if LOOT still reports it." : "Removed %ld outdated cleaned copies. Deploy, then clean again if LOOT still reports them.", names.count) }
        catch { message = "\(error)" }
        reload(); checkHealth()
    }
}

/// Credit for the tool that does the work (SkyrimMT skips xEdit's own start-up message when it runs it unattended).
struct XEditCredit: View {
    var body: some View {
        HStack(spacing: 4) {
            Text(localized("Cleaning is done by xEdit, by ElminsterAU and the xEdit team.")).font(.caption).foregroundStyle(.secondary)
            Link(localized("xEdit on GitHub (support the team)"), destination: URL(string: "https://github.com/TES5Edit/TES5Edit")!).font(.caption)
        }
    }
}
