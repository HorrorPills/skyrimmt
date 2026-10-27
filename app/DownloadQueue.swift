// Download queue (docs/MODMANAGER.md §3D): every download SkyrimMT runs — nxm links, updates, requirements — with
// progress, speed and Cancel. Cancel keeps the partial file; the next attempt resumes it (HTTP Range).
import SwiftUI

struct DownloadJob: Identifiable, Equatable {
    enum State: Equatable { case running, done, failed(String), cancelled }
    let id = UUID()
    var name: String
    var received: Int64 = 0
    var total: Int64?
    var speed: Double = 0            // bytes per second (smoothed)
    var state: State = .running
    let started = Date()
    var lastTick = Date()
    var lastBytes: Int64 = 0
}

extension ModManagerModel {
    /// Register a download; returns its id. `task` (if given) is cancelled by the Cancel button.
    func beginDownload(_ name: String) -> UUID {
        let j = DownloadJob(name: name)
        downloadJobs.insert(j, at: 0)
        if downloadJobs.count > 40 { downloadJobs.removeLast(downloadJobs.count - 40) }
        return j.id
    }

    func downloadProgress(_ id: UUID, _ got: Int64, _ total: Int64?) {
        guard let i = downloadJobs.firstIndex(where: { $0.id == id }) else { return }
        var j = downloadJobs[i]
        let now = Date(), dt = now.timeIntervalSince(j.lastTick)
        if dt >= 0.5 {
            let inst = Double(got - j.lastBytes) / dt
            j.speed = j.speed == 0 ? inst : j.speed * 0.6 + inst * 0.4
            j.lastTick = now; j.lastBytes = got
        }
        j.received = got; j.total = total
        downloadJobs[i] = j
    }

    func endDownload(_ id: UUID, error: Error? = nil) {
        guard let i = downloadJobs.firstIndex(where: { $0.id == id }) else { return }
        if error is CancellationError || (error as? URLError)?.code == .cancelled { downloadJobs[i].state = .cancelled }
        else if let e = error { downloadJobs[i].state = .failed("\(e)") }
        else { downloadJobs[i].state = .done }
        downloadTasks[id] = nil
    }

    func cancelDownload(_ id: UUID) { downloadTasks[id]?.cancel() }
}

struct DownloadQueueView: View {
    @ObservedObject var model: ModManagerModel
    var body: some View {
        let jobs = model.downloadJobs
        if !jobs.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Downloads in this session").font(.headline)
                    Spacer()
                    if jobs.contains(where: { $0.state != .running }) {
                        Button("Clear finished") { model.downloadJobs.removeAll { $0.state != .running } }.controlSize(.small)
                    }
                }
                ForEach(jobs) { j in row(j) }
            }
            .padding(10)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 10)
        }
    }

    /// "12 MB of 40 MB · 3 MB/s · 9 s left" (its own function: inline, older Swift compilers time out type-checking it)
    private func progressLine(_ j: DownloadJob, _ fmt: (Int64) -> String) -> String {
        var s = fmt(j.received)
        if let t = j.total { s += " of " + fmt(t) }
        if j.speed > 0 {
            s += " · \(fmt(Int64(j.speed)))/s"
            if let t = j.total { s += " · \(Int(Double(t - j.received) / j.speed)) s left" }
        }
        return s
    }

    private func row(_ j: DownloadJob) -> some View {
        let fmt = { (b: Int64) in ByteCountFormatter.string(fromByteCount: b, countStyle: .file) }
        return HStack(spacing: 10) {
            Group {
                switch j.state {
                case .running: ProgressView().controlSize(.small)
                case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                case .cancelled: Image(systemName: "pause.circle.fill").foregroundStyle(.secondary)
                }
            }.frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(j.name).lineLimit(1)
                if j.state == .running {
                    if let t = j.total, t > 0 { ProgressView(value: Double(j.received), total: Double(t)) }
                    Text(progressLine(j, fmt)).font(.caption).foregroundStyle(.secondary)
                } else if case .failed(let e) = j.state {
                    Text(e).font(.caption).foregroundStyle(.red).lineLimit(2)
                } else if j.state == .cancelled {
                    Text("Stopped — downloading it again continues where it left off.").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(fmt(j.received)).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if j.state == .running && model.downloadTasks[j.id] != nil {
                Button("Cancel") { model.cancelDownload(j.id) }.controlSize(.small)
            }
        }
    }
}
