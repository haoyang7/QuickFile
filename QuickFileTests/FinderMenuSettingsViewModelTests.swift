import Foundation
import XCTest
@testable import QuickFile
@testable import QuickFileCore

@MainActor
final class FinderMenuSettingsViewModelTests: XCTestCase {
    func testInitializationDoesNotReadOrWriteAndStartsWithAll() {
        let fixture = MenuSettingsFixture()
        let model = makeModel(fixture)

        XCTAssertEqual(model.savedLimit, .all)
        XCTAssertTrue(model.showsAll)
        XCTAssertEqual(model.maximumCountText, "")
        XCTAssertFalse(model.hasLoaded)
        XCTAssertFalse(model.canEdit)
        XCTAssertEqual(fixture.loadCount, 0)
        XCTAssertEqual(fixture.saveCount, 0)
    }

    func testInitialLoadRunsOnceOffMainThreadAndPopulatesEditor() async throws {
        let value = try FinderMenuDisplayLimit(maximumCount: 7)
        let fixture = MenuSettingsFixture(value: value)
        let model = makeModel(fixture)

        await model.loadIfNeeded()
        await model.loadIfNeeded()

        XCTAssertEqual(fixture.loadCount, 1)
        XCTAssertEqual(model.savedLimit, value)
        XCTAssertFalse(model.showsAll)
        XCTAssertEqual(model.maximumCountText, "7")
        XCTAssertEqual(model.savedSummary, "已保存：最多 7 个模板")
        XCTAssertTrue(model.canEdit)
        XCTAssertFalse(model.canSave)
    }

    func testSavePersistsAndNormalizesPositiveCountOffMainThread() async throws {
        let fixture = MenuSettingsFixture()
        let model = makeModel(fixture)
        await model.loadIfNeeded()
        model.showsAll = false
        model.maximumCountText = "  12\n"
        XCTAssertTrue(model.canSave)

        let saved = await model.save()

        XCTAssertTrue(saved)
        XCTAssertEqual(fixture.value, try FinderMenuDisplayLimit(maximumCount: 12))
        XCTAssertEqual(model.savedLimit, fixture.value)
        XCTAssertEqual(model.maximumCountText, "12")
        XCTAssertEqual(model.status, .success("Finder 菜单设置已保存。"))
        XCTAssertFalse(model.canSave)
        XCTAssertFalse(model.isSaving)
    }

    func testSwitchingBackToAllIgnoresUnusedCountText() async throws {
        let fixture = MenuSettingsFixture(value: try FinderMenuDisplayLimit(maximumCount: 3))
        let model = makeModel(fixture)
        await model.loadIfNeeded()
        model.showsAll = true
        model.maximumCountText = "invalid"

        let saved = await model.save()

        XCTAssertTrue(saved)
        XCTAssertEqual(fixture.value, .all)
        XCTAssertEqual(model.savedLimit, .all)
        XCTAssertEqual(model.maximumCountText, "")
        XCTAssertEqual(model.savedSummary, "已保存：全部模板")
    }

    func testInvalidDraftsNeverWriteOrChangeSavedLimit() async throws {
        let original = try FinderMenuDisplayLimit(maximumCount: 5)
        let fixture = MenuSettingsFixture(value: original)
        let model = makeModel(fixture)
        await model.loadIfNeeded()

        for text in ["", " ", "0", "-1", "+1", "1.5", "1e2", "１２", "2 3", String(repeating: "9", count: 100)] {
            model.maximumCountText = text
            XCTAssertTrue(model.canSave, text)
            let saved = await model.save()
            XCTAssertFalse(saved, text)
            XCTAssertEqual(model.savedLimit, original, text)
            XCTAssertEqual(model.maximumCountText, text)
            guard case let .failure(message) = model.status else {
                XCTFail("Expected a validation error for \(text)")
                continue
            }
            XCTAssertFalse(message.isEmpty)
        }
        XCTAssertEqual(fixture.saveCount, 0)
        XCTAssertEqual(fixture.value, original)
    }

    func testSaveFailureKeepsLastCommittedValueAndDraftForRetry() async throws {
        let original = try FinderMenuDisplayLimit(maximumCount: 4)
        let fixture = MenuSettingsFixture(value: original)
        let model = makeModel(fixture)
        await model.loadIfNeeded()
        fixture.setFailure(load: false, save: true)
        model.maximumCountText = "8"

        let failedSave = await model.save()

        XCTAssertFalse(failedSave)
        XCTAssertEqual(model.savedLimit, original)
        XCTAssertEqual(fixture.value, original)
        XCTAssertEqual(model.maximumCountText, "8")
        XCTAssertEqual(model.status, .failure(MenuSettingsTestError.unavailable.localizedDescription))
        XCTAssertTrue(model.canSave)
        XCTAssertFalse(model.isSaving)

        fixture.setFailure(load: false, save: false)
        let retry = await model.save()
        XCTAssertTrue(retry)
        XCTAssertEqual(model.savedLimit.maximumCount, 8)
        XCTAssertEqual(fixture.saveCount, 2)
    }

    func testReloadFailurePreservesCommittedValueAndAllowsExplicitRecovery() async throws {
        let original = try FinderMenuDisplayLimit(maximumCount: 6)
        let fixture = MenuSettingsFixture(value: original)
        let model = makeModel(fixture)
        await model.loadIfNeeded()
        fixture.setFailure(load: true, save: false)

        await model.reload()

        XCTAssertEqual(model.savedLimit, original)
        XCTAssertEqual(model.maximumCountText, "6")
        XCTAssertEqual(model.loadError, MenuSettingsTestError.unavailable.localizedDescription)
        XCTAssertTrue(model.canEdit)
        XCTAssertTrue(model.canSave)
        XCTAssertFalse(model.isLoading)
        XCTAssertEqual(fixture.saveCount, 0, "Read failure alone must not write")

        fixture.setFailure(load: false, save: false)
        await model.reload()
        XCTAssertNil(model.loadError)
        XCTAssertTrue(model.canEdit)
    }

    func testFailedInitialLoadDoesNotRepeatedlyReadUntilExplicitRetry() async {
        let fixture = MenuSettingsFixture()
        fixture.setFailure(load: true, save: false)
        let model = makeModel(fixture)

        await model.loadIfNeeded()
        await model.loadIfNeeded()
        XCTAssertEqual(fixture.loadCount, 1)
        XCTAssertFalse(model.hasLoaded)
        XCTAssertTrue(model.canSave, "Explicit Save can repair storage after a failed read")
        XCTAssertEqual(model.savedLimit, .all)

        fixture.setFailure(load: false, save: false)
        await model.reload()
        XCTAssertTrue(model.hasLoaded)
        XCTAssertNil(model.loadError)
        XCTAssertEqual(fixture.loadCount, 2)
    }

    func testFailedInitialReadCanRecoverByExplicitlySavingValidCount() async {
        let fixture = MenuSettingsFixture()
        fixture.setFailure(load: true, save: false)
        let model = makeModel(fixture)
        await model.loadIfNeeded()
        XCTAssertEqual(fixture.saveCount, 0)
        model.showsAll = false
        model.maximumCountText = "15"

        let saved = await model.save()

        XCTAssertTrue(saved)
        XCTAssertEqual(fixture.value.maximumCount, 15)
        XCTAssertEqual(model.savedLimit.maximumCount, 15)
        XCTAssertTrue(model.hasLoaded)
        XCTAssertNil(model.loadError)
        XCTAssertFalse(model.canSave)
    }

    func testFailedInitialReadCanRecoverByExplicitlySavingDefaultAll() async {
        let fixture = MenuSettingsFixture()
        fixture.setFailure(load: true, save: false)
        let model = makeModel(fixture)
        await model.loadIfNeeded()
        XCTAssertTrue(model.showsAll)
        XCTAssertTrue(model.canSave)

        let saved = await model.save()

        XCTAssertTrue(saved)
        XCTAssertEqual(fixture.saveCount, 1, "Explicit default Save must replace unreadable storage")
        XCTAssertEqual(fixture.value, .all)
        XCTAssertTrue(model.hasLoaded)
        XCTAssertNil(model.loadError)
    }

    func testSaveCannotOverwriteUnloadedSettings() async {
        let fixture = MenuSettingsFixture()
        let model = makeModel(fixture)
        model.showsAll = false
        model.maximumCountText = "9"

        let saved = await model.save()

        XCTAssertFalse(saved)
        XCTAssertEqual(fixture.loadCount, 0)
        XCTAssertEqual(fixture.saveCount, 0)
    }

    func testBlockedLoadKeepsMainActorResponsiveAndRejectsOverlappingSaveAndLoad() async throws {
        let gate = MenuSettingsOperationGate()
        defer { gate.release.signal() }
        let original = try FinderMenuDisplayLimit(maximumCount: 4)
        let fixture = MenuSettingsFixture(value: original, loadGate: gate)
        let model = makeModel(fixture)
        let load = Task { await model.loadIfNeeded() }
        let started = await BackgroundWork.run { gate.started.wait(timeout: .now() + 5) == .success }
        XCTAssertTrue(started)
        XCTAssertTrue(Thread.isMainThread)
        XCTAssertTrue(model.isLoading)
        XCTAssertFalse(model.canEdit)

        // Even programmatic changes while a read is pending must retain the draft.
        model.showsAll = false
        model.maximumCountText = "10"
        let overlappingSave = await model.save()
        await model.reload()
        XCTAssertFalse(overlappingSave)
        XCTAssertEqual(fixture.loadCount, 1)
        XCTAssertEqual(fixture.saveCount, 0)
        gate.release.signal()
        await load.value

        XCTAssertFalse(model.isLoading)
        XCTAssertEqual(model.savedLimit, original)
        XCTAssertEqual(model.maximumCountText, "10")
        XCTAssertTrue(model.canSave)
        let saved = await model.save()
        XCTAssertTrue(saved)
        XCTAssertEqual(model.savedLimit.maximumCount, 10)
    }

    func testBlockedSaveCannotBeSupersededByLoadOrDuplicateSaveAndPreservesNewerDraft() async throws {
        let gate = MenuSettingsOperationGate()
        defer { gate.release.signal() }
        let fixture = MenuSettingsFixture(value: try FinderMenuDisplayLimit(maximumCount: 3), saveGate: gate)
        let model = makeModel(fixture)
        await model.loadIfNeeded()
        model.maximumCountText = "8"
        let save = Task { await model.save() }
        let started = await BackgroundWork.run { gate.started.wait(timeout: .now() + 5) == .success }
        XCTAssertTrue(started)
        XCTAssertTrue(Thread.isMainThread)
        XCTAssertTrue(model.isSaving)
        XCTAssertFalse(model.canEdit)

        await model.reload()
        await model.loadIfNeeded()
        let duplicateSave = await model.save()
        XCTAssertFalse(duplicateSave)
        XCTAssertEqual(fixture.loadCount, 1)
        XCTAssertEqual(fixture.saveCount, 1)
        model.maximumCountText = "12"
        gate.release.signal()
        let firstSaved = await save.value

        XCTAssertTrue(firstSaved)
        XCTAssertFalse(model.isSaving)
        XCTAssertEqual(model.savedLimit.maximumCount, 8)
        XCTAssertEqual(fixture.value.maximumCount, 8)
        XCTAssertEqual(model.maximumCountText, "12")
        XCTAssertNil(model.status, "A newer draft must not be labelled saved")
        XCTAssertTrue(model.canSave)
        let secondSaved = await model.save()
        XCTAssertTrue(secondSaved)
        XCTAssertEqual(model.savedLimit.maximumCount, 12)
    }

    func testUnchangedSettingDoesNotWriteAndChangingDraftClearsSuccess() async {
        let fixture = MenuSettingsFixture()
        let model = makeModel(fixture)
        await model.loadIfNeeded()
        let unchanged = await model.save()
        XCTAssertTrue(unchanged)
        XCTAssertEqual(fixture.saveCount, 0)

        model.showsAll = false
        model.maximumCountText = "2"
        let saved = await model.save()
        XCTAssertTrue(saved)
        XCTAssertNotNil(model.status)
        model.maximumCountText = "3"
        XCTAssertNil(model.status)
    }

    func testSettledModelReleasesAfterRepeatedLoadsAndSaves() async {
        let fixture = MenuSettingsFixture()
        var model: FinderMenuSettingsViewModel? = makeModel(fixture)
        weak var released = model
        await model!.loadIfNeeded()
        for count in 1...10 {
            model!.showsAll = false
            model!.maximumCountText = String(count)
            let saved = await model!.save()
            XCTAssertTrue(saved)
            await model!.reload()
        }
        model = nil
        XCTAssertNil(released)
    }

    private func makeModel(_ fixture: MenuSettingsFixture) -> FinderMenuSettingsViewModel {
        FinderMenuSettingsViewModel(load: { try fixture.load() }, save: { try fixture.save($0) })
    }
}

private enum MenuSettingsTestError: LocalizedError {
    case unavailable
    var errorDescription: String? { "测试设置存储不可用。" }
}

private final class MenuSettingsFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: FinderMenuDisplayLimit
    private var loads = 0
    private var saves = 0
    private var failsLoading = false
    private var failsSaving = false
    private let loadGate: MenuSettingsOperationGate?
    private let saveGate: MenuSettingsOperationGate?

    init(
        value: FinderMenuDisplayLimit = .all,
        loadGate: MenuSettingsOperationGate? = nil,
        saveGate: MenuSettingsOperationGate? = nil
    ) {
        storedValue = value
        self.loadGate = loadGate
        self.saveGate = saveGate
    }

    var value: FinderMenuDisplayLimit { withLock { storedValue } }
    var loadCount: Int { withLock { loads } }
    var saveCount: Int { withLock { saves } }

    func setFailure(load: Bool, save: Bool) {
        withLock {
            failsLoading = load
            failsSaving = save
        }
    }

    func load() throws -> FinderMenuDisplayLimit {
        XCTAssertFalse(Thread.isMainThread, "Settings reads must run off the main actor")
        let (value, shouldFail) = withLock {
            loads += 1
            return (storedValue, failsLoading)
        }
        loadGate?.blockOnce()
        if shouldFail { throw MenuSettingsTestError.unavailable }
        return value
    }

    func save(_ value: FinderMenuDisplayLimit) throws {
        XCTAssertFalse(Thread.isMainThread, "Settings writes must run off the main actor")
        let shouldFail = withLock {
            saves += 1
            return failsSaving
        }
        saveGate?.blockOnce()
        if shouldFail { throw MenuSettingsTestError.unavailable }
        withLock { storedValue = value }
    }

    private func withLock<Value>(_ operation: () -> Value) -> Value {
        lock.lock()
        defer { lock.unlock() }
        return operation()
    }
}

private final class MenuSettingsOperationGate: @unchecked Sendable {
    let started = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var didBlock = false

    func blockOnce() {
        lock.lock()
        let shouldBlock = !didBlock
        didBlock = true
        lock.unlock()
        guard shouldBlock else { return }
        started.signal()
        XCTAssertEqual(release.wait(timeout: .now() + 10), .success)
    }
}
