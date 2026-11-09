// Every translation must take the same format arguments as its English key. A mismatch isn't a typo: "%@" given a number
// crashes the app when the string is shown. Run: swift tests/l10n/check.swift (or tests/l10n/run.sh)
import Foundation

let spec = try! NSRegularExpression(pattern: #"%(?:(\d+)\$)?[-+ #0]*\d*(?:\.\d+)?(hh|h|ll|l|q|z|t|j)?([@dDiuUxXoOfFeEgGcCsSaAp%])"#)
/// Argument number → conversion ("%@", "%ld"), positional or not. "%%" takes no argument.
func arguments(_ s: String) -> [Int: String] {
    var out: [Int: String] = [:], next = 1
    for m in spec.matches(in: s, range: NSRange(s.startIndex..., in: s)) {
        let conv = Range(m.range(at: 3), in: s).map { String(s[$0]) } ?? ""
        if conv == "%" { continue }
        let size = Range(m.range(at: 2), in: s).map { String(s[$0]) } ?? ""
        let n = Range(m.range(at: 1), in: s).flatMap { Int(s[$0]) } ?? next
        if Range(m.range(at: 1), in: s) == nil { next += 1 }
        out[n] = size + conv
    }
    return out
}
/// A % that isn't part of a valid conversion ("100 %" is "% " plus whatever follows: undefined).
func strayPercent(_ s: String) -> Bool {
    let matched = spec.matches(in: s, range: NSRange(s.startIndex..., in: s)).reduce(0) { n, m in
        n + (Range(m.range, in: s).map { s[$0].hasSuffix("%") ? 2 : 1 } ?? 0)
    }
    return s.filter { $0 == "%" }.count != matched
}

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "app/Resources")
let languages = try! FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasSuffix(".lproj") && !$0.hasPrefix("en") }.sorted()
var checked = 0, failed = 0
for lang in languages {
    let file = root.appendingPathComponent("\(lang)/Localizable.strings")
    guard let data = try? Data(contentsOf: file),
          let table = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: String] else {
        print("  FAIL \(lang): can't read Localizable.strings"); failed += 1; continue
    }
    for (key, value) in table {
        checked += 1
        if arguments(key) != arguments(value) {
            print("  FAIL \(lang): \(key.debugDescription) takes \(arguments(key)), its translation \(value.debugDescription) takes \(arguments(value))"); failed += 1
        } else if strayPercent(value) && !strayPercent(key) {
            print("  FAIL \(lang): stray % in \(value.debugDescription)"); failed += 1
        }
    }
}
print("\(languages.joined(separator: ", ")): \(checked) strings, \(failed) failed")
exit(failed == 0 ? 0 : 1)
