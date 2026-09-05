import AppKit
import ApplicationServices

// Read-only native accessibility snapshot for the isolated preview checks.
// macOS 27 exposes SwiftUI labels as attributed descriptions.
func attribute(_ element: AXUIElement, _ key: String) -> Any? {
    var result: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, key as CFString, &result) == .success else { return nil }
    return result
}
func plain(_ value: Any?) -> String {
    guard let value else { return "" }
    if let value = value as? NSAttributedString { return value.string }
    if let value = value as? String { return value }
    if let value = value as? NSNumber { return value.stringValue }
    return ""
}
let pid = pid_t(CommandLine.arguments[1])!
let root = AXUIElementCreateApplication(pid)
var rows: [[String: String]] = []
func visit(_ element: AXUIElement, depth: Int = 0) {
    guard depth < 30, rows.count < 1500 else { return }
    let label = ["AXTitle", "AXDescription", "AXAttributedDescription", "AXHelp"].map { plain(attribute(element, $0)) }.filter { !$0.isEmpty }.joined(separator: " | ")
    let value = ["AXValue", "AXAttributedValue"].map { plain(attribute(element, $0)) }.filter { !$0.isEmpty }.joined(separator: " | ")
    rows.append(["id": plain(attribute(element, "AXIdentifier")), "role": plain(attribute(element, "AXRole")), "text": label, "value": value])
    for child in attribute(element, "AXChildren") as? [AXUIElement] ?? [] { visit(child, depth: depth + 1) }
}
visit(root)
let data = try JSONSerialization.data(withJSONObject: rows, options: [.sortedKeys])
print(String(decoding: data, as: UTF8.self))
