// Mod Manager → Plugins: load order with filters and a detail pane (docs/MODMANAGER.md §3B) — what a plugin is, which
// mod brings it, its masters (and whether they are there), what needs it, LOOT's notes.
import SwiftUI
import AppKit

enum PluginFilter: String, CaseIterable, Identifiable {
    case all = "All plugins", active = "Active", inactive = "Inactive", light = "Light (ESL)", masters = "Masters", warnings = "With warnings"
    var id: String { rawValue }
}

extension ModManagerModel {
    func flagLight(_ names: [String]) {
        let gv = kit.gameVersionKey == "steam" ? versionSteam : kit.gameVersionKey
        undoable(localized("Flag Plugins Light")) {
            do {
                let done = try kit.flagLight(names, gameVersion: gv)
                message = localizedFormat(done.count == 1
                    ? "Flagged %ld plugin light — Deploy to use it. Remove the “Light-flagged Plugins” mod to undo."
                    : "Flagged %ld plugins light — Deploy to use them. Remove the “Light-flagged Plugins” mod to undo.", done.count)
            }
            catch { message = "\(error)" }
        }
        reload(); loadLightCandidates()
    }

    func loadLightCandidates() {
        let k = kit, gv = kit.gameVersionKey == "steam" ? versionSteam : kit.gameVersionKey
        Task.detached { let c = k.lightCandidates(gameVersion: gv); await MainActor.run { self.lightCandidates = c } }
    }

    /// Save a LOOT "load after" rule and sort right away so the player sees the effect (undoable like any sort).
    func setLoadAfter(_ plugin: String, _ after: [String]) {
        do { try kit.setLoadAfter(plugin, after: after); lootRules = kit.lootRules() } catch { message = "\(error)"; return }
        lootSort()
    }

    func setPluginLocked(_ name: String, _ on: Bool) {
        undoable(localizedFormat(on ? "Lock %@" : "Unlock %@", name)) {
            do { try kit.setPluginLocked(name, on); if on { lockedPlugins.insert(name.lowercased()) } else { lockedPlugins.remove(name.lowercased()) } }
            catch { message = "\(error)" }
        }
    }

    var visiblePlugins: [PluginRow] {
        plugins.filter { p in
            guard ModManagerModel.matches(p.name + " " + p.ownerName, pluginSearch) else { return false }
            switch pluginFilter {
            case .all: return true
            case .active: return p.active
            case .inactive: return !p.active
            case .light: return p.kind == "ESL" || p.kind == "ESP-FE"
            case .masters: return p.kind == "ESM" || p.kind == "ESL"
            case .warnings: return !p.issues.isEmpty || (lootMessages[p.id]?.contains { $0.type != "say" } ?? false)
            }
        }
    }
    var pluginCounts: (full: Int, light: Int) {
        let a = plugins.filter(\.active)
        let light = a.filter { $0.kind == "ESL" || $0.kind == "ESP-FE" }.count
        return (a.count - light, light)
    }
}

struct PluginsPage: View {
    @ObservedObject var model: ModManagerModel
    var body: some View { content.onAppear { model.loadLightCandidates() } }

    private var content: some View {
        HSplitView {
            VStack(spacing: 0) {
                HStack {
                    let c = model.pluginCounts
                    Text(localizedFormat("Top loads first, later plugins win · %ld/254 full · %ld/4096 light", c.full, c.light))
                        .foregroundStyle(c.full > 254 || c.light > 4096 ? .red : .secondary).font(.callout)
                    Spacer()
                    if model.hasLoot {
                        Button("Sort with LOOT") { model.lootSort() }
                            .help("Sorts with the LOOT masterlist. Active and inactive choices are kept.")
                    }
                    Button("Sort (basic)") { model.basicSort() }.help("Masters first, every plugin after its masters.")
                }
                .padding(10)
                if !model.lightCandidates.isEmpty {
                    let can = model.lightCandidates.filter { $0.reason == nil }
                    if !can.isEmpty {
                        HStack {
                            Label(localizedFormat(can.count == 1 ? "%ld plugin could be flagged light and free %ld full slot: %@" : "%ld plugins could be flagged light and free %ld full slots: %@", can.count, can.count, can.prefix(4).map(\.plugin).joined(separator: ", ") + (can.count > 4 ? "…" : "")),
                                  systemImage: "lightbulb").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button("Flag light") { model.flagLight(can.map(\.plugin)) }.controlSize(.small).disabled(model.busy != nil)
                                .help("Flagged copies go into “Light-flagged Plugins”. Originals are not changed.")
                        }.padding(.horizontal, 12).padding(.bottom, 6)
                    }
                }
                HStack(spacing: 8) {
                    let rows = model.visiblePlugins
                    SearchField(prompt: "Search plugins or mods", text: $model.pluginSearch, count: rows.count, total: model.plugins.count)
                    Picker("", selection: $model.pluginFilter) {
                        ForEach(PluginFilter.allCases) { Text(localized($0.rawValue)).tag($0) }
                    }
                        .labelsHidden().frame(width: 140)
                }
                .padding(.trailing, 10)
                List(selection: $model.selectedPlugin) {
                    ForEach(model.visiblePlugins) { p in row(p).tag(p.id) }
                        .onMove(perform: model.pluginSearch.isEmpty && model.pluginFilter == .all ? { model.movePlugins($0, $1) } : nil)
                }
                .overlay { if model.visiblePlugins.isEmpty && !model.plugins.isEmpty { Text("No plugin matches.").foregroundStyle(.secondary) } }
            }
            .frame(minWidth: 520, maxHeight: .infinity)
            ScrollView { detail.padding(14).frame(maxWidth: .infinity, alignment: .leading) }
                .frame(minWidth: 250, idealWidth: 300, maxWidth: 420)
        }
    }

    private func row(_ p: PluginRow) -> some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(get: { p.active }, set: { model.setPluginActive(p.name, $0) })).labelsHidden().disabled(p.implicit)
            Text(p.kind).font(.caption.monospaced()).frame(width: 52, alignment: .leading).foregroundStyle(.secondary)
            Text(p.name).foregroundStyle(p.implicit ? .secondary : .primary).lineLimit(1).truncationMode(.middle)
            if model.dirtyPlugins.keys.contains(where: { $0.lowercased() == p.id }) { Image(systemName: "sparkles").font(.caption).foregroundStyle(.yellow).help("LOOT: can be cleaned") }
            if model.lockedPlugins.contains(p.id) { Image(systemName: "lock.fill").font(.caption).foregroundStyle(.secondary).help("Position locked: sorting keeps it here") }
            Spacer()
            Text(p.ownerName).font(.caption).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.tail).frame(maxWidth: 180, alignment: .trailing)
            if !p.issues.isEmpty {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).help(p.issues.joined(separator: "\n"))
            }
            if let lm = model.lootMessages[p.id]?.filter({ $0.type != "say" }), !lm.isEmpty {
                Image(systemName: lm.contains { $0.type == "error" } ? "xmark.octagon.fill" : "info.circle.fill")
                    .foregroundStyle(lm.contains { $0.type == "error" } ? .red : .yellow)
                    .help(lm.map(\.text).joined(separator: "\n\n"))
            }
        }
    }

    @ViewBuilder private var detail: some View {
        if let id = model.selectedPlugin, let p = model.plugins.first(where: { $0.id == id }) {
            let present = Set(model.plugins.map(\.id)), active = Set(model.plugins.filter(\.active).map(\.id))
            VStack(alignment: .leading, spacing: 10) {
                Text(p.name).font(.title3.bold()).lineLimit(2)
                Text(kindText(p.kind) + (p.implicit ? localized(" · part of the game, always loaded") : "")).font(.caption).foregroundStyle(.secondary)
                if !p.ownerName.isEmpty, let mid = p.ownerID {
                    HStack {
                        Text(localizedFormat("From mod: %@", p.ownerName)).font(.callout)
                        Spacer()
                        Button("Show") { model.modSearch = ""; model.modFilter = .all; model.section = .mods; model.selectedIDs = [mid]; model.refreshDetail() }
                    }
                }
                if !p.implicit {
                    Toggle("Lock position (sorting keeps it in place)", isOn: Binding(get: { model.lockedPlugins.contains(p.id) }, set: { model.setPluginLocked(p.name, $0) }))
                        .toggleStyle(.checkbox).font(.callout)
                }
                if let d = model.dirtyPlugins[p.id] ?? model.dirtyPlugins.first(where: { $0.key.lowercased() == p.id })?.value {
                    VStack(alignment: .leading, spacing: 4) {
                        Label(localizedFormat("Needs cleaning: %@", d.summary), systemImage: "sparkles").font(.callout)
                        if d.autoCleanable { Button("Clean with xEdit") { model.cleanPlugins([p.name]) }.disabled(model.busy != nil) }
                        XEditCredit()
                    }.padding(8).background(Color.yellow.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
                }
                if let c = model.lightCandidates.first(where: { $0.plugin.lowercased() == p.id }) {
                    HStack {
                        Text(c.reason == nil ? localizedFormat("Could be flagged light (ESL): %ld new records, all in the light range — frees a full slot.", c.newRecords)
                                             : localizedFormat("Can't be flagged light: %@.", c.reason!)).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        if c.reason == nil { Button("Flag light") { model.flagLight([p.name]) }.controlSize(.small).disabled(model.busy != nil) }
                    }
                }
                if !p.author.isEmpty { Text(localizedFormat("Author: %@", p.author)).font(.callout) }
                if !p.about.isEmpty { Text(p.about).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).textSelection(.enabled) }
                if !p.issues.isEmpty {
                    ForEach(p.issues, id: \.self) { Label($0, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout) }
                }
                if let lm = model.lootMessages[p.id], !lm.isEmpty {
                    Text("LOOT").font(.headline)
                    ForEach(Array(lm.enumerated()), id: \.offset) { _, m in
                        Text(m.text).font(.caption).foregroundStyle(m.type == "error" ? .red : m.type == "warn" ? .orange : .secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                // LOOT rules: "load after" (userlist); applied by Sort with LOOT
                let after = model.lootRules[p.name] ?? model.lootRules.first(where: { $0.key.lowercased() == p.id })?.value ?? []
                if !p.implicit && model.hasLoot {
                    HStack {
                        Text("Load after").font(.headline)
                        Spacer()
                        Menu("Add…") {
                            ForEach(model.plugins.filter { !$0.implicit && $0.id != p.id && !after.map { $0.lowercased() }.contains($0.id) }) { o in
                                Button(o.name) { model.setLoadAfter(p.name, after + [o.name]) }
                            }
                        }.menuStyle(.borderlessButton).fixedSize()
                    }
                    if after.isEmpty { Text("No rules — LOOT decides.").font(.caption).foregroundStyle(.secondary) }
                    ForEach(after, id: \.self) { a in
                        HStack {
                            Image(systemName: "arrow.turn.down.right").foregroundStyle(.secondary)
                            Text(a).font(.callout)
                            Spacer()
                            Button { model.setLoadAfter(p.name, after.filter { $0 != a }) } label: { Image(systemName: "xmark.circle") }.accessibilityLabel("Remove rule").buttonStyle(.plain).help("Remove rule")
                        }
                    }
                }
                Text(localizedFormat("Needs (%ld)", p.masters.count)).font(.headline)
                if p.masters.isEmpty { Text("Nothing — loads on its own.").font(.caption).foregroundStyle(.secondary) }
                ForEach(p.masters, id: \.self) { m in
                    let l = m.lowercased()
                    HStack(spacing: 6) {
                        Image(systemName: !present.contains(l) ? "xmark.circle.fill" : active.contains(l) ? "checkmark.circle.fill" : "minus.circle.fill")
                            .foregroundStyle(!present.contains(l) ? .red : active.contains(l) ? .green : .orange)
                        Button(m) { model.selectedPlugin = l }.buttonStyle(.plain)
                        if !present.contains(l) { Text("missing").font(.caption).foregroundStyle(.red) }
                        else if !active.contains(l) { Text("inactive").font(.caption).foregroundStyle(.orange) }
                    }.font(.callout)
                }
                Text(localizedFormat("Needed by (%ld)", p.requiredBy.count)).font(.headline)
                if p.requiredBy.isEmpty { Text("No active plugin needs it.").font(.caption).foregroundStyle(.secondary) }
                ForEach(p.requiredBy.prefix(30), id: \.self) { d in Button(d) { model.selectedPlugin = d.lowercased() }.buttonStyle(.plain).font(.callout) }
                if p.requiredBy.count > 30 { Text(localizedFormat("… and %ld more", p.requiredBy.count - 30)).font(.caption).foregroundStyle(.secondary) }
            }
        } else {
            VStack(spacing: 6) {
                Text("Select a plugin").foregroundStyle(.secondary)
                Text("See which mod it comes from, what it needs and what needs it.").font(.caption).foregroundStyle(.tertiary)
            }.frame(maxWidth: .infinity, minHeight: 200)
        }
    }

    private func kindText(_ k: String) -> String {
        switch k {
        case "ESM": return "Master file (full slot)"
        case "ESL": return "Light master (no full slot)"
        case "ESP-FE": return "Light plugin (no full slot)"
        case "ESP": return "Plugin (full slot)"
        default: return "Unknown — file not found"
        }
    }
}
