import CoreGraphics
import Foundation

let owner = CommandLine.arguments[1]
let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
let filter = CommandLine.arguments.count > 2 && !CommandLine.arguments[2].isEmpty ? CommandLine.arguments[2] : nil
let wins = list.filter { ($0[kCGWindowOwnerName as String] as? String) == owner && ($0[kCGWindowLayer as String] as? Int) == 0 && (filter == nil || (($0[kCGWindowName as String] as? String) ?? "").contains(filter!)) }
let sorted = wins.sorted {
    let a = ($0[kCGWindowBounds as String] as? [String: Double]) ?? [:]
    let b = ($1[kCGWindowBounds as String] as? [String: Double]) ?? [:]
    return (a["Width"] ?? 0) * (a["Height"] ?? 0) > (b["Width"] ?? 0) * (b["Height"] ?? 0)
}
for w in sorted {
    let b = (w[kCGWindowBounds as String] as? [String: Double]) ?? [:]
    print("\(w[kCGWindowNumber as String] ?? 0) \(Int(b["Width"] ?? 0))x\(Int(b["Height"] ?? 0)) \(w[kCGWindowName as String] ?? "")")
}
