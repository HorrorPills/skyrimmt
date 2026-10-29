# Nexus download window regression checks

Issue: [#4](https://github.com/HorrorPills/skyrimmt/issues/4).

Build with `app/build.sh --no-install` on an Apple Silicon Mac. Run the built
app and use Downloads to register it as the handler for Nexus download links.
Use a test profile when checking actual downloads and installs.

The launcher uses SwiftUI's single-instance `Window` scene. Nexus links still
go through `AppDelegate.application(_:open:)` and the existing Mod Manager flow.

| Check | Expected result |
| --- | --- |
| Launch normally | One SkyrimMT launcher window opens. |
| With the launcher open, click Mod Manager Download on Nexus five times | Each link reaches the Mod Manager; there is still only one launcher and one Mod Manager window. |
| Close the Mod Manager, then open another Nexus download link | The Mod Manager reopens; no additional launcher appears. |
| Keep the Mod Manager open, close the launcher, then open another Nexus download link | The app stays running, the Mod Manager receives the link, and the launcher stays closed. |
| Switch to the browser and back to SkyrimMT several times | No additional windows appear. |
| Use Window > SkyrimMT repeatedly | The same launcher is shown each time. |
| Quit the app, then click a Nexus download link | The app launches, the link reaches the Mod Manager, and at most one launcher appears. |
| Download a mod and choose Install, then repeat and choose Later | Both existing download completion paths still work. |
| During a guided collection install, click a requested Nexus download link | The waiting install resumes without an extra launcher. |
| Close every app window | The app quits as before. |

Also check the `skyrim-rp://` browser login callback with Keizaal Online when
available; it must still reach `keizaal.sh` without spawning extra launchers.

These are manual macOS GUI checks. A successful build and the ModKit test suite
do not verify SwiftUI window creation or Launch Services URL delivery.
