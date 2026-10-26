// ModKit generators: tools that build files from the deployed mods (Pandora, BodySlide) keep their result as a
// per-profile output mod placed just below Overwrite, so the game folder stays fully managed.
import Foundation
import CryptoKit

extension ModKit {
    static func profileFolderName(_ profile: String) -> String {
        String(profile.map { "/:\\".contains($0) ? "_" : $0 })
    }

    /// Whether the generators rerun on their own (deploy, Play) for the current profile; "Generate now" always works.
    public var autoPandora: Bool { (try? currentProfile())?.autoPandora ?? true }
    public var autoBodySlide: Bool { (try? currentProfile())?.autoBodySlide ?? true }

    public func setAutoGenerate(_ name: String, pandora: Bool? = nil, bodySlide: Bool? = nil) throws {
        guard var p = profile(name) else { throw ModKitError.noSuchProfile(name) }
        if let pandora { p.autoPandora = pandora }
        if let bodySlide { p.autoBodySlide = bodySlide }
        try saveProfile(p)
    }

    /// Replace the profile's output mod `id` with the files in `dir` (moved), enable it just below Overwrite, deploy.
    func installGeneratedOutput(id: String, name: String, folder: String, from dir: URL, profile: inout Profile) throws {
        let fm = FileManager.default
        let rec = mod(id) ?? ModRecord(id: id, name: name, folder: folder)
        let staging = stagingFolder(rec)
        try? fm.removeItem(at: staging)
        try fm.createDirectory(at: staging.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.moveItem(at: dir, to: staging)
        if mod(id) == nil { appendMod(rec) }
        profile.mods.removeAll { $0.id == id }
        let at = profile.mods.firstIndex { ModKit.isOverwrite($0.id) } ?? profile.mods.count
        profile.mods.insert(ProfileMod(id: id, enabled: true), at: at)
        try saveProfile(profile)
        try deploy(profile)
    }

    /// Remove the profile's output mod `id` (nothing needs it any more) and deploy.
    func removeGeneratedOutput(id: String, profile: inout Profile) throws {
        if profile.mods.contains(where: { $0.id == id }) { profile.mods.removeAll { $0.id == id }; try saveProfile(profile) }
        if mod(id) != nil { try removeMod(id) }
        try deploy(profile)
    }

    /// Fingerprint of the deployed files matching `isInput` (generated outputs excluded) plus extra settings.
    func deployedInputs(excluding outputs: (String) -> Bool, _ isInput: (String) -> Bool, extra: [String]) throws -> (fingerprint: String, count: Int) {
        let m = try Manifest.load(deployer.layout.manifestURL)
        let inputs = m.entries.values.filter { !outputs($0.modID) && isInput($0.rel) }.sorted { $0.rel.lowercased() < $1.rel.lowercased() }
        var h = SHA256Hasher()
        for x in extra { h.update(x + "\n") }
        for e in inputs { h.update("\(e.rel.lowercased())\t\(e.modID)\t\(e.size)\t\(e.mtimeNs)\n") }
        return (h.hex, inputs.count)
    }
}

struct SHA256Hasher {
    private var h = SHA256()
    mutating func update(_ s: String) { h.update(data: Data(s.utf8)) }
    var hex: String { h.finalize().map { String(format: "%02x", $0) }.joined() }
}
