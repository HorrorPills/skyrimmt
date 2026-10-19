// Activity centre (docs/MODMANAGER.md §3I): every job the Mod Manager ran in this session — when, how long, how it
// ended — from the status-bar clock. Also appended to $SKYRIM_HOME/logs/activity.log for support.
import SwiftUI
import AppKit

struct ActivityEntry: Identifiable {
    let id = UUID()
    var title: String
    var lastStep: String
    let started: Date
    var ended: Date?
    var result: String?
    var failed: Bool {
        guard let r = result?.lowercased() else { return false }
        return ["couldn't", "could not", "failed", "error", "not found", "refused"].contains { r.contains($0) }
    }
}

extension ModManagerModel {
    func trackBusy(_ old: String?) {
        switch (old, busy) {
        case (nil, let b?):
            activity.append(ActivityEntry(title: b, lastStep: b, started: Date()))
        case (_?, let b?):
            if let i = activity.indices.last, activity[i].ended == nil { activity[i].lastStep = b }
        case (_?, nil):
            if let i = activity.indices.last, activity[i].ended == nil { activity[i].ended = Date(); log(activity[i]) }
        default: break
        }
        if activity.count > 300 { activity.removeFirst(activity.count - 300) }
    }

    /// A message right after a job finished is its result; otherwise it's a one-off entry.
    func trackMessage(_ m: String) {
        if let i = activity.indices.last, let e = activity[i].ended, activity[i].result == nil, Date().timeIntervalSince(e) < 3 {
            activity[i].result = m; log(activity[i])
        } else if busy == nil {
            var e = ActivityEntry(title: m, lastStep: m, started: Date()); e.ended = e.started; e.result = m
            activity.append(e); log(e)
        }
    }

    private func log(_ e: ActivityEntry) {
        let dir = kit.home.appendingPathComponent("logs"), url = dir.appendingPathComponent("activity.log")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let line = "\(ISO8601DateFormatter().string(from: e.started))\t\(String(format: "%.1f", (e.ended ?? Date()).timeIntervalSince(e.started)))s\t\(e.title)\t\(e.result ?? "")\n"
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close() }
        else { try? line.write(to: url, atomically: true, encoding: .utf8) }
    }
}

struct ActivityView: View {
    @ObservedObject var model: ModManagerModel
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Activity").font(.headline)
                Spacer()
                Button("Show log file") { NSWorkspace.shared.activateFileViewerSelecting([model.kit.home.appendingPathComponent("logs/activity.log")]) }
                    .controlSize(.small)
            }
            if model.activity.isEmpty {
                Text("Nothing yet in this session.").foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 80)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(model.activity.reversed()) { e in
                            HStack(alignment: .top, spacing: 8) {
                                Group {
                                    if e.ended == nil { ProgressView().controlSize(.small) }
                                    else { Image(systemName: e.failed ? "xmark.circle.fill" : "checkmark.circle.fill").foregroundStyle(e.failed ? .red : .green) }
                                }.frame(width: 16)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(e.ended == nil ? e.lastStep : e.title).lineLimit(2)
                                    if let r = e.result, r != e.title { Text(r).font(.caption).foregroundStyle(e.failed ? .red : .secondary).fixedSize(horizontal: false, vertical: true).textSelection(.enabled) }
                                    Text(e.started.formatted(date: .omitted, time: .shortened) + (e.ended.map { let d = $0.timeIntervalSince(e.started); return d >= 1 ? " · \(Int(d.rounded())) s" : "" } ?? " · running"))
                                        .font(.caption2).foregroundStyle(.tertiary)
                                }
                            }
                        }
                    }
                }
            }
        }
        .padding(12).frame(width: 420, height: 360)
    }
}
