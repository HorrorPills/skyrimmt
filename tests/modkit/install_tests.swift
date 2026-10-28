// M4 tests: archive formats (bsdtar), layout detection, FOMOD engine, install pipeline. Fixtures are generated here
// (synthetic content only — no real mods in the repo).
import Foundation

func bsdtar(_ args: [String]) -> Int32 {
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/bsdtar"); p.arguments = args
    p.standardError = FileHandle.nullDevice; try! p.run(); p.waitUntilExit(); return p.terminationStatus
}
/// Pack `dir`'s contents into an archive of the given format (zip, 7zip, gnutar+gzip).
func pack(_ dir: URL, _ out: URL, format: String) {
    try? fm.removeItem(at: out)
    var a = ["--format", format == "tgz" ? "gnutar" : format, "-cf", out.path]
    if format == "tgz" { a.insert("-z", at: 0) }
    check(bsdtar(a + ["-C", dir.path, "."]) == 0, "bsdtar creates \(format)")
}

let fomodXML = """
<?xml version="1.0" encoding="UTF-16"?>
<config xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
  <moduleName>Test Installer</moduleName>
  <requiredInstallFiles>
    <folder source="00 Core" destination="" />
    <file source="docs\\readme.txt" destination="Docs\\TestInstaller\\readme.txt" />
  </requiredInstallFiles>
  <installSteps order="Explicit">
    <installStep name="Body">
      <optionalFileGroups order="Explicit">
        <group name="Body type" type="SelectExactlyOne">
          <plugins order="Explicit">
            <plugin name="Vanilla body">
              <description>Plain</description>
              <files><folder source="10 Vanilla" destination="" /></files>
              <conditionFlags><flag name="body">vanilla</flag></conditionFlags>
              <typeDescriptor><type name="Optional"/></typeDescriptor>
            </plugin>
            <plugin name="CBBE">
              <description>Needs CBBE.esp</description>
              <files><folder source="11 CBBE" destination="" /></files>
              <conditionFlags><flag name="body">cbbe</flag></conditionFlags>
              <typeDescriptor><dependencyType><defaultType name="NotUsable"/>
                <patterns><pattern><dependencies operator="And"><fileDependency file="CBBE.esp" state="Active"/></dependencies><type name="Recommended"/></pattern></patterns>
              </dependencyType></typeDescriptor>
            </plugin>
          </plugins>
        </group>
        <group name="Extras" type="SelectAny">
          <plugins order="Ascending">
            <plugin name="Zeta extra"><description/><files><file source="extras\\zeta.dds" destination="textures\\extra\\zeta.dds"/></files><typeDescriptor><type name="Optional"/></typeDescriptor></plugin>
            <plugin name="Alpha extra"><description/><files><file source="extras\\alpha.dds" destination="textures\\extra\\alpha.dds"/>
              <file source="extras\\always.txt" destination="always.txt" alwaysInstall="true"/></files><typeDescriptor><type name="Optional"/></typeDescriptor></plugin>
            <plugin name="Usable extra"><description/><files><file source="extras\\usable.txt" destination="usable.txt" installIfUsable="true"/></files><typeDescriptor><type name="Optional"/></typeDescriptor></plugin>
          </plugins>
        </group>
        <group name="Patches" type="SelectAll"><plugins><plugin name="Patch"><description/><files><file source="patch\\Test - Patch.esp" destination="Test - Patch.esp"/></files><typeDescriptor><type name="Required"/></typeDescriptor></plugin></plugins></group>
        <group name="Optional one" type="SelectAtMostOne"><plugins><plugin name="Nothing here"><description/><typeDescriptor><type name="Optional"/></typeDescriptor></plugin></plugins></group>
        <group name="At least" type="SelectAtLeastOne"><plugins order="Explicit">
          <plugin name="Lo-res"><description/><files><file source="res\\lo.dds" destination="textures\\res.dds" priority="0"/></files><typeDescriptor><type name="Optional"/></typeDescriptor></plugin>
          <plugin name="Hi-res"><description/><files><file source="res\\hi.dds" destination="textures\\res.dds" priority="5"/></files><typeDescriptor><type name="Optional"/></typeDescriptor></plugin>
        </plugins></group>
      </optionalFileGroups>
    </installStep>
    <installStep name="CBBE options">
      <visible><flagDependency flag="body" value="cbbe"/></visible>
      <optionalFileGroups><group name="Physics" type="SelectExactlyOne"><plugins>
        <plugin name="SMP"><description/><files><file source="cbbe\\smp.xml" destination="meshes\\smp.xml"/></files><typeDescriptor><type name="Recommended"/></typeDescriptor></plugin>
      </plugins></group></optionalFileGroups>
    </installStep>
  </installSteps>
  <conditionalFileInstalls><patterns>
    <pattern><dependencies operator="And"><flagDependency flag="body" value="vanilla"/></dependencies><files><file source="cond\\vanilla.esp" destination="Test - Vanilla.esp"/></files></pattern>
    <pattern><dependencies operator="Or"><flagDependency flag="body" value="cbbe"/><fileDependency file="Missing.esp" state="Active"/></dependencies><files><file source="cond\\cbbe.esp" destination="Test - CBBE.esp"/></files></pattern>
  </patterns></conditionalFileInstalls>
</config>
"""

func makeFomodTree(_ dir: URL) {
    for (rel, c) in ["00 Core/textures/core.dds": "core", "00 Core/Test.esp": "esp", "docs/readme.txt": "read me",
                     "10 Vanilla/meshes/body.nif": "vanilla body", "11 CBBE/meshes/body.nif": "cbbe body",
                     "extras/zeta.dds": "zeta", "extras/alpha.dds": "alpha", "extras/always.txt": "always", "extras/usable.txt": "usable",
                     "patch/Test - Patch.esp": "patch", "res/lo.dds": "lo", "res/hi.dds": "hi", "cbbe/smp.xml": "smp",
                     "cond/vanilla.esp": "cond vanilla", "cond/cbbe.esp": "cond cbbe", "fomod/info.xml": "<fomod/>"] {
        write(dir.appendingPathComponent(rel), c)
    }
    var d = Data([0xFF, 0xFE]); d.append(fomodXML.data(using: .utf16LittleEndian)!)   // UTF-16 LE with BOM, like many real installers
    try! d.write(to: dir.appendingPathComponent("fomod/ModuleConfig.xml"))
}

func installTests() {
    section("archives + layout detection")
    let f = Fixture("install")
    let src = freshDir("install-src")
    // 1. plain mod in a wrapper folder, zip
    let plain = src.appendingPathComponent("plain/Plain Mod v1.2")
    write(plain.appendingPathComponent("Plain.esp"), "esp"); write(plain.appendingPathComponent("textures/plain/a.dds"), "a")
    write(plain.appendingPathComponent("readme.txt"), "r")
    pack(src.appendingPathComponent("plain"), src.appendingPathComponent("plain.zip"), format: "zip")
    // 2. Data/ folder at the top, 7z
    write(src.appendingPathComponent("datafolder/Data/meshes/m.nif"), "nif"); write(src.appendingPathComponent("datafolder/Data/Mod.esm"), "esm")
    pack(src.appendingPathComponent("datafolder"), src.appendingPathComponent("datafolder.7z"), format: "7zip")
    // 3. SKSE layout, tar.gz
    let sk = src.appendingPathComponent("skse/skse64_2_03_01")
    for (rel, c) in ["skse64_loader.exe": "loader", "skse64_1_7_104.dll": "dll", "skse64_steam_loader.dll": "steam", "skse64_readme.txt": "rm",
                     "Data/Scripts/skse.pex": "pex", "src/skse64/main.cpp": "src"] { write(sk.appendingPathComponent(rel), c) }
    pack(src.appendingPathComponent("skse"), src.appendingPathComponent("skse.tar.gz"), format: "tgz")
    // 4. FOMOD (UTF-16) zip, 5. C#-only installer
    makeFomodTree(src.appendingPathComponent("fomodmod"))
    pack(src.appendingPathComponent("fomodmod"), src.appendingPathComponent("fomod.zip"), format: "zip")
    write(src.appendingPathComponent("scriptonly/fomod/script.cs"), "class Script {}"); write(src.appendingPathComponent("scriptonly/x.esp"), "x")
    pack(src.appendingPathComponent("scriptonly"), src.appendingPathComponent("scriptonly.7z"), format: "7zip")

    var (w, l) = try! f.kit.beginInstall(archive: src.appendingPathComponent("plain.zip"))
    if case .data(let r) = l { check(r.lastPathComponent == "Plain Mod v1.2", "zip: wrapper folder stripped") } else { check(false, "zip: data layout (\(l))") }
    let pm = try! f.kit.finishInstall(work: w, layout: l, name: "Plain")
    check(read(f.kit.stagingFolder(pm).appendingPathComponent("textures/plain/a.dds")) == "a", "plain mod staged")
    (w, l) = try! f.kit.beginInstall(archive: src.appendingPathComponent("datafolder.7z"))
    if case .data(let r) = l { check(r.lastPathComponent == "Data", "7z: Data folder used as root") } else { check(false, "7z: data layout (\(l))") }
    _ = try! f.kit.finishInstall(work: w, layout: l, name: "DataFolder")
    (w, l) = try! f.kit.beginInstall(archive: src.appendingPathComponent("skse.tar.gz"))
    if case .skse = l { check(true, "") } else { check(false, "tar.gz: SKSE layout (\(l))") }
    let skm = try! f.kit.finishInstall(work: w, layout: l, name: "SKSE")
    let sks = snapshot(f.kit.stagingFolder(skm))
    check(sks == ["__root__/skse64_loader.exe": "loader", "__root__/skse64_1_7_104.dll": "dll", "__root__/skse64_steam_loader.dll": "steam",
                  "scripts/skse.pex": "pex"], "SKSE: loader+DLLs → game folder, Data/ → Data, src/ and readme skipped (\(sks.keys.sorted()))")
    (w, l) = try! f.kit.beginInstall(archive: src.appendingPathComponent("scriptonly.7z"))
    if case .scriptOnly = l { check(true, "") } else { check(false, "C# installer detected (\(l))") }
    check((try? f.kit.finishInstall(work: w, layout: l, name: "Script")) == nil, "C# installer refused with an explanation")
    // SSE Engine Fixes part 2 style: only DLLs at the top → game folder
    for n in ["d3dx9_42.dll", "tbb.dll", "tbbmalloc.dll", "EngineFixes_preload.txt"] { write(src.appendingPathComponent("root/\(n)"), n) }
    pack(src.appendingPathComponent("root"), src.appendingPathComponent("rootdlls.7z"), format: "7zip")
    (w, l) = try! f.kit.beginInstall(archive: src.appendingPathComponent("rootdlls.7z"))
    if case .gameRoot = l { check(true, "") } else { check(false, "DLL-only archive → game folder layout (\(l))") }
    let rm = try! f.kit.finishInstall(work: w, layout: l, name: "Engine Fixes part 2")
    check(snapshot(f.kit.stagingFolder(rm)).keys.sorted() == ["__root__/d3dx9_42.dll", "__root__/tbb.dll", "__root__/tbbmalloc.dll"], "DLLs staged for the game folder")
    // the Engine Fixes "SKSE64 Preloader" file from a Vortex collection also ships Vortex's root-install instructions
    write(src.appendingPathComponent("vortexroot/d3dx9_42.dll"), "d3dx9_42.dll")   // same bytes as part 2 above: both deploy next to the exe
    write(src.appendingPathComponent("vortexroot/vortex_override_instructions.json"), #"[{"type":"setmodtype","value":"dinput"}]"#)
    pack(src.appendingPathComponent("vortexroot"), src.appendingPathComponent("vortexroot.7z"), format: "7zip")
    (w, l) = try! f.kit.beginInstall(archive: src.appendingPathComponent("vortexroot.7z"))
    if case .gameRoot = l { check(true, "") } else { check(false, "DLL + Vortex instructions → game folder layout (\(l))") }
    let vm = try! f.kit.finishInstall(work: w, layout: l, name: "Engine Fixes - SKSE64 Preloader")
    check(snapshot(f.kit.stagingFolder(vm)).keys.sorted() == ["__root__/d3dx9_42.dll"], "DLL staged for the game folder, Vortex JSON left out")
    // Community Shaders feature: a lone Shaders/ folder is Data content, not a wrapper to strip
    write(src.appendingPathComponent("cs/Shaders/Features/TerrainVariation.ini"), "ini"); write(src.appendingPathComponent("cs/Shaders/TerrainVariation/TerrainVariation.hlsli"), "hlsl")
    pack(src.appendingPathComponent("cs"), src.appendingPathComponent("cs.7z"), format: "7zip")
    (w, l) = try! f.kit.beginInstall(archive: src.appendingPathComponent("cs.7z"))
    let csm = try! f.kit.finishInstall(work: w, layout: l, name: "Terrain Variation")
    check(snapshot(f.kit.stagingFolder(csm)).keys.sorted() == ["shaders/features/terrainvariation.ini", "shaders/terrainvariation/terrainvariation.hlsli"],
          "Shaders/ kept under Data (\(snapshot(f.kit.stagingFolder(csm)).keys.sorted()))")
    // essentials detection
    let ess = essentials.first { $0.id == "skse" }!
    check(!f.kit.isInstalled(essentials.first { $0.id == "skyui" }!), "SkyUI not installed")
    write(f.game.appendingPathComponent("Data/SKSE/Plugins/versionlib-1-7-104-0.bin"), "bin")
    check(f.kit.isInstalled(essentials.first { $0.id == "addresslib" }!), "Address Library found by versionlib-*.bin")
    _ = ess
    // corrupt archive
    write(src.appendingPathComponent("broken.7z"), "not an archive")
    check((try? f.kit.beginInstall(archive: src.appendingPathComponent("broken.7z"))) == nil, "broken archive → error")

    section("FOMOD engine")
    (w, l) = try! f.kit.beginInstall(archive: src.appendingPathComponent("fomod.zip"))
    guard case .fomod(_, let cfgURL) = l else { check(false, "FOMOD layout (\(l))"); return }
    let cfg = try! FomodParser.load(cfgURL)
    check(cfg.moduleName == "Test Installer" && cfg.steps.count == 2, "UTF-16 ModuleConfig parsed")
    check(cfg.steps[0].groups[1].options.map(\.name) == ["Alpha extra", "Usable extra", "Zeta extra"], "order=Ascending sorts options by name")
    // context: CBBE.esp not active → CBBE option NotUsable
    let inst = FomodInstaller(config: cfg, context: FomodContext(pluginState: { _ in .missing }))
    inst.applyDefaults(step: 0)
    check(inst.type(of: cfg.steps[0].groups[0].options[1], flags: [:]) == .notUsable, "dependencyType default when no pattern matches")
    check(inst.selections[0]?[0] == [0], "SelectExactlyOne defaults to the first usable option")
    check(inst.selections[0]?[2] == [0], "SelectAll / Required preselected")
    check(inst.visibleSteps == [0], "step hidden until its flag is set")
    inst.selections[0]?[0] = [1]
    check(inst.problem(step: 0, group: 0) != nil, "selecting a NotUsable option is a problem")
    inst.selections[0]?[0] = []
    check(inst.problem(step: 0, group: 0) == "Body type: choose exactly one", "SelectExactlyOne needs one")
    inst.selections[0]?[0] = [0]
    inst.selections[0]?[4] = []
    check(inst.problem(step: 0, group: 4) != nil, "SelectAtLeastOne needs one")
    inst.selections[0]?[4] = [0, 1]
    inst.selections[0]?[1] = [2]   // Zeta only
    check(inst.problems().isEmpty, "valid selection (\(inst.problems()))")
    let out = f.home.appendingPathComponent("fomod-out")
    guard case .fomod(let froot, _) = l else { return }
    try! inst.install(from: froot, to: out)
    let got = snapshot(out)
    let want: [String: String] = ["textures/core.dds": "core", "test.esp": "esp", "docs/testinstaller/readme.txt": "read me",
        "meshes/body.nif": "vanilla body", "textures/extra/zeta.dds": "zeta", "always.txt": "always", "usable.txt": "usable",
        "test - patch.esp": "patch", "textures/res.dds": "hi", "test - vanilla.esp": "cond vanilla"]
    check(got == want, "vanilla install: required + selected + alwaysInstall + installIfUsable + priority + conditional (\(got.keys.sorted()))")
    // context: CBBE.esp active → Recommended, second step visible, other conditional pattern
    let inst2 = FomodInstaller(config: cfg, context: FomodContext(pluginState: { $0 == "CBBE.esp" ? .active : .missing }))
    inst2.applyDefaults(step: 0)
    check(inst2.selections[0]?[0] == [1], "Recommended option preselected when its pattern matches")
    check(inst2.visibleSteps == [0, 1], "flag from step 1 makes step 2 visible")
    inst2.applyDefaults(step: 1)
    let out2 = f.home.appendingPathComponent("fomod-out2")
    try! inst2.install(from: froot, to: out2)
    let got2 = snapshot(out2)
    check(got2["meshes/body.nif"] == "cbbe body" && got2["meshes/smp.xml"] == "smp" && got2["test - cbbe.esp"] == "cond cbbe" && got2["test - vanilla.esp"] == nil,
          "CBBE install: second step + Or pattern (\(got2.keys.sorted()))")
    // replay saved choices
    let inst3 = FomodInstaller(config: cfg, context: FomodContext(pluginState: { _ in .missing }))
    inst3.replay(inst.choices)
    check(inst3.resolvedFiles() == inst.resolvedFiles(), "saved choices replay to the same files")
    // full pipeline
    let fm1 = try! f.kit.finishInstall(work: w, layout: l, name: "Fomod Mod", fomod: inst)
    check(snapshot(f.kit.stagingFolder(fm1)) == want, "FOMOD staged through the pipeline")
    check(f.kit.mod(fm1.id)?.installChoices?["Body/Body type"] == ["Vanilla body"], "choices saved on the mod record")
    try! f.kit.deploy()
    check(read(f.game.appendingPathComponent("Data/Test - Patch.esp")) == "patch", "installed FOMOD deploys")
    check(read(f.game.appendingPathComponent("skse64_loader.exe")) == "loader", "SKSE loader deployed to the game folder")
    check(f.kit.isInstalled(essentials.first { $0.id == "skse" }!), "SKSE essential detected after deploy")
    check(read(f.game.appendingPathComponent("d3dx9_42.dll")) == "d3dx9_42.dll", "Engine Fixes part 2 DLL deployed next to the exe")
    check(!fm.fileExists(atPath: f.home.appendingPathComponent("cache/install").path) || (try! fm.contentsOfDirectory(atPath: f.home.appendingPathComponent("cache/install").path)).isEmpty,
          "work folders cleaned up")
}

func readOnlyArchiveTests() {
    section("archives with read-only folders")
    let f = Fixture("readonly")
    let src = freshDir("readonly-src")
    write(src.appendingPathComponent("m/Music/Shadow/track.xwm"), "music")
    chmod(src.appendingPathComponent("m/Music/Shadow").path, 0o555)
    pack(src.appendingPathComponent("m"), src.appendingPathComponent("ro.zip"), format: "zip")
    chmod(src.appendingPathComponent("m/Music/Shadow").path, 0o755)
    let (w, l) = try! f.kit.beginInstall(archive: src.appendingPathComponent("ro.zip"))
    var st = stat(); lstat(w.appendingPathComponent("x/Music/Shadow").path, &st)
    check(st.st_mode & S_IWUSR != 0, "unpacked folder made writable")
    let m = try! f.kit.finishInstall(work: w, layout: l, name: "Music")
    check(!fm.fileExists(atPath: w.path), "work folder removed after install")
    try! f.kit.removeMod(m.id)
    check(!fm.fileExists(atPath: f.kit.stagingFolder(m).path), "mod folder removed")
    // a stale read-only leftover from an older version is cleaned at start
    let stale = f.home.appendingPathComponent("cache/install/OLD/x/ro"); write(stale.appendingPathComponent("f"), "x"); chmod(stale.path, 0o555)
    f.kit.cleanupStale()
    check(!fm.fileExists(atPath: f.home.appendingPathComponent("cache/install").path), "stale read-only work folders cleaned")
}
