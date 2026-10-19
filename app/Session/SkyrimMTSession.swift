// SkyrimMT Session — invisible helper app inside SkyrimMT.app (Contents/Helpers). The launcher opens it through
// LaunchServices (`open -n -g -j ... --args <script> [args]`) to run the scripts that start Steam/Skyrim/setup.
// Processes started this way are not attributed to the launcher, so on macOS 27 quitting SkyrimMT really quits it:
// no "running in background" Dock state whose "Stop Running in Background" would kill Steam and the game.
// Output (stdout+stderr) goes to $SKYRIMMT_OUT, the exit code to $SKYRIMMT_OUT.status; then this app exits.
// (Same design as tf2mt's TF2Session.swift, v0.3.1.)
import Foundation
import Darwin

let env = ProcessInfo.processInfo.environment
let args = Array(CommandLine.arguments.dropFirst())
let out = env["SKYRIMMT_OUT"] ?? "/dev/null"
func finish(_ code: Int32) -> Never {
    if out != "/dev/null" { try? "\(code)\n".write(toFile: out + ".status", atomically: true, encoding: .utf8) }
    exit(code)
}
guard !args.isEmpty else { finish(2) }
var fa: posix_spawn_file_actions_t? = nil
posix_spawn_file_actions_init(&fa)
posix_spawn_file_actions_addopen(&fa, 0, "/dev/null", O_RDONLY, 0)
posix_spawn_file_actions_addopen(&fa, 1, out, O_WRONLY | O_CREAT | O_APPEND, 0o644)
posix_spawn_file_actions_adddup2(&fa, 1, 2)
var attr: posix_spawnattr_t? = nil
posix_spawnattr_init(&attr)
posix_spawnattr_setflags(&attr, Int16(0x0400))   // POSIX_SPAWN_SETSID
let cmd: [String] = ["/bin/bash"] + args
var argv: [UnsafeMutablePointer<CChar>?] = cmd.map { strdup($0) } + [nil]
var pid: pid_t = 0
guard posix_spawn(&pid, "/bin/bash", &fa, &attr, &argv, environ) == 0 else { finish(127) }
var status: Int32 = 0
while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
finish((status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f))
