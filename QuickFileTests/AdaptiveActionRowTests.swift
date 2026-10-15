import AppKit
import SwiftUI
import XCTest
@testable import QuickFile

@MainActor
final class AdaptiveActionRowTests: XCTestCase {
    func testLongActionsRemainReachableWithoutStretchingMenusAtDifferentWidths() async throws {
        var frames: [String: CGRect] = [:]
        let probe = ActionRowProbe { frames = $0 }
        let host = NSHostingView(rootView: probe)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 160),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }

        var wideRowHeight: CGFloat = 0
        for width: CGFloat in [680, 300, 680] {
            window.setContentSize(NSSize(width: width, height: 160))
            for _ in 0..<5 {
                try await Task.sleep(nanoseconds: 20_000_000)
                host.layoutSubtreeIfNeeded()
            }
            XCTAssertEqual(Set(frames.keys), ["add", "manage", "repair"])
            for frame in frames.values {
                XCTAssertGreaterThan(frame.width, 40)
                XCTAssertGreaterThan(frame.height, 15)
                XCTAssertGreaterThanOrEqual(frame.minX, 0)
                XCTAssertLessThanOrEqual(frame.maxX, width + 1)
            }
            let menu = try XCTUnwrap(frames["repair"])
            XCTAssertLessThan(menu.width, 250, "A menu must not expand into a full-width field")
            let height = frames.values.map(\.maxY).max()! - frames.values.map(\.minY).min()!
            if width == 680 {
                XCTAssertLessThan(height, 35, "Actions fit on one row at normal width")
                wideRowHeight = height
            } else {
                XCTAssertGreaterThan(height, wideRowHeight * 2, "Long labels wrap instead of clipping")
            }
        }
    }
}

private struct ActionFrameKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

private struct ActionRowProbe: View {
    let measured: ([String: CGRect]) -> Void

    var body: some View {
        AdaptiveActionRow {
            Button("Add Authorized Folder…") {}.background(measure("add"))
            Button("Manage Folder Access…") {}.background(measure("manage"))
            Menu("Storage Maintenance") { Button("Repair…") {} }
                .background(measure("repair"))
        }
        .coordinateSpace(name: "actions")
        .onPreferenceChange(ActionFrameKey.self, perform: measured)
    }

    private func measure(_ id: String) -> some View {
        GeometryReader { proxy in
            Color.clear.preference(key: ActionFrameKey.self,
                                   value: [id: proxy.frame(in: .named("actions"))])
        }
    }
}
