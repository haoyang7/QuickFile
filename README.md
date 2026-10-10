# QuickFile

QuickFile 是 macOS Finder 的新建文件工具。支持模板、变量替换、同名自动编号，以及通过系统面板授权目标目录。主应用和 Finder 扩展共享本机模板与授权记录。

项目处于 0.1 开发阶段，最低支持 macOS 13，构建目标为 Apple Silicon 与 Intel Universal。源码、CI 和开发签名构建的可用性不代表正式分发已经验收；发布条件见 [发布清单](RELEASE_CHECKLIST.md)。

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

签名运行需要自己的 Apple 开发团队及相应 App ID、扩展 ID 和 App Group 能力。将 `YOUR_TEAM_ID` 替换为有权使用这些标识的团队：

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
| App Group | `group.com.haoyoung.QuickFile` |

两个 Target 使用同一开发团队。若自定义标识，同步修改 `project.yml`、`Shared/TemplateStore.swift` 中的配置及配置测试、校验脚本，再生成工程并自检。保留 App Sandbox 和 Hardened Runtime；扩展应嵌入 `QuickFile.app/Contents/PlugIns/FinderExtension.appex`。开发签名不能代替 Developer ID、公证和 Gatekeeper 验证。

## 安装与使用

1. 核对候选版本与签名，备份用户数据和现有安装。退出旧版 QuickFile，将构建目录中的 `Build/Products/Release/QuickFile.app` 安装到 `/Applications`。
2. 启动 QuickFile，在系统扩展设置中启用 Finder 扩展。在主应用选择目标目录，或首次从 Finder 创建时通过系统面板授权。
3. 在 Finder 文件夹背景右键，选择“新建文件 → Markdown”，确认生成并选中 `未命名.md`。
4. 升级后核对实际加载的主应用和扩展版本。旧扩展仍在运行时，保存当前工作后重新启动 Finder，再验证菜单。

测试版安装、恢复与清理遵循 [开发流程](CONTRIBUTING.md)。不要将隐藏构建目录作为日常安装位置；清理结束后再次验证 Finder 菜单。完整测试步骤见 [Beta 测试指南](BETA_TEST_GUIDE.md)。

## 创建规则

- 背景右键使用当前目录；单文件夹在内部创建；单文件使用父目录；同父目录多选使用共同父目录。侧边栏使用本次右键目标。目标含糊、失效或跨目录时拒绝创建，不回退到其他目录。
- 文件名按“本次输入 → 模板默认文件名 → 未命名”选择；默认文件名按字面使用，不展开变量。同名自动编号，不覆盖已有文件。已输入的模板扩展名不会重复添加；过长名称为扩展名和序号预留空间，保留完整 Unicode 字符。
- 扩展名可留空；输入或设置默认文件名为 `.gitignore` 等名称可按原名创建。Finder 菜单使用模板默认文件名，未设置时使用“未命名”。
- 内置文本、Markdown、JSON、YAML 和 Shell 模板。Shell 模板只创建文本，不自动运行或添加执行权限。
- 支持 `{{date}}`、`{{time}}`、`{{year}}`、`{{folderName}}`、`{{clipboard}}`、`{{sequence}}`。未知变量保持原文，替换结果不再次展开。仅实际使用含剪贴板变量的有效模板时读取剪贴板。
- 保存模板后通知主 App 与扩展刷新；主 App 激活时检查外部变更，也可在模板管理的“更多”菜单中重新加载。刷新保留编辑草稿，创建和保存仍校验最新配置；并发保存冲突不会覆盖其他实例已经保存的内容。
- 模板管理支持复制后编辑，保存时新增独立模板；取消不改变原模板。可用行首手柄拖动排序，松开后保存，也可使用上移、下移按钮；筛选时按完整列表重排。
- 编辑模板时可点击“预览内容”，查看使用示例日期、文件夹、剪贴板和序号生成的纯文本。JSON 模板还会提示示例结果的语法是否有效；不读取真实剪贴板，不执行正文。预览最多接收 64 KiB 正文、输出 128 KiB，超限会明确提示，不截取部分内容；保存限制保持不变。

设置默认文件名后，模板库使用带版本的格式，导出使用交换格式 v2；旧版应用不能读取带默认名的配置或导出文件。未设置默认名时保留原格式，新版仍可读取旧模板库与 v1 导出文件。

文件先写入同卷私有暂存目录，再以禁止覆盖的原子操作发布。只读卷、无法保护私有条目的卷、不支持安全发布的文件系统，以及带文件继承 ACL 的目标会明确失败。异常终止可能留下暂存数据，但不会发布未写完的正式文件。

菜单生成、授权确认与实际打开目录时分别核对目标身份。授权撤销先完成时，旧请求不能继续获得准入；已通过最终授权核对的操作可以完成。慢 I/O 继续占用有限执行槽，重复点击不会无限排队。具体并发与存储约束见 [架构说明](ARCHITECTURE.md)。

## 诊断

“诊断”页区分扩展嵌入、系统注册、用户启用和本次响应，也提供授权管理及目录写入探针。探针仅清理自身创建的文件与空目录，无法安全清理时报告残留位置。

- 菜单未出现：先核对安装副本和扩展开关，再打开 Finder 菜单并检查响应。未收到响应不等于扩展崩溃；扩展进程由 macOS 管理。
- 权限错误：重新确认目录授权，检查卷权限与可用空间。卷改名后可能需要刷新授权或通过系统面板重新授权。
- 文件已创建但无法定位：先检查目标目录，避免重复创建。Finder 定位失败不会删除已创建文件。
- 模板不可用：在主应用重新加载或修复配置，不通过删除原配置掩盖读取失败。

系统注册可用只读命令核对，确认路径属于预期安装：

```bash
pluginkit -m -A -D -v -i com.haoyoung.QuickFile.FinderExtension
```

诊断复制仅输出白名单字段，不含用户名、完整路径、模板正文、书签或剪贴板。QuickFile 不会自动切换系统扩展开关或终止 Finder。

## 文档与隐私

开发维护参阅 [架构](ARCHITECTURE.md)、[贡献流程](CONTRIBUTING.md) 和 [CI](CI.md)；测试与分发参阅 [Beta 规则](BETA_RELEASE.md)、[反馈模板](BETA_FEEDBACK.md)、[更新配置](UPDATES.md) 和 [变更记录](CHANGELOG.md)。

核心文件操作在本机完成，不含账号、遥测或分析 SDK，不请求完全磁盘访问。联网仅用于用户选择的软件更新，未配置更新源时保持离线。详见 [隐私说明](PRIVACY.md) 和 [MIT License](LICENSE)。
