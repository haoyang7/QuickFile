import AppKit
import ApplicationServices

#if QUICKFILE_AX_MALLOC_RECEIPT
private func mallocScribbleEnvironment() -> String {
    guard let value = getenv("MallocScribble") else { return "unset" }
    return strcmp(value, "1") == 0 ? "1" : "other"
}
#endif

private final class NotificationCount {
    struct Target {
        let element: AXUIElement
        var deliveries: [Int]
    }
    var observers: [AXObserver] = []
    var targets: [Target] = []
    var all = 0
    var unmatched = 0

    func track(_ element: AXUIElement) {
        precondition(!targets.contains { CFEqual($0.element, element) }, "Each button is a new generation")
        targets.append(Target(element: element, deliveries: Array(repeating: 0, count: observers.count)))
    }

    func receive(_ observer: AXObserver, element: AXUIElement) {
        all += 1
        guard let target = targets.firstIndex(where: { CFEqual($0.element, element) }),
              let observer = observers.firstIndex(where: { CFEqual($0, observer) }) else {
            unmatched += 1
            return
        }
        targets[target].deliveries[observer] += 1
    }

    var receipt: [String: Any] {
        ["notifications": all - unmatched, "all_notifications": all,
         "unmatched_notifications": unmatched, "tracked_buttons": targets.count,
         "target_notification_counts": targets.map(\.deliveries)]
    }
}

// Read and subscribe only to the exact fixture executable and its owned window.
// This client never invokes accessibility actions or operates another application.
@main struct AXCompatibilityReader {
    static func main() throws {
        let args = CommandLine.arguments
        if args.count == 2, args[1] == "--capabilities" {
            var result: [String: Any] = ["trusted": AXIsProcessTrusted()]
#if QUICKFILE_AX_MALLOC_RECEIPT
            result["malloc_scribble"] = mallocScribbleEnvironment()
#endif
            let data = try JSONSerialization.data(withJSONObject: result, options: .sortedKeys)
            print(String(decoding: data, as: UTF8.self))
            return
        }
        let readOnly = args.count == 5 && args[4] == "--read-only"
        guard (args.count == 4 || readOnly), let pid = Int32(args[1]), AXIsProcessTrusted() else { exit(2) }
        let state = URL(fileURLWithPath: args[3]).standardizedFileURL
        let expected = state.deletingLastPathComponent()
            .appendingPathComponent("AXCompatibilityFixture.app/Contents/MacOS/AXCompatibilityFixture").path
        guard args[2] == expected,
              NSRunningApplication(processIdentifier: pid)?.executableURL?.path == expected else { exit(3) }
        let count = NotificationCount()
        var observers: [AXObserver] = []
        let application = AXUIElementCreateApplication(pid)
        for _ in 0..<(readOnly ? 0 : 2) {
            var value: AXObserver?
            guard AXObserverCreate(pid, { observer, element, _, context in
                if let context {
                    Unmanaged<NotificationCount>.fromOpaque(context).takeUnretainedValue().receive(observer, element: element)
                }
            }, &value) == .success, let value else { exit(4) }
            CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(value), .defaultMode)
            guard AXObserverAddNotification(value, application, kAXUIElementDestroyedNotification as CFString,
                Unmanaged.passUnretained(count).toOpaque()) == .success else { exit(5) }
            observers.append(value)
        }
        count.observers = observers
        defer {
            for observer in observers {
                CFRunLoopRemoveSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(observer), .defaultMode)
            }
        }
        var lastSequence = 0
        let deadline = Date().addingTimeInterval(180)
        while Date() < deadline, !FileManager.default.fileExists(atPath: state.appendingPathComponent("stop-reader").path) {
            if let data = try? Data(contentsOf: state.appendingPathComponent("reader-command.json")),
               let command = try? JSONSerialization.jsonObject(with: data) as? [String: Int],
               let sequence = command["sequence"], sequence > lastSequence {
                var windowsValue: CFTypeRef?
                guard AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &windowsValue) == .success,
                      let windows = windowsValue as? [AXUIElement] else { exit(6) }
                let owned = windows.filter { window in
                    var title: CFTypeRef?
                    _ = AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &title)
                    return title as? String == "QuickFile AX Compatibility Test"
                }
                guard owned.count <= 1 else { exit(7) }
                if owned.isEmpty {
                    _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.025))
                    continue
                }
                var queue = owned, visited: [AXUIElement] = []
                var index = 0, buttons = 0, registrations = 0
                while index < queue.count, index < 500 {
                    let element = queue[index]
                    index += 1
                    if visited.contains(where: { CFEqual($0, element) }) { continue }
                    visited.append(element)
                    var identifier: CFTypeRef?
                    _ = AXUIElementCopyAttributeValue(element, kAXIdentifierAttribute as CFString, &identifier)
                    if let identifier = identifier as? String, identifier.hasPrefix("owned-ax-") {
                        buttons += 1
                        count.track(element)
                        for observer in observers {
                            guard AXObserverAddNotification(observer, element, kAXUIElementDestroyedNotification as CFString,
                                Unmanaged.passUnretained(count).toOpaque()) == .success else { exit(8) }
                            registrations += 1
                        }
                    }
                    var children: CFTypeRef?
                    if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
                       let children = children as? [AXUIElement] { queue.append(contentsOf: children) }
                }
                var result = count.receipt
                result["sequence"] = sequence
                result["buttons"] = buttons
                result["registrations"] = registrations
#if QUICKFILE_AX_MALLOC_RECEIPT
                result["malloc_scribble"] = mallocScribbleEnvironment()
#endif
                try JSONSerialization.data(withJSONObject: result, options: .sortedKeys)
                    .write(to: state.appendingPathComponent("reader-ready.json"), options: .atomic)
                lastSequence = sequence
            }
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.025))
        }
        try JSONSerialization.data(withJSONObject: count.receipt, options: .sortedKeys)
            .write(to: state.appendingPathComponent("reader-completed.json"), options: .atomic)
        withExtendedLifetime(observers) {}
    }
}
