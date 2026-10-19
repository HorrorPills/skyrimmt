// Crash detective (ModKit/CrashLogs.swift): Crash Logger SSE log parsing and suspect ranking. Synthetic logs in the
// real format (CrashLoggerSSE 1.15).
import Foundation

let crashLogWndproc = """
Skyrim SSE v1.6.1170
CrashLoggerSSE v1-15-0-0 Oct 12 2024 11:33:37

Unhandled exception "EXCEPTION_ACCESS_VIOLATION" at 0x0000FFFF002B
Exception Flags: 0x00000000

SYSTEM SPECS:
\tOS: Microsoft Windows 10 Pro v10.0.19043

PROBABLE CALL STACK:
\t[ 0] 0x0000FFFF002B                     
\t[ 1] 0x6FFFFF61977E           user32.dll+005977E
\t[ 2] 0x6FFFE5625263 CameraMod.dll+0095263\tmov rcx, [rsp+0x60] |  C:\\src\\Window.cpp:58 ?Handler@@
\t[ 3] 0x000140641606         SkyrimSE.exe+0641606 -> 36548+0x476\tmov dword ptr [rsp+0x20], 0x01
\t[ 4] 0x6FFFE5625263 OtherHook.dll+0001000
\t[ 5] 0x6FFFE5625263 CameraMod.dll+0095263

REGISTERS:
\tRAX 0xFFFF002B         (void*)

STACK:
\t[RSP+0  ] 0x6FFFFF61977E     (void* -> user32.dll+005977E\tmov r10, rax)

MODULES:
\tCameraMod.dll                    0x6FFFE5590000

SKSE PLUGINS:
\tCameraMod.dll

PLUGINS:
\t[ 0]     Skyrim.esm
"""

let crashLogHair = """
Skyrim SSE v1.6.1170
CrashLoggerSSE v1-15-0-0 Oct 12 2024 11:33:37

Unhandled exception "EXCEPTION_ACCESS_VIOLATION" at 0x000140CEC9C8 SkyrimSE.exe+0CEC9C8\tmov eax, [rax-0x08]

PROBABLE CALL STACK:
\t[ 0] 0x000140CEC9C8 SkyrimSE.exe+0CEC9C8 -> 69173+0x8\tmov eax, [rax-0x08]
\t[ 1] 0x0001404324C5 SkyrimSE.exe+04324C5 -> 26987+0xB5\tmov rcx, r14

REGISTERS:
\tRAX 0x1         (BSDynamicTriShape*)
\t\tName: "HairMaleTest03"
\t\tRTTIName: "BSDynamicTriShape"
\tRBX 0x2         (Character*)
\t\tFull Name: "Player"
\t\t\tFile: "StartMod.esp"
\t\t\tModified by: Skyrim.esm -> StartMod.esp -> PerspectiveMod.esp
\t\t\tFile: "PerspectiveMod.esp"
\t\t\tModified by: StartMod.esp -> PerspectiveMod.esp
\t\tName: "???"

STACK:
\t[RSP+8  ] 0x3  (NiNode*)
\t\tName: "meshes\\actors\\character\\hair\\testhair.nif"
"""

func crashLogTests() {
    section("crash detective")
    let u = URL(fileURLWithPath: "/tmp/crash-2026-10-18-09-00-18.log")
    let a = CrashLogParser.parse(crashLogWndproc, url: u, date: Date())!
    check(a.gameVersion == "1.6.1170" && a.exception == "EXCEPTION_ACCESS_VIOLATION", "header parsed (\(a.gameVersion), \(a.exception))")
    check(a.faultModule == "" && a.faultAddress == "0x0000FFFF002B", "jump to an address outside any module")
    check(a.stackModules == ["user32.dll", "CameraMod.dll", "SkyrimSE.exe", "OtherHook.dll"], "call stack modules in order, no duplicates (\(a.stackModules))")
    check(a.hints.contains { $0.contains("window") }, "Wine window-procedure handle recognised")
    check(a.summary.contains("CameraMod.dll"), "summary names the first mod DLL (\(a.summary))")
    let b = CrashLogParser.parse(crashLogHair, url: u, date: Date())!
    check(b.faultModule == "SkyrimSE.exe" && b.stackModules.allSatisfy(CrashLogParser.isSystem), "crash inside the game")
    check(b.plugins["PerspectiveMod.esp"] == 3 && b.plugins["StartMod.esp"] == 3 && b.plugins["Skyrim.esm"] == nil, "File/Modified by counted, base game left out (\(b.plugins))")
    check(b.objects.prefix(2) == ["HairMaleTest03", "Player"] && !b.objects.contains("???"), "objects in use (\(b.objects))")
    check(b.meshes.count == 1 && b.hints.contains { $0.contains("hair") }, "hair mesh noticed (\(b.meshes))")
    check(CrashLogParser.parse("just some text", url: u, date: Date()) == nil, "other logs ignored")

    // ranking against installed mods
    let f = Fixture("crashlogs")
    let k = f.kit
    let cam = f.addMod("Camera Mod", ["SKSE/Plugins/CameraMod.dll": "dll"])
    let other = f.addMod("Other Hook", ["SKSE/Plugins/OtherHook.dll": "dll"])
    let start = f.addMod("Start Mod", ["StartMod.esp": "p"])
    let persp = f.addMod("Perspective", ["PerspectiveMod.esp": "p"])
    let hair = f.addMod("Test Hair", ["meshes/actors/character/hair/testhair.nif": "nif"])
    var p = try! k.currentProfile(); p.mods[p.mods.firstIndex { $0.id == other.id }!].enabled = false; try! k.saveProfile(p)   // disabled: still found
    let dir = k.crashLogDir
    try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
    write(dir.appendingPathComponent("crash-2026-10-18-09-00-18.log"), crashLogWndproc)
    write(dir.appendingPathComponent("crash-2026-10-17-22-34-01.log"), crashLogHair)
    write(dir.appendingPathComponent("CrashLogger.log"), "not a crash")
    check(k.crashLogs().map(\.lastPathComponent) == ["crash-2026-10-18-09-00-18.log", "crash-2026-10-17-22-34-01.log"], "crash logs listed newest first")
    let ra = k.analyzeCrash(k.crashLogs()[0])!
    check(ra.suspects.first?.modID == cam.id && ra.suspects.first?.modName == "Camera Mod", "first mod DLL on the stack is the top suspect (\(ra.suspects.map(\.modName)))")
    check(ra.suspects.contains { $0.modID == other.id }, "a mod the profile doesn't deploy is still recognised")
    let rb = k.analyzeCrash(k.crashLogs()[1])!
    check(Set(rb.suspects.prefix(3).compactMap(\.modID)) == [start.id, persp.id, hair.id], "plugins and the mesh map to their mods (\(rb.suspects.map(\.modName)))")
}

let crashLog125 = """
CRASH TIME: 2026-10-18 23:34:28
Skyrim SSE v1.7.104
CrashLoggerSSE v1-25-0-0 Aug 21 2026 09:19:20

Unhandled exception "C++ Exception" at 0x6FFFFFC1CF77 kernelbase.dll+000CF77\tadd rsp, 0xC8

C++ EXCEPTION:
\tType: (DX::com_exception*)
\tInfo: HRESULT 0x80004002 (E_NOINTERFACE)
\tThrow Location: kernelbase.dll+000CF77

CALL STACK ([P]robable / [S]tack scan):
\t[ 0][P] 0x6FFFFFC1CF77            kernelbase.dll+000CF77
\t[ 1][P] 0x6FFFE5D11009      ShaderMod.dll+0501009\tint3 |  D:\\a\\src\\DX12SwapChain.cpp:13 void DX12SwapChain::CreateD3D12Device(IDXGIAdapter *) [?CreateD3D12Device@@Z] | params: a_adapter: IDXGIAdapter*
\t[ 2][P] 0x6FFFE2A57334      OtherTweaks.dll+0027334
\t[ 3][S] 0x6FFFE556D14E           NoiseOnStack.dll+013D14E\ttest rax, rax

REGISTERS:
\tRAX 0x1         (void*)
"""

func crashLog125Tests() {
    section("crash detective: Crash Logger 1.25 format")
    let r = CrashLogParser.parse(crashLog125, url: URL(fileURLWithPath: "/tmp/crash-2026-10-18-23-34-28.log"), date: Date())!
    check(r.gameVersion == "1.7.104" && r.exception == "C++ Exception", "header (\(r.gameVersion), \(r.exception))")
    check(r.cppException == "DX::com_exception: HRESULT 0x80004002 (E_NOINTERFACE)", "C++ exception read (\(r.cppException))")
    check(r.stackModules == ["kernelbase.dll", "ShaderMod.dll", "OtherTweaks.dll"], "[P] frames only, stack-scan noise ignored (\(r.stackModules))")
    check(r.functions["ShaderMod.dll"] == "DX12SwapChain::CreateD3D12Device", "function from PDB info (\(r.functions))")
    check(r.summary.contains("ShaderMod.dll stopped the game in DX12SwapChain::CreateD3D12Device"), "plain summary (\(r.summary))")
    check(r.hints.contains { $0.contains("Direct3D 12") }, "Direct3D 12 hint")
    check(MacCompat.hideReason(rel: "Data/Shaders/Features/Upscaling.ini", source: "/nonexistent") != nil
          && MacCompat.hideReason(rel: "Data/Shaders/Features/ScreenSpaceGI.ini", source: "/nonexistent") == nil,
          "Community Shaders Upscaling (Direct3D 12) left out on macOS, other features kept")
}

func crashProfileTests() {
    section("crash detective: the profile that was running")
    let f = Fixture("crashprofile")
    let k = f.kit
    try! k.createProfile("List"); try! k.createProfile("Main")
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    _ = try! k.switchProfile(to: "List"); k.recordLaunch(at: t0)
    _ = try! k.switchProfile(to: "Main"); k.recordLaunch(at: t0.addingTimeInterval(3600))
    check(k.profileActive(at: t0.addingTimeInterval(60)) == "List", "crash a minute after launching List → List")
    check(k.profileActive(at: t0.addingTimeInterval(3700)) == "Main", "later launch wins")
    check(k.profileActive(at: t0.addingTimeInterval(-10)) == nil && k.profileActive(at: t0.addingTimeInterval(3 * 86400)) == nil, "no launch before / too long ago → unknown")
}

func crashFixTests() {
    section("one-click crash fix: suspects off one at a time")
    let f = Fixture("crashfix")
    let k = f.kit
    let camera = f.addMod("Camera", ["SKSE/Plugins/CameraMod.dll": "c"])
    let hook = f.addMod("Hook", ["SKSE/Plugins/OtherHook.dll": "h"])
    _ = f.addMod("Unrelated", ["textures/x.dds": "x"])
    try! k.deploy()
    let dir = k.crashLogDir
    try! fm.createDirectory(at: dir, withIntermediateDirectories: true)
    let t0 = Date().addingTimeInterval(-7200)
    func log(_ name: String, _ text: String, at d: Date) -> URL {
        let u = dir.appendingPathComponent(name)
        try! text.write(to: u, atomically: true, encoding: .utf8)
        try! fm.setAttributes([.modificationDate: d], ofItemAtPath: u.path)
        return u
    }
    let first = log("crash-2026-10-19-08-00-00.log", crashLogWndproc, at: t0)
    let r = k.analyzeCrash(first)!
    check(k.crashFixCandidates(r) == [camera.id, hook.id], "candidates: managed, enabled suspects in order")
    func on(_ id: String) -> Bool { (try! k.currentProfile()).mods.first { $0.id == id }!.enabled }
    check(try! k.startCrashFix(r, at: t0.addingTimeInterval(60)) == camera.id && !on(camera.id) && on(hook.id), "start: top suspect off")
    check(k.evaluateCrashFix() == .waiting, "no session yet → waiting")
    k.recordLaunch(at: t0.addingTimeInterval(120))
    check(k.evaluateCrashFix() == .waiting, "game still running → waiting")
    let again = log("crash-2026-10-19-08-05-00.log", crashLogWndproc, at: t0.addingTimeInterval(300))
    check(k.evaluateCrashFix() == .sameCrash(again), "same crash without it → not the culprit")
    check(try! k.nextCrashFixSuspect(at: t0.addingTimeInterval(400)) == hook.id && on(camera.id) && !on(hook.id), "next: first back on, second off")
    check(k.evaluateCrashFix() == .waiting, "new attempt: earlier sessions don't count")
    k.recordLaunch(at: t0.addingTimeInterval(500)); k.recordGameExit(at: t0.addingTimeInterval(500 + 120))
    check(k.evaluateCrashFix() == .tooShort(minutes: 2), "quit after 2 minutes → too short to tell")
    k.recordLaunch(at: t0.addingTimeInterval(700)); k.recordGameExit(at: t0.addingTimeInterval(700 + 600))
    check(k.evaluateCrashFix() == .noCrash(minutes: 12), "sessions add up: 2 + 10 minutes without a crash")
    k.recordLaunch(at: t0.addingTimeInterval(1400))
    check(k.evaluateCrashFix() == .noCrash(minutes: 12), "playing on doesn't undo enough play time")
    try! k.endCrashFix(keepOff: true)
    check(k.crashFixTrial() == nil && on(camera.id) && !on(hook.id), "keep: culprit stays off, trial over")

    section("one-click crash fix: no crash, different crash, nothing left, undo")
    try! k.setModsEnabled([hook.id], true)
    let t1 = Date().addingTimeInterval(-3600)
    try! k.startCrashFix(r, at: t1)
    k.recordLaunch(at: t1.addingTimeInterval(10)); k.recordGameExit(at: t1.addingTimeInterval(10 + 900))
    check(k.evaluateCrashFix() == .noCrash(minutes: 15), "15 minutes without a crash → likely the culprit")
    try! k.endCrashFix(keepOff: false)
    check(on(camera.id) && on(hook.id) && k.crashFixTrial() == nil, "undo: everything back on")
    let t2 = Date().addingTimeInterval(-1800)
    try! k.startCrashFix(r, at: t2)
    k.recordLaunch(at: t2.addingTimeInterval(10))
    let other = log("crash-2026-10-19-09-00-00.log", crashLogHair, at: t2.addingTimeInterval(200))
    check(k.evaluateCrashFix() == .differentCrash(other), "a different crash is told apart")
    check(try! k.keepOffAndContinueCrashFix(at: t2.addingTimeInterval(300)) == hook.id && !on(camera.id) && !on(hook.id), "keep the first off, test the second too")
    check(try! k.nextCrashFixSuspect(at: t2.addingTimeInterval(400)) == nil && on(hook.id) && !on(camera.id) && k.crashFixTrial() == nil,
          "no suspects left: trial over, the kept one stays off")
    try! k.setModsEnabled([camera.id], true)
    try! k.startCrashFix(r)
    try! k.endCrashFix(keepOff: false)
    check(on(camera.id) && on(hook.id), "cancel right away restores")
    var noMods = r; noMods.suspects = []
    check(try! k.startCrashFix(noMods) == nil && k.crashFixTrial() == nil, "nothing to test → no trial")
    check(CrashFix.signature(k.analyzeCrash(other)!).hasPrefix("skyrimse.exe+0cec9c8|"), "signature uses module + offset (\(CrashFix.signature(k.analyzeCrash(other)!)))")
}
