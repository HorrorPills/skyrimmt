// Undo / Redo for profile edits (docs/MODMANAGER.md §3I): enable/disable, order, plugin order/active, sorts, locks.
// Uses the window's own UndoManager, so ⌘Z undoes typing inside a text field and mod changes everywhere else, with
// "Undo Disable 3 Mods"-style menu titles. Each step keeps the whole profile before and after (cheap: ids + order).
// Longer-term history (every saved version) stays in Profiles → History.
import SwiftUI

extension ModManagerModel {
    /// Run a profile edit; when it changed the profile, make it undoable.
    func undoable(_ name: String, _ body: () -> Void) {
        let before = try? kit.currentProfile()
        body()
        commitUndo(name, before: before)
    }

    /// For edits that finish later (LOOT sort): call with the profile captured before the change started.
    func commitUndo(_ name: String, before: Profile?) {
        guard let b = before, let after = try? kit.currentProfile(), after != b else { return }
        registerUndo(name, from: after, to: b)
    }

    private func registerUndo(_ name: String, from now: Profile, to target: Profile) {
        guard let um = undoManager else { return }
        um.registerUndo(withTarget: self) { m in
            m.applyProfileState(target)
            m.registerUndo(name, from: target, to: now)   // the matching redo
        }
        um.setActionName(name)
    }

    /// Put a profile state back: profile file, plugins.txt (load order) when it is the active one; deploy stays a click.
    func applyProfileState(_ p: Profile) {
        guard p.name == profile else { message = "That change belongs to profile “\(p.name)” — switch to it to undo."; return }
        do {
            let current = try kit.currentProfile()
            try kit.saveProfile(p)
            if current.loadOrder != p.loadOrder {
                var lo = kit.loadOrder(); lo.entries = p.loadOrder.filter { e in !lo.implicitSet.contains(e.name.lowercased()) }
                try lo.write(to: kit.pluginsTxt)
            }
        } catch { message = "\(error)" }
        reload()
    }

    static func plural(_ n: Int, _ one: String) -> String { n == 1 ? "1 \(one)" : "\(n) \(one)s" }
}

/// Hands the window's UndoManager to the model (SwiftUI only exposes it through the environment).
struct UndoManagerBridge: ViewModifier {
    @Environment(\.undoManager) private var undoManager
    let model: ModManagerModel
    func body(content: Content) -> some View {
        content.onAppear { model.undoManager = undoManager }.onChange(of: undoManager) { model.undoManager = $0 }
    }
}
