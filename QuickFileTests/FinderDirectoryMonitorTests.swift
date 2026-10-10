import AppKit
import XCTest

@MainActor
final class FinderDirectoryMonitorTests: XCTestCase {
    private let root = URL(fileURLWithPath: "/", isDirectory: true)
    private let first = URL(fileURLWithPath: "/Volumes/First", isDirectory: true)
    private let second = URL(fileURLWithPath: "/Volumes/Second", isDirectory: true)

    func testDefaultEnumerationRegistersAllMountedVolumesIncludingHiddenOnes() {
        let mountedPaths = Set((FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: nil,
            options: []
        ) ?? []).map { $0.standardizedFileURL.path })
        var registered: Set<URL> = []
        let monitor = FinderDirectoryMonitor(
            notificationCenter: NotificationCenter(),
            updateDirectories: { registered = $0 }
        )
        // URL equality includes its representation; the monitor registers canonical directory URLs.
        XCTAssertEqual(Set(registered.map(\.path)), mountedPaths.union([root.path]))
        withExtendedLifetime(monitor) {}
    }

    func testStartupNormalizesVolumePathsAndDirectoryHints() {
        var registered: Set<URL> = []
        let monitor = FinderDirectoryMonitor(
            notificationCenter: NotificationCenter(),
            mountedVolumes: {
                [URL(fileURLWithPath: "/Volumes/First/../First", isDirectory: false), self.first]
            },
            updateDirectories: { registered = $0 }
        )
        XCTAssertEqual(registered, [root, first])
        XCTAssertTrue(registered.allSatisfy(\.hasDirectoryPath))
        withExtendedLifetime(monitor) {}
    }

    func testStartupRegistersExistingVolumesAndRoot() {
        var updates: [Set<URL>] = []
        let monitor = FinderDirectoryMonitor(
            notificationCenter: NotificationCenter(),
            mountedVolumes: { [self.root, self.first, self.first, self.second] },
            updateDirectories: { updates.append($0) }
        )
        XCTAssertEqual(updates, [[root, first, second]])
        withExtendedLifetime(monitor) {}
    }

    func testMountAndUnmountRefreshWithoutRestart() {
        let center = NotificationCenter()
        var volumes = [first]
        var updates: [Set<URL>] = []
        let monitor = FinderDirectoryMonitor(
            notificationCenter: center,
            mountedVolumes: { volumes },
            updateDirectories: { updates.append($0) }
        )
        volumes.append(second)
        center.post(name: NSWorkspace.didMountNotification, object: nil,
                    userInfo: [NSWorkspace.volumeURLUserInfoKey: second])
        XCTAssertEqual(updates.last, [root, first, second])
        volumes.removeAll()
        center.post(name: NSWorkspace.didUnmountNotification, object: nil,
                    userInfo: [NSWorkspace.volumeURLUserInfoKey: first])
        center.post(name: NSWorkspace.didUnmountNotification, object: nil,
                    userInfo: [NSWorkspace.volumeURLUserInfoKey: second])
        XCTAssertEqual(updates.last, [root])
        XCTAssertEqual(updates.count, 4)
        withExtendedLifetime(monitor) {}
    }

    func testRenameRemovesOldMountPath() {
        let center = NotificationCenter()
        var volumes = [first]
        var updates: [Set<URL>] = []
        let monitor = FinderDirectoryMonitor(
            notificationCenter: center,
            mountedVolumes: { volumes },
            updateDirectories: { updates.append($0) }
        )
        volumes = [second]
        center.post(name: NSWorkspace.didRenameVolumeNotification, object: nil,
                    userInfo: [NSWorkspace.volumeURLUserInfoKey: second,
                               NSWorkspace.oldVolumeURLUserInfoKey: first])
        XCTAssertEqual(updates.last, [root, second])
        XCTAssertFalse(updates.last!.contains(first))
        withExtendedLifetime(monitor) {}
    }

    func testRapidRemountReleasesOldObservationDespiteStaleVolumeSnapshot() {
        let center = NotificationCenter()
        var reads = 0
        var updates: [Set<URL>] = []
        let monitor = FinderDirectoryMonitor(
            notificationCenter: center,
            mountedVolumes: { reads += 1; return [self.first] },
            updateDirectories: { updates.append($0) }
        )
        // The enumerator continues reporting the old URL throughout both events.
        let notifiedURL = URL(fileURLWithPath: first.path, isDirectory: false)
        center.post(name: NSWorkspace.didUnmountNotification, object: nil,
                    userInfo: [NSWorkspace.volumeURLUserInfoKey: notifiedURL])
        center.post(name: NSWorkspace.didMountNotification, object: nil,
                    userInfo: [NSWorkspace.volumeURLUserInfoKey: notifiedURL])
        XCTAssertEqual(updates, [[root, first], [root], [root, first]])
        XCTAssertEqual(reads, 1)
        withExtendedLifetime(monitor) {}
    }

    func testDestroyingMonitorUnregistersVolumeCallbacks() {
        let center = NotificationCenter()
        var reads = 0
        var monitor: FinderDirectoryMonitor? = FinderDirectoryMonitor(
            notificationCenter: center,
            mountedVolumes: { reads += 1; return [] },
            updateDirectories: { _ in }
        )
        weak var weakMonitor = monitor
        XCTAssertEqual(reads, 1)
        monitor = nil
        XCTAssertNil(weakMonitor)
        for name in [
            NSWorkspace.didMountNotification,
            NSWorkspace.didUnmountNotification,
            NSWorkspace.didRenameVolumeNotification
        ] {
            center.post(name: name, object: nil)
        }
        XCTAssertEqual(reads, 1)
    }
}
