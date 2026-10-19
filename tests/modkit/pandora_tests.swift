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
    check(r.files == 1 && r.warnings == 1, "output counted, log parsed (\(r.files) files, \(r.warnings) warnings)")
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
}
