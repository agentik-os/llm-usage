import AppKit
import ApplicationServices

// Native accessibility actions used by the macOS 27 interaction checks.
func attribute(_ element: AXUIElement, _ key: String) -> Any? {
    var result: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, key as CFString, &result) == .success else { return nil }
    return result
}
let pid = pid_t(CommandLine.arguments[1])!
let identifier = CommandLine.arguments[2]
func find(_ element: AXUIElement, depth: Int = 0) -> AXUIElement? {
    guard depth < 30 else { return nil }
    if identifier == "--menu", attribute(element, "AXRole") as? String == "AXMenuBarItem" { return element }
    if attribute(element, "AXIdentifier") as? String == identifier { return element }
    for child in attribute(element, "AXChildren") as? [AXUIElement] ?? [] {
        if let match = find(child, depth: depth + 1) { return match }
    }
    return nil
}
guard let element = find(AXUIElementCreateApplication(pid)) else {
    fputs("Control not found: \(identifier)\n", stderr); exit(1)
}
if CommandLine.arguments.count > 3, CommandLine.arguments[3] == "bounds" {
    var point = CGPoint.zero
    var size = CGSize.zero
    guard let position = attribute(element, "AXPosition"), let extent = attribute(element, "AXSize"),
          AXValueGetValue(position as! AXValue, .cgPoint, &point),
          AXValueGetValue(extent as! AXValue, .cgSize, &size) else { exit(1) }
    print("\(point.x), \(point.y), \(size.width), \(size.height)")
} else if CommandLine.arguments.count > 4, CommandLine.arguments[3] == "replace-text" {
    guard attribute(element, "AXRole") as? String == "AXTextField",
          let application = NSRunningApplication(processIdentifier: pid) else {
        fputs("Expected an editable text field\n", stderr); exit(1)
    }
    application.activate(options: [])
    if let window = (attribute(AXUIElementCreateApplication(pid), "AXWindows") as? [AXUIElement])?.first {
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
    }
    let focused = AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    guard focused == .success else { fputs("Could not focus text field\n", stderr); exit(1) }
    RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    // Deliver actual editing events to this preview process. AXSetValue alone
    // changes its accessibility value without updating the SwiftUI binding.
    func key(_ code: CGKeyCode, flags: CGEventFlags = []) {
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)!
            event.flags = flags
            event.postToPid(pid)
        }
    }
    key(0, flags: .maskCommand)
    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    let text = Array(CommandLine.arguments[4].utf16)
    for down in [true, false] {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down)!
        text.withUnsafeBufferPointer { pointer in
            event.keyboardSetUnicodeString(stringLength: pointer.count, unicodeString: pointer.baseAddress)
        }
        event.postToPid(pid)
    }
    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    key(48)
} else {
    let role = attribute(element, "AXRole") as? String
    let result = role == "AXTextField"
        ? AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        : AXUIElementPerformAction(element, kAXPressAction as CFString)
    guard result == .success else { fputs("Action failed: \(result.rawValue)\n", stderr); exit(1) }
}
