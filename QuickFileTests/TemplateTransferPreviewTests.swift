import AppKit
import Darwin
import SwiftUI
import XCTest
@testable import QuickFile
@testable import QuickFileCore
@testable import QuickFileInfrastructure

@MainActor
final class TemplateTransferPreviewTests: XCTestCase {
    func testPublishedImportFailureShowsReloadGuidanceAndCannotConfirmAgain() async throws {
        try await assertPublishedFailure(publishedStoreError(), isRecovery: false)
    }

    func testPublishedRecoveryFailureShowsReloadGuidanceAndCannotConfirmAgain() async throws {
        let error = TemplateStore.RecoveryError.replacementFailed(
            backupURL: URL(fileURLWithPath: "/private/fixture-backup"),
            underlying: publishedStoreError()
        )
        try await assertPublishedFailure(error, isRecovery: true)
    }

    private func publishedStoreError() -> TemplateStore.StoreError {
        .persistenceFailed(LocalSharedStorage.PublishedWriteError(
            underlyingError: NSError(domain: NSPOSIXErrorDomain, code: Int(EIO))
        ))
    }

    private func assertPublishedFailure(_ error: Error, isRecovery: Bool,
                                        file: StaticString = #filePath, line: UInt = #line) async throws {
        _ = NSApplication.shared
        let oldLanguage = QuickFileLanguage(rawValue: QuickFileLocalization.identifier) ?? .system
        QuickFileLocalization.apply(.simplifiedChinese)
        defer { QuickFileLocalization.apply(oldLanguage) }
        let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = NSApp.accessibilityAttributeValue(enhanced)
        NSApp.accessibilitySetValue(true, forAttribute: enhanced)
        defer { NSApp.accessibilitySetValue(previous, forAttribute: enhanced) }

        var attempts = 0
        let confirmTitle = "Apply fixture plan"
        let host = NSHostingController(rootView: TemplateTransferPreviewView(
            title: "Fixture preview", explanation: "Fixture plan",
            templates: [FileTemplate(name: "Fixture", fileExtension: "txt", content: "fixture")],
            renamedNames: [:], skippedCount: 0, clipboardCount: 0,
            isRecovery: isRecovery, confirmationActionTitle: confirmTitle
        ) {
            attempts += 1
            throw error
        }.environment(\.locale, Locale(identifier: "zh-Hans")))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 610, height: 540),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = host
        window.orderFront(nil)
        defer {
            window.contentViewController = nil
            window.close()
        }
        await settle(host.view)
        let confirm = try button(named: confirmTitle, in: host.view)
        XCTAssertEqual(isEnabled(confirm), true, file: file, line: line)
        try press(confirm)
        try press(confirm)

        let guidance = "请取消后重新加载模板，并检查当前配置后再操作。"
        for _ in 0..<100 {
            if texts(host.view).contains(guidance) { break }
            try await Task.sleep(nanoseconds: 20_000_000)
            host.view.layoutSubtreeIfNeeded()
        }
        let visibleText = texts(host.view).joined(separator: "\n")
        XCTAssertTrue(visibleText.contains(guidance), visibleText, file: file, line: line)
        XCTAssertTrue(visibleText.contains(QuickFileViewModel.templateOperationErrorMessage(error)),
                      visibleText, file: file, line: line)
        XCTAssertFalse(visibleText.contains("未应用本次计划"), visibleText, file: file, line: line)
        XCTAssertEqual(attempts, 1, file: file, line: line)

        let attemptedConfirm = try button(named: confirmTitle, in: host.view)
        XCTAssertEqual(isEnabled(attemptedConfirm), false, file: file, line: line)
        try press(attemptedConfirm)
        await settle(host.view)
        XCTAssertEqual(attempts, 1, "A failed plan cannot be confirmed again", file: file, line: line)
    }

    private func nodes(_ element: Any) -> [NSObject] {
        guard let node = element as? NSObject else { return [] }
        let selector = NSSelectorFromString("accessibilityChildren")
        let children = (node.responds(to: selector) ? node.perform(selector)?.takeUnretainedValue() as? [Any] : nil)
            ?? node.accessibilityAttributeValue(.children) as? [Any] ?? (node as? NSView)?.subviews ?? []
        return [node] + children.flatMap(nodes)
    }

    private func string(_ name: String, of node: NSObject) -> String? {
        let selector = NSSelectorFromString(name)
        guard node.responds(to: selector) else { return nil }
        return node.perform(selector)?.takeUnretainedValue() as? String
    }

    private func texts(_ element: Any) -> [String] {
        nodes(element).flatMap { node in
            [string("accessibilityLabel", of: node), string("accessibilityTitle", of: node),
             string("accessibilityValue", of: node), (node as? NSButton)?.title].compactMap { $0 }
        }
    }

    private func button(named title: String, in view: NSView) throws -> NSObject {
        let matches = nodes(view).filter { node in
            let isButton = node is NSButton
                || string("accessibilityRole", of: node) == NSAccessibility.Role.button.rawValue
            return isButton && [string("accessibilityLabel", of: node),
                                string("accessibilityTitle", of: node), (node as? NSButton)?.title].contains(title)
        }
        return try XCTUnwrap(matches.first { $0 is NSButton } ?? matches.first, "Missing button: \(title)")
    }

    private func isEnabled(_ node: NSObject) -> Bool? {
        if let control = node as? NSControl { return control.isEnabled }
        let selector = NSSelectorFromString("isAccessibilityEnabled")
        guard node.responds(to: selector) else { return nil }
        typealias Enabled = @convention(c) (AnyObject, Selector) -> Bool
        return unsafeBitCast(node.method(for: selector), to: Enabled.self)(node, selector)
    }

    private func press(_ node: NSObject) throws {
        if let button = node as? NSButton {
            button.performClick(nil)
            return
        }
        let selector = NSSelectorFromString("accessibilityPerformPress")
        guard node.responds(to: selector) else {
            XCTFail("Button does not implement accessibilityPerformPress")
            throw CocoaError(.featureUnsupported)
        }
        typealias Press = @convention(c) (AnyObject, Selector) -> Bool
        _ = unsafeBitCast(node.method(for: selector), to: Press.self)(node, selector)
    }

    private func settle(_ view: NSView) async {
        for _ in 0..<3 {
            try? await Task.sleep(nanoseconds: 20_000_000)
            view.layoutSubtreeIfNeeded()
        }
    }
}
