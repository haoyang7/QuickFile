import QuickFileCore
import SwiftUI

struct LanguageSettingsView: View {
    @Environment(\.locale) private var quickFileLocale
    @ObservedObject var model: LanguageSettingsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("语言", selection: Binding(get: { model.language }, set: { value in
                Task { await model.select(value) }
            })) {
                Text("跟随系统").tag(QuickFileLanguage.system)
                ForEach(QuickFileLanguage.allCases.filter { $0 != .system }, id: \.self) { language in
                    Text(verbatim: language.nativeName).tag(language)
                }
            }
            .disabled(model.isBusy || !model.hasLoaded)
            Text("同时用于 QuickFile 和 Finder 菜单。已有模板名称和内容保持不变。")
                .font(.caption).foregroundColor(.secondary)
            if let message = model.errorMessage {
                Text(message).foregroundColor(.red)
                Button("重新加载") { Task { await model.reload() } }.disabled(model.isBusy)
            }
        }
    }
}
