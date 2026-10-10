import Foundation
import AppKit
import ApplicationServices

// Read-only instrumentation of an owned, non-sandbox fixture. Never performs AX actions.
// The executable must be inside this repository's temporary area and carry the fixture ID.
enum AXReadError: Error { case windows(status: Int32, count: Int) }
final class ObserverStats { var notifications = 0; var registrations = 0 }
@main struct PersistentAXRead {
    static func isOwnedFixture(_ executable: String) -> Bool {
        let source = URL(fileURLWithPath: #filePath).standardizedFileURL
        let root = source.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let path = URL(fileURLWithPath: executable).resolvingSymlinksInPath().path
        guard path.hasPrefix(root.appendingPathComponent(".build/Temporary/").path + "/"),
              path.hasSuffix("/UIRecovery.app/Contents/MacOS/UIRecovery") else { return false }
        let app = URL(fileURLWithPath: path).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return Bundle(url: app)?.bundleIdentifier == "local.quickfile.investigation.ui-recovery"
    }
    static func observe(pid: Int32, executable: String, observer: AXObserver?, stats: ObserverStats) throws -> [String:Any] {
        guard
              AXIsProcessTrusted(), let process = NSRunningApplication(processIdentifier: pid),
              process.executableURL?.standardizedFileURL.path == executable,
              isOwnedFixture(executable) else {
            throw CocoaError(.userCancelled)
        }
        let application = AXUIElementCreateApplication(pid)
        var windowsValue: CFTypeRef?
        let windowsStatus = AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &windowsValue)
        guard windowsStatus == .success, let allWindows = windowsValue as? [AXUIElement] else {
            throw AXReadError.windows(status:windowsStatus.rawValue,count:-1)
        }
        let windows = allWindows.filter { window in
            var title: CFTypeRef?
            return AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &title) == .success && title as? String == "QuickFile UI Recovery Fixture"
        }
        guard windows.count == 1 else { throw AXReadError.windows(status:windowsStatus.rawValue,count:windows.count) }
        var queue = windows; var seen: [AXUIElement] = []; var index = 0
        var checkboxes = 0; var namedCheckboxes = 0; var actionableCheckboxes = 0
        var roles: [String: Int] = [:]
        var attributesRead = 0; var failedAttributes = 0
        while index < queue.count && index < 10000 {
            let element = queue[index]; index += 1
            if seen.contains(where: { CFEqual($0, element) }) { continue }
            seen.append(element)
            if let observer {
                let status = AXObserverAddNotification(observer, element, kAXUIElementDestroyedNotification as CFString, Unmanaged.passUnretained(stats).toOpaque())
                if status == .success { stats.registrations += 1 }
            }
            var roleValue: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleValue) == .success,
               let role = roleValue as? String {
                roles[role, default: 0] += 1
                if role == kAXCheckBoxRole {
                    checkboxes += 1
                    let hasName = [kAXTitleAttribute, kAXDescriptionAttribute].contains { attribute in
                        var value: CFTypeRef?
                        return AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success
                            && (value as? String)?.isEmpty == false
                    }
                    if hasName { namedCheckboxes += 1 }
                    var actions: CFArray?
                    if AXUIElementCopyActionNames(element, &actions) == .success,
                       let names = actions as? [String], names.contains(kAXPressAction) { actionableCheckboxes += 1 }
                }
            }
            var namesValue: CFArray?
            if AXUIElementCopyAttributeNames(element, &namesValue) == .success,
               let names = namesValue as? [String] {
                for name in names {
                    var value: CFTypeRef?
                    let status = AXUIElementCopyAttributeValue(element, name as CFString, &value)
                    attributesRead += 1
                    if status != .success { failedAttributes += 1 }
                    if name == kAXChildrenAttribute, status == .success, let children = value as? [AXUIElement] {
                        queue.append(contentsOf: children)
                    }
                }
            }
        }
        guard index < 10000 else { throw CocoaError(.fileReadTooLarge) }
        let result: [String: Any] = ["pid": pid, "readCount": 1,
            "method": observer == nil ? "persistent direct AX; no explicit observer" : "persistent direct AX with owned element destroyed notifications", "destroyedNotificationRegistrations":stats.registrations,"destroyedNotificationsReceived":stats.notifications,
            "visibleCheckboxes": checkboxes, "namedCheckboxes": namedCheckboxes,
            "actionableCheckboxes": actionableCheckboxes, "roleCounts": roles, "uniqueElements": seen.count,
            "attributeReads": attributesRead, "failedAttributes": failedAttributes,
            "noUIActions": true, "noContentsExported": true]
        return result
    }
    static func main() throws {
        let arguments = CommandLine.arguments
        guard (arguments.count == 4 || (arguments.count == 5 && arguments[4] == "--observe-destroyed")),
              let pid = Int32(arguments[1]), pid > 0,
              isOwnedFixture(arguments[2]),
              NSRunningApplication(processIdentifier: pid)?.executableURL?.standardizedFileURL.path == arguments[2],
              AXIsProcessTrusted() else { throw CocoaError(.userCancelled) }
        let root = URL(fileURLWithPath:arguments[3]); let stats = ObserverStats()
        var observer: AXObserver?
        if arguments.contains("--observe-destroyed") {
            guard AXObserverCreate(pid, { _,_,_,context in
                if let context { Unmanaged<ObserverStats>.fromOpaque(context).takeUnretainedValue().notifications += 1 }
            }, &observer) == .success, let observer else { throw CocoaError(.userCancelled) }
            CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        for stage in ["baseline8","large300-1","restored8-1","large300-2","restored8-2"] {
            let deadline = Date().addingTimeInterval(180)
            while true {
                if Date() > deadline || FileManager.default.fileExists(atPath:root.appendingPathComponent("abort").path) { throw CocoaError(.userCancelled) }
                if let data = try? Data(contentsOf:root.appendingPathComponent("ready.json")),
                   let ready = try? JSONSerialization.jsonObject(with:data) as? [String:Any], ready["checkpoint"] as? String == stage, ready["pid"] as? Int32 == pid { break }
                _ = RunLoop.current.run(mode:.default, before:Date().addingTimeInterval(0.05))
            }
            var result = try observe(pid:pid, executable:arguments[2], observer:observer, stats:stats)
            result["checkpoint"] = stage
            try JSONSerialization.data(withJSONObject:result,options:.sortedKeys).write(to:root.appendingPathComponent("ax-\(stage).json"),options:.atomic)
        }
        let deadline = Date().addingTimeInterval(180)
        while true {
            if Date() > deadline || FileManager.default.fileExists(atPath:root.appendingPathComponent("abort").path) { throw CocoaError(.userCancelled) }
            if FileManager.default.fileExists(atPath:root.appendingPathComponent("release-reader").path) { break }
            _ = RunLoop.current.run(mode:.default,before:Date().addingTimeInterval(0.05))
        }
        try JSONSerialization.data(withJSONObject:["persistentThroughFiveCheckpoints":true,"releasedByHandshake":true,"observerRegistered":observer != nil,"registrations":stats.registrations,"notifications":stats.notifications],options:.sortedKeys).write(to:root.appendingPathComponent("native-reader-completed.json"),options:.atomic)
        withExtendedLifetime(observer) {}
    }
}
