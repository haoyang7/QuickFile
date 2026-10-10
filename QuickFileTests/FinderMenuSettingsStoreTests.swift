import XCTest
@testable import QuickFileCore
@testable import QuickFileInfrastructure

final class FinderMenuSettingsStoreTests: XCTestCase {
    private var directoryURL: URL!
    private var notificationName: String!
    private var storageURL: URL { directoryURL.appendingPathComponent("finder-menu-settings.v1.json") }

    override func setUpWithError() throws {
        directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("QuickFileMenuSettings-\(UUID())", isDirectory: true)
        notificationName = "QuickFileTests.menu-settings.\(UUID())"
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directoryURL { try FileManager.default.removeItem(at: directoryURL) }
        directoryURL = nil
        notificationName = nil
    }

    func testMissingFileDefaultsToAllWithoutCreatingSettings() throws {
        XCTAssertEqual(try makeStore().load(), .all)
        XCTAssertFalse(FileManager.default.fileExists(atPath: storageURL.path))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directoryURL.path).isEmpty)
    }

    func testAllPersistsAsExplicitNullAndReloadsInAnotherStore() throws {
        try makeStore().save(.all)

        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: storageURL)) as? [String: Any])
        XCTAssertEqual(object["version"] as? Int, 1)
        XCTAssertTrue(object["maximumCount"] is NSNull)
        XCTAssertEqual(Set(object.keys), ["version", "maximumCount"])
        XCTAssertEqual(try makeStore().load(), .all)
    }

    func testPositiveLimitsIncludingIntMaxRoundTripAcrossIndependentReaders() throws {
        let writer = makeStore()
        let reader = makeStore()
        for count in [1, 8, 300, Int.max] {
            let expected = try FinderMenuDisplayLimit(maximumCount: count)
            try writer.save(expected)
            XCTAssertEqual(try reader.load(), expected, "Failed to reload \(count)")
            XCTAssertEqual(try makeStore().load(), expected)
        }
        try writer.save(.all)
        XCTAssertEqual(try reader.load(), .all)
    }

    func testUnavailableContainerReportsErrorsInsteadOfPretendingSettingsWereSaved() {
        let store = FinderMenuSettingsStore(storageURL: nil)
        XCTAssertThrowsError(try store.load()) { error in
            guard case FinderMenuSettingsStore.StoreError.unavailable = error else {
                return XCTFail("Unexpected load error: \(error)")
            }
        }
        XCTAssertThrowsError(try store.save(.all)) { error in
            guard case FinderMenuSettingsStore.StoreError.unavailable = error else {
                return XCTFail("Unexpected save error: \(error)")
            }
        }
    }

    func testMalformedDocumentsNeverSilentlyBecomeAll() throws {
        let malformedDocuments = [
            "", "not JSON", "null", "[]", "{}",
            #"{"version":1}"#,
            #"{"maximumCount":5}"#,
            #"{"version":null,"maximumCount":5}"#,
            #"{"version":0,"maximumCount":5}"#,
            #"{"version":2,"maximumCount":null}"#,
            #"{"version":"1","maximumCount":5}"#,
            #"{"version":true,"maximumCount":5}"#,
            #"{"version":1.5,"maximumCount":5}"#,
            #"{"version":9223372036854775808,"maximumCount":5}"#,
            #"{"version":1,"maximumCount":0}"#,
            #"{"version":1,"maximumCount":-1}"#,
            #"{"version":1,"maximumCount":-9223372036854775809}"#,
            #"{"version":1,"maximumCount":9223372036854775808}"#,
            #"{"version":1,"maximumCount":1.5}"#,
            #"{"version":1,"maximumCount":"5"}"#,
            #"{"version":1,"maximumCount":true}"#,
            #"{"version":1,"maximumCount":[]}"#,
            #"{"version":1,"maximumCount":{}}"#,
            #"{"version":1,"maximumCount":5} trailing"#
        ]
        for document in malformedDocuments {
            let data = Data(document.utf8)
            try data.write(to: storageURL, options: .atomic)
            XCTAssertThrowsError(try makeStore().load(), document) { error in
                guard case FinderMenuSettingsStore.StoreError.malformed = error else {
                    return XCTFail("Unexpected error for \(document): \(error)")
                }
            }
            XCTAssertEqual(try Data(contentsOf: storageURL), data, "Reading corruption must not rewrite it")
        }
    }

    func testInvalidUTF8IsMalformed() throws {
        try Data([0xff, 0xfe, 0x00, 0xff]).write(to: storageURL)
        XCTAssertThrowsError(try makeStore().load()) { error in
            guard case FinderMenuSettingsStore.StoreError.malformed = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testExistingDirectoryAtSettingsPathIsReadFailureNotMissingSettings() throws {
        try FileManager.default.createDirectory(at: storageURL, withIntermediateDirectories: false)
        XCTAssertThrowsError(try makeStore().load()) { error in
            guard case FinderMenuSettingsStore.StoreError.readFailed = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testSaveFailurePreservesPreviousSettingsAndTemplateBytes() throws {
        let liveDirectory = directoryURL.appendingPathComponent("live", isDirectory: true)
        let preservedDirectory = directoryURL.appendingPathComponent("preserved", isDirectory: true)
        try FileManager.default.createDirectory(at: liveDirectory, withIntermediateDirectories: false)
        let filename = "finder-menu-settings.v1.json"
        let store = FinderMenuSettingsStore(
            storageURL: liveDirectory.appendingPathComponent(filename),
            changeNotificationName: notificationName
        )
        let original = try FinderMenuDisplayLimit(maximumCount: 7)
        try store.save(original)
        let originalData = try Data(contentsOf: liveDirectory.appendingPathComponent(filename))
        let templateData = Data(#"[{"sentinel":"templates must remain byte-for-byte unchanged"}]"#.utf8)
        try templateData.write(to: liveDirectory.appendingPathComponent("templates.v2.json"))

        // Obstruct only this test's parent path with a regular file. This forces ENOTDIR
        // without permissions, a read-only volume, or touching any real App Group data.
        try FileManager.default.moveItem(at: liveDirectory, to: preservedDirectory)
        try Data("temporary obstruction".utf8).write(to: liveDirectory)
        XCTAssertThrowsError(try store.save(.all)) { error in
            guard case FinderMenuSettingsStore.StoreError.saveFailed = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: preservedDirectory.appendingPathComponent(filename)), originalData)
        XCTAssertEqual(try Data(contentsOf: preservedDirectory.appendingPathComponent("templates.v2.json")), templateData)
        try FileManager.default.removeItem(at: liveDirectory)
        try FileManager.default.moveItem(at: preservedDirectory, to: liveDirectory)
        XCTAssertEqual(try store.load(), original)
    }

    func testSettingsOperationsNeverReadOrRewriteTemplateFiles() throws {
        let templates = ["templates.json", "templates.v2.json"]
        let sentinel = Data([0x00, 0xff, 0x54, 0x45, 0x4d, 0x50, 0x0a])
        for filename in templates {
            try sentinel.write(to: directoryURL.appendingPathComponent(filename))
        }
        let store = makeStore()
        XCTAssertEqual(try store.load(), .all)
        for value in [FinderMenuDisplayLimit.all, try FinderMenuDisplayLimit(maximumCount: 3), .all] {
            try store.save(value)
            XCTAssertEqual(try store.load(), value)
            for filename in templates {
                XCTAssertEqual(try Data(contentsOf: directoryURL.appendingPathComponent(filename)), sentinel)
            }
        }
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: directoryURL.path).sorted(),
            (["finder-menu-settings.v1.json"] + templates).sorted()
        )
    }

    func testSaveNotifiesIndependentReadersOnlyAfterNewValueIsReadable() throws {
        let writer = makeStore()
        let firstReader = makeStore()
        let secondReader = makeStore()
        let expected = try FinderMenuDisplayLimit(maximumCount: 12)
        let firstNotified = expectation(description: "first reader sees committed settings")
        let secondNotified = expectation(description: "second reader sees committed settings")
        let firstObserver = DarwinTemplateNotificationObserver(name: notificationName) {
            XCTAssertEqual(try? firstReader.load(), expected)
            firstNotified.fulfill()
        }
        let secondObserver = DarwinTemplateNotificationObserver(name: notificationName) {
            XCTAssertEqual(try? secondReader.load(), expected)
            secondNotified.fulfill()
        }
        try writer.save(expected)
        withExtendedLifetime((firstObserver, secondObserver)) {
            wait(for: [firstNotified, secondNotified], timeout: 2)
        }
    }

    private func makeStore() -> FinderMenuSettingsStore {
        FinderMenuSettingsStore(storageURL: storageURL, changeNotificationName: notificationName)
    }
}
