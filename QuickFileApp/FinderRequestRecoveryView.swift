import AppKit
import QuickFileInfrastructure
import SwiftUI

/// A deliberately small recovery surface. It reveals only request identifiers and
/// safe classifications, never queue payloads, destination paths or bookmarks.
@MainActor
struct FinderRequestRecoveryView: View {
    @ObservedObject var model: FinderRequestRecoveryViewModel
    @State private var requestedCandidateID = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("检查 Finder 异常请求").font(.title2).fontWeight(.semibold)
            Text("只检查本机队列，最多检查 64 条记录；不会上传任何内容，也不会自动重试或创建文件。正常请求不能在这里归档。")
                .fixedSize(horizontal: false, vertical: true)
            Text("归档会把所选原件移入本机的隐藏私有目录，并将它移出待办；不会删除原件。取消确认不改动原始记录。无法安全保留原件时，不会用删除代替。")
                .font(.callout).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if model.hasInspected, model.candidates.isEmpty {
                Text("本次检查未发现可显示的异常记录。暂停状态仍保留，可关闭后显式重试读取。")
                    .frame(maxWidth: .infinity, minHeight: 140, alignment: .center)
            } else {
                List(selection: Binding(
                    get: { model.selectedCandidateID },
                    set: { model.select($0) }
                )) {
                    ForEach(model.candidates) { candidate in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(candidate.id).font(.system(.caption, design: .monospaced))
                            Text(candidate.reason.localizedDescription).font(.callout)
                            if !candidate.canPrepare {
                                Text("无法安全确认此记录，不能归档。请保留原件，检查本机存储或联系支持；不要清空队列。")
                                    .font(.caption).foregroundColor(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(.vertical, 3)
                        .tag(candidate.id)
                    }
                }
                .frame(minHeight: 90)
                .disabled(model.isOperationInFlight)
                .accessibilityLabel("异常请求，仅显示标识和原因")
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if model.isTruncated {
                        Label("本次只检查了部分记录。可处理所选记录后重新检查，也可按标识核对未显示的记录。", systemImage: "ellipsis.circle")
                            .font(.caption).fixedSize(horizontal: false, vertical: true)
                        GroupBox("按标识检查其他记录") {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("粘贴请求文件名中的 UUID，不含 .json；会先核对原件，再请你确认归档。")
                                    .font(.caption).fixedSize(horizontal: false, vertical: true)
                                TextField("请求标识（UUID）", text: $requestedCandidateID)
                                    .textFieldStyle(.roundedBorder)
                                    .accessibilityIdentifier("finderRecoveryRequestID")
                                    .disabled(!model.canInspect)
                                Button("检查并确认归档…") {
                                    let id = requestedCandidateID
                                    Task {
                                        if await model.prepareRequest(withID: id, confirm: Self.confirmArchive) {
                                            requestedCandidateID = ""
                                        }
                                    }
                                }
                                .disabled(!model.canInspect || requestedCandidateID.isEmpty)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    if model.legacyRecoveryUnsupported {
                        Label("检测到旧版偏好设置请求；本工具不支持归档该记录，原始数据会保留。请保留现状并联系支持，不要重置应用数据。", systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundColor(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let archive = model.lastArchive {
                        GroupBox("最近一次已提交的归档") {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("请求：\(archive.requestID)")
                                    .font(.system(.caption, design: .monospaced))
                                if let archiveURL = archive.archiveURL {
                                    Text("提交时确认的本机归档位置：").font(.caption)
                                    Text(archiveURL.path)
                                        .font(.caption).textSelection(.enabled)
                                        .fixedSize(horizontal: false, vertical: true)
                                } else {
                                    Text("原件已移出待办，但现在无法确认归档位置。请保留当前状态，不要重复归档此记录。")
                                        .font(.caption).foregroundColor(.orange)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                if archive.durabilityWarning {
                                    Text("归档已提交，但位置或持久化检查未完全通过。不会自动重试。")
                                        .font(.caption).foregroundColor(.orange)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    Text("归档保存在 QuickFile 共享容器的队列目录下 .recovery-archive 隐藏文件夹；关闭窗口不会删除归档。")
                        .font(.caption).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let status = model.status {
                        Text(status.message)
                            .foregroundColor(statusColor(status))
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("finderRequestRecoveryStatus")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 240)
            if let operation = model.operation {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(operation.message).font(.callout)
                }
            }
            HStack {
                Button("重新检查") { Task { await model.inspect() } }
                    .disabled(!model.canInspect)
                Spacer()
                Button("关闭") { model.close() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(model.operation == .archiving)
                Button("归档所选原件…") {
                    Task { await model.prepareSelected(confirm: Self.confirmArchive) }
                }
                .disabled(!model.canPrepareSelection)
            }
        }
        .padding(24)
        .frame(width: 640, height: 680)
        .interactiveDismissDisabled(model.operation == .archiving)
        .task { await model.inspect() }
        .onDisappear { requestedCandidateID = ""; model.close() }
    }

    private func statusColor(_ status: FinderRequestRecoveryViewModel.Status) -> Color {
        switch status {
        case .failure: return .red
        case .archived(true): return .orange
        case .information, .archived(false): return .primary
        }
    }

    static func confirmArchive(_ candidate: FinderRequestRecoveryViewModel.Candidate) -> Bool {
        runArchiveConfirmation(makeArchiveConfirmation(candidate))
    }

    static func makeArchiveConfirmation(_ candidate: FinderRequestRecoveryViewModel.Candidate) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "归档此原件并移出待办？"
        alert.informativeText = """
        请求：\(candidate.id)
        原因：\(candidate.reason.localizedDescription)

        确认后会把这一个原始记录移到本机的隐藏私有归档目录，使它不再等待处理。不会上传、自动重试或创建文件，也不会清空其他请求。无法安全保留原件时不会移除它。

        取消不改动原件。归档后自动处理仍暂停，需你另行点击“重试读取”。
        """
        let cancel = alert.addButton(withTitle: "取消")
        let archive = alert.addButton(withTitle: "归档原件并移出待办")
        // Return and Escape are deliberately safe. Archive requires an explicit
        // choice, rather than inheriting NSAlert's first-button default shortcut.
        archive.keyEquivalent = ""
        alert.window.defaultButtonCell = cancel.cell as? NSButtonCell
        return alert
    }

    static func runArchiveConfirmation(_ alert: NSAlert) -> Bool {
        // defaultButtonCell assigns Return to the cancel button, replacing any
        // Escape key equivalent. Keep both cancellation keys scoped to this
        // alert's modal loop, regardless of the currently focused control.
        let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.window === alert.window, [36, 53, 76].contains(event.keyCode),
                  event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty else {
                return event
            }
            alert.buttons[0].performClick(nil)
            return nil
        }
        defer { if let monitor { NSEvent.removeMonitor(monitor) } }
        return AppModalPresentationGate.shared.present({ alert.runModal() }) == .alertSecondButtonReturn
    }
}
