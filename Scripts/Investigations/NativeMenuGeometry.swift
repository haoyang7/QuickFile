import Foundation
import AppKit
import CoreGraphics
import ApplicationServices

// Read only the explicitly identified investigation window. The loading titles
// are checked against FinderMenuPresentation by test_finder_menu_observation.py.
@main struct Geometry {
static func main() throws {
let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder")
guard finder.count == 1 else { fatalError("unique Finder required") }
func attribute(_ element: AXUIElement, _ name: CFString) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, name, &value) == .success ? value : nil
}
let args = CommandLine.arguments
precondition(args.count == 6)
let title = args[1]
precondition(title.hasPrefix("QuickFileNativePerf-"))
let frame = CGRect(x: Double(args[2])!, y: Double(args[3])!, width: Double(args[4])!, height: Double(args[5])!)
let (window, source) = try ownedFinderWindow(pid: finder[0].processIdentifier, title: title, frame: frame)
var queue: [AXUIElement] = [window]
var index = 0
var rows: [[String:Any]] = []
while index < queue.count && index < 6000 {
    let element = queue[index]; index += 1
    let role = attribute(element, kAXRoleAttribute as CFString) as? String ?? ""
    let elementTitle = attribute(element, kAXTitleAttribute as CFString) as? String ?? ""
    let value = attribute(element, kAXValueAttribute as CFString) as? String ?? ""
    let isChild = role == kAXTextFieldRole as String && ["ColdChild","ColdRetry","ControlOwned.txt"].contains(value)
    if (isChild || role == kAXMenuItemRole as String && ["新建文件", "复制", "文本文档 (.txt)", "Owned Text (.txt)", "Owned 000 (.txt)", "在 QuickFile 中创建…", "正在确认创建位置…", "正在加载模板…"].contains(elementTitle)),
       let pos = attribute(element, kAXPositionAttribute as CFString), let size = attribute(element, kAXSizeAttribute as CFString) {
        var point = CGPoint.zero; var dimensions = CGSize.zero
        if AXValueGetValue(pos as! AXValue, .cgPoint, &point), AXValueGetValue(size as! AXValue, .cgSize, &dimensions) {
            rows.append(["title":isChild ? value : elementTitle,"x":point.x,"y":point.y,"width":dimensions.width,"height":dimensions.height])
        }
    }
    if let children = attribute(element, kAXChildrenAttribute as CFString) as? [AXUIElement] { queue.append(contentsOf: children) }
}
let data = try JSONSerialization.data(withJSONObject: ["ownedWindowTitle":title,"finderIsFrontmost":NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.finder","windowSource":source,"matchingMenuRows":rows], options: [.sortedKeys])
print(String(data:data,encoding:.utf8)!)

}
}
