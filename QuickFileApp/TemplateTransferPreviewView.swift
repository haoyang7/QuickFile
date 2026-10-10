import QuickFileCore
import QuickFileInfrastructure
import SwiftUI

/// One review sheet for a single immutable plan. A failure never rebuilds or retries that plan.
@MainActor
struct TemplateTransferPreviewView: View {
    @Environment(\.presentationMode) private var presentationMode
    @State private var isCommitting = false
    @State private var errorMessage: String?
    @State private var didAttemptCommit = false

    let title: String
    let explanation: String
    let templates: [FileTemplate]
    let renamedNames: [FileTemplate.ID: String]
    let skippedCount: Int
    let clipboardCount: Int
    let isRecovery: Bool
    var confirmationActionTitle: String? = nil
    let onConfirm: () async throws -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.title2).fontWeight(.semibold)
            Text(explanation).fixedSize(horizontal: false, vertical: true)
            Text("\(isRecovery ? "恢复" : "新增") \(templates.count) 个 · 改名 \(renamedNames.count) 个 · 跳过重复 \(skippedCount) 个")
            Text("启用 \(templates.filter(\.isEnabled).count) 个 · 停用 \(templates.filter { !$0.isEnabled }.count) 个")
                .font(.caption).foregroundColor(.secondary)
            if clipboardCount > 0 {
                Label("\(clipboardCount) 个模板包含 {{clipboard}}。导入不会读取剪贴板；日后创建文件时可能使用剪贴板内容。",
                      systemImage: "exclamationmark.triangle")
                    .foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            List(templates) { template in
                VStack(alignment: .leading, spacing: 3) {
                    Text(template.name)
                    if let original = renamedNames[template.id] {
                        Text("原名称：\(original)").font(.caption).foregroundColor(.secondary)
                    }
                    Text("\(template.fileExtension.isEmpty ? "无扩展名" : "." + template.fileExtension) · \(template.isEnabled ? "启用" : "停用")")
                        .font(.caption).foregroundColor(.secondary)
                    if !template.defaultFilename.isEmpty {
                        Text("默认文件名：\(template.defaultFilename)")
                            .font(.caption).foregroundColor(.secondary).lineLimit(2)
                    }
                }
            }
            if let errorMessage {
                Text(errorMessage).foregroundColor(.red).fixedSize(horizontal: false, vertical: true)
                Text("未应用本次计划。请取消后重新选择文件并检查最新预览。")
                    .font(.caption).foregroundColor(.secondary)
            }
            HStack {
                if isCommitting { ProgressView("正在保存…").controlSize(.small) }
                Spacer()
                Button("取消") { presentationMode.wrappedValue.dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isCommitting)
                Button(confirmationActionTitle ?? (isRecovery ? "备份原配置并恢复" : "确认追加导入")) {
                    Task { await commit() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isCommitting || didAttemptCommit || (!isRecovery && templates.isEmpty))
            }
        }
        .padding(24)
        .frame(width: 610, height: 540)
        .interactiveDismissDisabled(isCommitting)
    }

    private func commit() async {
        guard !isCommitting, !didAttemptCommit else { return }
        didAttemptCommit = true
        isCommitting = true
        defer { isCommitting = false }
        do {
            try await onConfirm()
            presentationMode.wrappedValue.dismiss()
        } catch {
            errorMessage = QuickFileViewModel.templateOperationErrorMessage(error)
        }
    }
}
