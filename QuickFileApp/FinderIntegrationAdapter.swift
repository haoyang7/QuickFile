import FinderSync

@MainActor
enum FinderIntegrationAdapter {
    static var isEnabled: Bool {
        FIFinderSyncController.isExtensionEnabled
    }

    static func openManagement() {
        FIFinderSyncController.showExtensionManagementInterface()
    }
}
