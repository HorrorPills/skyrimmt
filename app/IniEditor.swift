// Game settings editor (Skyrim.ini / SkyrimPrefs.ini / SkyrimCustom.ini) for any profile — the right file wherever
// the profile's settings live right now (ModKit.iniURL). Saved in Windows-1252 with CRLF, like Skyrim expects.
import SwiftUI
import AppKit

final class IniEditorState: ObservableObject, Identifiable {
    let id = UUID()
    let profile: String
    @Published var file = "SkyrimCustom.ini"
    @Published var text = ""
    @Published var original = ""
    init(profile: String) { self.profile = profile }
}

struct IniEditorView: View {
    @ObservedObject var state: IniEditorState
    let kit: ModKit
    let done: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(localizedFormat("Game settings — %@", state.profile)).font(.headline)
                Spacer()
                Picker("", selection: $state.file) { ForEach(ModKit.gameININames, id: \.self) { Text($0).tag($0) } }
                    .pickerStyle(.segmented).frame(width: 380).onChange(of: state.file) { _ in load() }
            }
            let description = state.file == "SkyrimCustom.ini" ? "Your own overrides — the safest place for changes (the game never rewrites it)."
                : state.file == "SkyrimPrefs.ini" ? "The game rewrites this on exit (graphics menu settings)." : "Base settings; mods' guides often ask for changes here."
            Text(localized(description))
                .font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $state.text).font(.system(.callout, design: .monospaced)).frame(minHeight: 360)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(.quaternary))
            HStack {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([kit.iniURL(profile: state.profile, file: state.file)]) }
                Spacer()
                Button("Cancel") { done() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    try? kit.writeINI(profile: state.profile, file: state.file, text: state.text); state.original = state.text
                }.disabled(state.text == state.original)
                Button("Save & Close") { try? kit.writeINI(profile: state.profile, file: state.file, text: state.text); done() }
                    .keyboardShortcut(.defaultAction).disabled(state.text == state.original)
            }
        }
        .padding(16).frame(width: 760)
        .onAppear { load() }
    }
    private func load() { state.text = kit.readINI(profile: state.profile, file: state.file); state.original = state.text }
}
