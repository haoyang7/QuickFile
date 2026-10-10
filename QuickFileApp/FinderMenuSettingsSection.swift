import SwiftUI

@MainActor
struct FinderMenuSettingsSection: View {
    @ObservedObject var viewModel: FinderMenuSettingsViewModel
    @State private var isExpanded = false

    private var isBusy: Bool {
        viewModel.isLoading || viewModel.isSaving
    }

    private var progress: some View {
        ProgressView()
            .controlSize(.small)
            .accessibilityLabel(viewModel.isSaving ? "正在保存菜单设置" : "正在加载菜单设置")
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            controls
                .padding(.top, 8)
        } label: {
            HStack {
                Text("Finder 菜单显示")
                Spacer()
                if isBusy {
                    progress
                } else if viewModel.loadError != nil {
                    Label("设置读取失败", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundColor(.red)
                } else if let status = viewModel.status, case .failure = status {
                    Label("设置未保存", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundColor(.red)
                } else if viewModel.hasLoaded {
                    Text(viewModel.savedSummary)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("显示数量")
                Picker("显示数量", selection: $viewModel.showsAll) {
                    Text("全部").tag(true)
                    Text("最多").tag(false)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 140)
                .disabled(!viewModel.canEdit)

                TextField("正整数", text: $viewModel.maximumCountText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
                    .accessibilityLabel("Finder 菜单最多显示的模板数")
                    .disabled(viewModel.showsAll || !viewModel.canEdit)
                Text("个模板")
                    .foregroundColor(.secondary)

                Button("保存") {
                    Task { await viewModel.save() }
                }
                .disabled(!viewModel.canSave)

                if isBusy {
                    progress
                }
                Spacer(minLength: 0)
            }
            Text("按上方列表顺序显示启用的模板；此设置不影响主应用中的模板列表。")
                .font(.caption)
                .foregroundColor(.secondary)

            if viewModel.hasLoaded {
                Text(viewModel.savedSummary)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            if let error = viewModel.loadError {
                Text("无法读取 Finder 菜单设置：\(error) 可重新加载，或保存设置以修复。")
                    .font(.caption)
                    .foregroundColor(.red)
                Button("重新加载菜单设置") { Task { await viewModel.reload() } }
                    .disabled(isBusy)
            }
            if let status = viewModel.status {
                switch status {
                case let .success(message):
                    Label(message, systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundColor(.green)
                case let .failure(message):
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundColor(.red)
                }
            }
        }
    }
}
