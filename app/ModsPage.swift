// Mod Manager → Mods page (docs/MODMANAGER.md §3A): sortable columns, filters, search, multi-select with bulk actions,
// separators (collapsible groups that move as a block), rename/notes, and a detail panel with per-file conflicts and
// file hiding. Reordering by drag works in priority order without a filter (otherwise "Move to…" is used).
import SwiftUI
import AppKit

enum ModFilter: String, CaseIterable, Identifiable {
    case all = "All mods", profile = "In this profile", enabled = "Enabled", disabled = "Disabled", conflicts = "With conflicts", plugins = "With plugins",
         notes = "With notes", updates = "Update available", collection = "From a collection", manual = "Installed by hand"
    var id: String { rawValue }
}

enum ModSort: String, CaseIterable { case priority = "Priority", name = "Name", version = "Version", category = "Category", conflicts = "Conflicts", files = "Files", installed = "Installed" }

extension ModManagerModel {
    static let tagColors: [(String, Color)] = [("red", .red), ("orange", .orange), ("yellow", .yellow), ("green", .green), ("blue", .blue), ("purple", .purple)]
    static func tagColor(_ name: String) -> Color? { tagColors.first { $0.0 == name }?.1 }

    var showCategoryColumn: Bool { mods.contains { !$0.category.isEmpty } }
    var modsFiltered: Bool { !modSearch.isEmpty || modFilter != .all || modSort != .priority || !modCategory.isEmpty }
    var categories: [String] { Array(Set(mods.map(\.category).filter { !$0.isEmpty })).sorted() }

    /// Rows to show: filtered/sorted flat list, or the priority order with collapsed groups folded.
    var visibleMods: [ModRow] {
        if modsFiltered {
            var rows = mods.filter { r in
                guard !r.separator else { return false }
                guard modCategory.isEmpty || r.category == modCategory else { return false }
                // search also finds authors and Nexus ids ("12604")
                let author = r.nexusID.flatMap { nexusDetails[$0]?.author } ?? ""
                guard ModManagerModel.matches(r.name + " " + r.notes + " " + r.category + " " + author + " " + (r.nexusID.map(String.init) ?? ""), modSearch) else { return false }
                switch modFilter {
                case .all: return true
                case .profile: return r.inProfile
                case .enabled: return r.enabled
                case .disabled: return !r.enabled
                case .conflicts: return r.wins + r.loses > 0
                case .plugins: return r.plugins > 0
                case .notes: return !r.notes.isEmpty
                case .updates: return updates[r.id] != nil
                case .collection: return !r.collection.isEmpty
                case .manual: return r.collection.isEmpty
                }
            }
            let asc = modSortAscending
            func cmp<T: Comparable>(_ a: T, _ b: T) -> Bool { asc ? a < b : a > b }
            switch modSort {
            case .priority: rows.sort { cmp($0.priority, $1.priority) }
            case .name: rows.sort { asc ? $0.name.localizedStandardCompare($1.name) == .orderedAscending : $0.name.localizedStandardCompare($1.name) == .orderedDescending }
            case .version: rows.sort { cmp($0.version, $1.version) }
            case .category: rows.sort { cmp($0.category, $1.category) }
            case .conflicts: rows.sort { cmp($0.wins + $0.loses, $1.wins + $1.loses) }
            case .files: rows.sort { cmp($0.files, $1.files) }
            case .installed: rows.sort { cmp($0.installed, $1.installed) }
            }
            return rows
        }
        var out: [ModRow] = [], hiding = false
        for r in mods {
            if r.separator { hiding = collapsedGroups.contains(r.id); out.append(r) }
            else if !hiding { out.append(r) }
        }
        return out
    }

    func groupSize(_ sep: String) -> (all: Int, enabled: Int) {
        guard let i = mods.firstIndex(where: { $0.id == sep }) else { return (0, 0) }
        let members = mods[(i + 1)...].prefix { !$0.separator }
        return (members.count, members.filter(\.enabled).count)
    }

    func toggleCollapsed(_ sep: String) {
        if collapsedGroups.contains(sep) { collapsedGroups.remove(sep) } else { collapsedGroups.insert(sep) }
        UserDefaults.standard.set(Array(collapsedGroups), forKey: "collapsedSeparators")
    }

    func sortBy(_ k: ModSort) { if modSort == k { modSortAscending.toggle() } else { modSort = k; modSortAscending = true } }

    /// Drag in the unfiltered list: visible indices → mod ids → ModKit.moveMods (a separator drags its group).
    func moveVisible(_ from: IndexSet, _ to: Int) {
        let rows = visibleMods
        let ids = from.map { rows[$0].id }
        let before = to < rows.count ? rows[to].id : nil
        undoable("Move \(ModManagerModel.plural(ids.count, "Mod"))") { run { try $0.moveMods(ids, before: before) } }
    }

    func setEnabled(_ ids: Set<String>, _ on: Bool) {
        // a separator's toggle switches its whole group
        var all = Set(ids)
        if let p = try? kit.currentProfile() { for id in ids where kit.mod(id)?.isSeparator == true { all.formUnion(kit.groupMembers(of: id, in: p)) } }
        if !on, guardPlaythroughs(kit.pluginsLost(disabling: all), action: "Turn Off") == .cancelled { reload(); return }
        undoable("\(on ? "Enable" : "Disable") \(ModManagerModel.plural(all.count, "Mod"))") {
            guard var p = try? kit.currentProfile() else { return }
            for i in p.mods.indices where all.contains(p.mods[i].id) { p.mods[i].enabled = on }
            if on { ModManagerModel.addToProfile(&p, all.filter { id in !p.mods.contains { $0.id == id } }.sorted()) }
            do { try kit.saveProfile(p) } catch { message = "\(error)" }
        }
        reload()
    }

    func move(_ ids: Set<String>, before: String?) {
        undoable("Move \(ModManagerModel.plural(ids.count, "Mod"))") { run { try $0.moveMods(self.mods.map(\.id).filter { ids.contains($0) }, before: before) } }
    }

    func moveToTop(_ ids: Set<String>) { move(ids, before: mods.first { !ids.contains($0.id) }?.id) }

    func addSeparator(before: String?) {
        guard let name = ask("New separator", "Name", "") else { return }
        run { try $0.addSeparator(name, before: before) }
    }

    func renameSelected(_ id: String) {
        guard let m = kit.mod(id), let name = ask("Rename “\(m.name)”", "Name", m.name) else { return }
        run { try $0.renameMod(id, to: name) }
    }

    func editNotes(_ id: String) {
        guard let m = kit.mod(id), let notes = ask("Notes for “\(m.name)”", "Notes", m.notes, multiline: true) else { return }
        run { try $0.setNotes(id, notes) }
    }

    /// Nexus details (picture, summary, stats) for installed mods: cache first, refresh weekly in the background.
    func loadNexusDetailsIfNeeded() {
        guard !nexusDetailsLoaded else { return }
        nexusDetailsLoaded = true
        nexusDetails = kit.cachedNexusDetails()
        let k = kit, c = client(), hasKey = nexusKeyStored
        Task.detached {
            let d = await k.refreshNexusDetails { try await c.modDetails(modIDs: $0) }
            let e = hasKey ? ((try? await c.endorsements()) ?? [:]) : [:]
            let t = hasKey ? ((try? await c.trackedMods()) ?? []) : []
            await MainActor.run { self.nexusDetails = d; self.endorsed = e; self.tracked = t }
        }
    }

    func setTracked(_ modID: Int, _ on: Bool) {
        guard nexusKeyStored else { message = "Add your Nexus Mods API key first (Downloads)."; return }
        let c = client()
        Task {
            do { try await c.setTracked(modID: modID, on); if on { tracked.insert(modID) } else { tracked.remove(modID) } }
            catch { message = "Nexus: \(error)" }
        }
    }

    func endorse(_ modID: Int, version: String) {
        guard nexusKeyStored else { message = "Add your Nexus Mods API key first (Downloads)."; return }
        let c = client()
        Task {
            do { try await c.endorse(modID: modID, version: version); endorsed[modID] = "Endorsed"; message = "Endorsed — thank you, the author sees it." }
            catch NexusError.http(let code, let msg) where code == 403 { message = "Nexus: \(msg.isEmpty ? "endorsing needs the mod downloaded with this account first" : msg)" }
            catch { message = "Nexus: \(error)" }
        }
    }

    func editCategory(_ ids: Set<String>) {
        let current = mods.first { ids.contains($0.id) }?.category ?? ""
        guard let c = ask(ids.count == 1 ? "Category" : "Category for \(ids.count) mods", "Category (empty = none)", current) else { return }
        let t = c.trimmingCharacters(in: .whitespacesAndNewlines)
        run { $0.setCategory(Array(ids), t.isEmpty ? nil : t) }
    }

    /// Fill empty categories from Nexus in the background (each mod tried once per session).
    func fillCategoriesIfNeeded() {
        let todo = kit.modsMissingCategory.filter { !categoryTried.contains($0.id) }
        guard !todo.isEmpty else { return }
        categoryTried.formUnion(todo.map(\.id))
        let k = kit, c = client()
        Task.detached {
            let n = (try? await k.fillCategories { try await c.categories(modIDs: $0) }) ?? 0
            if n > 0 { await MainActor.run { self.reload() } }
        }
    }

    func removeSelected(_ ids: Set<String>) {
        let names = mods.filter { ids.contains($0.id) }.map(\.name)
        guard !names.isEmpty else { return }
        let risk = guardPlaythroughs(kit.pluginsLost(disabling: ids), action: "Remove")
        if risk == .cancelled { return }
        if risk == .noRisk {
            let a = NSAlert(); a.messageText = names.count == 1 ? "Remove “\(names[0])”?" : "Remove \(names.count) mods?"
            a.informativeText = (names.count > 1 ? names.prefix(8).joined(separator: ", ") + (names.count > 8 ? "…" : "") + "\n\n" : "")
                + "Their files are removed from SkyrimMT (the downloaded archives stay). Deploy afterwards to take them out of the game. The profile's history keeps the old list."
            a.addButton(withTitle: "Remove"); a.addButton(withTitle: "Cancel")
            a.buttons.first?.hasDestructiveAction = true
            guard a.runModal() == .alertFirstButtonReturn else { return }
        }
        selectedIDs = []
        autoSnapshot("Before removing " + ModManagerModel.listNames(names), mods: Array(ids))
        run { try $0.removeMods(Array(ids)) }
    }

    func openNexus(_ id: Int) { NSWorkspace.shared.open(URL(string: "https://www.nexusmods.com/skyrimspecialedition/mods/\(id)")!) }

    /// Run a ModKit edit, report errors, reload.
    func run(_ f: (ModKit) throws -> Void) {
        do { try f(kit) } catch { message = "\(error)" }
        reload()
    }

    func ask(_ title: String, _ placeholder: String, _ value: String, multiline: Bool = false) -> String? {
        let a = NSAlert(); a.messageText = title
        if multiline {
            let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 120)); tv.string = value; tv.isRichText = false
            let sv = NSScrollView(frame: tv.frame); sv.documentView = tv; sv.hasVerticalScroller = true; sv.borderType = .bezelBorder
            a.accessoryView = sv
            a.addButton(withTitle: "Save"); a.addButton(withTitle: "Cancel")
            return a.runModal() == .alertFirstButtonReturn ? tv.string : nil
        }
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24)); field.stringValue = value; field.placeholderString = placeholder
        a.accessoryView = field; a.addButton(withTitle: "OK"); a.addButton(withTitle: "Cancel")
        a.window.initialFirstResponder = field
        guard a.runModal() == .alertFirstButtonReturn else { return nil }
        let v = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return v.isEmpty ? nil : v
    }
}

struct ModsPage: View {
    @ObservedObject var model: ModManagerModel

    var body: some View {
        HSplitView {
            list
                .safeAreaInset(edge: .top, spacing: 0) {
                    VStack(spacing: 0) { toolbar.padding(.top, 8); header; Divider() }.background(.bar)
                }
                .frame(minWidth: 640, maxHeight: .infinity)
            // no selection → the pane folds away (frame only: the list keeps its identity and scroll position)
            let open = !model.selectedIDs.isEmpty
            detail.frame(minWidth: open ? 250 : 0, idealWidth: open ? 300 : 0, maxWidth: open ? 420 : 0).opacity(open ? 1 : 0)
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            SearchField(prompt: "Search installed mods", text: $model.modSearch,
                        count: model.visibleMods.filter { !$0.separator }.count, total: model.mods.filter { !$0.separator }.count)
            if !model.categories.isEmpty {
                Picker("", selection: $model.modCategory) {
                    Text("All categories").tag("")
                    Divider()
                    ForEach(model.categories, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden().frame(width: 150).help("Show one Nexus category")
            }
            Picker("", selection: $model.modFilter) { ForEach(ModFilter.allCases) { Text($0.rawValue).tag($0) } }
                .labelsHidden().frame(width: 150).help("Show only some mods")
            let free = model.updatableByHand
            if !free.isEmpty {
                Button { model.updateMods(free) } label: { Label("Update all (\(free.count))", systemImage: "arrow.up.circle") }
                    .disabled(model.busy != nil)
                    .help("Updates all mods you installed yourself, keeping their position and installer choices. Collection mods stay at their pinned versions.")
            }
            Button { model.addSeparator(before: model.selectedIDs.first) } label: { Image(systemName: "rectangle.split.1x2") }.accessibilityLabel("Add a separator")
                .help("Add a separator (group) above the selected mod")
        }
        .padding(.trailing, 10)
    }

    private func col(_ title: String, _ key: ModSort, width: CGFloat? = nil, align: Alignment = .leading) -> some View {
        Button { model.sortBy(key) } label: {
            HStack(spacing: 3) {
                Text(title)
                if model.modSort == key { Image(systemName: model.modSortAscending ? "chevron.up" : "chevron.down").font(.system(size: 8, weight: .bold)) }
            }
            .frame(maxWidth: width == nil ? .infinity : width, alignment: align)
        }
        .buttonStyle(.plain).font(.caption.weight(.semibold)).foregroundStyle(model.modSort == key ? .primary : .secondary)
        .frame(width: width, alignment: align)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Color.clear.frame(width: 18, height: 1)   // checkbox column (a bare Color would take all the height)
            col("#", .priority, width: 34, align: .trailing)
            col("Mod", .name).frame(minWidth: 180)
            col("Version", .version, width: 62)
            if model.showCategoryColumn { col("Category", .category, width: 92) }
            col("Conflicts", .conflicts, width: 64, align: .trailing)
            col("Files", .files, width: 44, align: .trailing)
            col("Added", .installed, width: 52, align: .trailing)
        }
        .padding(.leading, 12).padding(.trailing, 18).padding(.vertical, 4)
    }

    private var list: some View {
        let rows = model.visibleMods
        return List(selection: Binding(get: { model.selectedIDs }, set: { model.selectedIDs = $0; model.refreshDetail() })) {
            ForEach(rows) { r in
                (r.separator ? AnyView(separatorRow(r)) : AnyView(modRow(r)))
                    .tag(r.id)
                    .contextMenu { menu(for: r) }
            }
            .onMove(perform: model.modsFiltered ? nil : { model.moveVisible($0, $1) })
        }
        .overlay {
            if model.mods.isEmpty {
                ScrollView { GetStartedView(model: model).frame(maxWidth: .infinity) }.background(.background)
            } else if rows.isEmpty {
                Text("No mod matches.").foregroundStyle(.secondary)
            }
        }
        .onDeleteCommand { model.removeSelected(model.selectedIDs) }
    }

    private func modRow(_ r: ModRow) -> some View {
        HStack(spacing: 8) {
            Toggle("", isOn: Binding(get: { r.enabled }, set: { model.setEnabled(model.selectedIDs.contains(r.id) ? model.selectedIDs : [r.id], $0) }))
                .labelsHidden().toggleStyle(.checkbox).frame(width: 18)
            Text(r.inProfile ? "\(r.priority + 1)" : "–").font(.caption.monospacedDigit()).foregroundStyle(.tertiary).frame(width: 34, alignment: .trailing)
            HStack(spacing: 5) {
                if let c = ModManagerModel.tagColor(r.color) { Circle().fill(c).frame(width: 8, height: 8) }
                Text(r.name).lineLimit(1).truncationMode(.middle).foregroundStyle(r.enabled ? .primary : .secondary)
                if !r.notes.isEmpty { Image(systemName: "note.text").font(.caption).foregroundStyle(.secondary).help(r.notes) }
                if let u = model.updates[r.id] {
                    Button { model.updateMods([r.id]) } label: { Image(systemName: "arrow.up.circle.fill").foregroundStyle(r.collection.isEmpty ? .green : .secondary) }.accessibilityLabel("Update \(r.name)")
                        .buttonStyle(.plain)
                        .help((r.collection.isEmpty ? "Update available: " : "Newer on Nexus (\(r.collection) pins this version): ") + ModManagerModel.versionText(u) + ". Click to update in place.")
                }
                if r.plugins > 0 { Text("\(r.plugins)P").font(.caption2.weight(.semibold)).foregroundStyle(.secondary).help("\(r.plugins) plugin\(r.plugins == 1 ? "" : "s")") }
                if !r.inProfile { Text("not in this profile").font(.caption2).foregroundStyle(.tertiary).help("Installed for another profile. Enable it to add it here.") }
            }
            .frame(minWidth: 180, maxWidth: .infinity, alignment: .leading)
            Text(r.version).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail).frame(width: 62, alignment: .leading)
            if model.showCategoryColumn {
                Text(r.category).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail).frame(width: 92, alignment: .leading).help(r.category)
            }
            HStack(spacing: 3) {
                if r.enabled && r.wins > 0 { Text("+\(r.wins)").foregroundStyle(.green).help("Overrides \(r.wins) files of mods above it") }
                if r.enabled && r.loses > 0 { Text("−\(r.loses)").foregroundStyle(.orange).help("\(r.loses) files overridden by mods below it") }
            }
            .font(.caption.monospacedDigit()).frame(width: 64, alignment: .trailing)
            Text("\(r.files)").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 44, alignment: .trailing)
            Text(r.installed == .distantPast ? "" : r.installed.formatted(.dateTime.day().month(.abbreviated)))
                .font(.caption).foregroundStyle(.secondary).lineLimit(1).frame(width: 52, alignment: .trailing)
        }
    }

    private func separatorRow(_ r: ModRow) -> some View {
        let g = model.groupSize(r.id)
        return HStack(spacing: 8) {
            Button { model.toggleCollapsed(r.id) } label: {
                Image(systemName: model.collapsedGroups.contains(r.id) ? "chevron.right" : "chevron.down").frame(width: 14)
            }.buttonStyle(.plain)
            Toggle("", isOn: Binding(get: { g.all > 0 && g.enabled == g.all }, set: { model.setEnabled([r.id], $0) }))
                .labelsHidden().toggleStyle(.checkbox).help("Enable or disable the whole group")
            Text(r.name).font(.headline)
            Text("\(g.enabled) of \(g.all)").font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.vertical, 2)
        .listRowBackground((ModManagerModel.tagColor(r.color) ?? Color.accentColor).opacity(0.12))
    }

    @ViewBuilder private func menu(for r: ModRow) -> some View {
        let ids = model.selectedIDs.contains(r.id) ? model.selectedIDs : [r.id]
        Button("Enable") { model.setEnabled(ids, true) }
        Button("Disable") { model.setEnabled(ids, false) }
        Divider()
        if ids.count == 1 {
            Button(r.separator ? "Rename separator…" : "Rename…") { model.renameSelected(r.id) }
            if !r.separator { Button("Notes…") { model.editNotes(r.id) } }
        }
        if !r.separator { Button(ids.count > 1 ? "Set category for \(ids.count) mods…" : "Category…") { model.editCategory(ids) } }
        Menu("Move to") {
            Button("Top (lowest priority)") { model.moveToTop(ids) }
            Button("Bottom (wins conflicts)") { model.move(ids, before: nil) }
            let seps = model.mods.filter { $0.separator && !ids.contains($0.id) }
            if !seps.isEmpty {
                Divider()
                ForEach(seps) { s in Button("Group “\(s.name)”") { model.move(ids, before: model.mods.drop { $0.id != s.id }.dropFirst().first { $0.separator }?.id) } }
            }
        }
        Menu("Colour") {
            ForEach(ModManagerModel.tagColors, id: \.0) { name, c in
                Button { model.run { $0.setColor(Array(ids), name) } } label: { Label(name.capitalized, systemImage: "circle.fill").foregroundStyle(c) }
            }
            Divider()
            Button("None") { model.run { $0.setColor(Array(ids), nil) } }
        }
        Button("Add separator above…") { model.addSeparator(before: r.id) }
        Divider()
        let ups = model.mods.map(\.id).filter { ids.contains($0) && model.updates[$0] != nil }   // list order
        if !ups.isEmpty {
            Button(ups.count == 1 ? "Update to \(model.updates[ups[0]]!.newVersion)" : "Update \(ups.count) mods") { model.updateMods(ups) }
            Divider()
        }
        if !r.separator && ids.count == 1 {
            Button(model.kit.mod(r.id)?.installChoices != nil ? "Change installer options…" : "Reinstall") { model.reinstall(r.id) }
        }
        if !r.separator {
            Button("Show files in Finder") { model.openFolder(r.id) }
            if let n = r.nexusID { Button("Open on Nexus Mods") { model.openNexus(n) } }
        }
        Button(ids.count > 1 ? "Remove \(ids.count) mods…" : (r.separator ? "Remove separator" : "Remove…")) { model.removeSelected(ids) }
    }

    @ViewBuilder private var detail: some View {
        if model.selectedIDs.count > 1 {
            BulkPanel(model: model)
        } else if let id = model.selected, let m = model.mods.first(where: { $0.id == id }), !m.separator {
            ModDetail(model: model, row: m)
        } else {
            VStack(spacing: 6) {
                Text("Select a mod").foregroundStyle(.secondary)
                Text("⌘-click or ⇧-click selects several.").font(.caption).foregroundStyle(.tertiary)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct BulkPanel: View {
    @ObservedObject var model: ModManagerModel
    var body: some View {
        let ids = model.selectedIDs
        VStack(alignment: .leading, spacing: 10) {
            Text("\(ids.count) mods selected").font(.title3.bold())
            HStack { Button("Enable") { model.setEnabled(ids, true) }; Button("Disable") { model.setEnabled(ids, false) } }
            HStack { Button("Move to top") { model.moveToTop(ids) }; Button("Move to bottom") { model.move(ids, before: nil) } }
            Button("Set category…") { model.editCategory(ids) }
            Button("Remove \(ids.count) mods…", role: .destructive) { model.removeSelected(ids) }
            Spacer()
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One mod: summary, per-file conflicts, its files (hide/show), notes.
struct ModDetail: View {
    @ObservedObject var model: ModManagerModel
    let row: ModRow

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(row.name).font(.title3.bold()).lineLimit(2)
            Text("Priority \(row.priority + 1) of \(model.mods.count) — lower in the list wins conflicts."
                 + (row.version.isEmpty ? "" : " Version \(row.version).") + (row.collection.isEmpty ? "" : " From \(row.collection)."))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let u = model.updates[row.id] {
                HStack {
                    Image(systemName: "arrow.up.circle.fill").foregroundStyle(.green)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(u.newVersion == u.currentVersion || u.newVersion.isEmpty ? "A newer file is available" : "Version \(u.newVersion) is available").font(.callout)
                        if !row.collection.isEmpty { Text("\(row.collection) pins this version — updating can break the collection.").font(.caption).foregroundStyle(.secondary) }
                    }
                    Spacer()
                    Button("Update") { model.updateMods([row.id]) }.disabled(model.busy != nil)
                }
                .padding(8).background(Color.green.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
            }
            if let n = row.nexusID, let d = model.nexusDetails[n] { NexusCard(model: model, d: d) }
            HStack {
                Button("Show files") { model.openFolder(row.id) }
                if let n = row.nexusID { Button("Nexus page") { model.openNexus(n) } }
                Button("Notes…") { model.editNotes(row.id) }
                if model.kit.mod(row.id)?.installChoices != nil { Button("Installer options…") { model.reinstall(row.id) } }
            }.controlSize(.small)
            if !row.notes.isEmpty { Text(row.notes).font(.callout).padding(6).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary, in: RoundedRectangle(cornerRadius: 6)) }
            Picker("", selection: $model.detailTab) { Text("Conflicts").tag(0); Text("Files").tag(1) }.pickerStyle(.segmented).labelsHidden()
            if model.detailTab == 0 { conflicts } else { files }
        }
        .padding(14)
        .task(id: row.id) { model.loadFileDetail(row.id) }
    }

    private var conflicts: some View {
        let c = model.fileDetail
        let name = { (id: String) in model.mods.first { $0.id == id }?.name ?? id }
        return List {
            if c.wins.isEmpty && c.loses.isEmpty { Text("No conflicts with other enabled mods.").foregroundStyle(.secondary) }
            if !c.wins.isEmpty {
                Section("Wins \(c.wins.count) files") {
                    ForEach(c.wins) { f in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(f.rel).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                            Text("over " + f.losers.map(name).joined(separator: ", ")).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
            }
            if !c.loses.isEmpty {
                Section("Loses \(c.loses.count) files") {
                    ForEach(c.loses) { f in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(f.rel).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                            Text("to " + name(f.winner)).font(.caption2).foregroundStyle(.orange).lineLimit(1)
                        }
                    }
                }
            }
        }
    }

    private var files: some View {
        VStack(alignment: .leading, spacing: 4) {
            SearchField(prompt: "Filter files", text: $model.fileFilter, count: model.fileList.filter { ModManagerModel.matches($0, model.fileFilter) }.count, total: model.fileList.count)
            List(model.fileList.filter { ModManagerModel.matches($0, model.fileFilter) }, id: \.self) { f in
                let hidden = f.hasSuffix(".mohidden")
                HStack {
                    Text(hidden ? String(f.dropLast(9)) : f).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                        .strikethrough(hidden).foregroundStyle(hidden ? .secondary : .primary)
                    Spacer()
                    Button(hidden ? "Show" : "Hide") { model.setFileHidden(row.id, f, !hidden) }.controlSize(.small)
                        .help(hidden ? "Deploy this file again" : "Leave this file out of the game (kept in the mod)")
                }
            }
            Text("Hidden files are skipped when deploying (.mohidden, as in Mod Organizer).").font(.caption2).foregroundStyle(.secondary)
        }
    }
}

/// Picture, summary and numbers from Nexus Mods (adult pictures blurred unless the player chose otherwise).
struct NexusCard: View {
    @ObservedObject var model: ModManagerModel
    let d: NexusModDetails
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            let blur = d.adult && !model.showAdultPictures
            if let s = (blur ? d.pictureBlurred : d.picture) ?? d.picture, let u = URL(string: s) {
                AsyncImage(url: u) { img in img.resizable().aspectRatio(contentMode: .fill) } placeholder: { Color.secondary.opacity(0.1) }
                    .frame(maxWidth: .infinity).frame(height: 130).clipped().clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(alignment: .bottomTrailing) {
                        if d.adult {
                            Button(blur ? "Show picture" : "Hide") { model.showAdultPictures.toggle(); UserDefaults.standard.set(model.showAdultPictures, forKey: "showAdultPictures") }
                                .controlSize(.small).padding(4)
                        }
                    }
            }
            if !d.summary.isEmpty { Text(d.summary).font(.callout).fixedSize(horizontal: false, vertical: true).textSelection(.enabled) }
            HStack(spacing: 12) {
                if !d.author.isEmpty { Label(d.author, systemImage: "person").lineLimit(1).truncationMode(.tail).help(d.author) }
                Label(d.endorsements.formatted(.number.notation(.compactName)), systemImage: "hand.thumbsup")
                Label(d.downloads.formatted(.number.notation(.compactName)), systemImage: "arrow.down.circle")
            }
            .font(.caption).foregroundStyle(.secondary)
            HStack {
                if model.endorsed[d.modID] == "Endorsed" { Label("You endorsed this mod", systemImage: "hand.thumbsup.fill").font(.caption).foregroundStyle(.green) }
                else { Button { model.endorse(d.modID, version: d.version) } label: { Label("Endorse", systemImage: "hand.thumbsup") }.controlSize(.small).help("Say thanks to the author on Nexus Mods") }
                let t = model.tracked.contains(d.modID)
                Button { model.setTracked(d.modID, !t) } label: { Label(t ? "Tracking" : "Track", systemImage: t ? "bell.fill" : "bell") }
                    .controlSize(.small).help(t ? "Stop tracking on Nexus Mods" : "Nexus Mods tells you when this mod is updated")
                Button { model.installFromNexus(modID: d.modID, name: d.name) } label: { Label("Install another file…", systemImage: "square.and.arrow.down.on.square") }
                    .controlSize(.small).help("Other files of this mod on Nexus: main file, options, patches, updates")
            }
        }
    }
}
