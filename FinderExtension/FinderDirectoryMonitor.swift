import AppKit

/// Finder needs each mounted volume registered explicitly; observing / alone does not cover it.
final class FinderDirectoryMonitor {
    private let notificationCenter: NotificationCenter
    private let updateDirectories: (Set<URL>) -> Void
    private var observers: [NSObjectProtocol] = []
    private var directories: Set<URL> = []

    init(
        notificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
        mountedVolumes: @escaping () -> [URL] = {
            FileManager.default.mountedVolumeURLs(
                includingResourceValuesForKeys: nil,
                options: []
            ) ?? []
        },
        updateDirectories: @escaping (Set<URL>) -> Void
    ) {
        self.notificationCenter = notificationCenter
        self.updateDirectories = updateDirectories
        // Register before the initial snapshot so a mount during startup is not missed.
        observers = [
            NSWorkspace.didMountNotification,
            NSWorkspace.didUnmountNotification,
            NSWorkspace.didRenameVolumeNotification
        ].map { name in
            notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                self?.volumeChanged(notification)
            }
        }
        directories = Set(mountedVolumes().map(Self.directoryURL))
        publishDirectories()
    }

    deinit {
        for observer in observers { notificationCenter.removeObserver(observer) }
    }

    private func volumeChanged(_ notification: Notification) {
        guard let volume = notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL else { return }
        // A snapshot taken during rapid unmount/remount can still contain the old root.
        // Remove the notified URL explicitly so Finder releases that observation first.
        if notification.name == NSWorkspace.didUnmountNotification {
            directories.remove(Self.directoryURL(volume))
        } else {
            if notification.name == NSWorkspace.didRenameVolumeNotification,
               let oldVolume = notification.userInfo?[NSWorkspace.oldVolumeURLUserInfoKey] as? URL {
                directories.remove(Self.directoryURL(oldVolume))
            }
            directories.insert(Self.directoryURL(volume))
        }
        publishDirectories()
    }

    private func publishDirectories() {
        directories.insert(URL(fileURLWithPath: "/", isDirectory: true))
        updateDirectories(directories)
    }

    private static func directoryURL(_ url: URL) -> URL {
        URL(fileURLWithPath: url.path, isDirectory: true).standardizedFileURL
    }
}
