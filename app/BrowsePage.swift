// Mod Manager → Browse: search Nexus Mods inside SkyrimMT and install with one click (Premium: the main file is
// downloaded and installed; free accounts: the file page opens and “Mod Manager Download” comes back here).
import SwiftUI
import AppKit

extension ModManagerModel {
    func searchNexus(more: Bool = false) {
        let c = client(), q = browseQuery, sort = browseSort, offset = more ? browseHits.count : 0
        browseLoading = true
        Task {
            do {
                let r = try await c.searchMods(q, sort: sort, offset: offset, count: 30)
                browseHits = more ? browseHits + r.hits : r.hits; browseTotal = r.total
            } catch { message = localizedFormat("Nexus search: %@", "\(error)") }
            browseLoading = false
        }
    }

    /// A mod already in the library (another profile has it): enable it in this profile, no download.
    func addFromLibrary(nexusID: Int) {
        let ids = kit.mods.filter { $0.nexus?.modID == nexusID }.map(\.id)
        undoable(localized("Add Mod")) {
            guard var p = try? kit.currentProfile() else { return }
            for id in ids {
                if let i = p.mods.firstIndex(where: { $0.id == id }) { p.mods[i].enabled = true }
                else {
                    let at = p.mods.firstIndex { ModKit.isOverwrite($0.id) || ModKit.isPandoraOutput($0.id) || ModKit.isBodySlideOutput($0.id) } ?? p.mods.count
                    p.mods.insert(ProfileMod(id: id, enabled: true), at: at)
                }
            }
            do { try kit.saveProfile(p) } catch { message = "\(error)" }
        }
        message = localizedFormat("Added to “%@” — Deploy to use it.", profile)
        reload()
    }

    /// Install from Nexus: a mod with several files (body + outfits, options, patches) asks which ones; the author's
    /// primary file is preselected. Premium downloads them; free accounts get each file's page (Nexus rule).
    func installFromNexus(modID: Int, name: String) {
        guard nexusKeyStored else { section = .downloads; message = localized("Add your Nexus Mods API key first (Downloads)."); return }
        let c = client()
        Task {
            do {
                let files = try await c.files(modID).filter { !["OLD_VERSION", "ARCHIVED", "DELETED", "REMOVED"].contains($0.category.uppercased()) }
                guard !files.isEmpty else { message = localizedFormat("%@ has no files to install.", name); return }
                let primary = try await c.mainFile(modID: modID)
                if files.count == 1 { downloadAndInstall(modID: modID, name: name, files: files, primary: primary?.fileID); return }
                filePicker = FilePickerState(modID: modID, name: name, files: files, primary: primary?.fileID, selected: Set(primary.map { [$0.fileID] } ?? []))
            } catch { message = "\(name): \(error)" }
        }
    }

    /// A file other than the primary one becomes its own mod: "<mod> – <file>".
    func downloadAndInstall(modID: Int, name: String, files: [NexusFileInfo], primary: Int?) {
        guard nexusUser?.premium ?? false else {
            for f in files.prefix(5) { NSWorkspace.shared.open(URL(string: "https://www.nexusmods.com/\(nexusGame)/mods/\(modID)?tab=files&file_id=\(f.fileID)&nmm=1")!) }
            message = localized("Click “Mod Manager Download” on the page that opened. SkyrimMT downloads and installs it."); return
        }
        let c = client(), folder = kit.home.appendingPathComponent("downloads")
        Task.detached {
            var archives: [URL] = []
            for f in files {
                let modName = f.fileID == primary ? name : "\(name) – \(f.name)"
                let job = await MainActor.run { self.beginDownload("\(modName) \(f.version)") }
                do {
                    let a = try await NexusDownloader(client: c, folder: folder).downloadFile(modID: modID, fileID: f.fileID, fileName: f.fileName, md5: f.md5,
                                                                                             size: f.sizeBytes, modName: modName, version: f.version) { got, total in
                        Task { @MainActor in self.downloadProgress(job, got, total) }
                    }
                    await MainActor.run { self.endDownload(job) }
                    archives.append(a)
                } catch { await MainActor.run { self.endDownload(job, error: error); self.message = "\(modName): \(error)" } }
            }
            let got = archives
            await MainActor.run { self.install(got); self.reloadDownloads() }   // installers appear one by one
        }
    }
}

struct FilePickerState: Identifiable {
    var id: Int { modID }
    let modID: Int, name: String, files: [NexusFileInfo], primary: Int?
    var selected: Set<Int>
}

/// Which of a mod's Nexus files to install.
struct FilePickerView: View {
    @ObservedObject var model: ModManagerModel
    var body: some View {
        if let st = model.filePicker {
            VStack(alignment: .leading, spacing: 12) {
                Text(localizedFormat("Install %@", st.name)).font(.title3.bold())
                Text("Choose the files to install. Each file becomes its own mod.").foregroundStyle(.secondary)
                List {
                    ForEach(["MAIN", "UPDATE", "OPTIONAL", "MISCELLANEOUS"], id: \.self) { cat in
                        let files = st.files.filter { $0.category.uppercased() == cat }.sorted { $0.uploadedTimestamp > $1.uploadedTimestamp }
                        if !files.isEmpty {
                            Section(cat == "MISCELLANEOUS" ? "Miscellaneous" : cat.capitalized) {
                                ForEach(files, id: \.fileID) { f in
                                    Toggle(isOn: Binding(get: { model.filePicker?.selected.contains(f.fileID) ?? false },
                                                         set: { on in if on { model.filePicker?.selected.insert(f.fileID) } else { model.filePicker?.selected.remove(f.fileID) } })) {
                                        HStack {
                                            Text(f.name)
                                            if f.fileID == st.primary { Text("primary").font(.caption2.weight(.semibold)).foregroundStyle(.green) }
                                            Spacer()
                                            Text(f.version).font(.caption).foregroundStyle(.secondary)
                                            if let b = f.sizeBytes { Text(ByteCountFormatter.string(fromByteCount: b, countStyle: .file)).font(.caption).foregroundStyle(.secondary).frame(width: 70, alignment: .trailing) }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                .frame(minHeight: 260)
                HStack {
                    Spacer()
                    Button("Cancel") { model.filePicker = nil }.keyboardShortcut(.cancelAction)
                    Button(localizedFormat(st.selected.count == 1 ? "Install %ld file" : "Install %ld files", st.selected.count)) {
                        let chosen = st.files.filter { st.selected.contains($0.fileID) }
                        model.filePicker = nil
                        model.downloadAndInstall(modID: st.modID, name: st.name, files: chosen, primary: st.primary)
                    }
                    .keyboardShortcut(.defaultAction).disabled(st.selected.isEmpty)
                }
            }
            .padding(18).frame(width: 620, height: 480)
        }
    }
}

struct BrowsePage: View {
    @ObservedObject var model: ModManagerModel
    var body: some View {
        let installed = Set(model.mods.compactMap(\.nexusID))
        let library = Set(model.kit.mods.compactMap { $0.nexus?.modID })
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                TextField("Search Nexus Mods for Skyrim Special Edition", text: $model.browseQuery)
                    .textFieldStyle(.roundedBorder).onSubmit { model.searchNexus() }
                Picker("", selection: $model.browseSort) {
                    ForEach(NexusSort.allCases) { Text(localized($0.rawValue)).tag($0) }
                }
                    .labelsHidden().frame(width: 170).onChange(of: model.browseSort) { _ in model.searchNexus() }
                Button("Search") { model.searchNexus() }.keyboardShortcut(.defaultAction)
            }
            .padding(10)
            if model.browseTotal > 0 {
                Text(localizedFormat("%@ mods", model.browseTotal.formatted())).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12)
            }
            List {
                ForEach(model.browseHits) { h in row(h, installed: installed.contains(h.modID), inLibrary: library.contains(h.modID)) }
                if model.browseHits.count < model.browseTotal {
                    HStack { Spacer(); Button(model.browseLoading ? "Loading…" : "Show more") { model.searchNexus(more: true) }.disabled(model.browseLoading); Spacer() }
                }
            }
            .overlay {
                if model.browseHits.isEmpty {
                    if model.browseLoading { ProgressView() }
                    else { Text("Search Nexus Mods. An empty search lists the most endorsed mods.").foregroundStyle(.secondary) }
                }
            }
        }
        .onAppear { if model.browseHits.isEmpty { model.searchNexus() } }
    }

    private func row(_ h: NexusSearchHit, installed: Bool, inLibrary: Bool) -> some View {
        let blur = h.adult && !model.showAdultPictures
        return HStack(alignment: .top, spacing: 12) {
            if let s = (blur ? h.thumbnailBlurred : h.thumbnail) ?? h.thumbnail, let u = URL(string: s) {
                AsyncImage(url: u) { img in img.resizable().aspectRatio(contentMode: .fill) } placeholder: { Color.secondary.opacity(0.1) }
                    .frame(width: 120, height: 68).clipped().clipShape(RoundedRectangle(cornerRadius: 5))
            } else { Color.secondary.opacity(0.1).frame(width: 120, height: 68).clipShape(RoundedRectangle(cornerRadius: 5)) }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(h.name).fontWeight(.medium).lineLimit(1)
                    if h.adult { Text("18+").font(.caption2.bold()).foregroundStyle(.orange) }
                }
                Text(h.summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                HStack(spacing: 10) {
                    Label(h.author, systemImage: "person").lineLimit(1)
                    Label(h.endorsements.formatted(.number.notation(.compactName)), systemImage: "hand.thumbsup")
                    Label(h.downloads.formatted(.number.notation(.compactName)), systemImage: "arrow.down.circle")
                    if !h.category.isEmpty { Text(h.category) }
                }.font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                if installed {
                    Label("Installed", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
                    Button("Other files…") { model.installFromNexus(modID: h.modID, name: h.name) }.buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
                }
                else if inLibrary {
                    Button("Add to profile") { model.addFromLibrary(nexusID: h.modID) }.disabled(model.busy != nil)
                        .help("Installed in another profile. Add it here without downloading again.")
                } else { Button("Install") { model.installFromNexus(modID: h.modID, name: h.name) }.disabled(model.busy != nil) }
                Button("Page") { model.openNexus(h.modID) }.buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}
