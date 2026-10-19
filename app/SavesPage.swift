// Mod Manager → Saves: every save with its picture, and whether the current profile can load it safely
// (ModKit/SaveGames.swift) — missing mods named, switched-off ones turned back on in one click.
import SwiftUI
import AppKit

extension ModManagerModel {
    func loadSaves() {
        let k = kit
        savesLoading = true
        Task.detached {
            let files = k.saveFiles()
            let infos = files.compactMap { try? SaveReader.read($0) }
            let backups = k.saveBackups()
            await MainActor.run {
                self.saves = infos; self.savesLoading = false; self.saveBackupList = backups
                if let s = self.saveSelected, !infos.contains(where: { $0.url == s.url }) { self.saveSelected = nil }
                if self.saveSelected == nil, let first = infos.first { self.selectSave(first.url) }
            }
        }
    }

    func selectSave(_ url: URL) {
        let k = kit
        Task.detached {
            guard let s = try? SaveReader.read(url, screenshot: true) else { return }
            let c = k.checkSave(s)
            await MainActor.run { self.saveSelected = s; self.saveCheck = c }
        }
    }

    func fixSelectedSave() {
        guard let c = saveCheck, let s = saveSelected else { return }
        do {
            try kit.fixSave(c)
            message = "Turned on \(c.fixable.count) plugin\(c.fixable.count == 1 ? "" : "s") this save uses — Deploy to apply. Undo: Profiles → History."
            reload(); selectSave(s.url)
        } catch { message = "\(error)" }
    }

    func restoreBackup(_ b: SaveBackup) {
        let a = NSAlert(); a.messageText = "Restore \(b.count) save\(b.count == 1 ? "" : "s") from \(b.date.formatted(date: .abbreviated, time: .shortened))?"
        a.informativeText = "Newer saves are kept. Saves with the same name are replaced only if you choose Replace."
        a.addButton(withTitle: "Restore missing"); a.addButton(withTitle: "Replace all"); a.addButton(withTitle: "Cancel")
        let r = a.runModal()
        guard r != .alertThirdButtonReturn else { return }
        do { let n = try kit.restoreSaves(b, replace: r == .alertSecondButtonReturn); message = "Restored \(n) file\(n == 1 ? "" : "s")." } catch { message = "\(error)" }
        loadSaves()
    }

    static func image(_ shot: (width: Int, height: Int, rgba: Data)?) -> NSImage? {
        guard let s = shot, s.width > 0, s.height > 0, s.rgba.count >= s.width * s.height * 4,
              let prov = CGDataProvider(data: s.rgba as CFData),
              let cg = CGImage(width: s.width, height: s.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: s.width * 4,
                               space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                               provider: prov, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: s.width, height: s.height))
    }
}

struct SavesPage: View {
    @ObservedObject var model: ModManagerModel
    var body: some View {
        HSplitView {
            List(selection: Binding(get: { model.saveSelected?.url }, set: { if let u = $0 { model.selectSave(u) } })) {
                ForEach(model.saves) { s in
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(s.player) · level \(s.level)").fontWeight(.medium)
                        Text("\(s.location) · \(s.saved.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                    }.tag(s.url)
                }
            }
            .safeAreaInset(edge: .bottom) {
                if !model.saveBackupList.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Backups before updates").font(.caption.bold()).foregroundStyle(.secondary)
                        ForEach(model.saveBackupList.prefix(5)) { b in
                            HStack {
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(b.date.formatted(date: .abbreviated, time: .shortened)).font(.caption)
                                    Text("\(b.reason) · \(b.count) saves").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                                Button("Restore…") { model.restoreBackup(b) }.controlSize(.small)
                            }
                        }
                    }.padding(8).background(.bar)
                }
            }
            .frame(minWidth: 220, idealWidth: 260, maxWidth: 320)
            .overlay {
                if model.savesLoading && model.saves.isEmpty { ProgressView() }
                else if model.saves.isEmpty { Text("No saves yet").foregroundStyle(.secondary) }
            }
            ScrollView { detail.padding(16).frame(maxWidth: .infinity, alignment: .leading) }
                .frame(minWidth: 460, maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { model.loadSaves() }
    }

    @ViewBuilder private var detail: some View {
        if let s = model.saveSelected, let c = model.saveCheck {
            VStack(alignment: .leading, spacing: 12) {
                if let img = ModManagerModel.image(s.shot) {
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fit).frame(maxWidth: 420).clipShape(RoundedRectangle(cornerRadius: 6))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(s.player), level \(s.level) \(s.race.replacingOccurrences(of: "Race", with: ""))").font(.title3.bold())
                    Text("\(s.location) · saved \(s.saved.formatted(date: .abbreviated, time: .shortened)) · \(s.plugins.count + s.lightPlugins.count) plugins").font(.caption).foregroundStyle(.secondary)
                }
                if c.ok {
                    Label("Safe to load with “\(model.profile)” — every plugin it uses is active.", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                } else {
                    if !c.fixable.isEmpty {
                        HStack(alignment: .top) {
                            Label("\(c.fixable.count) plugin\(c.fixable.count == 1 ? "" : "s") this save uses \(c.fixable.count == 1 ? "is" : "are") installed but switched off.", systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Spacer()
                            Button("Turn on") { model.fixSelectedSave() }.disabled(model.busy != nil)
                        }
                        Text(c.fixable.prefix(12).map(\.plugin).joined(separator: ", ") + (c.fixable.count > 12 ? "…" : "")).font(.caption).foregroundStyle(.secondary)
                    }
                    if !c.missing.isEmpty {
                        Label("\(c.missing.count) plugin\(c.missing.count == 1 ? "" : "s") this save uses \(c.missing.count == 1 ? "is" : "are") not installed. Loading it anyway drops what they added (items, quests, places) and can break the save.", systemImage: "xmark.octagon.fill")
                            .foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                        Text(c.missing.prefix(20).joined(separator: ", ") + (c.missing.count > 20 ? "…" : "")).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        if c.missing.count > 20 || s.allPlugins.count > 50 && c.missing.count * 2 > s.allPlugins.count {
                            Text("This save likely belongs to another profile. Switch to it in Profiles.").font(.caption)
                        }
                    }
                }
                if !c.added.isEmpty {
                    Text("\(c.added.count) active plugin\(c.added.count == 1 ? " is" : "s are") new since this save — usually fine.").font(.caption).foregroundStyle(.secondary)
                }
                HStack { Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([s.url]) }; Spacer() }
            }
        } else {
            Text("Select a save.").foregroundStyle(.secondary)
        }
    }
}
