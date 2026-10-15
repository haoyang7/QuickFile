# QuickFile

QuickFile 是 macOS Finder 的新建文件工具。支持模板、变量替换、同名自动编号，以及通过系统面板授权目标目录。主应用和 Finder 扩展共享本机模板与授权记录。

设置 → 通用可选择跟随系统、简体中文或 English，显式选择同时用于主 App 和 Finder 菜单；已有模板内容保持原样。同页可开启“创建后自动打开”，默认关闭，开启后使用系统默认应用打开成功创建的文件。

项目处于 0.1 开发阶段，最低部署目标为 macOS 13，构建目标为 Apple Silicon 与 Intel Universal。macOS 13/14 尚未完成实机验收；具体候选的系统、架构和安装验证范围以其发布说明为准。源码、CI 和开发签名构建的可用性不代表正式分发已经验收；发布条件见 [发布清单](RELEASE_CHECKLIST.md)。

## 普通用户下载与安装

Community DMG 只从 [GitHub Releases](https://github.com/haoyang7/QuickFile/releases) 对应发布页取得；发布状态以 GitHub Releases 为准，需要核对构建身份时再查看该页的 `build-provenance.json`；没有对应发布页时不视为已经发布。普通安装只需下载 DMG 和对应 `.sha256` 并先核对 SHA-256；`artifact-check.json`、`INSTALL.txt` 和 `build-provenance.json` 是按需查看的收据与说明。随后退出旧版并备份，拖到“应用程序”、推出 DMG，最后从“应用程序”打开。完整的未公证 App 首次打开、Finder 扩展、目录授权、升级和 `xattr` 排障步骤见[安装指南](INSTALLATION.md)。

Community 与 Developer ID 构建使用相同应用标识和本地共享目录，覆盖安装时延续模板与设置；签名变化后的书签权限仍须单独验证。较早的 App Group 版本通过导出、预览导入迁移模板。已有可用安装的用户应先阅读[升级与恢复](INSTALLATION.md#升级与恢复)。

## 构建与测试

使用 Xcode 26.3 和 XcodeGen 2.46.0，`project.yml` 是工程配置源文件：

```bash
xcodegen generate
open QuickFile.xcodeproj
```

不需要签名的原生测试与 Universal 自检：

```bash
./Scripts/verify-release-readiness.sh
```

脚本会生成工程、运行单元测试并检查 Release 产物的架构、嵌入扩展、标识和权限配置。Linux 只能运行适用的 Python 脚本测试；macOS 原生检查由 [CI](CI.md) 或本机 Xcode 执行。

没有 Apple 开发者会员时，可使用实验性的[免费自行分发流程](COMMUNITY_DISTRIBUTION.md)，生成保留沙盒的 ad-hoc Universal DMG，支持拖拽至“应用程序”安装。该应用未经公证，跨机器安装、Finder 集成及升级仍须单独验收：

```bash
./Scripts/build-community.sh --output .build/Packages/community-candidate
```

生成带发布标签的候选时追加 `--release-tag v0.1.0-beta.2`（示例）；参数用于对外 DMG 文件名，不创建 Git 标签或发布 Release。内部 build 以应用和收据为准。

维护者的 GitHub Actions 打包入口、五项 artifact 和不自动公开 Release 的约束见[免费自行分发流程](COMMUNITY_DISTRIBUTION.md#github-actions-打包)。

证书签名构建需要自己的 Apple 开发团队及相应 App ID、扩展 ID。两种站外渠道均使用精确路径权限访问同一本地共享目录，不要求 App Group 能力。将 `YOUR_TEAM_ID` 替换为有权使用这些标识的团队：

```bash
xcodebuild \
  -project QuickFile.xcodeproj \
  -scheme QuickFile \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath .build/Temporary/signed-candidate/DerivedData \
  DEVELOPMENT_TEAM=YOUR_TEAM_ID \
  -allowProvisioningUpdates \
  ONLY_ACTIVE_ARCH=NO \
  "ARCHS=arm64 x86_64" \
  clean build
```

| 配置 | 默认标识 |
| --- | --- |
| 主应用 | `com.haoyoung.QuickFile` |
| Finder 扩展 | `com.haoyoung.QuickFile.FinderExtension` |
| 共享存储 | `~/Library/Application Support/QuickFileCommunity/` |
| 默认构建渠道 | `development` |

两个 Target 使用同一开发团队。若自定义标识，同步修改 `project.yml`、`Shared/TemplateStore.swift` 中的配置及配置测试、校验脚本，再生成工程并自检。保留 App Sandbox 和 Hardened Runtime；扩展应嵌入 `QuickFile.app/Contents/PlugIns/FinderExtension.appex`。开发签名不能代替 Developer ID、公证和 Gatekeeper 验证。Developer ID Archive 需设置 `QUICKFILE_DISTRIBUTION_CHANNEL=developer-id`；Community 构建脚本设置 `community`，两端存储模式均为 `local-shared`。

## 安装与使用

普通用户安装和权限排障请先阅读[安装指南](INSTALLATION.md)；以下步骤用于安装后的基本功能验收。

1. 启动 QuickFile，在系统扩展设置中启用 Finder 扩展。主应用“选择文件夹”用于当前创建，不自动保存 Finder 授权；需要持久授权时，在创建页的 Finder 设置或诊断页添加，或在首次 Finder 创建时确认系统授权面板。
2. 在 Finder 文件夹背景右键，选择“新建文件 → Markdown”，确认生成并选中 `未命名.md`。
3. 升级后核对实际加载的主应用和扩展版本。旧扩展仍在运行时，保存当前工作后重新启动 Finder，再验证菜单。

测试版安装、恢复与清理遵循 [开发流程](CONTRIBUTING.md)。不要将隐藏构建目录作为日常安装位置；清理结束后再次验证 Finder 菜单。完整测试步骤见 [Beta 测试指南](BETA_TEST_GUIDE.md)。

## 创建规则

- 背景右键使用当前目录；单文件夹在内部创建；单文件使用父目录；同父目录多选使用共同父目录。侧边栏使用本次右键目标。目标含糊、失效或跨目录时拒绝创建，不回退到其他目录。
- 文件名按“本次输入 → 模板默认文件名 → 未命名”选择；默认文件名按字面使用，不展开变量。同名自动编号，不覆盖已有文件。已输入的模板扩展名不会重复添加；过长名称为扩展名和序号预留空间，保留完整 Unicode 字符。
- 扩展名可留空；输入或设置默认文件名为 `.gitignore` 等名称可按原名创建。Finder 菜单使用模板默认文件名，未设置时使用“未命名”。
- 新建、编辑或导入模板时，名称和默认文件名拒绝控制字符、双向排版控制符及零宽空格；合法 emoji、连字和组合附标继续保留。历史模板仍可加载和修复，Finder 菜单与创建出的文件名会净化风险字符。
- 默认模板依次为 Word（`.docx`）、Excel（`.xlsx`）、PowerPoint（`.pptx`）、文本（`.txt`）、Markdown、JSON、YAML 和 Shell。Office 模板生成有效的空白文档，可修改名称、默认文件名、启用状态或复制、删除；内容在对应的 Office 应用中编辑。Shell 模板只创建文本，不自动运行或添加执行权限。已有模板库不会自动插入新项，“恢复默认模板”会替换为这 8 项。
- 支持 `{{date}}`、`{{time}}`、`{{year}}`、`{{folderName}}`、`{{clipboard}}`、`{{sequence}}`。未知变量保持原文，替换结果不再次展开。仅实际使用含剪贴板变量的有效模板时读取剪贴板。
- 保存模板后通知主 App 与扩展刷新；主 App 激活时检查外部变更，也可在模板管理的“更多”菜单中重新加载。刷新保留编辑草稿，创建和保存仍校验最新配置；并发保存冲突不会覆盖其他实例已经保存的内容。
- 模板管理支持复制后编辑，保存时新增独立模板；取消不改变原模板。可用行首手柄拖动排序，松开后保存，也可使用上移、下移按钮；筛选时按完整列表重排。
- 编辑模板时可点击“预览内容”，查看使用示例日期、文件夹、剪贴板和序号生成的纯文本。JSON 模板还会提示示例结果的语法是否有效；不读取真实剪贴板，不执行正文。预览最多接收 64 KiB 正文、输出 128 KiB，超限会明确提示，不截取部分内容；保存限制保持不变。

含 Office 模板的模板库使用 v4、导出使用交换格式 v3，避免旧版应用丢失文档类型。纯文本库有默认文件名时仍使用库 v3 / 交换 v2，否则保留旧数组 / 交换 v1；新版兼容读取这些旧格式。普通文本模板不会仅因扩展名为 `.docx`、`.xlsx` 或 `.pptx` 而改变内容生成方式。

文件先写入同卷私有暂存目录，再以禁止覆盖的原子操作发布。只读卷、无法保护私有条目的卷、不支持安全发布的文件系统，以及带文件继承 ACL 的目标会明确失败。异常终止可能留下暂存数据，但不会发布未写完的正式文件。

模板导出允许原子替换保存面板选定路径上的普通文件；确认后若其他程序替换了该路径，导出仍按路径覆盖。QuickFile 自身配置、锁文件和恢复备份受保护。导出失败不会先删除旧文件。

菜单生成、授权确认与实际打开目录时分别核对目标身份。授权撤销先完成时，旧请求不能继续获得准入；已通过最终授权核对的操作可以完成。慢 I/O 继续占用有限执行槽，重复点击不会无限排队。具体并发与存储约束见 [架构说明](ARCHITECTURE.md)。

## 诊断

“诊断”页区分扩展嵌入、系统注册、用户启用和本次响应，也提供授权管理及目录写入探针。探针仅清理自身创建的文件与空目录，无法安全清理时报告残留位置。

- 菜单未出现：先核对安装副本和扩展开关，再打开 Finder 菜单并检查响应。未收到响应不等于扩展崩溃；扩展进程由 macOS 管理。
- 权限错误：重新确认目录授权，检查卷权限与可用空间。卷改名后可能需要刷新授权或通过系统面板重新授权。
- 授权记录无法读取或保存：在“文件夹授权 → 授权存储维护”中修复记录权限或显示存储目录；列表读取失败时直接显示修复入口。权限修复不修改书签，也不代替文件夹重新授权。
- 文件已创建但无法定位：先检查目标目录，避免重复创建。Finder 定位失败不会删除已创建文件。
- 模板不可用：在主应用重新加载或修复配置，不通过删除原配置掩盖读取失败。

系统注册可用只读命令核对，确认路径属于预期安装：

```bash
pluginkit -m -A -D -v -i com.haoyoung.QuickFile.FinderExtension
```

诊断复制仅输出白名单字段，不含用户名、完整路径、模板正文、书签或剪贴板。QuickFile 不会自动切换系统扩展开关或终止 Finder。

## 文档与隐私

开发维护参阅 [架构](ARCHITECTURE.md)、[贡献流程](CONTRIBUTING.md) 和 [CI](CI.md)；测试与分发参阅 [安装指南](INSTALLATION.md)、[免费自行分发](COMMUNITY_DISTRIBUTION.md)、[Beta 规则](BETA_RELEASE.md)、[反馈模板](BETA_FEEDBACK.md)、[更新配置](UPDATES.md) 和 [变更记录](CHANGELOG.md)。

核心文件操作在本机完成，不含账号、遥测或分析 SDK，不请求完全磁盘访问。联网仅用于用户选择的软件更新，未配置更新源时保持离线。详见 [隐私说明](PRIVACY.md) 和 [MIT License](LICENSE)。
