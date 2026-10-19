// Mod Manager → Snapshots (ModKit/Snapshots.swift): the setup before every risky change, restorable in one click.
import SwiftUI
import AppKit

extension ModManagerModel {
    nonisolated static func listNames(_ names: [String]) -> String {
        names.count <= 2 ? names.joined(separator: " and ") : "\(names[0]), \(names[1]) and \(names.count - 2) more"
    }

    /// Before a risky change: quiet (a failed snapshot never blocks the change; it's reported).
    func autoSnapshot(_ reason: String, mods: [String] = []) {
        do { try kit.takeSnapshot(reason: reason, mods: mods) } catch { message = "Snapshot failed: \(error)" }
        snapshots = kit.snapshots()
    }

    func reloadSnapshots() { let k = kit; Task.detached { let s = k.snapshots(); await MainActor.run { self.snapshots = s } } }

    func takeSnapshotNow() {
        do { try kit.takeSnapshot(reason: "Taken by hand"); message = "Snapshot taken." } catch { message = "\(error)" }
        snapshots = kit.snapshots()
    }

    func restoreSnapshot(_ s: Snapshot) {
        guard !gameRunning() else { message = "Quit Skyrim before restoring."; return }
        let a = NSAlert()
        a.messageText = "Restore “\(s.reason)”?"
        a.informativeText = "Restores the mod list, load order and game settings of \(s.profile)"
            + (s.savedMods.isEmpty ? "." : ", and the files of \(s.savedMods.count) mod\(s.savedMods.count == 1 ? "" : "s").")
            + " Saves are not changed. The current setup is snapshotted first."
        a.addButton(withTitle: "Restore"); a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let k = kit
        busy = "Restoring…"
        Task.detached {
            do {
                let r = try k.restoreSnapshot(s)
                _ = try k.deploy()
                var m = "Restored “\(s.reason)”."
                if !r.restoredFiles.isEmpty { m += " Files restored for " + ModManagerModel.listNames(r.restoredFiles) + "." }
                if !r.missing.isEmpty { m += " No longer installed: " + ModManagerModel.listNames(r.missing) + "." }
                let done = m
                await MainActor.run { self.busy = nil; self.message = done; self.snapshots = k.snapshots(); self.reload() }
            } catch { await MainActor.run { self.busy = nil; self.message = "\(error)"; self.reload() } }
        }
    }

    func deleteSnapshot(_ s: Snapshot) { kit.deleteSnapshot(s); snapshots = kit.snapshots() }
}

struct SnapshotsPage: View {
    @ObservedObject var model: ModManagerModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                Text("A snapshot is taken before removing, updating or reinstalling mods, sorting with LOOT and updating collections. It holds the mod list, load order, game settings and the affected mod files. Saves are backed up separately.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Take snapshot now") { model.takeSnapshotNow() }.disabled(model.busy != nil)
            }
            List(model.snapshots) { s in
                HStack(spacing: 10) {
                    Image(systemName: "clock.arrow.circlepath").foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s.reason)
                        Text(detail(s)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if s.profile == model.profile { Button("Restore") { model.restoreSnapshot(s) }.disabled(model.busy != nil) }
                    else { Button("Switch to \(s.profile)") { model.switchProfile(s.profile) }.disabled(model.busy != nil || !model.profiles.contains(s.profile)) }
                }
                .padding(.vertical, 2)
                .contextMenu { Button("Delete snapshot", role: .destructive) { model.deleteSnapshot(s) } }
            }
            .overlay { if model.snapshots.isEmpty { Text("No snapshots yet.").foregroundStyle(.secondary) } }
            Text("The latest \(ModKit.snapshotsKept) snapshots are kept. Mod files are stored as APFS clones and use space only when the original changes.")
                .font(.caption).foregroundStyle(.tertiary)
        }
        .padding(14)
        .onAppear { model.reloadSnapshots() }
    }

    private func detail(_ s: Snapshot) -> String {
        var p = [s.date.formatted(date: .abbreviated, time: .shortened) + " (" + s.date.formatted(.relative(presentation: .named)) + ")", s.profile, "\(s.modCount) mods on"]
        let files = s.savedMods.filter { !ModKit.isOverwrite($0) }.count
        if files > 0 { p.append("files of \(files) mod\(files == 1 ? "" : "s") kept") }
        return p.joined(separator: " · ")
    }
}
