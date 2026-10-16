# 开发与维护

开始改动前按 [架构说明](ARCHITECTURE.md) 确认模块、依赖方向及状态所有者。`project.yml` 是工程配置源；新增 Shared 文件只归属一个库目标，同步生成工程并保留扩展安全 API 编译约束。

## 本地构建与测试

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

生成带发布标签的候选时追加 `--release-tag v0.1.0-beta.2`（示例）；参数用于对外 DMG 文件名，并在签名前写入主 App 与 Finder 扩展的 `QuickFileReleaseTag`，不创建 Git 标签或发布 Release。标准版本/build 保持数字形式；内部 build 以应用和收据为准。不传标签的本地打包会清除副本中的旧标签。

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

## 创建行为与兼容性参考

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

## 修改与验证

从最新 main 建短分支，每次解决一个明确问题。保留已有用户修改；普通 PR 在实现完成后接受检查，未收敛的实验使用 Draft。提交、推送、合并、签名安装和发布分别遵循任务的授权范围。默认保留可追溯提交；历史清理仅在明确授权并确认范围后执行。

验证覆盖改动影响的行为与失败边界。源码、脚本和配置修改应运行相应测试，并等待相关 CI 终态；文案或注释修改可先检查 diff、链接和事实，若触发 CI 则如实记录结果。不能以减少测试、放宽签名或安全断言消除失败。

性能与内存调查使用隔离夹具，记录版本、环境、根因假设、对照、失败条件与证据范围。计时区分输入、产品处理、文件出现和 Finder 显示选中，注明单调时钟、端点和误差。自动化工具往返不是产品耗时，少量样本不能证明总体百分位；减少刷新、短时内存稳定或 CI 通过不能替代泄漏归因。

本地化与新增语言遵循 [LOCALIZATION.md](LOCALIZATION.md)，包括资源接入、动态文案、翻译校验及安装验收。

## CI 与合并

工作流、矩阵及证据边界见 [CI.md](CI.md)。主 CI 覆盖 Linux 脚本、macOS 15 arm64/Intel 和 macOS 26 arm64；macOS 27 兼容性独立运行，AX 系统基线仅手动调查。

检查必须绑定 PR head、base、实际 checkout SHA、run URL 和各 job 结论。PR 默认验证临时合并结果；base 变化时重新核对，合并后检查最终 main。PR 仅修改根目录 Markdown 或 LICENSE 时，`CI required` 明确验收跳过范围，应记为“门禁通过，测试未执行”；main push 等被路径过滤的运行仍记为“CI 未触发”。

合并要求目的明确、相关检查完成、没有已知回归，并准确记录未验证范围。单人维护可记录自审结论，不将其称为独立审批。main 是开发主线；合并不等于发布。正式发布按 [29 项清单](RELEASE_CHECKLIST.md) 验收，并以版本标签固定最终源码。

## 构建与实机验收

- 开发期营销版本可保持 0.1.0。产品源码、签名、profile 或重新打包产生新候选时，递增并对齐 App/Extension build；单纯文档和注释修改无需递增。
- 固定源码与构建输入，按所选路线检查签名：证书路线核对证书及 profile；Community 核对逐架构 ad-hoc、无 Team/profile 和精确权限。记录安装版本，备份数据与旧产物后从干净输出构建对应候选。
- 安装后核对主应用和实际加载扩展的身份，再执行 [Beta 测试](BETA_TEST_GUIDE.md)。版本、二进制哈希与实测结果应一一对应。
- CI 无签名产物不能替代签名安装、Finder 交互、真实存储、性能和分发验证。同一源码的不同签名产物不能自动继承验收。
- 无法执行的项目明确记为未执行或受阻；保留失败证据及数据恢复结果，不把历史结果写成当前候选实测。

## 公开内容与本地记录

Git 只保留产品源码、测试、构建配置和维护所需文档。阶段调查、实机原始证据、机器状态、任务交接、个人代理配置和计划放在被忽略的 `.local/`、`.build/`、`Investigation/` 或 `.codex/` 中。共享技能仅跟踪 `.codex/skills/apple-design/SKILL.md`。长期有效的技术约束提炼到架构、测试或发布说明；公开文档不链接本机证据。

代码、注释、示例和公开回执使用仓库相对路径或不含身份的示例。不要提交开发者个人目录、外部产品分析、原始 trace、书签、证书、profile、环境变量或用户数据。安全测试需要的合成隐私字段可以保留。提交前检查完整 diff 和暂存文件清单，避免将忽略文件强行加入。

保留 Sandbox、Hardened Runtime、精确的共享目录权限与安全写入边界；保留旧 App Group 中的用户数据。录屏、输入、外部上传、联系测试者及安全设置变更须有覆盖该动作的授权。

## 临时产物回收

测试和调查产物放入当轮独立的 `.build/Temporary/<任务>/`。临时安装测试版时记录原安装及恢复信息；结束后恢复日常版本并核对实际加载身份，再停止测试进程、注销独立测试 App 的 Launch Services 注册，删除测试包、解包副本、构建缓存和短期备份。普通签名安装成功后同样回收验证宿主和旧安装备份，默认只保留当前安装版、最新交付压缩包与必要收据。

回收前区分独立测试身份与共享日常 Bundle ID 的副本。同 ID 的 App/扩展副本不得逐个执行 `pluginkit -r`，这可能注销正在使用的实例。副本回收及其他注销结束后，对日常 App 执行 `lsregister -f`、对其 Finder 扩展执行 `pluginkit -a`，再核对实际加载路径/UUID，并在真实 Finder 目录右键确认菜单和模板。最终菜单验收必须在清理之后，注册库存不能替代实际菜单。

临时产物回收不删除源码、测试、调查记录，以及当前本地共享目录或旧 App Group 中的用户模板、授权和恢复文件。记录构建输入、签名、安装及清理结果；失败或仍需回滚时只保留必要产物并说明原因。已删除产物的历史报告不代表对应二进制仍然存在。

交付时给出实际修改、验证结果及必要的提交/PR 链接，区分通过、失败、未执行和受阻。安装任务还须说明数据恢复、实际加载身份及临时产物回收结果。

## 用户文档与截图

README 面向首次使用 QuickFile 的用户：先介绍用途、下载和基本操作，构建命令与内部契约留在开发文档。`README.md` 与 `README.zh-CN.md`、`INSTALLATION.en.md` 与 `INSTALLATION.md` 应在同一次改动中同步；按钮名称以对应语言的实际界面为准，支持范围和使用限制须一致。Release 使用同一个版本和安装包，在一篇说明中分别提供 English 与简体中文。

截图必须取自说明所对应的实际发布包，分别使用中文和英文界面。采集前核对安装版本与 build；只展示示例内容，不展示个人路径、授权列表、私人模板或其他应用。保留原始界面，不用合成图片替代产品截图。截图版本及用途写在 `Screenshots/README.md`；机器状态、原始记录和采集过程留在忽略目录。
