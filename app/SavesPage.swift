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
            let key = c.fixable.count == 1
                ? "Turned on %ld plugin this save uses — Deploy to apply. Undo: Profiles → History."
                : "Turned on %ld plugins this save uses — Deploy to apply. Undo: Profiles → History."
            message = localizedFormat(key, c.fixable.count)
            reload(); selectSave(s.url)
        } catch { message = "\(error)" }
    }

    func restoreBackup(_ b: SaveBackup) {
        let a = NSAlert()
        let key = b.count == 1 ? "Restore %ld save from %@?" : "Restore %ld saves from %@?"
        a.messageText = localizedFormat(key, b.count, b.date.formatted(date: .abbreviated, time: .shortened))
        a.informativeText = localized("Newer saves are kept. Saves with the same name are replaced only if you choose Replace.")
        a.addButton(withTitle: localized("Restore missing")); a.addButton(withTitle: localized("Replace all")); a.addButton(withTitle: localized("Cancel"))
        let r = a.runModal()
        guard r != .alertThirdButtonReturn else { return }
        do {
            let n = try kit.restoreSaves(b, replace: r == .alertSecondButtonReturn)
            message = localizedFormat(n == 1 ? "Restored %ld file." : "Restored %ld files.", n)
        } catch { message = "\(error)" }
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
                        Text(localizedFormat("%@ · level %ld", s.player, s.level)).fontWeight(.medium)
                        Text(localizedFormat("%@ · %@", s.location, s.saved.formatted(date: .abbreviated, time: .shortened))).font(.caption).foregroundStyle(.secondary)
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
                                    Text(localizedFormat(b.count == 1 ? "%@ · %ld save" : "%@ · %ld saves", b.reason, b.count)).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
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
                    Text(localizedFormat("%@, level %ld %@", s.player, s.level, s.race.replacingOccurrences(of: "Race", with: ""))).font(.title3.bold())
                    let pluginCount = s.plugins.count + s.lightPlugins.count
                    Text(localizedFormat(pluginCount == 1 ? "%@ · saved %@ · %ld plugin" : "%@ · saved %@ · %ld plugins", s.location, s.saved.formatted(date: .abbreviated, time: .shortened), pluginCount)).font(.caption).foregroundStyle(.secondary)
                }
                if c.ok {
                    Label(localizedFormat("Safe to load with “%@” — every plugin it uses is active.", model.profile), systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                } else {
                    if !c.fixable.isEmpty {
                        HStack(alignment: .top) {
                            let key = c.fixable.count == 1
                                ? "%ld plugin this save uses is installed but switched off."
                                : "%ld plugins this save uses are installed but switched off."
                            Label(localizedFormat(key, c.fixable.count), systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Spacer()
                            Button("Turn on") { model.fixSelectedSave() }.disabled(model.busy != nil)
                        }
                        Text(c.fixable.prefix(12).map(\.plugin).joined(separator: ", ") + (c.fixable.count > 12 ? "…" : "")).font(.caption).foregroundStyle(.secondary)
                    }
                    if !c.missing.isEmpty {
                        let key = c.missing.count == 1
                            ? "%ld plugin this save uses is not installed. Loading it anyway drops what it added (items, quests, places) and can break the save."
                            : "%ld plugins this save uses are not installed. Loading it anyway drops what they added (items, quests, places) and can break the save."
                        Label(localizedFormat(key, c.missing.count), systemImage: "xmark.octagon.fill")
                            .foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                        Text(c.missing.prefix(20).joined(separator: ", ") + (c.missing.count > 20 ? "…" : "")).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        if c.missing.count > 20 || s.allPlugins.count > 50 && c.missing.count * 2 > s.allPlugins.count {
                            Text("This save likely belongs to another profile. Switch to it in Profiles.").font(.caption)
                        }
                    }
                }
                if !c.added.isEmpty {
                    let key = c.added.count == 1
                        ? "%ld active plugin is new since this save — usually fine."
                        : "%ld active plugins are new since this save — usually fine."
                    Text(localizedFormat(key, c.added.count)).font(.caption).foregroundStyle(.secondary)
                }
                HStack { Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([s.url]) }; Spacer() }
            }
        } else {
            Text("Select a save.").foregroundStyle(.secondary)
        }
    }
}
