# QuickFile 更新发布说明

QuickFile 使用 Sparkle 2，默认构建不启用在线更新。正式更新源和签名公钥尚未确定；Developer ID、公证、真实 HTTPS 跨版本升级和完整运行准入仍需完成，尚未对外发布。源码版本以 [project.yml](project.yml) 为准，发布门槛见 [RELEASE_CHECKLIST.md](RELEASE_CHECKLIST.md)。

## 应用行为

- 应用菜单提供“检查更新…”，设置窗口显示版本及更新选项。未启用在线更新的构建显示手动安装说明，检查菜单禁用。
- 自动检查默认关闭；用户开启后每天检查一次。下载与安装由用户确认，不提供后台静默安装。
- 正式版本使用默认稳定渠道；选择“接收 Beta 版本”后，同时接收 `beta` 渠道。关闭自动检查时，改变渠道不会触发联网检查。
- Debug 和 XCTest 不启动更新器。源码自编译默认不启用正式渠道，避免替换自编译应用的签名身份及授权环境。
- 主 App 使用 Sparkle Installer/Downloader XPC 服务，保留原有沙盒、文件访问与 App Group 权限；Finder Extension 不嵌入更新器。
- Finder 响应探针同时核对安装路径与运行版本。旧版本仍在运行时不会被标记为当前版本已响应；用户可在诊断页按指引重新启用扩展，必要时重启 Finder。

## 配置正式更新渠道

`project.yml` 是配置源，工程与 Info.plist 由 XcodeGen 生成。正式包需要在 Archive 时提供三个构建设置：

| 设置 | 默认值 | 正式包要求 |
| --- | --- | --- |
| `QUICKFILE_UPDATES_ENABLED` | `NO` | `YES` |
| `QUICKFILE_UPDATE_FEED_URL` | 空 | 固定 HTTPS appcast 地址 |
| `QUICKFILE_UPDATE_PUBLIC_KEY` | 空 | Sparkle 生成的 Base64 EdDSA 公钥 |

SPM 包版本由 `project.yml` 固定，`Package.resolved` 保存对应提交。Sparkle 工具位于 Xcode 包目录的 `SourcePackages/artifacts/sparkle/Sparkle/bin/`，以下示例使用独立构建目录；实际路径以本次构建为准。

普通 Xcode 构建的 Code Sign on Copy 只签外层 framework。工程在复制 Sparkle 后运行 `Scripts/sign-sparkle.sh`，用当前构建身份按 Installer、Downloader、Autoupdate、Updater、framework 的顺序重签，再由 Xcode 签主 App；Downloader 保留自有 entitlements。无签名自检跳过此阶段。发布前仍检查最终导出产物，不能只检查 framework 外层。流程依据 [Sparkle 官方签名说明](https://sparkle-project.org/documentation/sandboxing/#code-signing)。

正式签名密钥确定后，可用 Sparkle 的 `generate_keys --account quickfile-release` 创建或读取该账号的密钥。私钥保存在登录 Keychain，不写入源码、命令参数或更新服务器；公钥用于上述构建设置。不要临时更换已发布应用的公钥，轮换必须按 Sparkle 的迁移规则处理。

生成工程后，Archive 命令的形式如下；路径、Team、地址及公钥必须替换为实际值：

```bash
xcodegen generate
xcodebuild \
  -project QuickFile.xcodeproj -scheme QuickFile -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath .build/Temporary/update-release/QuickFile.xcarchive \
  -clonedSourcePackagesDirPath .build/Temporary/update-release/SourcePackages \
  DEVELOPMENT_TEAM=YOUR_TEAM \
  QUICKFILE_UPDATES_ENABLED=YES \
  QUICKFILE_UPDATE_FEED_URL='https://YOUR_HOST/appcast.xml' \
  QUICKFILE_UPDATE_PUBLIC_KEY='YOUR_PUBLIC_KEY' \
  archive
```

随后按既有 Developer ID 导出配置导出，完成公证与 App 装订。Archive/Export 会处理 Sparkle framework、XPC 服务与更新辅助进程的签名；只对最外层 framework 执行签名不能证明内部辅助进程已正确签名。保持主 App、扩展的发布标识、团队与 App Group 连续。

## 准备更新包与 appcast

每次候选递增 `CURRENT_PROJECT_VERSION`，主 App 与扩展保持一致；Beta 与稳定版共享递增构建号。营销版本使用数字形式，Beta 标记放在发布说明与 appcast 渠道中。

对最终签名、公证并装订的 App 执行以下命令。脚本只准备本地产物，不执行公证或上传：

```bash
python3 Scripts/prepare-update.py \
  --app .build/Temporary/update-release/Export/QuickFile.app \
  --output .build/Updates \
  --download-url-prefix 'https://YOUR_HOST/downloads/v0.1.0/' \
  --sparkle-bin .build/Temporary/update-release/SourcePackages/artifacts/sparkle/Sparkle/bin \
  --key-account quickfile-release \
  --channel stable \
  --release-notes CHANGELOG.md
```

`--release-notes` 可省略。发布 Beta 时使用 `--channel beta`。输出目录用于保存版本历史，正式发布前应确保其中的 appcast 与线上版本一致；脚本保留旧稳定版与 Beta 条目，并拒绝重复或递减构建号。更新包采用全量 ZIP，说明嵌入 appcast，不生成增量包。

App 内更新由 Swift 接入 Sparkle。Python 脚本负责本地发布准备和产物检查，打包、签名与 appcast 生成使用系统及 Sparkle 工具。

脚本在读取版本历史前获取输出目录的独占文件锁，并保持到本次准备结束。同目录另一个准备任务会立即报错，待前一个任务结束后重试。`.quickfile-update.lock` 文件保留在输出目录，锁由系统随文件关闭释放；不要删除该文件，以免进程锁住不同文件。

脚本先调用 `verify-beta-artifact.py` 检查 Developer ID、App Group、描述文件、Sparkle framework 及四个辅助程序的签名与双架构、Gatekeeper，再打包、生成 appcast 并验证最终更新包的 EdDSA 签名。架构检查针对最终待发布 App，拒绝单架构、缺失程序或无法读取架构的产物。未通过时不会替换既有 appcast。默认 Gatekeeper 设置的新机器验收仍需单独完成；本机关闭 Gatekeeper 时不能通过该发布检查。

ZIP 与校验报告写入时拒绝覆盖同名文件，最后原子替换 appcast。若在 appcast 替换成功前发生提交异常或 Ctrl+C，脚本撤回本次新增的 ZIP 与报告，保留既有 appcast 和历史产物，可以重试同一构建号。

发布时先上传最终 ZIP 并确认下载地址可用，再发布 appcast。不要覆盖已经发布的同版本 ZIP，也不要在签名后修改 ZIP。当前没有更新器的旧版需要手动覆盖安装一次，之后才能使用 App 内更新。

## 验证与发布门槛

本地自检：`./Scripts/verify-release-readiness.sh`。更新脚本测试：`python3 -m unittest discover -s Scripts/tests -v`。

真实发布前仍需两份正式签名产物和实际 HTTPS 测试源，覆盖：

- 手动检查、自动检查关闭/开启、偏好重启后保留；稳定用户不收到 Beta，选择后可收到。
- 旧版升级新版、Finder 扩展正在运行时升级、升级后当前版本探针及实际文件创建。
- 模板、目录授权、共享存储与版本迁移保持正确。
- 下载中断、签名错误、同字节长度的篡改包、最低系统不满足时不安装。
- 默认安全设置下首次下载、安装、启动，以及所有 Sparkle 辅助进程的签名与双架构。

源码、签名或包内容改变后，为新候选更新包、校验和与收据，并重验受影响项。发布完成后按 [CONTRIBUTING.md](CONTRIBUTING.md) 回收本轮临时构建与验证产物；更新源所需的已发布 ZIP、appcast 和版本历史须保留，不能在回收时删除。Mac App Store 构建需要移除 Sparkle 分发配置并交由商店更新。

参考：[Sparkle 接入](https://sparkle-project.org/documentation/)、[沙盒配置](https://sparkle-project.org/documentation/sandboxing/)、[发布与渠道](https://sparkle-project.org/documentation/publishing/)。
