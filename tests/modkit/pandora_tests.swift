// Pandora integration (ModKit/Pandora.swift) with a stand-in Pandora binary: inputs fingerprint, the per-profile
// "Pandora Output" mod, reruns on change, removal when no animation mods are left, failures keep the old output.
import Foundation

func pandoraTests() {
    section("pandora output mod")
    let f = Fixture("pandora")
    let k = f.kit
    let bin = k.pandoraBinary
    func fakePandora(exit code: Int32 = 0) {
        // writes a behaviour file + log into the -o folder, like Pandora's --auto_run --auto_close
        write(bin, """
        #!/bin/bash
        out=""; while [ $# -gt 0 ]; do [ "$1" = -o ] && out=$2; shift; done
        mkdir -p "$out/meshes/actors/character/behaviors" "$out/Pandora_Engine"
        echo "generated $(date +%s%N)" > "$out/meshes/actors/character/behaviors/0_master.hkx"
        echo out > "$out/Pandora_Engine/PreviousOutput.txt"
        printf 'INFO : ok\\nWARN : something\\n' > "$out/Engine.log"
        exit \(code)
        """)
        chmod(bin.path, 0o755)
    }

    _ = try! k.deploy()
    check(!k.pandoraNeedsRun(), "no animation mods: nothing to run")
    check(!k.pandoraInstalled, "not installed without the binary")

    let anim = f.addMod("Anim Mod", ["Nemesis_Engine/mod/anim/info.ini": "name=Anim", "meshes/actors/character/animations/anim/a.hkx": "a"])
    _ = f.addMod("Texture Mod", ["textures/t.dds": "t"])
    _ = try! k.deploy()
    check(k.pandoraNeedsRun(), "an engine patch makes the output stale")
    check(ModKit.isPandoraInput("Data/meshes/actors/character/animations/XPMSE/FNIS_XPMSE_List.txt"), "FNIS list is an input")
    check(ModKit.isPandoraInput("Data/meshes/actors/character/Behaviors/FNIS_XPMSE_Behavior.hkx"), "FNIS behaviour is an input")
    check(!ModKit.isPandoraInput("Data/meshes/actors/character/behaviors/0_master.hkx"), "Pandora's output isn't an input")
    var threw = false
    do { try k.runPandora() } catch { threw = true }
    check(threw, "run without Pandora installed reports it")

    fakePandora()
    let r = try! k.runPandora()
    let outID = ModKit.pandoraOutputID(try! k.currentProfile().name)
    let prof = try! k.currentProfile()
    // behaviour + the patch selection handed to Pandora (Pandora_Engine/ActiveMods.json, which Pandora keeps)
    check(r.files == 2 && r.warnings == 1, "output counted, log parsed (\(r.files) files, \(r.warnings) warnings)")
    check(k.mod(outID) != nil && prof.mods.last?.id == outID && prof.mods.last?.enabled == true, "output mod enabled and last")
    check(fm.fileExists(atPath: f.game.appendingPathComponent("Data/meshes/actors/character/behaviors/0_master.hkx").path), "output deployed")
    check(!fm.fileExists(atPath: k.stagingFolder(k.mod(outID)!).appendingPathComponent("Pandora_Engine/PreviousOutput.txt").path), "run bookkeeping dropped")
    check(!fm.fileExists(atPath: k.stagingFolder(k.mod(outID)!).appendingPathComponent("Engine.log").path), "log kept out of the mod")
    check(!k.pandoraNeedsRun(), "up to date after the run")
    _ = try! k.deploy()
    check(!k.pandoraNeedsRun(), "still up to date after a plain deploy")

    // Overwrite keeps winning over the output
    var p = try! k.currentProfile(); p.mods.append(ProfileMod(id: ModKit.overwriteID, enabled: true)); try! k.saveProfile(p)
    _ = try! k.runPandora()
    p = try! k.currentProfile()
    check(p.mods.firstIndex { $0.id == outID }! + 1 == p.mods.firstIndex { $0.id == ModKit.overwriteID }!, "output sits just below Overwrite")

    // changed input → stale; failed run keeps the previous output
    write(k.stagingFolder(anim).appendingPathComponent("Nemesis_Engine/mod/anim/0_master/#0001.txt"), "patch")   // mod update adds a patch
    _ = try! k.deploy()
    check(k.pandoraNeedsRun(), "changed engine patch makes the output stale")
    let before = read(f.game.appendingPathComponent("Data/meshes/actors/character/behaviors/0_master.hkx"))
    fakePandora(exit: 3)
    threw = false
    do { try k.runPandora() } catch { threw = true }
    check(threw, "failed run reports the error")
    check(read(f.game.appendingPathComponent("Data/meshes/actors/character/behaviors/0_master.hkx")) == before, "failed run keeps the old output deployed")
    fakePandora()
    _ = try! k.runPandora()
    check(!k.pandoraNeedsRun(), "rerun fixes it")

    // no animation mods left → output removed
    p = try! k.currentProfile(); p.mods = p.mods.map { $0.id == anim.id ? ProfileMod(id: $0.id, enabled: false) : $0 }; try! k.saveProfile(p)
    _ = try! k.deploy()
    check(k.pandoraNeedsRun(), "output without inputs is stale")
    let r2 = try! k.runPandora()
    check(r2.files == 0 && k.mod(outID) == nil, "output mod removed when nothing needs it")
    check(!fm.fileExists(atPath: f.game.appendingPathComponent("Data/meshes/actors/character/behaviors/0_master.hkx").path), "output gone from the game")
    check(!k.pandoraNeedsRun(), "nothing to do afterwards")
    try? fm.removeItem(at: f.home)

    section("pandora patch selection")
    let g = Fixture("pandora-selection")
    let kg = g.kit
    let received = g.home.appendingPathComponent("received-ActiveMods.json")
    // keeps the selection SkyrimMT hands over (Pandora reads <-o>/Pandora_Engine/ActiveMods.json)
    write(kg.pandoraBinary, """
    #!/bin/bash
    out=""; while [ $# -gt 0 ]; do [ "$1" = -o ] && out=$2; shift; done
    cp "$out/Pandora_Engine/ActiveMods.json" "\(received.path)"
    mkdir -p "$out/meshes/actors/character/behaviors"; echo x > "$out/meshes/actors/character/behaviors/0_master.hkx"
    """)
    chmod(kg.pandoraBinary.path, 0o755)
    // the Nemesis mod ships the engine and template patches for mods that may not be installed (as Nemesis does)
    _ = g.addMod("Nemesis Unlimited Behavior Engine", ["Nemesis_Engine/behavior_templates/0_master.txt": "t",
                                                       "Nemesis_Engine/mod/tudm/info.ini": "name=TUDM template",
                                                       "Nemesis_Engine/mod/tkuc/info.ini": "name=TK template"])
    _ = g.addMod("Some Animation", ["Nemesis_Engine/mod/anim/info.ini": "name=Anim", "meshes/actors/character/animations/anim/a.hkx": "a"])
    _ = g.addMod("The Ultimate Dodge Mod", ["Nemesis_Engine/mod/tudm/info.ini": "name=TUDM", "meshes/actors/character/animations/tudm/d.hkx": "d"])
    _ = try! kg.deploy()
    _ = try! kg.runPandora()
    let entries = (try? JSONSerialization.jsonObject(with: Data(contentsOf: received))) as? [[String: Any]] ?? []
    let active = Dictionary(uniqueKeysWithValues: entries.compactMap { e in (e["code"] as? String).map { ($0, e["active"] as? Bool ?? false) } })
    check(active.count == 3, "every patch listed (\(active.keys.sorted()))")
    check(active["anim"] == true, "a patch shipped by an animation mod is on")
    check(active["tudm"] == true, "an engine template also provided by its mod is on")
    check(active["tkuc"] == false, "an engine-only template is off (its animations aren't installed)")

    section("generators run automatically (per profile)")
    let name = try! kg.currentProfile().name
    let file = kg.profilesDir.appendingPathComponent("\(name)/profile.json")
    // a profile.json written before the setting existed still decodes (a decode failure would rebuild the profile)
    write(file, #"{"version":1,"items":{"name":"\#(name)","mods":[],"loadOrder":[],"separateSaves":false}}"#)
    check(kg.profile(name) != nil && kg.autoPandora && kg.autoBodySlide, "old profile: decodes, both on")
    try! kg.setAutoGenerate(name, pandora: false)
    check(!kg.autoPandora && kg.autoBodySlide, "Pandora off, BodySlide untouched")
    try! kg.setAutoGenerate(name, bodySlide: false)
    check(kg.profile(name)?.autoPandora == false && kg.profile(name)?.autoBodySlide == false, "both saved in profile.json")
    try? fm.removeItem(at: g.home)
}
