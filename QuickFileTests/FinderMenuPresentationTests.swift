import AppKit
import XCTest
@testable import QuickFileCore

@MainActor
final class FinderMenuPresentationTests: XCTestCase {
    private let target = NSObject()
    private let createAction = NSSelectorFromString("createFileFromMenu:")
    private let openCreate = NSSelectorFromString("openCreatePage:")
    private let openTemplates = NSSelectorFromString("openTemplateManager:")

    private var presenter: FinderMenuPresentation {
        FinderMenuPresentation(target: target, createAction: createAction,
            openCreateAction: openCreate, openTemplatesAction: openTemplates)
    }

    private func submenu(_ menu: NSMenu) throws -> NSMenu {
        XCTAssertEqual(menu.items.count, 1)
        XCTAssertEqual(menu.items.first?.title, "新建文件")
        let submenu = try XCTUnwrap(menu.items.first?.submenu)
        XCTAssertFalse(submenu.autoenablesItems)
        return submenu
    }

    func testEmptyAndAllDisabledMenusKeepRootAndOfferTemplateManagement() throws {
        let disabled = FileTemplate(name: "Off", fileExtension: "txt", content: "", isEnabled: false)
        for templates in [[], [disabled]] {
            var registrations = 0
            let menu = presenter.templates(FinderMenuModelBuilder().presentation(from: templates)) { entries in
                entries.map { _ in
                    registrations += 1
                    return registrations
                }
            }
            let items = try submenu(menu).items
            XCTAssertEqual(registrations, 0)
            XCTAssertEqual(items.count, 2)
            XCTAssertFalse(items[0].isEnabled)
            XCTAssertEqual(items[0].title, "暂无启用的模板，请添加或启用模板")
            XCTAssertNil(items[0].action)
            XCTAssertFalse(items.contains(where: \.isSeparatorItem))
            XCTAssertEqual(items.compactMap(\.action), [openTemplates])
            XCTAssertEqual(items.last?.action, openTemplates)
            XCTAssertEqual(items.last?.tag, 0)
            XCTAssertTrue(items.last?.isEnabled == true)
            XCTAssertTrue(items.last?.target === target)
            XCTAssertTrue(items.allSatisfy { $0.tag == 0 })
            XCTAssertFalse(items.contains(where: { $0.action == createAction }))
        }
    }

    func testEveryUnavailableStateExposesOnlyItsContextualExplanationAndRecovery() throws {
        let cases: [(state: FinderMenuPresentation.UnavailableState, message: String, action: Selector?)] = [
            (.operationInProgress, "已有文件请求正在处理，请稍后重新打开菜单", nil),
            (.sidebarSelectionUnavailable, "请先打开边栏中的文件夹，再右键创建", nil),
            (.mixedSelection, "所选项目来自不同文件夹，请先打开要创建文件的文件夹", nil),
            (.destinationMissing, "当前位置不可用，请重新选择文件夹", nil),
            (.destinationLoading, "正在确认创建位置…", openCreate),
            (.destinationBusy, "创建位置暂时繁忙", openCreate),
            (.destinationUnavailable, "无法确认当前位置，请打开文件夹后重新右键", openCreate),
            (.templatesLoading, "正在加载模板…", openCreate),
            (.templateReadFailed, "暂时无法加载模板，请在 QuickFile 中重新加载", openTemplates),
            (.noEnabledTemplates, "暂无启用的模板，请添加或启用模板", openTemplates)
        ]
        XCTAssertEqual(cases.map(\.state), FinderMenuPresentation.UnavailableState.allCases)
        for (state, message, action) in cases {
            let items = try submenu(presenter.unavailable(state)).items
            XCTAssertEqual(items.count, action == nil ? 1 : 2, "\(state)")
            XCTAssertEqual(items[0].title, message)
            XCTAssertFalse(items[0].isEnabled)
            XCTAssertNil(items[0].action)
            XCTAssertFalse(items.contains(where: \.isSeparatorItem))
            if let action {
                XCTAssertEqual(items.compactMap(\.action), [action])
                XCTAssertEqual(items[1].title, action == openCreate ? "在 QuickFile 中创建…" : "打开模板管理…")
                XCTAssertTrue(items[1].isEnabled)
                XCTAssertTrue(items[1].target === target)
            } else {
                XCTAssertTrue(items.compactMap(\.action).isEmpty)
            }
            XCTAssertTrue(items.allSatisfy { $0.tag == 0 })
            XCTAssertFalse(items.contains(where: { $0.action == createAction }))
        }
    }

    func testSlowPreparationOffersCreationNavigationWithoutUnpreparedCreationActions() throws {
        let states: [FinderMenuPresentation.UnavailableState] = [
            .destinationLoading, .destinationBusy, .templatesLoading
        ]
        for state in states {
            let items = try submenu(presenter.unavailable(state)).items
            XCTAssertFalse(items[0].title.contains("重新打开菜单"))
            XCTAssertEqual(items.count, 2)
            XCTAssertNil(items[0].action)
            XCTAssertFalse(items[0].isEnabled)
            XCTAssertEqual(items[1].title, "在 QuickFile 中创建…")
            XCTAssertEqual(items[1].action, openCreate)
            XCTAssertTrue(items[1].isEnabled)
            XCTAssertTrue(items.allSatisfy { $0.tag == 0 && $0.action != createAction })
        }
    }

    func testRecoveryNavigationCannotConsumeCreationTags() throws {
        let registry = FinderMenuActionRegistry()
        let template = FileTemplate(name: "Text", fileExtension: "txt", content: "")
        let destination = URL(fileURLWithPath: "/tmp/Original Menu Folder", isDirectory: true)
        let tag = registry.registerMenu([FinderMenuAction(templateID: template.id, context: .container, destinationFolder: destination)])[0]
        for state in FinderMenuPresentation.UnavailableState.allCases {
            let items = try submenu(presenter.unavailable(state)).items
            for item in items {
                XCTAssertEqual(item.tag, 0)
                XCTAssertNil(registry.takeAction(for: item.tag))
            }
        }
        let captured = try XCTUnwrap(registry.takeAction(for: tag))
        XCTAssertEqual(captured.templateID, template.id)
        XCTAssertEqual(captured.target, .directory(destination))
    }

    func testReadyMenuContainsOnlyEnabledTemplateCreationEntries() throws {
        let templates = [
            FileTemplate(name: "Text", fileExtension: "txt", content: ""),
            FileTemplate(name: "Off", fileExtension: "txt", content: "", isEnabled: false),
            FileTemplate(name: "Markdown", fileExtension: "md", content: "")
        ]
        let limits: [FinderMenuDisplayLimit] = [.all, try FinderMenuDisplayLimit(maximumCount: 10)]
        for limit in limits {
            var registeredIDs: [FileTemplate.ID] = []
            let menu = presenter.templates(FinderMenuModelBuilder().presentation(from: templates, limit: limit)) { entries in
                entries.map { entry in
                    registeredIDs.append(entry.id)
                    return registeredIDs.count
                }
            }
            let items = try submenu(menu).items
            XCTAssertEqual(registeredIDs, [templates[0].id, templates[2].id])
            XCTAssertEqual(items.map(\.title), ["Text (.txt)", "Markdown (.md)"])
            XCTAssertEqual(items.compactMap(\.action), [createAction, createAction])
            XCTAssertEqual(items.map(\.tag), [1, 2])
            XCTAssertTrue(items.allSatisfy { $0.isEnabled && !$0.isSeparatorItem && $0.target === target })
        }
    }

    func testLegacyBlankTemplateNamesRemainVisibleActionableAndRegistered() throws {
        let templates = [
            FileTemplate(name: "", fileExtension: "", content: "keep this content"),
            FileTemplate(name: " \t\n", fileExtension: " .txt ", content: "")
        ]
        var registeredIDs: [FileTemplate.ID] = []
        let menu = presenter.templates(FinderMenuModelBuilder().presentation(from: templates)) { entries in
            entries.map { entry in
                registeredIDs.append(entry.id)
                return registeredIDs.count
            }
        }
        let items = try submenu(menu).items
        XCTAssertEqual(items.map(\.title), ["未命名模板", "未命名模板 (.txt)"])
        XCTAssertEqual(items.compactMap(\.action), [createAction, createAction])
        XCTAssertEqual(items.map(\.tag), [1, 2])
        XCTAssertTrue(items.allSatisfy { $0.isEnabled && !$0.isSeparatorItem })
        XCTAssertEqual(registeredIDs, templates.map(\.id))
    }

    func testLimitedReadyMenuContainsOnlyCreationEntriesWithoutFooterOrNavigation() throws {
        let templates = (0..<30).map { FileTemplate(name: "Template \($0)", fileExtension: "txt", content: "") }
        let registry = FinderMenuActionRegistry()
        let presentation = FinderMenuModelBuilder().presentation(
            from: templates, limit: try FinderMenuDisplayLimit(maximumCount: 10)
        )
        let destination = URL(fileURLWithPath: "/tmp/Original Menu Folder", isDirectory: true)
        var registrations = 0
        let menu = presenter.templates(presentation) { entries in
            registrations += 1
            return registry.registerMenu(entries.map { entry in
                FinderMenuAction(templateID: entry.id, context: .container, destinationFolder: destination)
            })
        }
        XCTAssertEqual(registrations, 1, "A menu registers its complete visible batch exactly once")
        let items = try submenu(menu).items
        let creationItems = items.filter { $0.action == createAction }
        XCTAssertEqual(items.count, 10)
        XCTAssertEqual(items.compactMap(\.action), Array(repeating: createAction, count: 10))
        XCTAssertEqual(creationItems.count, 10)
        XCTAssertEqual(Set(creationItems.map(\.tag)).count, 10)
        XCTAssertTrue(creationItems.allSatisfy { $0.tag > 0 })
        XCTAssertFalse(items.contains(where: \.isSeparatorItem))
        XCTAssertTrue(items.allSatisfy(\.isEnabled))
        XCTAssertNil(registry.takeAction(for: 0))
        for (index, item) in creationItems.enumerated() {
            let captured = try XCTUnwrap(registry.takeAction(for: item.tag))
            XCTAssertEqual(captured.templateID, templates[index].id)
            XCTAssertEqual(captured.target, .directory(destination))
        }
    }

    func testRecoveryRoutesPreserveAlreadyCreatedAndPermissionSemantics() {
        for reason in [FinderExtensionFailureReason.templateUnavailable, .templateReadFailed,
            .templateStorageUnavailable, .templateWriteFailed, .renderedContentTooLarge] {
            XCTAssertEqual(reason.recoveryRoute, .templates)
        }
        for reason in [FinderExtensionFailureReason.directoryNotAuthorized, .authorizationUnavailable,
            .permissionDenied, .readOnlyVolume, .writeFailed, .createdFileLocationUnavailable] {
            XCTAssertEqual(reason.recoveryRoute, .diagnostics)
        }
        for reason in [FinderExtensionFailureReason.menuContextUnavailable, .destinationUnavailable,
            .operationInProgress, .destinationMissing, .invalidFilename, .conflictLimitReached] {
            XCTAssertEqual(reason.recoveryRoute, .create)
        }
        XCTAssertEqual(FinderExtensionFailureReason.createdFileLocationUnavailable.recoveryRoute.url,
                       URL(string: "quickfile://open/diagnostics"))
    }
}
