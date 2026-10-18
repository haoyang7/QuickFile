# Repository Guidelines

QuickFile 是 macOS 文件创建工具，包含主应用和独立的 Finder Sync 扩展。开始前检查分支与工作区，保留已有修改。

## 项目结构与模块

- `QuickFileApp/`：SwiftUI/AppKit 界面、应用级状态、Services 入口与更新器。
- `FinderExtension/`：Finder 菜单、缓存与后台操作调度。
- `Shared/`：共享源码，由 `project.yml` 分配到 Core、Application、Infrastructure 三个库；后两者只依赖 Core，App 与扩展分别装配它们。
- `QuickFileTests/`：以主 App 为宿主的 XCTest；`Scripts/tests/`：脚本测试；`Resources/`：共享本地化资源。

新增共享文件须明确唯一模块归属；共享库不得反向依赖应用或扩展入口。职责与数据契约见 [ARCHITECTURE.md](ARCHITECTURE.md)。

## 构建与开发命令

工具链与环境准备见 [CONTRIBUTING.md](CONTRIBUTING.md)。工程配置以 `project.yml` 为源，修改后重新生成工程并检查生成差异。

```sh
xcodegen generate                         # 生成 Xcode 工程
open QuickFile.xcodeproj                  # 使用 QuickFile scheme 开发
./Scripts/verify-release-readiness.sh     # 原生测试及 Universal Release 包检查
python3 -m unittest discover -s Scripts/tests -v  # 脚本测试
```

模块归属检查用 `python3 Scripts/verify-architecture.py`；本地化检查用 `python3 Scripts/verify-localizations.py`。完整验证脚本会生成工程、运行测试并检查无签名产物，不能替代签名安装后的 Finder 实机验收。

## 编码与命名

沿用 Swift 的 4 空格缩进，类型使用 `UpperCamelCase`，属性与方法使用 `lowerCamelCase`，文件按主要类型命名。UI 与原生面板放在 `MainActor`；同步文件工作沿用现有后台执行机制。

产品文案放入 `Resources/Localizable.xcstrings`，Services 菜单放入 `QuickFileApp/*.lproj/ServicesMenu.strings`。语言切换与原生控件验收遵循 [LOCALIZATION.md](LOCALIZATION.md)。

## 测试与验证

Swift 测试使用 XCTest，放在对应 `*Tests.swift` 中，方法名以 `test` 开头并描述行为。复用已有覆盖，必要时补充本次涉及的失败、并发或生命周期用例。按改动范围运行相关测试；目标、模块或原生包变更运行完整验证脚本。纯文档修改检查 diff、链接和事实即可。

测试夹具及构建缓存放入独立的 `.build/Temporary/<任务>/`。安装、日常版本恢复与产物回收按 CONTRIBUTING.md 执行；Finder 实机步骤见 [BETA_TEST_GUIDE.md](BETA_TEST_GUIDE.md)。

## 关键行为边界

- Finder 菜单回调读取内存快照，目录准备与权威读取在后台执行；创建时重新读取模板并核对目录身份。
- 创建必须有明确目标与有效授权。保留同卷私有暂存、排他原子发布和重名编号，不能覆盖已有文件；Services 目录提示不能充当写入授权。
- 模板保存必须提供读取基线，在跨进程文件锁内核对权威配置，文本字段按原始 UTF-8 字节比较。读取失败或已保存配置丢失应暴露错误，不能静默恢复默认模板。

涉及权限、存储或 AX 兼容代码时，先阅读 ARCHITECTURE.md 对应章节，保留现有安全检查。

## 提交与 Pull Request

使用短分支，每次改动围绕一个明确目的。提交信息沿用近期的 `fix:`、`feat:`、`docs:` 等前缀与简短动作描述。PR 说明问题、行为变化、验证结果及未完成的实机检查；CI 结论按 [CI.md](CI.md) 绑定实际提交与运行。

公开文档使用仓库相对路径；README 与 INSTALLATION 的中英文版本同步维护。提交、推送、安装及发布须有用户授权；发布另按 [RELEASE_CHECKLIST.md](RELEASE_CHECKLIST.md) 执行。
