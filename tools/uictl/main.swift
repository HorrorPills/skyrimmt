// uictl — drive macOS UI for unattended checks: uictl click X Y [double] | move X Y | type TEXT | key NAME [cmd|shift|opt]…
// | scroll DY | front APP. Coordinates are screen points (as in a 1:1 screenshot scaled by the display factor).
import Foundation
import CoreGraphics
import AppKit

let a = Array(CommandLine.arguments.dropFirst())
func post(_ e: CGEvent?) { e?.post(tap: .cghidEventTap); usleep(12000) }
func mouse(_ t: CGEventType, _ p: CGPoint, clicks: Int64 = 1) {
    let e = CGEvent(mouseEventSource: nil, mouseType: t, mouseCursorPosition: p, mouseButton: .left)
    e?.setIntegerValueField(.mouseEventClickState, value: clicks); post(e)
}
let keys: [String: CGKeyCode] = ["return": 36, "tab": 48, "space": 49, "delete": 51, "escape": 53, "left": 123, "right": 124,
    "down": 125, "up": 126, "a": 0, "r": 15, "f": 3, "w": 13, "z": 6, "comma": 43, "1": 18, "2": 19, "3": 20, "4": 21, "5": 23, "6": 22, "7": 26, "8": 28, "9": 25, "0": 29, "o": 31, "d": 2, "u": 32]
switch a.first {
case "click"?:
    let p = CGPoint(x: Double(a[1])!, y: Double(a[2])!)
    mouse(.mouseMoved, p); mouse(.leftMouseDown, p); mouse(.leftMouseUp, p)
    if a.count > 3 && a[3] == "double" { mouse(.leftMouseDown, p, clicks: 2); mouse(.leftMouseUp, p, clicks: 2) }
case "move"?: mouse(.mouseMoved, CGPoint(x: Double(a[1])!, y: Double(a[2])!))
case "type"?:
    for ch in a.dropFirst().joined(separator: " ").utf16 {
        var c = ch
        let d = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true); d?.keyboardSetUnicodeString(stringLength: 1, unicodeString: &c); post(d)
        let u = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false); u?.keyboardSetUnicodeString(stringLength: 1, unicodeString: &c); post(u)
    }
case "key"?:
    guard let k = keys[a[1]] else { print("unknown key"); exit(2) }
    var f: CGEventFlags = []
    for m in a.dropFirst(2) { switch m { case "cmd": f.insert(.maskCommand); case "shift": f.insert(.maskShift); case "opt": f.insert(.maskAlternate); case "ctrl": f.insert(.maskControl); default: break } }
    let d = CGEvent(keyboardEventSource: nil, virtualKey: k, keyDown: true); d?.flags = f; post(d)
    let u = CGEvent(keyboardEventSource: nil, virtualKey: k, keyDown: false); u?.flags = f; post(u)
case "scroll"?:
    post(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: Int32(a[1])!, wheel2: 0, wheel3: 0))
case "front"?:
    NSWorkspace.shared.runningApplications.first { $0.localizedName == a[1] }?.activate()
    usleep(300000)
default: print("usage: uictl click X Y [double] | move X Y | type TEXT | key NAME [mods] | scroll DY | front APP")
}
