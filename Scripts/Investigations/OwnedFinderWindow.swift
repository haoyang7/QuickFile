import Foundation
import AppKit
import ApplicationServices

enum OwnedFinderWindowError: Error {
    case rejected(focusStatus: Int32, reason: String)
}

// A Finder context menu temporarily removes AXFocusedWindow. Accept only the
// matching main window with an attached QuickFile menu; other errors fail closed.
func ownedFinderWindow(pid: pid_t, title: String, frame: CGRect) throws -> (AXUIElement, String) {
    guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
        throw OwnedFinderWindowError.rejected(focusStatus: Int32.min, reason: "Finder is not frontmost")
    }
    let app = AXUIElementCreateApplication(pid)
    func value(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
        var result: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, key as CFString, &result) == .success ? result : nil
    }
    func matches(_ window: AXUIElement) -> Bool {
        guard value(window, kAXTitleAttribute) as? String == title,
              let position = value(window, kAXPositionAttribute), let size = value(window, kAXSizeAttribute) else { return false }
        var p = CGPoint.zero; var s = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &p),
              AXValueGetValue(size as! AXValue, .cgSize, &s) else { return false }
        return abs(p.x - frame.minX) <= 1 && abs(p.y - frame.minY) <= 1 &&
            abs(s.width - frame.width) <= 1 && abs(s.height - frame.height) <= 1
    }
    var focused: CFTypeRef?
    let status = AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &focused)
    if status == .success, let focused {
        let window = focused as! AXUIElement
        guard matches(window) else {
            throw OwnedFinderWindowError.rejected(focusStatus: status.rawValue, reason: "focused window identity differs")
        }
        return (window, "focused")
    }
    guard status == .noValue, let rawMain = value(app, kAXMainWindowAttribute) else {
        throw OwnedFinderWindowError.rejected(focusStatus: status.rawValue, reason: "focused window unavailable")
    }
    let window = rawMain as! AXUIElement
    guard matches(window) else {
        throw OwnedFinderWindowError.rejected(focusStatus: status.rawValue, reason: "main window identity differs")
    }
    var queue = [window]; var index = 0
    while index < queue.count && index < 6000 {
        let element = queue[index]; index += 1
        if value(element, kAXRoleAttribute) as? String == kAXMenuItemRole,
           value(element, kAXTitleAttribute) as? String == "新建文件" {
            return (window, "main-with-attached-QuickFile-menu")
        }
        if let children = value(element, kAXChildrenAttribute) as? [AXUIElement] { queue.append(contentsOf: children) }
    }
    throw OwnedFinderWindowError.rejected(focusStatus: status.rawValue, reason: "owned context menu not attached")
}
