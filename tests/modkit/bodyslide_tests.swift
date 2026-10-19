// BodySlide integration (ModKit/BodySlide.swift) with a stand-in BodySlide: project scan, body-family detection
// (3BA over CBBE, CBBE outfits as 3BA fallback, other families left out), conflict choices, output mod, stale check.
import Foundation

func bodySlideTests() {
    section("bodyslide output mod")
    let f = Fixture("bodyslide")
    let k = f.kit
    func osp(_ sets: [(String, String, String)]) -> String {   // (name, OutputPath, OutputFile)
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<SliderSetInfo version=\"1\">\n" + sets.map {
            "<SliderSet name=\"\($0.0)\"><OutputPath>\($0.1)</OutputPath><OutputFile GenWeights=\"true\">\($0.2)</OutputFile></SliderSet>\n"
        }.joined() + "</SliderSetInfo>\n"
    }
    func groups(_ g: [(String, [String])]) -> String {
        "<SliderGroups>\n" + g.map { "<Group name=\"\($0.0)\">" + $0.1.map { "<Member name=\"\($0)\"/>" }.joined() + "</Group>\n" }.joined() + "</SliderGroups>\n"
    }
    let bs = "CalienteTools/BodySlide/"
    // outfits and hair only: no body project → nothing is built (pre-built body meshes stay)
    _ = f.addMod("Armors", [
        bs + "SliderSets/armor.osp": osp([("Armor (CBBE)", "meshes\\armor\\steel", "cuirass"), ("Armor (3BA)", "meshes\\armor\\steel", "cuirass"),
                                         ("Armor (BHUNP)", "meshes\\armor\\steel", "cuirass"), ("Boots (CBBE)", "meshes\\armor\\steel", "boots"),
                                         ("Hair Collision", "meshes\\hair", "collision")]),
        bs + "SliderGroups/armor.xml": groups([("CBBE", ["Armor (CBBE)", "Boots (CBBE)"]), ("3BA", ["Armor (3BA)"]), ("BHUNP 3BBB", ["Armor (BHUNP)"])]),
    ])
    _ = try! k.deploy()
    var scan = try! k.bodySlideScan()
    check(scan.outfits.count == 5 && scan.detectedFamily == nil, "no body project: nothing detected (\(scan.outfits.count) outfits)")
    check(k.bodySlidePlan(scan, family: nil, profile: try! k.currentProfile()).outfits.isEmpty, "no family: nothing to build")
    check(!k.bodySlideNeedsRun(), "no body project: not stale")

    // CBBE + 3BA bodies installed (3BA needs CBBE) → 3BA
    _ = f.addMod("Bodies", [
        bs + "SliderSets/body.osp": osp([("CBBE Body", "meshes\\actors\\character\\character assets", "femalebody"),
                                        ("3BA Body", "meshes\\actors\\character\\character assets", "femalebody")]),
        bs + "SliderGroups/body.xml": groups([("CBBE Bodies", ["CBBE Body"]), ("3BBB", ["3BA Body"])]),
        bs + "SliderPresets/p.xml": "<SliderPresets><Preset name=\"Curvy\" set=\"x\"><Group name=\"CBBE\"/></Preset><Preset name=\"Bhunp Thing\" set=\"y\"><Group name=\"BHUNP 3BBB\"/></Preset></SliderPresets>",
    ])
    _ = try! k.deploy()
    scan = try! k.bodySlideScan()
    check(scan.detectedFamily == "3BA", "3BA body wins over CBBE (\(scan.detectedFamily ?? "none"))")
    check(scan.presets(for: "3BA").map(\.name) == ["Curvy"], "CBBE presets offered for 3BA, BHUNP ones not")
    let plan = k.bodySlidePlan(scan, family: "3BA", profile: try! k.currentProfile())
    let names = Set(plan.outfits.map(\.name))
    check(names == ["Armor (CBBE)", "Armor (3BA)", "Boots (CBBE)", "Hair Collision", "CBBE Body", "3BA Body"], "BHUNP outfit left out (\(names.sorted()))")
    check(plan.choices["meshes/armor/steel/cuirass"] == "Armor (3BA)", "3BA version wins the contested cuirass")
    check(plan.choices["meshes/actors/character/character assets/femalebody"] == "3BA Body", "3BA body wins the body mesh")
    check(plan.choices["meshes/armor/steel/boots"] == nil, "uncontested outfit needs no choice")
    let cbbe = k.bodySlidePlan(scan, family: "CBBE", profile: try! k.currentProfile())
    check(!cbbe.outfits.contains { $0.name == "Armor (3BA)" } && cbbe.choices["meshes/actors/character/character assets/femalebody"] == nil,
          "CBBE chosen: 3BA outfits left out")
    check(k.bodySlideNeedsRun(), "body project installed: output stale")

    // stand-in BodySlide: builds every listed outfit (one file each) and logs like the real one
    let bin = k.bodySlideDir.appendingPathComponent("BodySlide")
    write(bin, """
    #!/bin/bash
    list=""; out=""; ni=0; preset=""
    while [ $# -gt 0 ]; do case $1 in --buildlist) list=$2; shift;; --targetdir) out=$2; shift;; --noninteractive) ni=1;; --preset) preset=$2; shift;; esac; shift; done
    [ $ni = 1 ] || exit 9
    echo "preset=$preset" > "$(dirname "$0")/args.txt"
    while IFS= read -r o || [ -n "$o" ]; do [ -n "$o" ] || continue; d="$out/meshes/built"; mkdir -p "$d"; echo "$o" > "$d/$(echo "$o" | tr -c 'A-Za-z0-9\\n' _).nif"; done < "$list"
    echo "[00:00:00][3] All command-line build sets processed successfully!" > "$(dirname "$0")/Log_BS.txt"
    """)
    chmod(bin.path, 0o755)
    write(k.bodySlideDir.appendingPathComponent("Config.default.xml"), "<Config>\n    <TargetGame>-1</TargetGame>\n    <GameDataPath></GameDataPath>\n    <ProjectPath></ProjectPath>\n</Config>\n")
    try! k.setBodySlideSettings(BodySlideSettings(preset: "Curvy"))
    let r = try! k.runBodySlide()
    let outID = ModKit.bodySlideOutputID(try! k.currentProfile().name)
    check(r.family == "3BA" && r.outfits == 6 && r.files == 6, "built 6 outfits for 3BA (\(r.outfits) → \(r.files))")
    check(read(k.bodySlideDir.appendingPathComponent("args.txt"))?.contains("preset=Curvy") == true, "profile preset passed")
    let config = read(k.bodySlideDir.appendingPathComponent("Config.xml")) ?? ""
    check(config.contains("<TargetGame>4</TargetGame>") && config.contains("/CalienteTools/BodySlide</ProjectPath>"), "Config.xml points at the deployed projects")
    let sel = read(k.bodySlideDir.appendingPathComponent("BuildSelection.xml")) ?? ""
    check(sel.contains("path=\"meshes/armor/steel/cuirass\" choice=\"Armor (3BA)\""), "conflict choices written for BodySlide")
    check(k.mod(outID) != nil && fm.fileExists(atPath: f.game.appendingPathComponent("Data/meshes/built").path), "output mod deployed")
    check(!k.bodySlideNeedsRun(), "up to date after the run")
    try! k.setBodySlideSettings(BodySlideSettings(preset: "Curvy", triMorphs: true))
    check(k.bodySlideNeedsRun(), "changing a setting makes it stale")
    try? fm.removeItem(at: f.home)
}

// Built-in fixes (ModKit.builtinMods): deployed with every profile from the app bundle, removed by purge.
func builtinTests() {
    section("built-in fixes")
    let f = Fixture("builtin")
    let root = f.home.appendingPathComponent("bundle-builtin")
    write(root.appendingPathComponent("SkyrimMT Mac Fixes/SKSE/Plugins/SkyrimMT_MacFixes.dll"), "dll")
    setenv("SKYRIMMT_BUILTIN", root.path, 1)
    defer { setenv("SKYRIMMT_BUILTIN", noBuiltins.path, 1) }
    let dll = f.game.appendingPathComponent("Data/SKSE/Plugins/SkyrimMT_MacFixes.dll")
    _ = try! f.kit.deploy()
    check(read(dll) == "dll", "built-in plugin deployed with an empty profile")
    check(!(try! f.kit.currentProfile()).mods.contains { $0.id.hasPrefix("builtin:") }, "not listed as a profile mod")
    _ = try! f.kit.purge()
    check(!fm.fileExists(atPath: dll.path), "purge removes it")
    try? fm.removeItem(at: f.home)
}

// Deleting profiles: not the active one; generated outputs go; shared mods stay; unused mods only when asked.
func deleteProfileTests() {
    section("delete profile")
    let f = Fixture("delprofile")
    let k = f.kit
    let shared = f.addMod("Shared", ["textures/s.dds": "s"])
    try! k.createProfile("Other", cloneFrom: try! k.currentProfile().name)
    let only = f.addMod("Only Default", ["textures/o.dds": "o"])   // added to the current (Default) profile only
    _ = try! k.switchProfile(to: "Other")
    var threw = false
    do { try k.deleteProfile("Other", removeUnusedMods: false) } catch { threw = true }
    check(threw, "active profile can't be deleted")
    // a generated output belonging to Default
    write(k.modsDir.appendingPathComponent("Pandora Output - Default/meshes/x.hkx"), "x")
    var d = k.profile("Default")!
    k.appendMod(ModRecord(id: ModKit.pandoraOutputID("Default"), name: "Pandora Output (Default)", folder: "Pandora Output - Default"))
    d.mods.append(ProfileMod(id: ModKit.pandoraOutputID("Default"), enabled: true)); try! k.saveProfile(d)
    check(k.modsOnlyIn("Default").map(\.id) == [only.id], "only-this-profile mods found (outputs not counted)")
    try! k.deleteProfile("Default", removeUnusedMods: false)
    check(k.profile("Default") == nil && k.profileNames() == ["Other"], "profile folder removed")
    check(k.mod(ModKit.pandoraOutputID("Default")) == nil, "its Pandora output removed")
    check(k.mod(only.id) != nil && k.mod(shared.id) != nil, "mods kept when not asked")
    try! k.createProfile("Third")
    var t = k.profile("Third")!; t.mods = [ProfileMod(id: only.id, enabled: true)]; try! k.saveProfile(t)
    var o = k.profile("Other")!; o.mods.removeAll { $0.id == only.id }; try! k.saveProfile(o)
    try! k.deleteProfile("Third", removeUnusedMods: true)
    check(k.mod(only.id) == nil && k.mod(shared.id) != nil, "unused mod uninstalled on request, shared one kept")
    try? fm.removeItem(at: f.home)
}

// Owner report 2026-10-18: "Remove all mods" then a profile/version switch must not overwrite the profile's load order.
func purgeKeepsLoadOrderTests() {
    section("purge keeps load order")
    let f = Fixture("purgelo")
    let k = f.kit
    _ = f.addMod("Plugin Mod", ["A.esp": String(decoding: pluginBytes(flags: 0, masters: ["Skyrim.esm"]), as: UTF8.self)])
    write(f.game.appendingPathComponent("Data/Skyrim.esm"), String(decoding: pluginBytes(flags: 1, masters: []), as: UTF8.self))
    _ = try! k.deploy()
    var p = try! k.currentProfile(); p.loadOrder = [LoadOrderEntry(name: "A.esp", active: true)]; try! k.saveProfile(p)
    _ = try! k.deploy()
    let before = try! k.currentProfile().loadOrder
    try! k.createProfile("Other")
    _ = try! k.purge()
    _ = try! k.switchProfile(to: "Other")
    check(k.profile(p.name)!.loadOrder == before, "load order survives purge + switch (\\(k.profile(p.name)!.loadOrder.map(\\.name)))")
    try? fm.removeItem(at: f.home)
}

func bodySlideConfigTests() {
    section("BodySlide config: data path in the right section, skeleton set")
    let f = Fixture("bsconfig")
    let app = f.kit.bodySlideDir
    try! fm.createDirectory(at: app, withIntermediateDirectories: true)
    let def = """
    <Config>
        <TargetGame>0</TargetGame>
        <GameDataFiles>
            <SkyrimSpecialEdition></SkyrimSpecialEdition>
        </GameDataFiles>
        <GameDataPaths>
            <SkyrimSpecialEdition></SkyrimSpecialEdition>
        </GameDataPaths>
        <GameDataPath></GameDataPath>
        <Anim>
            <DefaultSkeletonReference></DefaultSkeletonReference>
            <SkeletonRootName></SkeletonRootName></Anim>
    </Config>
    """
    try! def.write(to: app.appendingPathComponent("Config.default.xml"), atomically: true, encoding: .utf8)
    try! f.kit.prepareBodySlideConfig()
    let c = read(app.appendingPathComponent("Config.xml"))!
    let data = f.game.appendingPathComponent("Data").path + "/"
    let files = c.components(separatedBy: "<GameDataFiles>")[1].components(separatedBy: "</GameDataFiles>")[0]
    let paths = c.components(separatedBy: "<GameDataPaths>")[1].components(separatedBy: "</GameDataPaths>")[0]
    check(files.contains("<SkyrimSpecialEdition></SkyrimSpecialEdition>"), "archive blacklist left empty")
    check(paths.contains("<SkyrimSpecialEdition>\(data)</SkyrimSpecialEdition>"), "game data path under GameDataPaths")
    check(c.contains("<DefaultSkeletonReference>res/skeleton_female_sse.nif</DefaultSkeletonReference>") && c.contains("<SkeletonRootName>NPC Root [Root]</SkeletonRootName>"),
          "Skyrim SE skeleton set (as BodySlide's own setup does)")
    // the player picks another skeleton in BodySlide's Settings (written to Config.xml)
    let own = c.replacingOccurrences(of: "<DefaultSkeletonReference>res/skeleton_female_sse.nif</DefaultSkeletonReference>", with: "<DefaultSkeletonReference>/x/custom.nif</DefaultSkeletonReference>")
    try! own.write(to: app.appendingPathComponent("Config.xml"), atomically: true, encoding: .utf8)
    try! f.kit.prepareBodySlideConfig()
    check(read(app.appendingPathComponent("Config.xml"))!.components(separatedBy: "<GameDataPaths>").count == 2, "no duplicated sections on rewrite")
    check(read(app.appendingPathComponent("Config.xml"))!.contains("<DefaultSkeletonReference>/x/custom.nif</DefaultSkeletonReference>"), "a skeleton the player chose is kept")
}
