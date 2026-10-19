// Essentials → Install all: SKSE, Address Library, Engine Fixes, Display Tweaks, Crash Logger and SkyUI in one step.
// Premium accounts download through the API; free accounts start each download on the opened file page (Nexus rule),
// SkyrimMT continues when the link arrives. The right file per mod comes from ModKit.essentialFiles.
import SwiftUI
import AppKit

extension ModManagerModel {
    var missingEssentials: [Essential] { essentials.filter { !kit.isInstalled($0) } }

    func installEssentials() {
        guard nexusKeyStored else { section = .downloads; message = "Add your Nexus Mods API key first (Downloads)."; return }
        guard !gameRunning() else { message = "Quit Skyrim first."; return }
        guard busy == nil else { return }
        let missing = missingEssentials
        guard !missing.isEmpty else { message = "All essentials are installed."; return }
        let premium = nexusUser?.premium ?? false
        if !premium && !isNxmHandler { becomeNxmHandler(); guard isNxmHandler else { return } }
        let c = client(), folder = kit.home.appendingPathComponent("downloads"), gv = gameVersion()
        busy = "Installing essentials…"
        colCancelled = false
        Task {
            var archives: [URL] = [], failed: [String] = []
            outer: for (i, e) in missing.enumerated() {
                do {
                    let files = ModKit.essentialFiles(e, from: try await c.files(e.nexusID), gameVersion: gv)
                    guard !files.isEmpty else { failed.append(e.name); continue }
                    for f in files {
                        let job = beginDownload("\(e.name) \(f.version)")
                        do {
                            let a: URL
                            if premium {
                                busy = "Downloading \(e.name) (\(i + 1)/\(missing.count))…"
                                a = try await NexusDownloader(client: c, folder: folder).downloadFile(
                                    modID: e.nexusID, fileID: f.fileID, fileName: f.fileName, md5: f.md5, size: f.sizeBytes,
                                    modName: e.name, version: f.version) { got, total in Task { @MainActor in self.downloadProgress(job, got, total) } }
                            } else {
                                busy = "Click “Slow download” for \(e.name) (\(i + 1)/\(missing.count)) on the page that opened"
                                NSWorkspace.shared.open(URL(string: "https://www.nexusmods.com/\(nexusGame)/mods/\(e.nexusID)?tab=files&file_id=\(f.fileID)&nmm=1")!)
                                let link = await withCheckedContinuation { (k: CheckedContinuation<NxmLink?, Never>) in nxmWaiters["\(e.nexusID):\(f.fileID)"] = k }
                                guard let link, !colCancelled else { endDownload(job); break outer }
                                busy = "Downloading \(e.name)…"
                                a = try await NexusDownloader(client: c, folder: folder).download(link) { got, total in Task { @MainActor in self.downloadProgress(job, got, total) } }
                            }
                            endDownload(job)
                            archives.append(a)
                        } catch { endDownload(job, error: error); throw error }
                    }
                } catch { failed.append(e.name) }
            }
            busy = nil
            if !failed.isEmpty { message = "Not installed: \(failed.joined(separator: ", ")). Use “Get on Nexus” for these." }
            guard !archives.isEmpty else { return }
            deployAfterInstall = true
            install(archives)
            reloadDownloads()
        }
    }
}
