import XCTest
@testable import QuickFile
@testable import QuickFileInfrastructure

final class FileCreationSettingsStoreTests: XCTestCase {
    private func makeRoot() throws -> URL {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/Temporary/file-creation-settings-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        return root.resolvingSymlinksInPath()
    }

    func testDefaultIsOffAndTwoInstancesReadOnlyExplicitSavedChoice() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = FileCreationSettingsStore(storage: LocalSharedStorage(root: root))
        let reader = FileCreationSettingsStore(storage: LocalSharedStorage(root: root))
        XCTAssertFalse(try reader.loadAutomaticallyOpen())
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("file-creation-settings.v1.json").path))
        try writer.saveAutomaticallyOpen(true)
        XCTAssertTrue(try reader.loadAutomaticallyOpen())
        try writer.saveAutomaticallyOpen(false)
        XCTAssertFalse(try reader.loadAutomaticallyOpen())
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["file-creation-settings.v1.json"])
        let attributes = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("file-creation-settings.v1.json").path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testInvalidSettingsArePreservedAndNeverEnableOpening() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = LocalSharedStorage(root: root)
        let url = root.appendingPathComponent("file-creation-settings.v1.json")
        let store = FileCreationSettingsStore(storage: storage)
        for text in ["", "{}", #"{"version":1}"#, #"{"version":2,"automaticallyOpen":true}"#,
                     #"{"version":1,"automaticallyOpen":1}"#, #"{"version":1,"automaticallyOpen":null}"#] {
            let data = Data(text.utf8)
            try storage.write(data, to: url)
            XCTAssertThrowsError(try store.loadAutomaticallyOpen())
            XCTAssertEqual(try storage.read(url, maximumBytes: 4096), data)
        }
        XCTAssertThrowsError(try FileCreationSettingsStore(storage: nil).loadAutomaticallyOpen())
        XCTAssertThrowsError(try FileCreationSettingsStore(storage: nil).saveAutomaticallyOpen(true))
    }

    func testSymlinkCannotEnableOpeningOrOverwriteOutsideFile() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = LocalSharedStorage(root: root)
        try storage.prepare(root)
        let target = root.appendingPathComponent("untouched.json")
        let data = Data(#"{"version":1,"automaticallyOpen":true}"#.utf8)
        try data.write(to: target)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("file-creation-settings.v1.json"), withDestinationURL: target)
        let store = FileCreationSettingsStore(storage: storage)
        XCTAssertThrowsError(try store.loadAutomaticallyOpen())
        XCTAssertThrowsError(try store.saveAutomaticallyOpen(false))
        XCTAssertEqual(try Data(contentsOf: target), data)
    }
}

@MainActor
final class CreationSettingsViewModelTests: XCTestCase {
    func testFailedSaveKeepsCommittedChoiceAndAllowsRetry() async {
        let shouldFail = LockedTestValue(true)
        let saved = LockedTestValue<[Bool]>([])
        let model = CreationSettingsViewModel(load: { false }, save: { value in
            if shouldFail.value { throw CocoaError(.fileWriteNoPermission) }
            saved.update { $0.append(value) }
        })
        await model.reload()
        await model.setAutomaticallyOpen(true)
        XCTAssertFalse(model.automaticallyOpen)
        XCTAssertNotNil(model.errorMessage)
        shouldFail.update { $0 = false }
        await model.setAutomaticallyOpen(true)
        XCTAssertTrue(model.automaticallyOpen)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(saved.value, [true])
    }

    func testFailedLoadDoesNotEnableOpeningAndExplicitOffCanRepair() async {
        let saved = LockedTestValue<[Bool]>([])
        let model = CreationSettingsViewModel(load: { throw FileCreationSettingsStore.StoreError.malformed },
                                              save: { value in saved.update { $0.append(value) } })
        await model.reload()
        XCTAssertFalse(model.automaticallyOpen)
        XCTAssertNotNil(model.errorMessage)
        await model.setAutomaticallyOpen(false)
        XCTAssertTrue(model.hasLoaded)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(saved.value, [false])
    }
}
