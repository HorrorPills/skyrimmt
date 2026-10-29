// Mod Manager → Data (ModKit/DataTree.swift): the Data folder as this profile deploys it. Red: folders with files that
// more than one mod provides, and the files themselves; the detail pane names the mods.
import SwiftUI
import AppKit

extension ModManagerModel {
    func loadDataTree() {
        let k = kit
        dataLoading = true
        Task.detached {
            let t = try? k.dataTree()
            await MainActor.run { self.dataTree = t; self.dataLoading = false }
        }
    }

    func originName(_ id: String) -> String {
        id == ModKit.vanillaOrigin ? localized("Skyrim (game files)") : kit.mod(id)?.name ?? id
    }

    /// Files and folders whose path contains the search text (first 500).
    func dataMatches(_ q: String) -> [DataNode] {
        guard let root = dataTree else { return [] }
        let needle = q.lowercased()
        var out: [DataNode] = []
        func walk(_ n: DataNode) {
            for c in n.children ?? [] {
                if out.count >= 500 { return }
                if c.id.contains(needle) { out.append(c) }
                if c.isFolder { walk(c) }
            }
        }
        walk(root)
        return out
    }

    func dataNode(_ id: String) -> DataNode? {
        guard var n = dataTree else { return nil }
        var path = ""
        for part in id.split(separator: "/") {
            path = path.isEmpty ? String(part) : path + "/" + part
            guard let c = n.children?.first(where: { $0.id == path }) else { return nil }
            n = c
        }
        return n
    }
}

struct DataPage: View {
    @ObservedObject var model: ModManagerModel
    var body: some View {
        HSplitView {
            VStack(spacing: 8) {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search the Data folder", text: $model.dataSearch).textFieldStyle(.plain)
                    if model.dataLoading { ProgressView().controlSize(.small) }
                }
                .padding(7).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 7))
                if let root = model.dataTree {
                    if model.dataSearch.trimmingCharacters(in: .whitespaces).isEmpty {
                        List(root.children ?? [], children: \.children, selection: $model.dataSelection) { n in row(n, showPath: false).tag(n.id) }
                    } else {
                        List(model.dataMatches(model.dataSearch.trimmingCharacters(in: .whitespaces)), selection: $model.dataSelection) { n in row(n, showPath: true).tag(n.id) }
                    }
                } else {
                    Spacer()
                }
                Text("Red: files provided by more than one mod, and the folders that contain them.").font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(12)
            .frame(minWidth: 420, maxWidth: .infinity)
            detail.frame(minWidth: 280, idealWidth: 340, maxWidth: 460, maxHeight: .infinity, alignment: .topLeading)
        }
        .onAppear { model.loadDataTree() }
    }

    private func row(_ n: DataNode, showPath: Bool) -> some View {
        let conflict = n.isFolder ? n.conflicts > 0 : !n.losers.isEmpty
        return HStack(spacing: 6) {
            Image(systemName: n.isFolder ? "folder" : "doc").foregroundStyle(conflict ? .red : .secondary)
            Text(showPath ? n.id : n.name).lineLimit(1).truncationMode(.middle).foregroundStyle(conflict ? .red : .primary)
            Spacer()
            if n.isFolder {
                Text(localizedFormat(n.mods.count == 1 ? "%ld source" : "%ld sources", n.mods.count)).font(.caption).foregroundStyle(.secondary)
            } else if let w = n.winner {
                Text(model.originName(w)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    @ViewBuilder private var detail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if let id = model.dataSelection, let n = model.dataNode(id) {
                    Text("Data/" + id).font(.headline).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    if n.isFolder {
                        let key = n.files == 1 ? "%ld file · %ld provided by more than one mod" : "%ld files · %ld provided by more than one mod"
                        Text(localizedFormat(key, n.files, n.conflicts)).font(.callout).foregroundStyle(n.conflicts > 0 ? .red : .secondary)
                        Text("Mods with files in this folder").font(.subheadline.bold())
                        ForEach(n.mods.sorted { $0.value > $1.value }, id: \.key) { m in
                            HStack {
                                Text(model.originName(m.key)).lineLimit(2)
                                Spacer()
                                Text("\(m.value)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                if m.key != ModKit.vanillaOrigin { showButton(m.key) }
                            }
                        }
                    } else {
                        Text("Provided by").font(.subheadline.bold())
                        if let w = n.winner { HStack { Text(model.originName(w)); Spacer(); if w != ModKit.vanillaOrigin { showButton(w) } } }
                        if !n.losers.isEmpty {
                            Text("Overrides").font(.subheadline.bold()).foregroundStyle(.red)
                            ForEach(n.losers, id: \.self) { l in HStack { Text(model.originName(l)); Spacer(); if l != ModKit.vanillaOrigin { showButton(l) } } }
                        }
                    }
                    Button("Show in Finder") {
                        let u = model.kit.gameDir.appendingPathComponent("Data").appendingPathComponent(id)
                        if FileManager.default.fileExists(atPath: u.path) { NSWorkspace.shared.activateFileViewerSelecting([u]) }
                        else { model.message = localized("Not deployed yet. Deploy to place it in the game folder.") }
                    }
                } else {
                    Text("Select a file or folder to see which mods provide it.").foregroundStyle(.secondary)
                }
            }
            .padding(14)
        }
    }

    private func showButton(_ id: String) -> some View {
        Button { model.modSearch = ""; model.modFilter = .all; model.section = .mods; model.selectedIDs = [id]; model.refreshDetail() } label: {
            Image(systemName: "arrow.right.circle")
        }
        .buttonStyle(.plain).help(localized("Show in the mod list")).accessibilityLabel(localized("Show in the mod list"))
    }
}
