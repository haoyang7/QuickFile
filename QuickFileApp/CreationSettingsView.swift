import SwiftUI

struct CreationSettingsView: View {
    @Environment(\.locale) private var quickFileLocale
    @ObservedObject var model: CreationSettingsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("文件创建").font(.title2).fontWeight(.semibold)
            Toggle("创建后自动打开", isOn: Binding(
                get: { model.automaticallyOpen },
                set: { value in Task { await model.setAutomaticallyOpen(value) } }
            ))
            .disabled(model.isBusy || (!model.hasLoaded && model.errorMessage == nil))
            Text("使用系统默认应用打开新文件，同时适用于主应用和 Finder 菜单。默认关闭；打开失败不会删除文件或重复创建。")
                .font(.caption)
                .foregroundColor(.secondary)
            if model.isBusy { ProgressView().controlSize(.small) }
            if let message = model.errorMessage {
                Text(message).foregroundColor(.red)
                HStack {
                    Button("重新加载") { Task { await model.reload() } }
                    Button("保存为关闭") { Task { await model.setAutomaticallyOpen(false) } }
                }
                .disabled(model.isBusy)
            }
            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(width: 440, alignment: .leading)
        .task { await model.reload() }
    }
}
