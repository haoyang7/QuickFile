# 持续集成

本文说明仓库工作流的实际检查范围。每次结论须绑定确切提交与运行，CI 不代替签名安装、Finder 交互、性能或发布验收。

## 工作流范围

[主 CI](.github/workflows/ci.yml) 在 main 的相关代码/配置变更、PR 和手动触发时运行；根目录纯文档修改不自动启动；`Scripts/` 等受监控目录内的文档仍会触发检查。

| 作业 | 环境 | 验证 |
| --- | --- | --- |
| Python scripts | Ubuntu 24.04 / Python 3.13 | 发布准备、签名检查脚本的模拟与文件事务测试 |
| macOS 15 / arm64 | `macos-15` / Xcode 26.3 / XcodeGen 2.46.0 | 脚本测试、原生 Swift 测试、无签名 Universal 构建与 bundle/权限配置自检 |
| macOS 15 / x86_64 | `macos-15-intel` / 同一工具版本 | 同一测试及自检在 Intel runner 上执行 |
| macOS 26 / arm64 | `macos-26` / Xcode 26.3 / XcodeGen 2.46.0 | 同一测试及自检；显式选择 26.3，不使用镜像默认 Xcode |

macOS 脚本测试中的授权、创建边界和创建预检三组测试，在同一 Python 进程内共用一次新编译的 debug 模块。每组仍单独编译可执行文件，各场景仍用独立进程和数据目录；完整 UI 夹具编译检查保持独立。共享模块不跨进程缓存，构建失败立即清理，正常退出时回收。

Python 脚本测试同时运行 [架构守卫](Scripts/verify-architecture.py)，检查 Shared 源码归属及共享库依赖方向。`verify-release-readiness.sh` 在生成工程前重复执行该守卫；GitHub Actions 中还在 XcodeGen 生成前后核对受管的已跟踪工程、共享 scheme、Info.plist 和 entitlements，存在差异即失败，避免 CI 自动修正未同步的工程后继续通过。本地开发允许已有未提交改动，不使用这项 HEAD 差异门禁；SwiftPM 锁文件继续按独立哈希检查验证。

构建设置查询前显式解析锁定的 SwiftPM 依赖，复用本轮包目录。仅当解析失败明确报告二进制依赖下载超时且没有其他错误时，最多尝试 3 次；每次结束都检查锁文件哈希，漂移或其他错误立即失败。下载和 checksum 验证仍由 SwiftPM 完成，构建设置查询、原生测试及 Release 构建各执行一次，失败不会触发整轮重试。

[macOS 27 兼容性](.github/workflows/macos-27-compatibility.yml) 独立使用 `xcode-27` 标准 arm64 runner、真实 macOS 27、`/Applications/Xcode_27.0.app/Contents/Developer` 和 Xcode 27.0。初期只在 main 相关变更或手动触发时运行，不跟随每个 PR。它保留与主矩阵相同的脚本测试、原生 Swift 测试、Universal 构建和安全检查；失败正常标红，没有 `continue-on-error`，不依赖主 CI，也不改变 required checks 或仓库保护规则。preview 可能排队、调整镜像或工具链；失配必须修正基线，不能把 macOS 26 上的 27 SDK 冒充真实 macOS 27 主机。

每行矩阵都声明 runner、macOS 主版本、架构、Xcode 版本和 Developer 路径，并将 OS/架构/Xcode 写入 job 名称。`ci-evidence.py initialize` 在安装工具、测试和构建前读取 `sw_vers`、`uname -m`、`xcodebuild -version`，同时记录 OS build、Xcode build、macOS SDK、Swift/Clang build 和 Python 版本。实际身份必须与期望一致。GitHub-hosted 镜像会更新，工作流不会静默改用默认 Xcode；固定版本不可用时应明确失败并审查基线。XcodeGen 继续使用固定 2.46.0 发布包、SHA-256 校验和实际版本断言。

[AX system baseline](.github/workflows/ax-system-baseline.yml) 是独立的手动工作流：在 GitHub Actions 中选择它，再点 Run workflow，即可运行 macOS 15、26、27 ARM 的 AX 调查。它不由 push 或 PR 触发，普通 PR 检查列表中不再出现 AX 专项的 Skipped 项；使用独立 concurrency 分组，不取消同一分支的普通 CI。主 CI 的手动入口只运行常规检查，不再提供 `ax_system_probe` 开关。

AX 工作流默认包含无订阅读取、无插桩的销毁通知、目标数组分配代次和系统调用点；已核对映像另测当前产品补偿。`ax_causal_probe=true` 跳过前两项无插桩运行，执行所有权插桩，并只对已审查 UUID 运行独立补释放对照。插桩结果中的堆扫描来自同一个插桩进程，必须与另次无插桩运行区分。macOS 27.0/27.0.1 的已测映像已自行释放目标 copy，调查矩阵不对其启用补释放。

AX 读取权限由实际 reader 可执行文件检查；不匹配映像或缺权限明确报告未覆盖，已匹配映像安装拒绝、通知不足、扫描失败仍失败。目标按钮的两个观察者须逐项恰好收到一次，重复和缺失不能互相抵消；总通知和未匹配通知另行记录。产品扫描先建立不含目标按钮的 AX/XPC 启动基线，再要求目标 AX 泄漏为零、无未分类节点和未知根；已知 NSXPCConnection 基线的节点数、字节数与根数均不能增长。解析器分别保存 ROOT LEAK/CYCLE 分类与实际根类型。全堆报告与目标 AX 数量分别记录，不能将稳定的非零基线写成全堆零泄漏。专项使用一次性 synthetic AppKit 宿主，不代替签名安装 App、Finder 或 VoiceOver 验收。

产品验证另在首批按钮注册后、每批销毁后及观察者退出后扫描，始终与最初的空窗口基线比较。堆断言或逐按钮通知断言失败后继续收集剩余检查点；最终收据标为 `failed`，进程返回非零。后续堆恢复不能撤销前面的失败。扫描不可用、进程异常或协议握手失败仍立即中止，已有原始记录仅留在本地临时目录。

手动 AX 工作流的 `heap_diagnostics` 入口只在 macOS 26 arm64 运行五对独立的空目标对照和产品夹具，在相邻配对间交替先后顺序，与 `ax_causal_probe` 互斥。每个实例使用原有空窗口基线和全部检查点，并在首次添加按钮后、读取与订阅前增加检查点；同次活体扫描保存内存图，在 runner 上离线分析对象差分。任何实例失败、超时、摘要缺失、对象差分解析或分配分类不完整都会使调查 job 失败，后续实例的成功不能撤销它。控制台只输出经过字段白名单、枚举、数量和字节上限校验的脱敏摘要。系统符号只允许经过固定 Apple 映像路径及本进程 `dladdr` 元数据双重核对的无序计数；原始内存图、地址、路径、完整分配栈及日志不上传，结束后回收。摘要的 `status` 表示对象差分解析完整度；`symbols_status` 单独记录符号覆盖，未解析或隐藏的系统符号会使其不完整，但不改变产品退出码和对象差分判定。离线分配分类结合基线全堆清单和未压缩的分配历史，区分基线后分配、基线前已存在及身份不确定的对象；地址相等本身不能证明对象身份。`cohorts_status` 单独记录分配分类是否完整；候选地址最多 128 个，额外工具调用共限时 45 秒，无法确认的对象保留为未知。诊断模式使用未压缩的分配日志和完整历史内存图，普通验证模式不变。分类不完整或工具不可用不能覆盖原始堆断言或产品退出码。无目标对照使用 `--heap-control`，保留相同检查点与 AX 读取次数，将添加和移除按钮的位置替换为空窗口 checkpoint；每阶段的目标按钮、累计分配/销毁、两类补偿以及 reader 注册/通知必须为零。对照收据标为 `measured`，不声明产品补偿通过。该入口用于归因，不替代常规 CI 或证明内存问题已修复。

## 有限、可追溯的 CI 证据

每个 macOS job 创建独立 runner 临时目录，原生测试与 Release 构建分别显式指定 `tests.xcresult` / `release.xcresult` 的 `-resultBundlePath`。已有结果目录或符号链接会失败，不清除或覆盖上次失败结果。非 CI 本地运行默认在 `.build/VerificationResults.XXXXXX` 创建新目录。`run-native` 保留原失败退出码；退出成功但缺少任一结果 bundle 也判为失败。

每个 macOS job 只上传两份从有限字段生成的 synthetic CI JSON 回执，不读取或导出 xcresult 内容：

- `identity.json`：实际 checkout SHA、event SHA、workflow SHA、PR head/base SHA（适用时），run/attempt 链接、job、预期与实际 OS/架构/工具身份
- `verification.json`：身份/工具/脚本/原生步骤的 outcome、上传前 job 状态、原生命令退出码、两个结果 bundle 是否存在，以及实际 XcodeGen 版本

这些回执不声明测试数量或断言详情，也不是签名、实机、安装、性能或发布验收。PR 的 checkout 通常是临时合并提交，不应拿 PR head SHA 替代。最终 job 结论仍以 Actions 为准：`job_before_upload` 不能证明上传步骤本身成功。

上传前校验严格字段/类型、文件名白名单、无符号链接且每文件不超过 16 KiB；两份文件合计最多 32 KiB。`upload-artifact` 固定官方 v7.0.1 的完整提交 SHA，路径逐个列出，不使用 glob。artifact 名含 job、OS、架构、Xcode、run ID 与 attempt，不覆盖旧 artifact，只保留 7 天。身份校验、测试或构建失败后仍用 `always()` 生成脱敏回执，并保持原 job 失败；若 checkout/Python 初始化失败、作业被硬终止或上传服务失败，可能没有回执，不得解释为验证通过。

原始 `.xcresult` 留在 runner 本地，随托管 runner 回收；不上传原始 trace、测试附件/消息、完整日志、整个 `.build`/DerivedData、证书、profile、环境变量 dump、书签或用户数据。新增或修改回执逻辑后应检查生成的两份回执与 Actions 日志、确认身份/退出码/失败路径，再判断是否需要另行设计经过审查的数值型 xcresult 摘要；不能直接扩大为原包上传。

工作流仍只需要 `contents: read`，checkout 不保留凭据，不使用 secrets，不配置证书/profile、不发布 App/ZIP，不引入自托管或付费大 runner。fork/untrusted PR 使用原有 `pull_request` 权限边界，不使用 `pull_request_target`。现有路径过滤保留；未来若设置 required checks，必须先解决纯文档 PR 被过滤后永久 Pending 的问题，不能仅凭工作流配置推定仓库已设置 required checks。

## 本机与远程验证

Linux 可运行 `python3 -m unittest discover -s Scripts/tests -v`，原生场景按环境跳过；SwiftUI、AppKit、Finder Sync 和宿主测试需要 macOS。原生自检使用 `./Scripts/verify-release-readiness.sh`。

已授权的分支可手动触发常规 CI：

```bash
gh workflow run ci.yml --ref <branch>
gh run list --workflow ci.yml --branch <branch> --limit 5
gh run view <run-id> --json headSha,status,conclusion,jobs
gh run view <run-id> --log-failed
```

触发后必须等待终态，核对 `headSha`、实际 checkout、各 job 及失败日志。PR 检查通常运行临时合并提交；合并前确认 base 没有失配，合并后另核对 main 结果。主 CI 与 macOS 27 兼容性结论分别记录；被路径过滤的改动记为“CI 未触发”。

签名、安装、Finder 实机、真实存储和性能验收另见 [开发流程](CONTRIBUTING.md) 与 [发布清单](RELEASE_CHECKLIST.md)。工作流不配置用户证书或 profile，不发布应用。
