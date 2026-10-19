import AppKit
import FinderSync
import XCTest
import os
import QuickFileCore
import QuickFileApplication
@testable import QuickFileInfrastructure
@testable import QuickFile

/// Exercises the production FinderSync adapter, including selector dispatch and worker completion.
/// All stores/targets are isolated; only presentation and OS handoff edges are substituted.
@MainActor
final class FinderSyncTests: XCTestCase {
    private var root: URL!
    private var target: URL!
    private var storage: LocalSharedStorage!
    private let template = FileTemplate(name: "Adapter fixture", fileExtension: "txt", content: "adapter bytes")

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/Temporary/finder-adapter-\(UUID())")
        target = root.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        storage = LocalSharedStorage(root: root.appendingPathComponent("shared"))
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    private func store(resolved: OSAllocatedUnfairLock<[URL]> = .init(initialState: []),
                       start: @escaping @Sendable (URL) -> Bool,
                       stop: @escaping @Sendable (URL) -> Void = { _ in }) -> AuthorizedDirectoryStore {
        let resolve: AuthorizedDirectoryStore.BookmarkResolver = { data in
            let url = URL(fileURLWithPath: String(decoding: data, as: UTF8.self))
            resolved.withLock { $0.append(url) }
            return ResolvedSecurityScopedBookmark(url: url, isStale: false)
        }
        return AuthorizedDirectoryStore(defaults: nil, localStorage: storage,
            persistentBookmarkCreator: { Data($0.path.utf8) }, transferBookmarkCreator: { Data($0.path.utf8) },
            persistentBookmarkResolver: resolve, transferBookmarkResolver: resolve,
            startAccessing: start, stopAccessing: stop)
    }

    private func adapter(store: AuthorizedDirectoryStore,
                         load: (@Sendable () throws -> FileTemplate?)? = nil,
                         reveal: @escaping @MainActor (URL) -> Void = { _ in XCTFail("Unexpected reveal") },
                         open: @escaping @MainActor (FileCreationResult, UUID) async -> Error? = { _, _ in XCTFail("Unexpected open"); return nil },
                         alert: @escaping @MainActor (NSAlert) -> NSApplication.ModalResponse = { _ in XCTFail("Unexpected alert"); return .alertFirstButtonReturn },
                         launch: @escaping @MainActor (QuickFileAppRoute, @escaping @MainActor @Sendable (Error?) -> Void) -> Void = { _, _ in XCTFail("Unexpected launch") }) -> FinderSync {
        let template = self.template
        let entries = FinderMenuModelBuilder().entries(from: [template])
        return FinderSync(
            templateCache: FinderTemplateCache(loadForCreation: { _ in
                .init(template: try load.map { try $0() } ?? template, menuEntries: entries)
            }, loadMenuEntries: { entries }, changeNotificationName: "fixture.\(UUID())"),
            menuSettingsCache: FinderMenuSettingsCache(load: { .all }),
            languageSettings: FinderLanguageSettings(load: { .system }, apply: { _ in }, notificationName: nil),
            activityRecorder: FinderActivityRecorder(persist: { _, _, _ in }),
            authorizationRequestStore: FinderAuthorizationRequestStore(defaults: nil, directoryURL: storage.root.appendingPathComponent("finder-authorization-requests"), localStorage: storage),
            authorizedDirectoryStore: store, fileCreationService: FileCreationService(),
            selection: { [target] in (target, []) }, reveal: reveal, openCreatedFile: open,
            presentAlert: alert, launchApplication: launch, registerWithFinder: false)
    }

    private func creationItem(_ adapter: FinderSync) async throws -> NSMenuItem {
        adapter.beginObservingDirectory(at: target)
        for _ in 0..<100 {
            if let item = adapter.menu(for: .contextualMenuForContainer)?.items.first?.submenu?.items.first(where: { $0.tag > 0 }) {
                XCTAssertEqual(item.title, "Adapter fixture (.txt)")
                XCTAssertTrue(item.target === adapter)
                return item
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw FinderFileCreationError.menuContextUnavailable
    }

    private func click(_ item: NSMenuItem) throws {
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
    }

    func testCreatedFileHandoffUsesAdmittedParentIDAndReleasesBothScopes() async throws {
        let resolved = OSAllocatedUnfairLock(initialState: [URL]())
        let balance = OSAllocatedUnfairLock(initialState: 0)
        let store = store(resolved: resolved, start: { _ in balance.withLock { $0 += 1 }; return true },
                          stop: { _ in balance.withLock { $0 -= 1 } })
        let unrelated = root.appendingPathComponent("unrelated")
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: false)
        _ = try store.authorize(unrelated)
        let admitted = try store.authorize(root)
        let completed = expectation(description: "automatic open finished")
        let opener = AutomaticFileOpener(prepare: { url, id, required in
            XCTAssertTrue(required)
            XCTAssertEqual(id, admitted.id)
            let access = try store.beginAccess(to: url.deletingLastPathComponent(), authorizationID: id)
            return .init { access.release() }
        }, open: { url, done in
            XCTAssertEqual(balance.withLock { $0 }, 1)
            XCTAssertEqual(try? String(contentsOf: url), "adapter bytes")
            done(nil)
        })
        let adapter = adapter(store: store, reveal: { _ in
            XCTAssertEqual(balance.withLock { $0 }, 0, "Creation scope ends before main completion")
            resolved.withLock { $0 = [] }
        }, open: { creation, id in
            let error = await opener.openCreatedFile(creation, authorizationID: id, requiresAuthorization: true)
            completed.fulfill()
            return error
        })
        try click(await creationItem(adapter))
        await fulfillment(of: [completed], timeout: 4)
        XCTAssertEqual(resolved.withLock { $0.map(\.path) }, [root.path])
        XCTAssertEqual(balance.withLock { $0 }, 0)
        XCTAssertFalse(opener.isOccupied)
    }

    func testSecurityScopeRejectionPersistsRequestWithoutCreatingOrOpening() async throws {
        let starts = OSAllocatedUnfairLock(initialState: 0)
        let store = store(start: { url in
            starts.withLock { $0 += 1 }
            return false
        }, stop: { $0.stopAccessingSecurityScopedResource() })
        _ = try store.authorize(target)
        let launched = expectation(description: "authorization continuation")
        let adapter = adapter(store: store, launch: { route, _ in
            XCTAssertEqual(route, .create)
            // Do not broadcast a production notification into the user's running app.
            launched.fulfill()
        })
        try click(await creationItem(adapter))
        await fulfillment(of: [launched], timeout: 4)
        XCTAssertEqual(starts.withLock { $0 }, 1)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty)
        let request = try FinderAuthorizationRequestStore(defaults: nil, directoryURL: storage.root.appendingPathComponent("finder-authorization-requests"), localStorage: storage).takePendingRequest()
        XCTAssertEqual(request?.templateID, template.id)
        XCTAssertEqual(request?.destinationFolder.path, target.path)
    }

    func testRealFoundationScopeCallHasBalancedLifetime() throws {
        let results = OSAllocatedUnfairLock(initialState: [Bool]())
        let stops = OSAllocatedUnfairLock(initialState: 0)
        let store = store(start: { url in
            let started = url.startAccessingSecurityScopedResource()
            results.withLock { $0.append(started) }
            return started
        }, stop: { url in
            url.stopAccessingSecurityScopedResource()
            stops.withLock { $0 += 1 }
        })
        let grant = try store.authorize(target)
        do {
            let access = try store.beginAccess(to: target, authorizationID: grant.id)
            XCTAssertEqual(access.authorizationID, grant.id)
            XCTAssertEqual(results.withLock { $0 }, [true])
            access.release()
            access.release()
            XCTAssertEqual(stops.withLock { $0 }, 1)
        } catch {
            guard case AuthorizedDirectoryStore.StoreError.securityScopeUnavailable = error else { throw error }
            XCTAssertEqual(results.withLock { $0 }, [false])
            XCTAssertEqual(stops.withLock { $0 }, 0)
        }
        // An unsigned XCTest host may return true for plain URLs. This checks the real
        // API lifetime, not sandbox admission in an installed, signed Finder extension.
    }

    func testRemovedTemplatePresentsCreationFailureAndDoesNotAutoOpen() async throws {
        let shown = expectation(description: "creation alert")
        let adapter = adapter(store: store(start: { _ in XCTFail("No scope for missing template"); return false }),
            load: { nil }, alert: { alert in
                XCTAssertEqual(alert.messageText, QuickFileLocalization.text(.init("QuickFile 无法创建文件")))
                XCTAssertEqual(alert.buttons.count, 2)
                shown.fulfill()
                return .alertFirstButtonReturn
            })
        try click(await creationItem(adapter))
        await fulfillment(of: [shown], timeout: 4)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty)
    }

    func testAutoOpenFailurePreservesFileAndShowsPostCreationMessage() async throws {
        let store = store(start: { _ in true })
        _ = try store.authorize(target)
        let shown = expectation(description: "open alert")
        var created: URL?
        let adapter = adapter(store: store, reveal: { created = $0 },
            open: { _, _ in CocoaError(.fileReadNoPermission) }, alert: { alert in
                XCTAssertEqual(alert.messageText, QuickFileLocalization.text(.init("文件已创建，但无法自动打开")))
                XCTAssertEqual(alert.buttons.count, 1)
                shown.fulfill()
                return .alertFirstButtonReturn
            })
        try click(await creationItem(adapter))
        await fulfillment(of: [shown], timeout: 4)
        XCTAssertEqual(try String(contentsOf: XCTUnwrap(created)), "adapter bytes")
    }
}
