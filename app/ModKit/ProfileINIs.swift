// Per-profile game INIs (MO2's "LocalSettings"): a profile may carry its own Skyrim.ini / SkyrimPrefs.ini /
// SkyrimCustom.ini (Wabbajack lists depend on theirs). On a profile switch the INIs in My Games are saved back to the
// profile being left (in-game changes are kept) — or to the shared copy if it has no own INIs — and the new
// profile's INIs (or the shared copy) are put in place. Profiles without own INIs never touch anything.
import Foundation

extension ModKit {
    static let iniNames = ["Skyrim.ini", "SkyrimPrefs.ini", "SkyrimCustom.ini"]

    /// prefix/drive_c/users/<user>/Documents/My Games/Skyrim Special Edition (derived from plugins.txt's location)
    public var myGamesDir: URL {
        pluginsTxt.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Documents/My Games/Skyrim Special Edition")
    }
    public func profileINIDir(_ name: String) -> URL { profilesDir.appendingPathComponent("\(name)/ini") }
    var sharedINIDir: URL { stateDir.appendingPathComponent("shared-ini") }
    public func hasOwnINIs(_ name: String) -> Bool {
        ModKit.iniNames.contains { FileManager.default.fileExists(atPath: profileINIDir(name).appendingPathComponent($0).path) }
    }

    /// Swap INIs for a switch from `old` to `new`. Returns true when files in My Games changed.
    @discardableResult
    func swapINIs(from old: String, to new: String) throws -> Bool {
        let oldOwn = hasOwnINIs(old), newOwn = hasOwnINIs(new)
        guard oldOwn || newOwn else { return false }
        let fm = FileManager.default
        func copyAll(_ from: URL, _ to: URL, only: Set<String>? = nil) throws {
            try fm.createDirectory(at: to, withIntermediateDirectories: true)
            for n in ModKit.iniNames where only?.contains(n) ?? true {
                let s = from.appendingPathComponent(n), d = to.appendingPathComponent(n)
                guard fm.fileExists(atPath: s.path) else { continue }
                try? fm.removeItem(at: d); try fm.copyItem(at: s, to: d)
            }
        }
        // keep what is in My Games now with the profile being left
        if oldOwn {
            let own = Set(ModKit.iniNames.filter { fm.fileExists(atPath: profileINIDir(old).appendingPathComponent($0).path) })
            try copyAll(myGamesDir, profileINIDir(old), only: own)
        } else {
            try copyAll(myGamesDir, sharedINIDir)
        }
        // put the new profile's INIs (or the shared ones) in place
        if newOwn { try copyAll(profileINIDir(new), myGamesDir) } else { try copyAll(sharedINIDir, myGamesDir) }
        return true
    }
}

// MARK: separate saves per profile (Skyrim's [General] SLocalSavePath, relative to My Games; set in SkyrimCustom.ini)

/// Minimal INI editing that keeps everything else in the file as it is (CRLF kept).
enum IniEdit {
    static func set(_ url: URL, section: String, key: String, value: String?) throws {
        let raw = (try? String(contentsOf: url, encoding: .utf8)) ?? (try? String(contentsOf: url, encoding: .windowsCP1252)) ?? ""
        let nl = raw.contains("\r\n") ? "\r\n" : "\n"
        var lines = raw.isEmpty ? [] : raw.components(separatedBy: nl)
        if lines.last == "" { lines.removeLast() }
        var sec = "", secStart: Int?, keyLine: Int?, secEnd = lines.count
        for (i, l) in lines.enumerated() {
            let t = l.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("[") && t.hasSuffix("]") {
                if secStart != nil && secEnd == lines.count { secEnd = i }
                sec = String(t.dropFirst().dropLast())
                if sec.caseInsensitiveCompare(section) == .orderedSame { secStart = i; secEnd = lines.count }
                continue
            }
            if secStart != nil, secEnd == lines.count, sec.caseInsensitiveCompare(section) == .orderedSame,
               let eq = t.firstIndex(of: "="), t[..<eq].trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(key) == .orderedSame { keyLine = i }
        }
        if let k = keyLine { if let v = value { lines[k] = "\(key)=\(v)" } else { lines.remove(at: k) } }
        else if let v = value {
            if let s = secStart { lines.insert("\(key)=\(v)", at: secEnd > s ? secEnd : s + 1) }
            else { lines += ["[\(section)]", "\(key)=\(v)"] }
        } else { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (lines.joined(separator: nl) + nl).write(to: url, atomically: true, encoding: .utf8)
    }
}

extension ModKit {
    /// Save folder (inside My Games) of a profile with separate saves. ASCII only: Skyrim reads SkyrimCustom.ini as
    /// Windows-1252, so "A Dragonborn's Fate – Standard" came out as "…Fate â€“ Standard" (in-game test 2026-10-19).
    public func profileSavesFolder(_ name: String) -> URL { myGamesDir.appendingPathComponent("Saves/SkyrimMT/\(ModKit.asciiFolderName(name))") }

    /// "A Dragonborn’s Fate – Standard" → "A Dragonborn's Fate - Standard"; "Skyrim Ågård" → "Skyrim Agard".
    public static func asciiFolderName(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "–", with: "-").replacingOccurrences(of: "—", with: "-")
            .replacingOccurrences(of: "’", with: "'").replacingOccurrences(of: "‘", with: "'")
            .replacingOccurrences(of: "“", with: "").replacingOccurrences(of: "”", with: "")
        t = t.applyingTransform(.toLatin, reverse: false) ?? t
        t = t.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        let bad = CharacterSet(charactersIn: "\\/:*?\"<>|")
        t = String(String.UnicodeScalarView(t.unicodeScalars.map { $0.isASCII && !bad.contains($0) && $0.value >= 32 ? $0 : "_" }))
        t = t.trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        return t.isEmpty ? "Profile" : t
    }

    /// Earlier names of a profile's save folder: the exact name (before 2026-10-19) and how Skyrim misread it.
    func legacySaveFolders(_ name: String) -> [URL] {
        let base = myGamesDir.appendingPathComponent("Saves/SkyrimMT")
        var names = [name]
        if let mojibake = String(data: Data(name.utf8), encoding: .windowsCP1252), mojibake != name { names.append(mojibake) }
        return names.filter { $0 != ModKit.asciiFolderName(name) }.map { base.appendingPathComponent($0) }
    }

    /// Point Skyrim at the active profile's saves (or back at the shared Saves folder).
    func applySavePath(_ name: String) throws {
        let custom = myGamesDir.appendingPathComponent("SkyrimCustom.ini")
        if profile(name)?.separateSaves == true {
            let folder = profileSavesFolder(name)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            // saves written under an earlier folder name move into the current one (never overwritten)
            let fm = FileManager.default
            for old in legacySaveFolders(name) where fm.fileExists(atPath: old.path) {
                for f in (try? fm.contentsOfDirectory(atPath: old.path)) ?? [] where !fm.fileExists(atPath: folder.appendingPathComponent(f).path) {
                    try? fm.moveItem(at: old.appendingPathComponent(f), to: folder.appendingPathComponent(f))
                }
                if ((try? fm.contentsOfDirectory(atPath: old.path)) ?? []).isEmpty { try? fm.removeItem(at: old) }
            }
            try IniEdit.set(custom, section: "General", key: "SLocalSavePath", value: "Saves\\SkyrimMT\\\(ModKit.asciiFolderName(name))\\")
        } else {
            try IniEdit.set(custom, section: "General", key: "SLocalSavePath", value: nil)
        }
    }

    public func setSeparateSaves(_ name: String, _ on: Bool) throws {
        guard var p = profile(name) else { throw ModKitError.noSuchProfile(name) }
        p.separateSaves = on; try saveProfile(p)
        if name == currentProfileName { try applySavePath(name) }
    }
}

extension ModKit {
    public static var gameININames: [String] { iniNames }

    /// The file a profile's game setting lives in right now (see swapINIs): the live My Games file for the active
    /// profile, the profile's own copy, or the shared copy used by profiles without their own INIs.
    public func iniURL(profile name: String, file: String) -> URL {
        if name == currentProfileName { return myGamesDir.appendingPathComponent(file) }
        if hasOwnINIs(name) { return profileINIDir(name).appendingPathComponent(file) }
        // profiles without own INIs share one set: live while such a profile is active, else the saved copy
        return hasOwnINIs(currentProfileName) ? sharedINIDir.appendingPathComponent(file) : myGamesDir.appendingPathComponent(file)
    }

    public func readINI(profile: String, file: String) -> String {
        let u = iniURL(profile: profile, file: file)
        return (try? String(contentsOf: u, encoding: .utf8)) ?? (try? String(contentsOf: u, encoding: .windowsCP1252)) ?? ""
    }

    /// Skyrim reads its INIs as Windows-1252 (found 2026-10-19): written in that encoding when it can hold the text.
    public func writeINI(profile: String, file: String, text: String) throws {
        let u = iniURL(profile: profile, file: file)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r\n")
        if let d = normalized.data(using: .windowsCP1252) { try d.write(to: u, options: .atomic) }
        else { try normalized.write(to: u, atomically: true, encoding: .utf8) }
    }
}
