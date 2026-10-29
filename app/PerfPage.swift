// Mod Manager → Performance (ModKit/Perf.swift): what each mod costs in frame time, measured with the unattended
// benchmark (tools/bench/bench.sh) — the profile as it is, then once without each chosen mod.
import SwiftUI
import AppKit

extension ModManagerModel {
    func loadPerf() {
        let k = kit
        Task.detached {
            let save = k.benchSave().flatMap { try? SaveReader.read($0) }
            let c = (try? k.perfCandidates(limit: 30, save: save)) ?? []
            let r = k.perfReport()
            await MainActor.run {
                self.perfCandidates = c; self.perfReportShown = r; self.perfHasSave = save != nil
                if self.perfSelected.isEmpty || !self.perfSelected.isSubset(of: Set(c.map(\.modID))) { self.perfSelected = Set(c.prefix(6).map(\.modID)) }
            }
        }
    }

    /// ~3 minutes per run: full, one per mod, full again.
    var perfMinutes: Int { (perfSelected.count + 2) * 3 }

    func runPerf() {
        guard !gameRunning() else { message = localized("Quit Skyrim first."); return }
        guard perfHasSave else { message = localizedFormat("The benchmark needs the save “%@” (see below).", ModKit.benchSaveName); return }
        let chosen = perfCandidates.filter { perfSelected.contains($0.modID) }
        guard !chosen.isEmpty else { return }
        let a = NSAlert()
        a.messageText = localizedFormat(chosen.count == 1 ? "Measure %ld mod? About %ld minutes." : "Measure %ld mods? About %ld minutes.", chosen.count, perfMinutes)
        a.informativeText = localizedFormat("Skyrim is started %ld times with “%@” and controlled by keyboard and mouse input. Do not use the Mac until it finishes, and keep the display awake. Your profile is restored afterwards.", chosen.count + 2, ModKit.benchSaveName)
        a.addButton(withTitle: localized("Start")); a.addButton(withTitle: localized("Cancel"))
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let k = kit
        let out = URL(fileURLWithPath: Paths.game).appendingPathComponent("cache/perf")
        let bench = Paths.repo + "/tools/bench/bench.sh"
        busy = localized("Measuring performance…")
        Task.detached {
            // a profile with its own saves folder: the bench save is copied in for the test
            let saveDst = k.activeSavesFolder.appendingPathComponent(ModKit.benchSaveName + ".ess")
            var copied = false
            if let src = k.benchSave(), src.path != saveDst.path { copied = (try? FileManager.default.copyItem(at: src, to: saveDst)) != nil }
            defer { if copied { try? FileManager.default.removeItem(at: saveDst) } }
            do {
                let report = try k.runPerfTest(chosen, measure: { label in
                    let r = SessionRunner.runSync([bench, "perf-\(label)", ModKit.benchSaveName, "2"], env: scriptEnv(["SKYRIMMT_BENCH_OUT": out.path], removing: ["MTL_HUD_ENABLED"]))
                    let dir = out.appendingPathComponent("perf-\(label)")
                    guard r.status == 0 else {
                        throw PerfError.measurement(r.status == 3 ? "the display slept or locked during a run" : "benchmark failed: " + (r.output.split(separator: "\n").last.map(String.init) ?? "see \(dir.path)"))
                    }
                    return try FrameTrace.sample(csv: dir.appendingPathComponent("frames.csv"), marks: dir.appendingPathComponent("marks.txt"))
                }, progress: { text in Task { @MainActor in self.busy = text } })
                await MainActor.run {
                    self.busy = nil; self.perfReportShown = report
                    self.message = localized("Measurement complete.") + (report.results.first.map { localizedFormat(" Highest cost: %@ (%.1f ms per frame).", $0.candidate.name, $0.costMs) } ?? "")
                    self.reload()
                }
            } catch { await MainActor.run { self.busy = nil; self.message = localizedFormat("Performance test stopped: %@. Your profile was restored.", "\(error)"); self.reload() } }
        }
    }
}

struct PerfPage: View {
    @ObservedObject var model: ModManagerModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Measures the frame-time cost of each selected mod by benchmarking the same scene with and without it. Dependent mods are disabled with it. Your profile is restored afterwards.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let r = model.perfReportShown { reportView(r) }
                Text("Mods to measure").font(.headline)
                if !model.perfHasSave {
                    Label(localizedFormat("Requires a save named “%@” made outdoors without mods. Start a new game with mods disabled, go outside, open the console (~) and enter: save %@", ModKit.benchSaveName, ModKit.benchSaveName), systemImage: "info.circle")
                        .font(.callout).fixedSize(horizontal: false, vertical: true)
                }
                if model.perfCandidates.isEmpty {
                    Text("No measurable mods in this profile.").foregroundStyle(.secondary)
                }
                ForEach(model.perfCandidates) { c in
                    Toggle(isOn: Binding(get: { model.perfSelected.contains(c.modID) },
                                         set: { if $0 { model.perfSelected.insert(c.modID) } else { model.perfSelected.remove(c.modID) } })) {
                        HStack {
                            Text(c.name)
                            Text(ByteCountFormatter.string(fromByteCount: c.assetBytes, countStyle: .file)).font(.caption).foregroundStyle(.secondary)
                            if !c.together.isEmpty { Text(localizedFormat("+ %ld dependent", c.together.count)).font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                }
                HStack {
                    Button(localizedFormat(model.perfSelected.count == 1 ? "Measure %ld mod (about %ld min)" : "Measure %ld mods (about %ld min)", model.perfSelected.count, model.perfMinutes)) { model.runPerf() }
                        .disabled(model.busy != nil || model.perfSelected.isEmpty || !model.perfHasSave)
                    Spacer()
                }
                Text("Results apply to the benchmark location and your current settings. Differences below the noise level are shown as no measurable cost.")
                    .font(.caption).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { model.loadPerf() }
    }

    @ViewBuilder private func reportView(_ r: PerfReport) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(localizedFormat("Last measurement — %@, %@", r.profile, r.date.formatted(date: .abbreviated, time: .shortened))).font(.headline)
            Text(localizedFormat("Whole setup: %.0f FPS (%.2f ms per frame) · noise ±%.2f ms", r.baseline.fps, r.baseline.meanMs, r.noiseMs))
                .font(.callout).foregroundStyle(.secondary)
            let worst = max(r.results.map(\.costMs).max() ?? 1, 0.01)
            ForEach(r.results) { x in
                HStack(spacing: 8) {
                    Text(x.candidate.name).frame(width: 260, alignment: .leading).lineLimit(1)
                    GeometryReader { g in
                        RoundedRectangle(cornerRadius: 3).fill(x.costMs > r.noiseMs ? Color.orange : Color.secondary.opacity(0.4))
                            .frame(width: max(2, g.size.width * CGFloat(max(x.costMs, 0) / worst)))
                    }.frame(height: 10)
                    Text(x.costMs > r.noiseMs
                         ? localizedFormat("%.2f ms · +%.0f FPS without", x.costMs, x.without.fps - r.baseline.fps)
                         : localized("below noise"))
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 170, alignment: .trailing)
                }
            }
        }
        .padding(10).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }
}
