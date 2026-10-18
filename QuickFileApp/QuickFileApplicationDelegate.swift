import AppKit

@MainActor
final class QuickFileApplicationDelegate: NSObject, NSApplicationDelegate {
    let folderService = QuickFileFolderService()

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard ProcessInfo.processInfo.environment["XCTestBundlePath"] == nil else { return }
        NSApp.servicesProvider = folderService
    }
}
