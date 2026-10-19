// Game controllers for the launcher: what macOS sees (GameController framework — live connect/disconnect, battery;
// IOKit HID for Bluetooth/USB), Bluetooth pads that are paired but switched off, and what Skyrim will see — XInput 1.3
// inside Skyrim's Wine prefix (scripts/controllers.sh → xinputprobe.exe; Wine's winebus maps pads to XInput via SDL).
import Foundation
import GameController
import IOKit.hid

struct Pad: Identifiable, Equatable {
    var id: String { name + transport }
    let name: String
    let transport: String      // "Bluetooth", "USB", …
    var battery: Int?          // percent
    var charging = false
}

@MainActor
final class ControllerMonitor: ObservableObject {
    @Published var pads: [Pad] = []
    @Published var pairedOff: [String] = []     // paired Bluetooth gamepads that are not connected
    @Published var gameSlots: [Int]? = nil      // XInput slots with a pad, as Skyrim sees them (nil = not checked yet)
    @Published var checking = false
    @Published var probeError: String?
    private var observers: [NSObjectProtocol] = []
    private var probeTask: Task<Void, Never>?

    init() {
        let nc = NotificationCenter.default
        for n in [Notification.Name.GCControllerDidConnect, .GCControllerDidDisconnect] {
            observers.append(nc.addObserver(forName: n, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refresh(probeAfter: 2) }   // winebus needs a moment to see the change
            })
        }
        GCController.startWirelessControllerDiscovery {}   // lets already-paired pads that wake up show up promptly
        refresh(probeAfter: 0)
    }

    func refresh(probeAfter delay: Double? = nil) {
        var list = ControllerMonitor.hidPads()
        for c in GCController.controllers() {   // battery from the GameController framework, matched by name
            let name = c.vendorName ?? c.productCategory
            guard let b = c.battery, !(b.batteryState == .unknown && b.batteryLevel <= 0) else { continue }   // unknown ≠ empty
            if let i = list.firstIndex(where: { $0.name == name || name.contains($0.name) || $0.name.contains(name) }) {
                list[i].battery = Int((b.batteryLevel * 100).rounded()); list[i].charging = b.batteryState == .charging
            } else {
                list.append(Pad(name: name, transport: "", battery: Int((b.batteryLevel * 100).rounded()), charging: b.batteryState == .charging))
            }
        }
        if list != pads { pads = list }
        Task.detached {
            let off = ControllerMonitor.pairedBluetoothPads(connected: false)
            await MainActor.run { if off != self.pairedOff { self.pairedOff = off } }
        }
        if let d = delay { probe(after: d) }
    }

    /// Ask XInput inside Skyrim's prefix which slots have a controller (≈2 s; starts the prefix if needed).
    func probe(after delay: Double = 0) {
        probeTask?.cancel()
        probeTask = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1e9)) }
            guard let self, !Task.isCancelled else { return }
            self.checking = true
            let r = await Task.detached { shell(["/bin/bash", Paths.script("controllers.sh")]) }.value
            let lines = r.output.split(separator: "\n").map(String.init)
            if let e = lines.first(where: { $0.hasPrefix("error") }) {
                self.probeError = String(e.dropFirst(6)); self.gameSlots = nil
            } else {
                self.probeError = nil
                self.gameSlots = lines.compactMap { l -> Int? in
                    let f = l.split(separator: " "); return f.count >= 3 && f[2] == "connected" ? Int(f[1]) : nil
                }
            }
            self.checking = false
        }
    }

    /// HID game controllers (Generic Desktop: joystick, gamepad, multi-axis) with their transport.
    nonisolated static func hidPads() -> [Pad] {
        let m = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let match = [4, 5, 8].map { [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: $0] as CFDictionary }
        IOHIDManagerSetDeviceMatchingMultiple(m, match as CFArray)
        guard let set = IOHIDManagerCopyDevices(m) as? Set<IOHIDDevice> else { return [] }
        var seen = Set<String>(), out: [Pad] = []
        for d in set {
            let name = IOHIDDeviceGetProperty(d, kIOHIDProductKey as CFString) as? String ?? "Game controller"
            let transport = IOHIDDeviceGetProperty(d, kIOHIDTransportKey as CFString) as? String ?? ""
            let key = name + transport
            if seen.insert(key).inserted { out.append(Pad(name: name, transport: transport.hasPrefix("Bluetooth") ? "Bluetooth" : transport)) }
        }
        return out.sorted { $0.name < $1.name }
    }

    /// Paired Bluetooth devices whose minor type is Gamepad/Joystick (system_profiler; no Bluetooth permission needed).
    nonisolated static func pairedBluetoothPads(connected: Bool) -> [String] {
        let r = shell(["/usr/sbin/system_profiler", "SPBluetoothDataType", "-json"])
        guard let data = r.output.data(using: .utf8),
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let bt = (j["SPBluetoothDataType"] as? [[String: Any]])?.first else { return [] }
        let key = connected ? "device_connected" : "device_not_connected"
        var names: [String] = []
        for entry in bt[key] as? [[String: Any]] ?? [] {
            for (name, info) in entry {
                let minor = (info as? [String: Any])?["device_minorType"] as? String ?? ""
                if minor.localizedCaseInsensitiveContains("gamepad") || minor.localizedCaseInsensitiveContains("joystick") { names.append(name) }
            }
        }
        return names.sorted()
    }
}
