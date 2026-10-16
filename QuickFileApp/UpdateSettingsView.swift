import QuickFileCore
import SwiftUI
import QuickFileInfrastructure

struct UpdateSettingsView: View {
    @Environment(\.locale) private var quickFileLocale
    @ObservedObject var updates: UpdateController

    private var installedVersionName: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? QuickFileLocalization.text(.init("未知"))
        return CommunityReleaseChecker.installedVersionName(
            version: version, releaseTag: Bundle.main.object(forInfoDictionaryKey: "QuickFileReleaseTag") as? String
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("软件更新")
                    .font(.title2)
                    .fontWeight(.semibold)
                Text("当前版本 \(installedVersionName)（\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? QuickFileLocalization.text(.init("未知")))）")
                    .foregroundColor(.secondary)

                Text("分发渠道：\(QuickFileDistributionChannel.current?.displayName ?? QuickFileLocalization.text(.init("未知")))")
                    .foregroundColor(.secondary)

                if updates.isAvailable {
                    if updates.usesGitHubReleases {
                        Text("点击“检查更新”时连接 GitHub Release；新版需手动下载和安装。")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else {
                        Toggle("自动检查更新", isOn: Binding(
                            get: { updates.automaticallyChecksForUpdates },
                            set: updates.setAutomaticallyChecksForUpdates
                        ))
                        Text("开启后每天检查一次。下载和安装前会询问你。")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Toggle("接收 Beta 版本", isOn: Binding(
                        get: { updates.receivesBetaUpdates },
                        set: updates.setReceivesBetaUpdates
                    ))
                    Button("检查更新…", action: updates.checkForUpdates)
                        .disabled(!updates.canCheckForUpdates)
                    if updates.usesGitHubReleases {
                        if updates.isCheckingForUpdates {
                            HStack {
                                ProgressView().controlSize(.small)
                                Text("正在检查 GitHub Release…")
                            }
                        }
                        if let status = updates.communityCheckStatus {
                            Text(QuickFileLocalization.text(status.message))
                                .fixedSize(horizontal: false, vertical: true)
                            if let release = status.release {
                                Link("打开发行页", destination: release.pageURL)
                            }
                        }
                        Link("查看 GitHub 发行版", destination: CommunityReleaseChecker.releasesPage)
                        Text("仅手动检查时连接 GitHub 及其下载服务；对方可见 IP 等连接信息。不会上传文件、路径、模板或剪贴板内容。")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else {
                        Text("更新检查会连接更新服务，不上传文件、路径、模板或剪贴板内容。")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
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
}
