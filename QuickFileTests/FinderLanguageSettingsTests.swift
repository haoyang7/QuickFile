import XCTest
import QuickFileCore
@testable import QuickFileInfrastructure

final class FinderLanguageSettingsTests: XCTestCase {
    func testBlockedOldReadDoesNotBlockMenusOrOverwriteNewSelection() {
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let calls = LockedTestValue(0)
        let values = LockedTestValue<[QuickFileLanguage]>([])
        let published = expectation(description: "new choice published")
        let cache = FinderLanguageSettings(load: {
            XCTAssertFalse(Thread.isMainThread)
            let number = calls.update { $0 += 1; return $0 }
            if number == 1 {
                started.signal()
                _ = release.wait(timeout: .now() + 5)
                return .english
            }
            return .simplifiedChinese
        }, apply: { language in
            values.update { $0.append(language) }
            published.fulfill()
        }, notificationName: nil, refreshInterval: .infinity)
        XCTAssertEqual(started.wait(timeout: .now() + 2), .success)
        let menus = expectation(description: "menu refresh checks return while disk read is blocked")
        DispatchQueue.global().async {
            for _ in 0..<100 { cache.refreshIfNeeded() }
            menus.fulfill()
        }
        wait(for: [menus], timeout: 2)
        cache.requestRefresh()
        cache.requestRefresh()
        release.signal()
        wait(for: [published], timeout: 2)
        XCTAssertEqual(calls.value, 2)
        XCTAssertEqual(values.value, [.simplifiedChinese])
    }

    func testSeparateWriterNotifiesRunningReaderWithoutMenuPolling() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/Temporary/language-notification-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let name = "QuickFileTests.language.\(UUID())"
        let storage = LocalSharedStorage(root: root.resolvingSymlinksInPath())
        let writer = LanguageSettingsStore(storage: storage, changeNotificationName: name)
        let reader = LanguageSettingsStore(storage: storage)
        let applied = DispatchSemaphore(value: 0)
        let values = LockedTestValue<[QuickFileLanguage]>([])
        let cache = FinderLanguageSettings(load: { try reader.load() }, apply: { language in
            values.update { $0.append(language) }; applied.signal()
        }, notificationName: name, refreshInterval: .infinity)
        withExtendedLifetime(cache) {
            XCTAssertEqual(applied.wait(timeout: .now() + 2), .success)
        }
        for language in [QuickFileLanguage.english, .simplifiedChinese, .system] {
            try writer.save(language)
            XCTAssertEqual(applied.wait(timeout: .now() + 2), .success)
            XCTAssertEqual(values.value.last, language)
        }
        withExtendedLifetime(cache) {}
    }
}
