import AppKit
import QuickFileCore

extension CommunityUpdateStatus {
    var message: LocalizedStringResource {
        switch self {
        case .checked(.updateAvailable(let release)):
            return .init("update.community.available",
                         defaultValue: "发现新版本 \(release.tag)（build \(release.build)）。请前往 GitHub 发行页下载安装。",
                         comment: "Community update result. Arguments are the published tag and internal build; installation is manual.")
        case .checked(.upToDate):
            return .init("当前没有比此构建更新的已发布版本。", comment: "Community version check found no newer eligible release.")
        case .checked(.noPublishedRelease):
            return .init("GitHub 当前没有符合所选渠道的已发布版本。", comment: "No published release matches the user's stable or beta choice.")
        case .failed(.invalidCurrentVersion):
            return .init("当前构建的版本信息无效，无法比较更新。", comment: "Community update check cannot parse the installed version or build.")
        case .failed(.invalidResponse):
            return .init("GitHub 返回的版本信息无效，请稍后重试。", comment: "Community update check received an invalid release response.")
        case .failed(.rateLimited):
            return .init("GitHub 暂时限制了检查请求，请稍后重试。", comment: "GitHub rejected a manual update check due to rate limiting.")
        case .failed(.requestFailed):
            return .init("无法连接 GitHub 检查更新，请检查网络后重试。", comment: "Community update check failed to reach GitHub.")
        case .failed(.responseTooLarge):
            return .init("GitHub 版本信息超过检查上限，无法确认最新版本。", comment: "Community update check exceeded its response or pagination budget.")
        case .failed(.missingProvenance):
            return .init("该发行版的构建收据或下载资产不完整，无法确认更新版本。", comment: "Community release metadata cannot be matched to its build provenance and download assets.")
        }
    }

    var release: CommunityRelease? {
        if case .checked(.updateAvailable(let release)) = self { return release }
        return nil
    }
}

@MainActor
enum CommunityUpdatePresentation {
    static func present(_ status: CommunityUpdateStatus) {
        let alert = NSAlert()
        alert.messageText = QuickFileLocalization.text(.init("软件更新"))
        alert.informativeText = QuickFileLocalization.text(status.message)
        if status.release != nil {
            alert.addButton(withTitle: QuickFileLocalization.text(.init("打开发行页", comment: "Open the selected Community release in the default browser.")))
            alert.addButton(withTitle: QuickFileLocalization.text(.init("取消")))
        } else {
            alert.addButton(withTitle: QuickFileLocalization.text(.init("好")))
        }
        // Keep the result in Settings if a Finder or file panel already owns the modal slot.
        guard let response = AppModalPresentationGate.shared.present({
            NSApp.activate(ignoringOtherApps: true)
            return alert.runModal()
        }) else { return }
        if response == .alertFirstButtonReturn, let release = status.release {
            NSWorkspace.shared.open(release.pageURL)
        }
    }
}
