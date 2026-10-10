import SwiftUI

struct UpdateSettingsView: View {
    @ObservedObject var updates: UpdateController

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("软件更新")
                .font(.title2)
                .fontWeight(.semibold)
            Text("当前版本 \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "未知")（\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "未知")）")
                .foregroundColor(.secondary)

            if updates.isAvailable {
                Toggle("自动检查更新", isOn: Binding(
                    get: { updates.automaticallyChecksForUpdates },
                    set: updates.setAutomaticallyChecksForUpdates
                ))
                Text("开启后每天检查一次。下载和安装前会询问你。")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Toggle("接收 Beta 版本", isOn: Binding(
                    get: { updates.receivesBetaUpdates },
                    set: updates.setReceivesBetaUpdates
                ))
                Button("检查更新…", action: updates.checkForUpdates)
                    .disabled(!updates.canCheckForUpdates)
                Text("更新检查会连接更新服务，不上传文件、路径、模板或剪贴板内容。")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                Text("当前构建未启用在线更新，请通过安装新版应用更新。")
                    .foregroundColor(.secondary)
            }

            Text("更新后若 Finder 菜单未恢复，请在诊断页检查扩展状态；必要时在系统扩展管理中关闭再开启 QuickFile。")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(24)
        .frame(width: 440, alignment: .leading)
    }
}
