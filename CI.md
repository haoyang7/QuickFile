# 持续集成

本文说明仓库工作流的实际检查范围。每次结论须绑定确切提交与运行，CI 不代替签名安装、Finder 交互、性能或发布验收。

## 工作流范围

Community 分支构建的 artifact 标签由 `project.yml` 唯一营销版本推导为 `v<版本>`，不沿用旧 Beta 标签；版本标签事件与手动 `release_tag` 输入保留原值。分支产物不代表该版本已公开发布。

[Community DMG](.github/workflows/community-dmg.yml) 独立负责分发包构建：固定事件提交，在 macOS 15 arm64 / Xcode 26.3 / XcodeGen 2.46.0 上生成并检查 ad-hoc Universal DMG，拒绝源码漂移，只上传五项交付文件，保留 14 天。它由版本标签、手动入口或匹配路径的 `codex/**` 分支推送触发，不自动公开 Release。首次手动入口需先让工作流进入默认分支；分支推送可先验证流程。来源记录、下载核对及正式发布步骤见[免费自行分发](COMMUNITY_DISTRIBUTION.md#github-actions-打包)。

[主 CI](.github/workflows/ci.yml) 在 main 的相关代码/配置变更、所有 PR 和手动触发时运行。main push 保留原路径过滤；PR 在作业内分类范围，仅根目录 `*.md` 和 `LICENSE` 的改动跳过 Linux 与 macOS 测试，其它路径（包括子目录文档、截图及未知路径）均执行现有验证。手动触发始终执行完整验证。

PR 范围通过完整 Git 历史中的 base/head 三点 diff 分类，使用 NUL 分隔路径且关闭重命名检测，删除或移出代码目录不会被文档名称掩盖，也不受 GitHub 路径过滤的 300 文件上限影响。SHA 通过环境变量传入，缺失、格式错误或 diff 失败使分类作业失败；测试仍 checkout PR 临时合并提交，分类所用 head SHA 不代替实际测试 SHA。

| 作业 | 环境 | 验证 |
| --- | --- | --- |
| Classify verification scope | Ubuntu 24.04 | 确定完整验证或明确的根文档跳过范围 |
| Python scripts | Ubuntu 24.04 / Python 3.13 | 发布准备、签名检查脚本的模拟与文件事务测试 |
| macOS 15 / arm64 | `macos-15` / Xcode 26.3 / XcodeGen 2.46.0 | 脚本测试、原生 Swift 测试、无签名 Universal 构建与 bundle/权限配置自检 |
| macOS 15 / x86_64 | `macos-15-intel` / 同一工具版本 | 同一测试及自检在 Intel runner 上执行 |
| macOS 26 / arm64 | `macos-26` / Xcode 26.3 / XcodeGen 2.46.0 | 同一测试及自检；显式选择 26.3，不使用镜像默认 Xcode |
| CI required | Ubuntu 24.04 | 汇总分类、Linux 与全部 macOS 矩阵的终态 |

稳定总门禁名称为 `CI required`，使用 `always()` 等待上述依赖。代码范围只有分类、Linux 和全部三项 macOS 验证成功才通过；失败、取消、意外跳过或缺失分类输出均失败。根文档范围仅在分类成功且两类测试作业均明确 skipped 时通过，摘要记录“跳过、未测试”，不能将门禁成功写成测试通过。配置 main 的 required status check 时应选此总门禁，避免把允许跳过的单项测试设为必需；工作流文件自身不设置仓库保护，也不能证明线上规则已经启用。

macOS 脚本测试中的授权、创建边界和创建预检三组测试，在同一 Python 进程内共用一次新编译的 debug 模块。每组仍单独编译可执行文件，各场景仍用独立进程和数据目录；完整 UI 夹具编译检查保持独立。共享模块不跨进程缓存，构建失败立即清理，正常退出时回收。

Python 脚本测试同时运行 [架构守卫](Scripts/verify-architecture.py)，检查 Shared 源码归属及共享库依赖方向。`verify-release-readiness.sh` 在生成工程前重复执行该守卫；GitHub Actions 中还在 XcodeGen 生成前后核对受管的已跟踪工程、共享 scheme、Info.plist 和 entitlements，存在差异即失败，避免 CI 自动修正未同步的工程后继续通过。本地开发允许已有未提交改动，不使用这项 HEAD 差异门禁；SwiftPM 锁文件继续按独立哈希检查验证。

构建设置查询前显式解析锁定的 SwiftPM 依赖，复用本轮包目录。仅当解析失败明确报告二进制依赖下载超时且没有其他错误时，最多尝试 3 次；每次结束都检查锁文件哈希，漂移或其他错误立即失败。下载和 checksum 验证仍由 SwiftPM 完成，构建设置查询、原生测试及 Release 构建各执行一次，失败不会触发整轮重试。

[macOS 27 兼容性](.github/workflows/macos-27-compatibility.yml) 独立使用 `xcode-27` 标准 arm64 runner、真实 macOS 27、`/Applications/Xcode_27.0.app/Contents/Developer` 和 Xcode 27.0。初期只在 main 相关变更或手动触发时运行，不跟随每个 PR。它保留与主矩阵相同的脚本测试、原生 Swift 测试、Universal 构建和安全检查；失败正常标红，没有 `continue-on-error`，不依赖主 CI，也不改变 required checks 或仓库保护规则。preview 可能排队、调整镜像或工具链；失配必须修正基线，不能把 macOS 26 上的 27 SDK 冒充真实 macOS 27 主机。

每行矩阵都声明 runner、macOS 主版本、架构、Xcode 版本和 Developer 路径，并将 OS/架构/Xcode 写入 job 名称。`ci-evidence.py initialize` 在安装工具、测试和构建前读取 `sw_vers`、`uname -m`、`xcodebuild -version`，同时记录 OS build、Xcode build、macOS SDK、Swift/Clang build 和 Python 版本。实际身份必须与期望一致。GitHub-hosted 镜像会更新，工作流不会静默改用默认 Xcode；固定版本不可用时应明确失败并审查基线。XcodeGen 继续使用固定 2.46.0 发布包、SHA-256 校验和实际版本断言。

[AX system baseline](.github/workflows/ax-system-baseline.yml) 是独立的手动工作流：在 GitHub Actions 中选择它，再点 Run workflow，即可运行 macOS 15、26、27 ARM 的 AX 调查。它不由 push 或 PR 触发，普通 PR 检查列表中不再出现 AX 专项的 Skipped 项；使用独立 concurrency 分组，不取消同一分支的普通 CI。主 CI 的手动入口只运行常规检查，不再提供 `ax_system_probe` 开关。

AX 工作流默认包含无订阅读取、无插桩的销毁通知、目标数组分配代次和系统调用点；已核对映像另测当前产品补偿。`ax_causal_probe=true` 跳过前两项无插桩运行，执行所有权插桩，并只对已审查 UUID 运行独立补释放对照。插桩结果中的堆扫描来自同一个插桩进程，必须与另次无插桩运行区分。macOS 27.0/27.0.1 的已测映像已自行释放目标 copy，调查矩阵不对其启用补释放。

`malloc_scribble=true` 单独启动 macOS 26 配对调查：同一 runner 交替执行 5 组 `MallocScribble` 关闭/开启 × 空白对照/产品路径，共 20 次。关闭时删除继承变量，开启时设置为 `1`，并核对实际宿主与 AX reader 的环境回执。默认 `scan_mode=diagnostic` 保留完整分配历史，离线扫描冻结堆图及额外的 `added-10` 检查点；`scan_mode=live` 使用普通 CI 相同的实时扫描命令、栈记录配置与六个检查点，不采集或声明分配代次诊断。live 模式要求同时开启 `malloc_scribble`。

`live_attribution=true` 单独运行一对同构建的空白对照与产品路径；其他输入须保持默认值。此入口内部采用普通 live 扫描和原来的两个 malloc 栈记录变量，在原始 baseline 与首次节点或字节增长扫描结束后，各追加一张旁路图，最多两张。六次原始扫描、严格判定及失败结果保留，离线分析在子进程退出后进行。摘要分别绑定原始 stdout 和后采集图的哈希、计数及采集间隔；计数不符明确标为 partial，计数相同也不证明对象集合相同。旁路采集会改变后续时序，不能与无旁路运行等同；compact 日志中的已有地址不能证明分配代次，未知代次继续报告 unknown。此模式用于调查，不能凭诊断结果解除普通 CI 的失败。

独立的 `AX reference validation` 手动工作流在 macOS 26 arm64 执行一次四组冻结调查：产品动作、复用同一普通二进制的空窗口、另行构建且不链接产品 AX 实现的纯 AppKit 空窗口，以及只进行初始 AX 查询的纯 AppKit 空窗口。最后一组仍保留宿主命令、reader 生命周期和七个堆快照检查点；它仅停止基线后的 AX 查询，不能称为完全无活动对照。四组均固定 MallocScribble off，并从实际自有子进程启动元数据核对 host/reader 的 `MallocStackLogging` 未设置、`MallocStackLoggingNoCompact=1`。此配置为独立完整历史协议，会改变普通 live 的测量条件，不能撤销普通严格失败。

原严格计数、冻结对象和 bridge schema 先保存，再运行独立有界 reference 侧录，补充 source/target 角色、两端分配代次、工具报告的引用路径差集、NSXPCConnection 环成员在基线的存在及泄漏判定、data/block 上游，以及事件首次可见的检查点区间。采图开始/结束使用同一单调时钟；首次可见区间不能替代分配事件的精确时间，路径或槽位也不证明完整强所有权。未采到服务接口身份、精确 malloc_history 时钟、完整代次或所有候选时保留 unknown/partial。无节点或字节增长时明确使用终点作补充比较，不冒充首次增长样本。

侧录最多 56 次工具调用、180 秒、128 KiB 公共摘要，另行绑定原 frozen/bridge 摘要和七张图的哈希；不占用或扩大原诊断预算。campaign 使用独立进程组，逐例保留严格退出码及证据完整度；已知严格失败仍采集后续对照，进程回收无法确认则停止。上传前独立校验固定字段、枚举、数量、嵌套摘要和总字节上限，仅上传匿名 `summary.json`；原始地址、路径、完整栈、启动元数据、堆图和日志保留在私有临时目录，不上传。确认所有进程退出后回收本轮 App、缓存和原始临时产物；回收失败保持非零结果。该工作流只用于归因，完整侧录不等于产品泄漏已排除或正式版放行。

独立 `AX settled baseline shadow` 手动工作流（也可由 `AX system baseline` 的 `settled_baseline_shadow=true` 转发）在 macOS 26 arm64 执行一次四组影子实验：产品动作、带补丁空窗口、纯 AppKit 空窗口、只进行初始 AX 查询的纯 AppKit 空窗口。普通严格基线及六点判定保留；候选基线的假设判定单独记录，不能覆盖原失败。host 保持普通 compact 配置（`MallocStackLogging=1`、`MallocStackLoggingNoCompact=1`），reader 的两个键未设置，双方 `MallocScribble` 未设置；必须从实际子进程启动元数据核验。影子模式额外观测改变后续时序，不能声称与未扰动的普通 CI 等价。

影子候选只在零目标、零补偿阶段观测，最多六次、总期限 15 秒、单工具最多 5 秒，相邻观测间隔至少两秒。连续两次节点、字节和根组签名相等只是 `observed-stable`，未比较完整尺寸直方图，也不证明永久稳定；两根状态可以成为候选，不要求第三根出现。超时或观测失败明确保留 `not_settled` / 不可判定。公共 campaign schema 3 保留 `capture_status=timeout|failed|complete`、未核验的早期活动状态和固定的投影失败阶段；合法的截止时间耗尽不能丢弃原观测或成为有效候选。公开毫秒区间的舍入不确定性须与精确截止判定区分。单调时钟记录原基线结束、稳定观测开始、首个测量循环开始和最后原扫描结束，公开摘要只保留相对区间，以核对前期采图早于目标动作、晚期采图晚于原六点。

最多保留初始、候选、晚期三张辅助 current-stack 图，各有独立的 15 秒采图工具超时。初始图完成后才开始稳定性轮询的 15 秒期限；候选图在轮询结束后采集，晚期图在原六点之后采集，采图不消耗轮询期限。采图时间窗口还包含文件与哈希处理，不能等同于工具运行时长。夹具退出后，在同一图上交叉核对完整 list/tree、哈希、精确类型与 malloc size 的有界直方图，公开前后带正负桶的成分差集、节点及字节守恒、`unknown` 和遗漏状态。图与前一原扫描的总数相等只称 `totals-match`，不证明对象同一；初始辅助图晚于原 baseline，不能据此恢复原 baseline 的地址或分配代次。数值分桶无遗漏时，未知类型仍以 `unknown` 参与差集，并用 `type_coverage=includes-unknown` 标记命名缺口；数值完整不代表类型已识别。每例离线最多六次工具调用、45 秒，总进程限时 60 秒；单份公共摘要上限 512 KiB。所有地址、原图和完整日志留在 runner，确认进程退出后回收。原严格失败、证据失败与假设结果分别记录；上传独立校验后的单份摘要，不放宽主 CI 或发布门槛。

live 旁路图只请求当前存活分配的栈，不要求 `--fullStackHistory`；普通 malloc 记录设置、六次原始扫描及严格阈值不变。图中的当前分配栈不能证明已释放对象的历史或跨扫描分配代次，冻结调查仍使用独立的完整历史协议。

独立 [AX Reader exit controls](.github/workflows/ax-reader-exit.yml) 手动工作流（也可由 `AX system baseline` 的 `reader_exit_control=true` 转发）执行预先固定的九次普通 live 调查。同一 ordinary host/reader 构建用于三个 block；顺序依次为 `keep/early/late`、`early/late/keep`、`late/keep/early`，每例均启动新进程，不因增长选择性重跑。以唯一一次初始 AX 查询完成为零点，六次 checkpoint 和扫描安排在第 0、20、40、60、80、110 秒；Reader 分别持续运行至最后扫描结束、在第 30 秒请求正常退出、在第 70 秒请求正常退出。各组保持相同扫描次数及 checkpoint 序列；记录 Host 启动、ready、Reader 启动、初始查询、checkpoint、扫描和退出的实际相对时钟。计划时点最大迟到 3 秒，退出同时约束 stop 请求和 wait 返回；wait 返回是已退出的观察上界，不是精确死亡时刻。扫描、checkpoint、退出等待分别限时 12、5、5 秒；时间失配、提前退出和不完整样本保留，不冒充配平。初始查询完成后的日程相同不能自动证明 Host 进程龄相同，归因前须对照各组实际启动及扫描时钟。

这轮的零活动仅指零目标按钮、零目标注册、零目标通知和零补偿；Reader 仍创建原有两个应用级 AXObserver，Host 的 checkpoint 仍执行原布局、显示和回执。初始查询后不再主动查询 AX，补丁和普通 compact 环境保持启用，并核对实际子进程环境及复用二进制哈希。不增加 memgraph、settling 或故障注入，复用已有类型成分解析器。严格分类及相对起始基线的增长判定逐点保留；严格失败不阻止后续样本，清理无法确认则停止。上传前独立验证匿名 `summary.json`，原始 stdout、启动元数据、地址和日志不上传。该调查能检验报告变化与 Reader 退出时点的关系，不能仅由根数量推断新增连接，也不能排除扫描自身或异步初始化的作用；专项实验结果不能覆盖普通 CI 或更改发布门禁。

旁路采图失败时，仅公开固定的错误词法提示，不将其称为根因。身份验证成功、测量及离线工具的进程清理均确认后，才运行额外的自有进程 CLI 检查，验证当前图及其分配栈可读；同进程另记完整历史能力对照，明确区分模式不支持与未知失败。此检查位于原测量之后，不会覆盖原失败，也不在 live 采图失败后自动改用另一套协议。

`receipt_mode=internal` 是默认回执路径，在夹具中编译额外的环境读取代码。`receipt_mode=external-startup` 要求 `malloc_scribble=true`、`scan_mode=live`、`heap_diagnostics=false` 和 `ax_causal_probe=false`：只构建一次普通 host/reader，不定义 `QUICKFILE_AX_MALLOC_RECEIPT`，将同一签名 App 和 reader 按字节复制到 20 个独立 case。准备清单绑定当前夹具源码哈希；每次复制、实际子进程启动检查、测量完成和子进程退出后均校验两个可执行文件的 SHA-256，工作流再次对照统一构建哈希。这里保证本轮 off/on 和 control/product 复用相同字节，不宣称与另一个 CI job 的独立构建逐字节相同。

外部回执只读取本轮持有的实际 `Popen` 子进程，通过 `KERN_PROCARGS2` 核验启动 executable 路径对应的文件、前后存活、非空且匹配的已知 `PATH`，再确认 `MallocScribble` 为 unset 或 `1`。不可读取、空环境、解析异常、身份或哈希不匹配均失败；仅公开字面状态、布尔和哈希，不导出环境内容。这是启动元数据与磁盘文件核验，不是当前 `getenv`、进程映射字节或对象所有权证明；其他进程和其他系统映像的环境可见性不能从 owned fixture 推广。Darwin 的环境访问限制见 [XNU sysctl_procargsx](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/kern/kern_sysctl.c)。

`KERN_PROCARGS2` 返回长度须严格小于原缓冲区容量；等于容量时按 `result_size` 失败，因为 [XNU 的兼容分支可成功返回截断数据](https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/bsd/kern/kern_sysctl.c#L1561)。完整数据中，非空键值区的末条自身 NUL 后可直接 EOF，[尾部对齐不保证额外空项](https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/bsd/kern/kern_exec.c#L6226)。额外空项仍终止解析；缺条目终止 NUL、空环境、重复键或非法键值继续失败，不新增 apple 尾部格式容错，也不补 NUL 或重试。

`pure_appkit_control=true` 单独选择纯 AppKit 空白对照调查，其他输入须保持默认值（包括 `scan_mode=diagnostic`、`receipt_mode=internal`）；此入口明确采用 **live + external-startup + MallocScribble off**，不采集终点图。它在同一 macOS 26 runner 执行 5 对 `patched` / `pure-appkit` 空白宿主，逐对反转顺序，共 10 case、60 个普通实时扫描点。两种宿主共用仓库测试夹具的 Owner、窗口、IPC 和 checkpoint 序列，均在 reader 准备后取基线，要求零目标、零补偿、零通知；每个严格失败保留到终态。`pure-appkit` 的编译分支不导入生产 AX 头文件，不编译或链接 `QuickFileApp/AXCompatibility.m`，也不调用其安装与计数函数；它仍包含仓库测试宿主和 reader，不提供产品销毁覆盖。原有 heap-control 会链接并安装生产补丁，零补偿不能据此排除补丁的影响。

此入口各构建一次两种模式，准备清单 schema 2 分别记录模式、固定源码哈希、链接输入、两个可执行文件 SHA-256 和 `nm` 的生产 AX 符号计数。纯宿主和 reader 必须没有 `QuickFileInstallAXCompatibility` / `QuickFileAX*` 符号；带补丁宿主须保留四个预期生产导出。每个 case 校验清单模式、capabilities 模式与该模式的可执行字节，并沿用外部启动回执；不编译宿主内部 MallocScribble 回执。只在同一模式内要求复用相同字节，两侧构建不同，不能称为同一 binary。新增 capabilities 字段仅存在于两种显式空白构建，普通构建清单和默认流程保持 schema 1。工作流仍只上传受限摘要，不公开本地路径、任意符号或原始 `nm` 输出；结果只能检验此测试宿主中生产补丁链接/安装的影响，不能单凭增长或通过证明对象所有权、分配年龄或排除基线漏报。

`install_gate_control=true` 启用安装末端对照，除可显式选择 `heap_diagnostics=true` 外，其他工作流输入须为默认值。它构建一次带 `QUICKFILE_AX_INSTALL_PROBE` 的 host 和普通 reader，逐例核对同一组可执行文件 SHA-256，然后交替执行五对 `installed` / `preflight-only` 空窗口对照。默认共 10 cases、60 个原 live 扫描点，两模式均固定 MallocScribble off、external-startup、零目标与零通知，不捕获终点图。gate 仅在所有原安装前置检查以及两份原 IMP 保存之后执行；两模式均保存原/替换 IMP 供比较，`preflight-only` 跳过整个 `class_addMethod` / `method_setImplementation` 路径，`installed` 照常继续。该宏未定义时不包含调查 hook，不改变普通产品路径。

同时选择 `heap_diagnostics=true` 时，入口归一化为 diagnostic/external-startup，每例采集七个冻结快照，严格计数与首次增长对象分析使用对应的同一张图。两模式仍复用同一构建，并保留原退出码、候选省略及清理失败；匿名对象证据按 `installed` / `preflight-only` 命名并绑定摘要。冻结和额外检查点会改变测量时序，结果只用于该模式内配对归因，不能替代 ordinary live 结果或撤销其失败。将对象结论推广到 live 路径时仍需该路径的证据。

该入口的构建清单 schema 3 绑定 `install-gate` 模式、源文件哈希、生产对象/宿主的唯一调查宏、reader 无宏及链接输入，不能借用 ordinary 或 pure AppKit 构建。外部启动回执在两个实际 owned PID 上核验 `QUICKFILE_AX_INSTALL_PROBE_MODE` 的固定值；它仍只证明启动元数据。capability 子进程与实际测量宿主分别验收：实际初始 ready 和后续每次 ready 均须显示前置检查已完成、gate 恰好调用一次，以及两个当前 IMP 分别匹配保存值或替换值；公开摘要保留初始和所有扫描点的固定状态，不公开地址。前置检查不支持时两模式都失败，off 不能只凭模式名称通过。严格堆断言及清理失败保留，失败后按既有安全边界收集后续对照。该链接宿主仍包含测试代码和调查回执；结果可比较最后的 IMP 替换路径，不能独自证明泄漏所有权、基线漏报或补丁因果缺陷，也不能与先前不同二进制的 pure 对照直接等同。

所有 external-startup case 另验收 `startup-failures.json`，公开最多四条按 host、reader、complete、final 排序且阶段唯一的失败记录，仅含固定 `stage`、`reason` 和 `errno`（null 或 0…4095 整数）。原因区分启动身份、sysctl 容量/读取、解析、PATH 可见性、开关值、字节哈希及回执完整性；失败 syscall 的 errno 在返回时立即保存，未知异常仅公开 `unclassified`。摘要缺失、字段/枚举/阶段组合或 errno 类型越界都使工作流失败。原私有错误和固定 category 计数继续保留；一次角色失败可进一步导致 complete/final 两次完整性失败，不能将这些计数视为独立环境读取。成功回执、读取时点和次数、宿主/reader 字节及六点严格扫描不变，不增加重试；回执失败削弱验证范围，不豁免同时观察到的堆增长。

`terminal_origin=true` 是另一个有界入口，要求同时传入 `malloc_scribble=true`、`scan_mode=live`、`receipt_mode=external-startup`、`heap_diagnostics=false`、`ax_causal_probe=false`。它将上述 20 case 改为按顺序执行一次 off/control 和一次 off/product；同一构建的两个可执行文件继续逐次核对 SHA-256。每例先完成普通 CI 的全部六个实时扫描点，然后在 `observer-exited` 扫描之后、宿主停止之前仅捕获一份后续堆图；合计 12 个原扫描点和 2 次终点捕获。host/reader 均退出后，才用该图生成 grouped/list 两份离线文本，不增加基线前采样、不启用 NoCompact 优先模式、不记录分配年龄或代次。

`terminal_snapshot` 将每个 grouped 根组与其自身分配栈关联，list 仅汇总全图的固定类型、大小与分配栈计数，不将 list 子节点归属到某个 NSXPC 根。公开帧按原帧号规范为 `allocation-first`（从分配端向调用者），保留重复帧及 index；这不是调用时序。每一保留帧必须通过本机 `SystemSymbols` 的系统映像、地址/偏移与符号核验，上传前再次独立查找符号。地址、路径、任意类型和未经核验的符号均不公开；非白名单类型仅记 `unknown`。摘要最多保留 16 个根组、96 个分配组和总计 96 次符号核验尝试（含失败查找），另记缺帧、不可解析行、过滤帧、未验证帧及预算省略数；原始栈和堆图不上传。终点对象的 JSON 编码与实际缩进文件分别受原有 64 KiB 上限约束；提高保留组数不改变这两处限制或无省略组的判定。

终点摘要 schema 3 的每个保留根组另含 `reported_image_counts`，按报告中的图像标签计入固定的 AppKit、Foundation、CoreFoundation、libxpc、libobjc、libmalloc、libdispatch 或 `other` 桶。它只描述可解析帧中的报告标签，不是独立映像核验；未知标签不公开。`reported_filtered_reason_counts` 将图像前置过滤分为 `known_image_excluded`（后三个固定图像桶）和 `unrecognized_image`（`other`），不把过滤误记为符号核验失败。上述计数不增加符号查找，缺帧与不可解析行仍单独记录。`allocation_type_totals` 在 list 截断前累计全部节点，以固定 `HEAP_TYPES` 和 `unknown` 记录节点/字节总数及 `retained_*`、`omitted_*` 范围；公开 gate 核对逐类守恒、保留组计数和全图总数，未成功解析时该账本为 `null`。完整类型账本不补齐省略的分配栈，也不改变省略组的失败判定，不建立跨扫描对象身份、分配年龄或所有权关系。

终点 schema 3 另在保留根组的 `other_image_identity` 中记录 `other` 帧的映像身份，最多处理 96 个根帧，独立于原 96 次符号核验预算。目标 PC 仅匹配本报告 `Binary Images` 的唯一范围，再以唯一 UUID 关联离线验证进程已加载的映像。验证要求规范的 `/System/Library/` 或 `/usr/lib/` 路径、当前 dyld shared-cache membership 及 `MH_DYLIB_IN_CACHE`；不按报告路径加载，不依赖目标与验证进程共享地址。仅公开原帧 index、安全 basename/UUID 和固定失败计数；重叠或无效报告范围、冲突 UUID、未加载或未核验映像、验证进程失败/超时和预算省略均不能生成身份。未知标签、符号、PC、路径仍不公开。

验证 helper 仅在 host/reader 退出后的终点离线处理及上传 gate 中运行。它固定加载 AppKit，在有界的 owned 子进程内持有 dyld 回调，完整写出本轮私有结果文件后以 `os._exit` 退出，避免无法注销的 Python callback 在析构后被调用；父进程通过 `run_owned` 的独立私有进程组和有界退出回执确认回收。正常错误或已确认回收的超时可降级为身份不可用；退出未确认时禁止启动后续 helper。collection 保存原终点后保留清理失败，上传 gate 以独立清理回执复核；本例的六点、原严格失败和通过结构校验的旧终点先保存到摘要，再停止后续 case。公开 `terminal_image_worker_cleanup` 只取 `confirmed`、`unconfirmed` 或 `not-run`；后者仅用于 runner 明确未进入离线分析的情况，缺少必要回执不能证明退出，也不等于证明 worker 已启动。另以 `terminal_image_worker_artifact_cleanup` 区分 `complete`、`failed`、`unconfirmed` 与 `not-run`。进程退出已确认但产物删除失败时，保留已确认的退出状态，保存本例原严格类别与安全终点后使调查失败，停止后续 case；未删除目录留存。回执写入失败也保留固定产物错误且不重试该文件；若跨进程无法读取有效退出回执，仍按证据未知处理。私有 sidecar schema 2 分别记录退出与产物回收，仅接受普通文件，最多读取 129 字节并拒绝超过 128 字节、额外键或非严格布尔值。上传前还读取 runner 的 `process-cleanup.json`：仅接受有界普通文件中的固定 `errors` stage 列表；`terminal_snapshot` 优先于旧 sidecar 的产物成功状态，缺失或非法 stage 回执也阻止新 helper 与后续 case。这个 stage 只表明终点收集或产物处理失败，不指定删除失败原因；进程退出证据仍由 sidecar 决定。原严格失败、六点和通过完整结构/隐私校验的终点先保存，再停止。此回执不能替代终点内容校验。结果文件按原 schema/字节预算读取，supervisor 的 stdout/stderr 合并日志必须为空，纯空白 stderr 也拒绝。上传 gate 先完整拒绝非法结构，再以一次新的验证进程重新核验所有 basename/UUID，不能只接受字符串格式。若 fresh catalog 不可用或某个身份无法再次核验，仅原地移除相应新增帧，累计 `local_catalog_unavailable` / `uuid_not_verified` 并将该身份字段标记为 `partial`；旧终点计数、栈状态、完整性判定和严格失败继续保留。新字段的 `complete` 仅表示已解析的 `other` 帧全部找到唯一系统映像，不能补齐缺失/不可解析帧，也不改变原栈覆盖、64 KiB 摘要上限或终点完整性失败。它只识别系统组件，不核验原始符号，不证明构造函数、对象所有权、分配年龄或跨扫描身份。

`terminal_origin` 还可产生独立 case 字段 `terminal_cache_image_identity`（schema 1），不修改原 `terminal_snapshot` schema 3、loaded 身份、64 KiB 上限或严格结论。它从本次实际解析的 grouped stdout 重新导出根序号、原 frame index 与唯一报告 UUID；私有绑定记录校验原终点文件和纯 stdout 的 SHA-256，上传时再次从报告导出映射，不能仅信请求表。现有混合 stdout/stderr 日志不作绑定源。公开字段绑定最终发布终点的规范 JSON SHA-256，只含固定状态/原因计数、active cache UUID 及已核验的根/帧序号、safe basename/UUID，不上传原始报告、地址、路径、标签或符号。

缓存查询复用 `SharedCacheCapability.c --lookup OUTPUT UUID...` 的一次 setup、一次正式完整遍历和 closed 检查；最多 96 个去重 canonical UUID、16384 个回调，完整遍历后才排除所有重复 UUID。返回文件最多 24 KiB，公开字段连同 case 缩进也限制为 24 KiB。collection 与上传各自拥有短期编译/查询目录，通过 `run_owned` 确认编译器和查询进程退出后回收，不跨进程转交 binary。collection 先保存旧终点，上传先保存六点、strict 和安全旧终点，再 fresh 查询并要求同一 active cache UUID；普通编译、查询、格式、绑定、预算或身份复核失败仅使新增诊断 `partial`/`unavailable`，不改变旧终点通过条件。退出未知或产物处理失败仍保存原证据并阻断后续 helper/case。`complete` 仅表示本次已解析且在预算内的 other 根帧均有缓存映像证据；缓存身份不等于本进程 loaded 身份，不验证构造函数、所有权、年龄或基线漏报。


独立的 `SharedCacheCapability.c` / `test_shared_cache_capability.py` 随现有 macOS unittest（含独立 macOS 27 兼容性检查）验证当前活动 shared cache 的 SPI 枚举能力，Linux 明确跳过原生部分。固定 Apple dyld 版本的声明与遍历契约见夹具源码；API 不可用、格式不支持或能力失败都使测试失败。夹具在同一进程严格执行一次 setup 遍历，再建立 setup 后的 loaded census，最后执行一次正式遍历，不循环重试。setup 独立要求 API 成功、回调 schema/预算完整及活动 cache UUID 前后相同；失败禁止正式阶段，setup rows 不复用。正式遍历再次绑定同一 cache UUID。schema 2 保留 setup/measurement 的独立 API 返回码、接收/有效记录数、schema 错误及 UUID 稳定性，并按固定阶段计数初始 observer 回放、setup、census、正式枚举和格式化中的 add/remove；初始回放不等于新加载。census 建立后直至有界结果格式化结束的任何变化仍失败；最终状态核对后才输出，`measurement_closed` 表示该关闭点，不声称覆盖输出或进程退出之后。固定 Apple 入口可能在首次调用时初始化 introspection 依赖，相关源码链接见夹具；这不证明任何特定远端失败实际加载了哪个组件。测试继续核对规范系统路径与 cache membership、重复 UUID 整组排除及计数守恒；`loaded_uuid_records` 是此独立非 AX 进程在 setup 后的加载回调记录数，不保证 UUID 唯一，未加载计数仅相对此进程，不能推断覆盖另一验证 helper 的全部映像。遍历完整性仍依赖 API 成功返回的契约，并非独立解析所有 cache 文件。Python 严格校验子进程输出后才公开有界的源码/二进制 SHA-256、OS/架构、cache UUID、固定计数和少量安全 basename/UUID，不输出 PID、PC、路径、环境或任意错误文本。编译、正常、失败与超时路径使用 owned supervisor，产物位于 `.build/Temporary/` 独立目录并回收二进制/缓存；退出未确认则失败并停止后续子命令。此能力测试尚未接入终点映像核验，不改变原符号权限、AX 六点扫描或严格增长判定。

终点摘要的 `parsing_status` 只说明两份文本的节点/字节/根组结构是否完整，`stacks_status` 单独说明已报告帧的公开覆盖。应用帧、隐藏系统帧或预算过滤会使栈为 `partial`，不能称为完整原始栈，即使剩下的系统帧均已核验。`terminal_snapshot_checks_passed` 要求捕获和离线工具成功、计数结构完整、无省略组、每组有栈且无缺帧或不可解析行；明确计数的过滤/未验证帧允许受限提取成功，同时保留 `partial` 栈状态。捕获/工具超时、格式不支持、缺栈等会使调查失败，原六点的 `strict_checks_passed` 和断言类别仍独立保留；退出已确认时两例继续收集。终点图是较晚的一次暂停观察，计数相同也不证明与之前扫描中的对象相同，分配来源与保守引用关系都不能证明所有权或基线漏报。

两种扫描模式只上传受限的 `ax-heap-diagnostics-summary`，明确记录扫描/回执模式、checkout、系统映像、进程环境、扫描节点/字节/根数、未知根和目标堆栈标记，以及逐扫描工具返回码和固定类别的断言失败计数；原始堆图、环境和日志不上传。原严格检查失败、回执缺失或该模式所需证据不完整都会使调查失败，同时继续收集后续对照；构建失败则保留未完成状态。运行返回码、断言分类与分配诊断完整性分别记录，live 不宣称完整分配诊断。每 case 的命令最多 180 秒，之后另有有界回收。独立 supervisor 保持私有进程组 leader 的 PID 身份，命令结束、失败或超时后均在回收 leader 前终止该组并核对组内已无运行成员，再等待 leader；不向已回收 leader 的历史 PGID 发送终止信号。`process_run` 分别记录原命令返回码、超时/协议状态和组清理结果；`group_inspection` 区分已退出、仍有运行成员、查询失败/超时、格式异常及 `leader_unverified`，不公开 PID 或进程表。检查必须见到唯一且 PGID 一致的未回收 leader；leader 缺失、重复或不一致时不得将空组视为已退出。无法确认组退出时保留失败并停止后续 case。runner 对 reader、host 各自执行有界 wait、terminate/wait、kill/wait，一方失败仍执行另一方、Launch Services 和必要回执清理；两进程退出未确认时不运行离线图分析。结束后清理夹具、缓存、堆图及原始日志。不同扫描模式的结果不能直接互相替代；内部回执仍会改变夹具二进制，外部读取也增加启动检查耗时。Scribble 用于调查残留指针是否影响保守扫描，但也可能改变分配器行为；环境回执、通过的重复运行和计数变化均不能替代对象所有权或基线漏报的因果证据。

AX 读取权限由实际 reader 可执行文件检查；不匹配映像或缺权限明确报告未覆盖，已匹配映像安装拒绝、通知不足、扫描失败仍失败。目标按钮的两个观察者须逐项恰好收到一次，重复和缺失不能互相抵消；总通知和未匹配通知另行记录。产品扫描先建立不含目标按钮的 AX/XPC 启动基线，再要求目标 AX 泄漏为零、无未分类节点和未知根；已知 NSXPCConnection 基线的节点数、字节数与根数均不能增长。解析器分别保存 ROOT LEAK/CYCLE 分类与实际根类型。全堆报告与目标 AX 数量分别记录，不能将稳定的非零基线写成全堆零泄漏。专项使用一次性 synthetic AppKit 宿主，不代替签名安装 App、Finder 或 VoiceOver 验收。

产品验证另在首批按钮注册后、每批销毁后及观察者退出后扫描，始终与最初的空窗口基线比较。堆断言或逐按钮通知断言失败后继续收集剩余检查点；最终收据标为 `failed`，进程返回非零。后续堆恢复不能撤销前面的失败。扫描不可用、进程异常或协议握手失败仍立即中止，已有原始记录仅留在本地临时目录。

`--copy-lifetime` 使用另一独立宿主，在已匹配的两个产品调用点登记实际返回数组。专用编译宏启用固定的 60 个 ARC 弱引用槽，每槽仅写入一次；普通和可变 copy 各须覆盖 30 次，并与补偿、按钮销毁计数一致。每个检查点拒绝缺失记录、异常登记和仍可获取的弱引用，后续释放不能撤销失败。弱引用清零表示对象已不能通过 weak 获取，不代表析构全部完成或存储已归还。该插桩会影响堆扫描的可达性判断，因此此模式只验证生命周期与通知，不运行或声明通过整堆检查；全部命令检查点与观察窗口保持。原无插桩通知与全堆检查仍独立运行，原堆增长约束不变；正常产品构建不包含此回调。

手动 AX 工作流的 `heap_diagnostics` 入口只在 macOS 26 arm64 运行五对独立的空目标对照和产品夹具，在相邻配对间交替先后顺序，与 `ax_causal_probe` 互斥。每个实例使用原有空窗口基线和全部检查点，并在首次添加按钮后、读取与订阅前增加检查点；同次活体扫描保存内存图，在 runner 上离线分析对象差分。任何实例失败、超时、摘要缺失、对象差分解析或分配分类不完整都会使调查 job 失败，后续实例的成功不能撤销它。控制台只输出经过字段白名单、枚举、数量和字节上限校验的脱敏摘要。系统符号只允许经过固定 Apple 映像路径及本进程 `dladdr` 元数据双重核对的无序计数；原始内存图、地址、路径、完整分配栈及日志不上传，结束后回收。摘要的 `status` 表示对象差分解析完整度；`symbols_status` 单独记录符号覆盖，未解析或隐藏的系统符号会使其不完整，但不改变产品退出码和对象差分判定。离线分配分类结合基线全堆清单和未压缩的分配历史，区分基线后分配、基线前已存在及身份不确定的对象；地址相等本身不能证明对象身份。`cohorts_status` 单独记录分配分类是否完整；候选地址最多 128 个，额外工具调用共限时 45 秒，无法确认的对象保留为未知。诊断模式使用未压缩的分配日志和完整历史内存图，普通验证模式不变。分类不完整或工具不可用不能覆盖原始堆断言或产品退出码。无目标对照使用 `--heap-control`，保留相同检查点与 AX 读取次数，将添加和移除按钮的位置替换为空窗口 checkpoint；每阶段的目标按钮、累计分配/销毁、两类补偿以及 reader 注册/通知必须为零。对照收据标为 `measured`，不声明产品补偿通过。该入口用于归因，不替代常规 CI 或证明内存问题已修复。

`frozen_control=true` 选择一次 macOS 26 空目标冻结对照，其余输入必须保持默认值。它复用原有 `--heap-diagnostics --heap-control` 的七个检查点和严格断言，工作流显式取消继承的 `MallocScribble`，宿主继续使用既有 NoCompact 日志配置；此模式没有外部启动环境回执，也不等同于普通六点实时扫描。原 runner 及 host/reader 退出均已确认后，独立进程组才执行节点分析。按检查点顺序选择首个完整的非空泄漏差集，再将同图的绝对列表、默认泄漏树、分配历史和外部根查询交叉核对。`traceTree` 的根数表示工具报告的进程根到对象的引用路径，默认泄漏树用于节点与循环的关联；两者均不证明完整图边或对象所有权。基线前已存在的分配可能在引用消失后成为泄漏，不能据分配时间豁免增长。

单独使用 `heap_diagnostics=true` 时，既有五对空目标/产品冻结调查也执行节点分析，选择原严格扫描中节点数或字节数首次超过基线的检查点。更早的等量地址替换不会提前结束选点；根数及其他严格检查继续独立阻断。没有节点或字节增长时明确记为 `no-strict-growth`，仍解析基线泄漏树以核验实际系统输出格式。工作流再次核对选点与原扫描一致。该入口保留 NoCompact 和七点采样的边界，不能恢复其他普通 live 运行中未保存的对象。

节点摘要的 schema 2 保留同次运行的匿名对象编号、允许列出的连接协议、父子引用、循环回边，以及基线和选中快照的反向引用路径。堆对象的相同编号只对应相同地址；分配历史另行判断是否为同一分配，避免地址复用造成误判。非堆根使用独立身份，不能反推堆地址。关系标记为 `tool-reported`，不能仅凭循环标记推断完整 ARC 所有权，也不能据此确认 Apple 的桥接字段扫描误报。

新增节点分析最多选择 16 个地址，引用表最多 512 个节点记录、1024 条边，总工具期限 90 秒、单命令 15 秒，外层进程组期限 120 秒；原 runner 的期限和回收规则不变。五对分析的工作流期限为 55 分钟，覆盖既有 runner 与新增离线进程的期限。公开节点摘要不超过 128 KiB，以容纳含上百节点的反向引用树；只允许固定字段、枚举与计数，原始地址、路径、堆图、历史和树文本不上传。超出摘要预算时优先保留选中快照的循环路径，省略视图明确标记为不完整。无新增差集明确记为 `no-new-leak`，不据此声明没有泄漏或历史问题已修复；缺失、截断、格式不支持、候选省略及身份不确定分别保留不完整状态。原严格结论与新增诊断结论分别保存，任一失败均使该调查失败。

泄漏树或反向引用解析失败时，另保存有界的匿名词法证据，帮助修复实际系统输出格式。每 case 最多 2 MiB，只保留固定词表、标点、缩进、结构计数和稳定匿名编号；未知文本不可还原，原始地址、路径、任意符号及报告正文不上传。证据绑定同次图哈希、工具序号与失败类别，截断显式标记。上传前再次核对固定文件名、规范编码、哈希和摘要回执；未绑定文件阻止整个词法证据 artifact 上传，原扫描摘要仍独立保留。它不替代引用图、所有权证据或原严格检查。

解析器支持 macOS 26 的多实例分组 `TOTAL` 包装和三句反向引用说明，同时兼容带第四句 Instruments 说明的格式。汇总行不算对象；逐组成员数、根数、子树计数及分隔缩进仍须一致。未知输出格式继续报告不完整；匿名词法证据丢失的原文含义不能靠猜测恢复。

首次严格增长候选的基线反向引用在解析成功时也保留有界匿名语法，标记 `error=none` 并绑定该次成功工具和完整基线引用视图。固定词表可区分已审核的 continuation 分配函数及 Swift metadata 描述；保留引用槽偏移以核验中间节点的结构。名称和布局只用于提出可检验的分配来源假设，不能证明缓存状态、实际所有权或目标系统实现与某份源码相同。

反向路径中的无地址槽位根接受完整的 `<TYPE> +offset: __strong slot` 叶子格式，路径数必须为 1。它使用独立的槽位身份，公开类型为 `unknown`、大小为零，不反推基址或对象大小；同一快照内相同槽位的描述、偏移及直接目标必须一致。此格式不把未知名称解释为 Swift 根，也不改变泄漏树根分类、严格扫描、检查点或基线。

线程寄存器根只接受完整的 `Thread N description $x0` 至 `$x30` 格式，可带有界的 `--> offset N` 内部偏移；偏移必须小于直接父对象的已知大小。线程序号与描述有界，路径数必须为 1，必须有父节点且不可包含子节点。公开摘要使用 `unknown`、零大小和 `other` 根类别，身份按检查点隔离；报告中的线程序号不代表跨快照物理线程身份。同一快照的相同线程及寄存器不能指向冲突目标或偏移。词法证据保留固定语法、寄存器名、内部偏移与路径计数，线程序号替换为合成编号，整个显示描述匿名化；不公开实际线程标识或队列名。旧证据已经丢失的终端语义不能通过新解析器恢复。

冻结调查另采集基线反向路径中 `64B +40 → 48B` 结构的桥接对象，要求 48B 目标同时出现在该候选选中快照的完整泄漏树视图内；按地址去重，最多选取两个。该结构仅用于选样，不识别分配器或所有权。侧录复用基线完整堆清单，补充选中快照完整堆清单、两侧相同地址集合的分配历史及定点出向布局；与原节点分析共享 90 秒期限和 45 次工具调用总上限，原 16 候选覆盖不减。没有剩余预算、格式不支持、历史缺失或采样省略均保留不完整状态。侧录绑定最终节点摘要及两张图的摘要、候选编号和原基线引用视图，经过独立的固定字段校验后纳入调查摘要，最多 32 KiB。原始布局、地址及分配栈留在 runner 私有目录并随本轮回收。

桥接侧录区分完整堆清单中的存活状态、分配历史变化和工具报告的槽位目标。`CONTENTS` 表示工具报告的出向引用，`REFERENCES TO THIS` 是入向引用；入向区段可包含经完整格式校验的堆槽、线程寄存器或区域根，仍逐行核对引用数，不把入向根当成出向槽位。没有报告 `+40` 引用不等于物理槽位清零。侧录的分配代际只检查桥接源 P；`original_target_address` 仅表示槽位目标与原目标地址相同，不证明目标 M 未释放后复用。工具可达性变化不能替代 ARC 所有权或产品因果证据。侧录不改变原严格检查、基线或增长判据；缺失、不完整及清理未确认仍使调查失败。

桥接摘要 schema 2 为布局保留固定解析错误码和匿名语法，绑定对应记录、检查点、工具调用与图摘要。最多四份、每份不超过 4 KiB，整个桥接摘要仍不超过 32 KiB；截断或无法等价重放必须显式标记并保留不完整结论。仅在扫描头后接受一次经格式校验的 `Call stack:` 元数据行；匿名证据以固定标记替代该行，不上传帧内容，也不把它计入入向引用数或用于所有权归因。描述、路径和真实地址不公开；只有原文已核验的基址加偏移关系才编码为槽位关系，零地址和非法字符结构也保留。完整匿名语法须核对原文与重放的解析成败、固定错误码以及槽位状态和尺寸；不以匿名名称核验类型身份。匿名化不能将原文的拒绝条件变成通过证据。工具执行成功与布局解析成功分别记录；缺失 `CONTENTS`、未知入向或出向格式不能合并成已验证的空槽位。

## 有限、可追溯的 CI 证据

每个 macOS job 创建独立 runner 临时目录，原生测试与 Release 构建分别显式指定 `tests.xcresult` / `release.xcresult` 的 `-resultBundlePath`。已有结果目录或符号链接会失败，不清除或覆盖上次失败结果。原生自检每次在 `.build/Temporary/release-readiness.XXXXXX/` 创建独立的 Debug、Release 和包缓存，解析使用本轮 DerivedData，构建设置查询显式指定本轮产品和中间目录。成功、失败或收到 HUP/INT/TERM 时回收本轮缓存和 App，保留 `records/cleanup.json` 及结果 bundle；外部提供的结果目录只用于保存结果，不参与清理。非 CI 本地运行默认结果目录为本轮目录中的 `Results/`。`run-native` 保留原失败退出码；退出成功但缺少任一结果 bundle 也判为失败。

Xcode 的 macOS App 构建会添加 Launch Services 注册步骤，文件回收不能证明注册状态已恢复。CI 临时 runner 没有日常安装版；本机验证结束后须按 [临时产物回收约定](CONTRIBUTING.md#临时产物回收) 恢复日常 App 与 Finder 扩展的实际加载身份，并在清理后验收真实 Finder 菜单。自检脚本的清理收据只记录本轮文件回收结果。

每个 macOS job 上传三份从有限字段生成的 synthetic CI JSON 回执，不读取或导出 xcresult 内容：

- `identity.json`：实际 checkout SHA、event SHA、workflow SHA、PR head/base SHA（适用时），run/attempt 链接、job、预期与实际 OS/架构/工具身份
- `verification.json`：身份/工具/脚本/原生步骤的 outcome、上传前 job 状态、原生命令退出码、两个结果 bundle 是否存在，以及实际 XcodeGen 版本
- `ax-evidence.json`：schema 2 保留原六点严格 AX 扫描、各点有界类型成分、带正负计数的成分差集，以及严格失败后可用的终点图和精确尺寸直方图；未执行、能力跳过、缺失和不完整状态分别保留

类型成分子摘要使用 schema 3；无法解析时以固定 `failure_stage` 定位失败阶段，不输出原始行或类型名。树行格式失败可附不超过 4 KiB 的匿名诊断片段：最多两个父行和当前行，经已有词法白名单编码，地址匿名化、任意名称替换为 opaque，完整摘要仍限 8 KiB。片段仅用于语法调查，不是完整树、类型身份或等价重放证据；超预算时不保留片段。真实报告的子层 `ROOT CYCLE` 标记不新增根或节点，层级与计数仍由缩进及子树守恒核对。

身份与 verification 回执不声明测试数量或断言详情；AX 回执只保留有限扫描判定标签与脱敏诊断。三份回执都不是签名、实机、安装、性能或发布验收。PR 的 checkout 通常是临时合并提交，不应拿 PR head SHA 替代。最终 job 结论仍以 Actions 为准：`job_before_upload` 不能证明上传步骤本身成功。

上传前校验严格字段/类型、精确文件名白名单、无符号链接及硬链接，并用同一文件描述符有界读取。`identity.json` 与 `verification.json` 各不超过 16 KiB；`ax-evidence.json` 独立上限为 256 KiB，三份合计最多 288 KiB。`upload-artifact` 固定官方 v7.0.1 的完整提交 SHA，路径逐个列出，不使用 glob。artifact 名含 job、OS、架构、Xcode、run ID 与 attempt，不覆盖旧 artifact，只保留 7 天。身份校验、测试或构建失败后仍用 `always()` 生成脱敏回执，并保持原 job 失败；若 checkout/Python 初始化失败、作业被硬终止或上传服务失败，可能没有回执，不得解释为验证通过。

`run-scripts` 将原脚本测试命令的 AX 记录目录绑定为本 job 独占的 `ax-records/`，由原 runner 独占创建，命令结束后直接收集证据，不重跑失败测试。原失败退出码始终保留；原命令成功但必要 AX 证据缺失或不完整仍失败。collector 出错使用固定 `unavailable` 摘要；脚本步骤未执行时，`finish` 生成明确的 `not_attempted` 摘要。原始 `groupByType` 输出不包含完整地址；严格失败后的单张终点图晚于原六点扫描，不是 baseline 或 first-growth 快照，不能提供分配 generation 或跨图 diff，也不改变原严格扫描、门禁、malloc 配置或发布验收声明。原始 AX 记录和内存图只留在 runner，不上传。

原 grouped 输出的行数值描述子树总量，不能直接当类型实例数或每实例 size。类型自身计数通过完整树的直接子树扣除核对；只有可证明的单实例、未舍入字节数才能进入精确尺寸桶。同类型多实例聚合与 K/M 舍入造成的尺寸缺失明确记录，不能推断为某个 48 B 对象。成分解析是独立补充状态，失败不会丢掉原严格扫描或改变其判定。终点精确直方图来自后期图的完整节点，仅在完整成分间计算差集；固定类型白名单外归 `unknown`，正负桶变化不建立分配年龄、代次或所有权关系。

原始 `.xcresult` 留在 runner 本地，随托管 runner 回收；不上传原始 trace、测试附件/消息、完整日志、整个 `.build`/DerivedData、证书、profile、环境变量 dump、书签或用户数据。新增或修改回执逻辑后应检查生成的三份回执与 Actions 日志、确认身份/退出码/失败路径，再判断是否需要另行设计经过审查的数值型 xcresult 摘要；不能直接扩大为原包上传。

上述验证工作流只需要 `contents: read`，checkout 不保留凭据，不使用 secrets，不配置证书/profile，只上传验证收据，不发布 App/ZIP；Community DMG 的五项分发产物按前述独立流程上传。各流程不引入自托管或付费大 runner。fork/untrusted PR 使用原有 `pull_request` 权限边界，不使用 `pull_request_target`。主 CI 的 PR 入口没有工作流级路径过滤，文档跳过由总门禁明确判定；其它工作流保留各自触发范围。工作流未启动或整体取消不等于门禁通过，仍须核对当前提交的 required check 终态。

## 本机与远程验证

Linux 可运行 `python3 -m unittest discover -s Scripts/tests -v`，原生场景按环境跳过；SwiftUI、AppKit、Finder Sync 和宿主测试需要 macOS。原生自检使用 `./Scripts/verify-release-readiness.sh`。

已授权的分支可手动触发常规 CI：

```bash
gh workflow run ci.yml --ref <branch>
gh run list --workflow ci.yml --branch <branch> --limit 5
gh run view <run-id> --json headSha,status,conclusion,jobs
gh run view <run-id> --log-failed
```

触发后必须等待终态，核对 `headSha`、实际 checkout、各 job 及失败日志。PR 检查通常运行临时合并提交；合并前确认 base 没有失配，合并后另核对 main 结果。主 CI 与 macOS 27 兼容性结论分别记录；PR 根文档跳过记为“门禁通过，测试未执行”，main push 等被路径过滤的运行记为“CI 未触发”。

签名、安装、Finder 实机、真实存储和性能验收另见 [开发流程](CONTRIBUTING.md) 与 [发布清单](RELEASE_CHECKLIST.md)。工作流不配置用户证书或 profile，不发布应用。
