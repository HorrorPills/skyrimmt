// First run: three ways in, each one click from here (docs/MODMANAGER.md §3I "Onboarding"). Shown on the Mods page
// while the profile has no mods.
import SwiftUI
import AppKit

struct GetStartedView: View {
    @ObservedObject var model: ModManagerModel
    var body: some View {
        VStack(spacing: 18) {
            VStack(spacing: 4) {
                Text("Let's mod Skyrim").font(.largeTitle.bold())
                Text("Choose a starting point. Each setup lives in its own profile.")
                    .foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            HStack(alignment: .top, spacing: 14) {
                card("square.stack.3d.up.fill", .blue, "A ready-made collection",
                     "Curated, tested mod lists from Nexus Mods. Paste a link; SkyrimMT downloads, installs and sorts everything.",
                     need: model.nexusUser?.premium == true ? "Nexus Premium: fully automatic." : "Needs a Nexus API key. Free accounts confirm each download.",
                     button: "Browse collections") {
                    NSWorkspace.shared.open(URL(string: "https://www.nexusmods.com/games/skyrimspecialedition/collections")!)
                    model.section = .collections
                }
                card("shippingbox.and.arrow.backward.fill", .purple, "A Wabbajack list",
                     "Complete modpacks, installed exactly as their authors built them.",
                     need: "Requires Nexus Premium.", button: "Open the gallery") {
                    model.section = .wabbajack; model.loadGallery()
                }
                card("hammer.fill", .orange, "Build your own",
                     "Start with the essentials (SKSE, Address Library, SkyUI…), then add any mod from Nexus.",
                     need: "Free and Premium accounts.", button: "Show the essentials") {
                    model.section = .essentials
                }
            }
            Text("Coming from Mod Organizer 2? Import it on the Wabbajack page, including order, plugins and settings.")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(24).frame(maxWidth: 860)
    }

    private func card(_ icon: String, _ tint: Color, _ title: String, _ text: String, need: String, button: String, action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: icon).font(.system(size: 28)).foregroundStyle(tint)
            Text(localized(title)).font(.headline)
            Text(localized(text)).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Text(localized(need)).font(.caption).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            Button(localized(button), action: action).buttonStyle(.borderedProminent).tint(tint)
        }
        .padding(14).frame(maxWidth: .infinity, minHeight: 230, alignment: .topLeading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }
}
