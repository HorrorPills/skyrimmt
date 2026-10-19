// skyrimmt-keyhelper — the only SkyrimMT code that touches the Nexus API key in the login Keychain.
// Why a separate program: SkyrimMT is signed with a self-made certificate, and for such apps macOS ties the Keychain's
// "Always Allow" to the exact binary — every app update would ask again. This helper is built once and reused
// unchanged by every app build (app/build.sh caches it by source hash), so one "Always Allow" lasts.
//   skyrimmt-keyhelper get        → key on stdout (exit 1 if none)
//   skyrimmt-keyhelper set        ← key on stdin
//   skyrimmt-keyhelper delete
import Foundation
import Security

let service = "SkyrimMT Nexus Mods API key"
let args = CommandLine.arguments
func base() -> [String: Any] { [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service] }

switch args.count > 1 ? args[1] : "" {
case "get":
    var q = base(); q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
    var out: CFTypeRef?
    guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { exit(1) }
    FileHandle.standardOutput.write(d)
case "set":
    let key = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !key.isEmpty else { exit(2) }
    SecItemDelete(base() as CFDictionary)
    var q = base(); q[kSecAttrAccount as String] = "apikey"; q[kSecValueData as String] = Data(key.utf8)
    exit(SecItemAdd(q as CFDictionary, nil) == errSecSuccess ? 0 : 3)
case "delete":
    SecItemDelete(base() as CFDictionary)
default:
    FileHandle.standardError.write(Data("usage: skyrimmt-keyhelper get|set|delete\n".utf8)); exit(64)
}
