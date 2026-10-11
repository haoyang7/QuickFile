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

`malloc_scribble=true` 单独启动 macOS 26 配对调查：同一 runner 交替执行 5 组 `MallocScribble` 关闭/开启 × 空白对照/产品路径，共 20 次。关闭时删除继承变量，开启时设置为 `1`，并核对实际宿主与 AX reader 的环境回执。默认 `scan_mode=diagnostic` 保留完整分配历史，离线扫描冻结堆图及额外的 `added-10` 检查点；`scan_mode=live` 使用普通 CI 相同的实时扫描命令、栈记录配置与六个检查点，不采集或声明分配代次诊断。live 模式要求同时开启 `malloc_scribble`。

`receipt_mode=internal` 是默认回执路径，在夹具中编译额外的环境读取代码。`receipt_mode=external-startup` 要求 `malloc_scribble=true`、`scan_mode=live`、`heap_diagnostics=false` 和 `ax_causal_probe=false`：只构建一次普通 host/reader，不定义 `QUICKFILE_AX_MALLOC_RECEIPT`，将同一签名 App 和 reader 按字节复制到 20 个独立 case。准备清单绑定当前夹具源码哈希；每次复制、实际子进程启动检查、测量完成和子进程退出后均校验两个可执行文件的 SHA-256，工作流再次对照统一构建哈希。这里保证本轮 off/on 和 control/product 复用相同字节，不宣称与另一个 CI job 的独立构建逐字节相同。

外部回执只读取本轮持有的实际 `Popen` 子进程，通过 `KERN_PROCARGS2` 核验启动 executable 路径对应的文件、前后存活、非空且匹配的已知 `PATH`，再确认 `MallocScribble` 为 unset 或 `1`。不可读取、空环境、解析异常、身份或哈希不匹配均失败；仅公开字面状态、布尔和哈希，不导出环境内容。这是启动元数据与磁盘文件核验，不是当前 `getenv`、进程映射字节或对象所有权证明；其他进程和其他系统映像的环境可见性不能从 owned fixture 推广。Darwin 的环境访问限制见 [XNU sysctl_procargsx](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/kern/kern_sysctl.c)。

`KERN_PROCARGS2` 返回长度须严格小于原缓冲区容量；等于容量时按 `result_size` 失败，因为 [XNU 的兼容分支可成功返回截断数据](https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/bsd/kern/kern_sysctl.c#L1561)。完整数据中，非空键值区的末条自身 NUL 后可直接 EOF，[尾部对齐不保证额外空项](https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/bsd/kern/kern_exec.c#L6226)。额外空项仍终止解析；缺条目终止 NUL、空环境、重复键或非法键值继续失败，不新增 apple 尾部格式容错，也不补 NUL 或重试。

`pure_appkit_control=true` 单独选择纯 AppKit 空白对照调查，其他输入须保持默认值（包括 `scan_mode=diagnostic`、`receipt_mode=internal`）；此入口明确采用 **live + external-startup + MallocScribble off**，不采集终点图。它在同一 macOS 26 runner 执行 5 对 `patched` / `pure-appkit` 空白宿主，逐对反转顺序，共 10 case、60 个普通实时扫描点。两种宿主共用仓库测试夹具的 Owner、窗口、IPC 和 checkpoint 序列，均在 reader 准备后取基线，要求零目标、零补偿、零通知；每个严格失败保留到终态。`pure-appkit` 的编译分支不导入生产 AX 头文件，不编译或链接 `QuickFileApp/AXCompatibility.m`，也不调用其安装与计数函数；它仍包含仓库测试宿主和 reader，不提供产品销毁覆盖。原有 heap-control 会链接并安装生产补丁，零补偿不能据此排除补丁的影响。

此入口各构建一次两种模式，准备清单 schema 2 分别记录模式、固定源码哈希、链接输入、两个可执行文件 SHA-256 和 `nm` 的生产 AX 符号计数。纯宿主和 reader 必须没有 `QuickFileInstallAXCompatibility` / `QuickFileAX*` 符号；带补丁宿主须保留四个预期生产导出。每个 case 校验清单模式、capabilities 模式与该模式的可执行字节，并沿用外部启动回执；不编译宿主内部 MallocScribble 回执。只在同一模式内要求复用相同字节，两侧构建不同，不能称为同一 binary。新增 capabilities 字段仅存在于两种显式空白构建，普通构建清单和默认流程保持 schema 1。工作流仍只上传受限摘要，不公开本地路径、任意符号或原始 `nm` 输出；结果只能检验此测试宿主中生产补丁链接/安装的影响，不能单凭增长或通过证明对象所有权、分配年龄或排除基线漏报。

`install_gate_control=true` 单独启用安装末端对照，要求其他工作流输入均为默认值。它构建一次带 `QUICKFILE_AX_INSTALL_PROBE` 的 host 和普通 reader，逐例核对同一组可执行文件 SHA-256，然后交替执行五对 `installed` / `preflight-only` 空窗口对照，共 10 cases、60 个原 live 扫描点。两模式均固定 MallocScribble off、external-startup、零目标与零通知，不捕获终点图。gate 仅在所有原安装前置检查以及两份原 IMP 保存之后执行；两模式均保存原/替换 IMP 供比较，`preflight-only` 跳过整个 `class_addMethod` / `method_setImplementation` 路径，`installed` 照常继续。该宏未定义时不包含调查 hook，不改变普通产品路径。

该入口的构建清单 schema 3 绑定 `install-gate` 模式、源文件哈希、生产对象/宿主的唯一调查宏、reader 无宏及链接输入，不能借用 ordinary 或 pure AppKit 构建。外部启动回执在两个实际 owned PID 上核验 `QUICKFILE_AX_INSTALL_PROBE_MODE` 的固定值；它仍只证明启动元数据。capability 子进程与实际测量宿主分别验收：实际初始 ready 和后续每次 ready 均须显示前置检查已完成、gate 恰好调用一次，以及两个当前 IMP 分别匹配保存值或替换值；公开摘要保留初始和六个扫描点的固定状态，不公开地址。前置检查不支持时两模式都失败，off 不能只凭模式名称通过。严格堆断言及清理失败保留，失败后按既有安全边界收集后续对照。该链接宿主仍包含测试代码和调查回执；结果可比较最后的 IMP 替换路径，不能独自证明泄漏所有权、基线漏报或补丁因果缺陷，也不能与先前不同二进制的 pure 对照直接等同。

所有 external-startup case 另验收 `startup-failures.json`，公开最多四条按 host、reader、complete、final 排序且阶段唯一的失败记录，仅含固定 `stage`、`reason` 和 `errno`（null 或 0…4095 整数）。原因区分启动身份、sysctl 容量/读取、解析、PATH 可见性、开关值、字节哈希及回执完整性；失败 syscall 的 errno 在返回时立即保存，未知异常仅公开 `unclassified`。摘要缺失、字段/枚举/阶段组合或 errno 类型越界都使工作流失败。原私有错误和固定 category 计数继续保留；一次角色失败可进一步导致 complete/final 两次完整性失败，不能将这些计数视为独立环境读取。成功回执、读取时点和次数、宿主/reader 字节及六点严格扫描不变，不增加重试；回执失败削弱验证范围，不豁免同时观察到的堆增长。

`terminal_origin=true` 是另一个有界入口，要求同时传入 `malloc_scribble=true`、`scan_mode=live`、`receipt_mode=external-startup`、`heap_diagnostics=false`、`ax_causal_probe=false`。它将上述 20 case 改为按顺序执行一次 off/control 和一次 off/product；同一构建的两个可执行文件继续逐次核对 SHA-256。每例先完成普通 CI 的全部六个实时扫描点，然后在 `observer-exited` 扫描之后、宿主停止之前仅捕获一份后续堆图；合计 12 个原扫描点和 2 次终点捕获。host/reader 均退出后，才用该图生成 grouped/list 两份离线文本，不增加基线前采样、不启用 NoCompact 优先模式、不记录分配年龄或代次。

`terminal_snapshot` 将每个 grouped 根组与其自身分配栈关联，list 仅汇总全图的固定类型、大小与分配栈计数，不将 list 子节点归属到某个 NSXPC 根。公开帧按原帧号规范为 `allocation-first`（从分配端向调用者），保留重复帧及 index；这不是调用时序。每一保留帧必须通过本机 `SystemSymbols` 的系统映像、地址/偏移与符号核验，上传前再次独立查找符号。地址、路径、任意类型和未经核验的符号均不公开；非白名单类型仅记 `unknown`。摘要最多保留 16 个根组、96 个分配组和总计 96 次符号核验尝试（含失败查找），另记缺帧、不可解析行、过滤帧、未验证帧及预算省略数；原始栈和堆图不上传。终点对象的 JSON 编码与实际缩进文件分别受原有 64 KiB 上限约束；提高保留组数不改变这两处限制或无省略组的判定。

终点摘要 schema 3 的每个保留根组另含 `reported_image_counts`，按报告中的图像标签计入固定的 AppKit、Foundation、CoreFoundation、libxpc、libobjc、libmalloc、libdispatch 或 `other` 桶。它只描述可解析帧中的报告标签，不是独立映像核验；未知标签不公开。`reported_filtered_reason_counts` 将图像前置过滤分为 `known_image_excluded`（后三个固定图像桶）和 `unrecognized_image`（`other`），不把过滤误记为符号核验失败。上述计数不增加符号查找，缺帧与不可解析行仍单独记录。`allocation_type_totals` 在 list 截断前累计全部节点，以固定 `HEAP_TYPES` 和 `unknown` 记录节点/字节总数及 `retained_*`、`omitted_*` 范围；公开 gate 核对逐类守恒、保留组计数和全图总数，未成功解析时该账本为 `null`。完整类型账本不补齐省略的分配栈，也不改变省略组的失败判定，不建立跨扫描对象身份、分配年龄或所有权关系。

终点 schema 3 另在保留根组的 `other_image_identity` 中记录 `other` 帧的映像身份，最多处理 96 个根帧，独立于原 96 次符号核验预算。目标 PC 仅匹配本报告 `Binary Images` 的唯一范围，再以唯一 UUID 关联离线验证进程已加载的映像。验证要求规范的 `/System/Library/` 或 `/usr/lib/` 路径、当前 dyld shared-cache membership 及 `MH_DYLIB_IN_CACHE`；不按报告路径加载，不依赖目标与验证进程共享地址。仅公开原帧 index、安全 basename/UUID 和固定失败计数；重叠或无效报告范围、冲突 UUID、未加载或未核验映像、验证进程失败/超时和预算省略均不能生成身份。未知标签、符号、PC、路径仍不公开。

验证 helper 仅在 host/reader 退出后的终点离线处理及上传 gate 中运行。它固定加载 AppKit，在有界的 owned 子进程内持有 dyld 回调，完整写出本轮私有结果文件后以 `os._exit` 退出，避免无法注销的 Python callback 在析构后被调用；父进程通过 `run_owned` 的独立私有进程组和有界退出回执确认回收。正常错误或已确认回收的超时可降级为身份不可用；退出未确认时禁止启动后续 helper。collection 保存原终点后保留清理失败，上传 gate 以独立清理回执复核；本例的六点、原严格失败和通过结构校验的旧终点先保存到摘要，再停止后续 case。公开 `terminal_image_worker_cleanup` 只取 `confirmed`、`unconfirmed` 或 `not-run`；后者仅用于 runner 明确未进入离线分析的情况，缺少必要回执不能证明退出，也不等于证明 worker 已启动。另以 `terminal_image_worker_artifact_cleanup` 区分 `complete`、`failed`、`unconfirmed` 与 `not-run`。进程退出已确认但产物删除失败时，保留已确认的退出状态，保存本例原严格类别与安全终点后使调查失败，停止后续 case；未删除目录留存。回执写入失败也保留固定产物错误且不重试该文件；若跨进程无法读取有效退出回执，仍按证据未知处理。私有 sidecar schema 2 分别记录退出与产物回收，仅接受普通文件，最多读取 129 字节并拒绝超过 128 字节、额外键或非严格布尔值。上传前还读取 runner 的 `process-cleanup.json`：仅接受有界普通文件中的固定 `errors` stage 列表；`terminal_snapshot` 优先于旧 sidecar 的产物成功状态，缺失或非法 stage 回执也阻止新 helper 与后续 case。这个 stage 只表明终点收集或产物处理失败，不指定删除失败原因；进程退出证据仍由 sidecar 决定。原严格失败、六点和通过完整结构/隐私校验的终点先保存，再停止。此回执不能替代终点内容校验。结果文件按原 schema/字节预算读取，supervisor 的 stdout/stderr 合并日志必须为空，纯空白 stderr 也拒绝。上传 gate 先完整拒绝非法结构，再以一次新的验证进程重新核验所有 basename/UUID，不能只接受字符串格式。若 fresh catalog 不可用或某个身份无法再次核验，仅原地移除相应新增帧，累计 `local_catalog_unavailable` / `uuid_not_verified` 并将该身份字段标记为 `partial`；旧终点计数、栈状态、完整性判定和严格失败继续保留。新字段的 `complete` 仅表示已解析的 `other` 帧全部找到唯一系统映像，不能补齐缺失/不可解析帧，也不改变原栈覆盖、64 KiB 摘要上限或终点完整性失败。它只识别系统组件，不核验原始符号，不证明构造函数、对象所有权、分配年龄或跨扫描身份。

独立的 `SharedCacheCapability.c` / `test_shared_cache_capability.py` 随现有 macOS unittest（含独立 macOS 27 兼容性检查）验证当前活动 shared cache 的 SPI 枚举能力，Linux 明确跳过原生部分。固定 Apple dyld 版本的声明与遍历契约见夹具源码；API 不可用、格式不支持或能力失败都使测试失败。夹具在同一进程严格执行一次 setup 遍历，再建立 setup 后的 loaded census，最后执行一次正式遍历，不循环重试。setup 独立要求 API 成功、回调 schema/预算完整及活动 cache UUID 前后相同；失败禁止正式阶段，setup rows 不复用。正式遍历再次绑定同一 cache UUID。schema 2 保留 setup/measurement 的独立 API 返回码、接收/有效记录数、schema 错误及 UUID 稳定性，并按固定阶段计数初始 observer 回放、setup、census、正式枚举和格式化中的 add/remove；初始回放不等于新加载。census 建立后直至有界结果格式化结束的任何变化仍失败；最终状态核对后才输出，`measurement_closed` 表示该关闭点，不声称覆盖输出或进程退出之后。固定 Apple 入口可能在首次调用时初始化 introspection 依赖，相关源码链接见夹具；这不证明任何特定远端失败实际加载了哪个组件。测试继续核对规范系统路径与 cache membership、重复 UUID 整组排除及计数守恒；`loaded_uuid_records` 是此独立非 AX 进程在 setup 后的加载回调记录数，不保证 UUID 唯一，未加载计数仅相对此进程，不能推断覆盖另一验证 helper 的全部映像。遍历完整性仍依赖 API 成功返回的契约，并非独立解析所有 cache 文件。Python 严格校验子进程输出后才公开有界的源码/二进制 SHA-256、OS/架构、cache UUID、固定计数和少量安全 basename/UUID，不输出 PID、PC、路径、环境或任意错误文本。编译、正常、失败与超时路径使用 owned supervisor，产物位于 `.build/Temporary/` 独立目录并回收二进制/缓存；退出未确认则失败并停止后续子命令。此能力测试尚未接入终点映像核验，不改变原符号权限、AX 六点扫描或严格增长判定。

终点摘要的 `parsing_status` 只说明两份文本的节点/字节/根组结构是否完整，`stacks_status` 单独说明已报告帧的公开覆盖。应用帧、隐藏系统帧或预算过滤会使栈为 `partial`，不能称为完整原始栈，即使剩下的系统帧均已核验。`terminal_snapshot_checks_passed` 要求捕获和离线工具成功、计数结构完整、无省略组、每组有栈且无缺帧或不可解析行；明确计数的过滤/未验证帧允许受限提取成功，同时保留 `partial` 栈状态。捕获/工具超时、格式不支持、缺栈等会使调查失败，原六点的 `strict_checks_passed` 和断言类别仍独立保留；退出已确认时两例继续收集。终点图是较晚的一次暂停观察，计数相同也不证明与之前扫描中的对象相同，分配来源与保守引用关系都不能证明所有权或基线漏报。

两种扫描模式只上传受限的 `ax-heap-diagnostics-summary`，明确记录扫描/回执模式、checkout、系统映像、进程环境、扫描节点/字节/根数、未知根和目标堆栈标记，以及逐扫描工具返回码和固定类别的断言失败计数；原始堆图、环境和日志不上传。原严格检查失败、回执缺失或该模式所需证据不完整都会使调查失败，同时继续收集后续对照；构建失败则保留未完成状态。运行返回码、断言分类与分配诊断完整性分别记录，live 不宣称完整分配诊断。每 case 的命令最多 180 秒，之后另有有界回收。独立 supervisor 保持私有进程组 leader 的 PID 身份，命令结束、失败或超时后均在回收 leader 前终止该组并核对组内已无运行成员，再等待 leader；不向已回收 leader 的历史 PGID 发送终止信号。`process_run` 分别记录原命令返回码、超时/协议状态和组清理结果；`group_inspection` 区分已退出、仍有运行成员、查询失败/超时、格式异常及 `leader_unverified`，不公开 PID 或进程表。检查必须见到唯一且 PGID 一致的未回收 leader；leader 缺失、重复或不一致时不得将空组视为已退出。无法确认组退出时保留失败并停止后续 case。runner 对 reader、host 各自执行有界 wait、terminate/wait、kill/wait，一方失败仍执行另一方、Launch Services 和必要回执清理；两进程退出未确认时不运行离线图分析。结束后清理夹具、缓存、堆图及原始日志。不同扫描模式的结果不能直接互相替代；内部回执仍会改变夹具二进制，外部读取也增加启动检查耗时。Scribble 用于调查残留指针是否影响保守扫描，但也可能改变分配器行为；环境回执、通过的重复运行和计数变化均不能替代对象所有权或基线漏报的因果证据。

AX 读取权限由实际 reader 可执行文件检查；不匹配映像或缺权限明确报告未覆盖，已匹配映像安装拒绝、通知不足、扫描失败仍失败。目标按钮的两个观察者须逐项恰好收到一次，重复和缺失不能互相抵消；总通知和未匹配通知另行记录。产品扫描先建立不含目标按钮的 AX/XPC 启动基线，再要求目标 AX 泄漏为零、无未分类节点和未知根；已知 NSXPCConnection 基线的节点数、字节数与根数均不能增长。解析器分别保存 ROOT LEAK/CYCLE 分类与实际根类型。全堆报告与目标 AX 数量分别记录，不能将稳定的非零基线写成全堆零泄漏。专项使用一次性 synthetic AppKit 宿主，不代替签名安装 App、Finder 或 VoiceOver 验收。

产品验证另在首批按钮注册后、每批销毁后及观察者退出后扫描，始终与最初的空窗口基线比较。堆断言或逐按钮通知断言失败后继续收集剩余检查点；最终收据标为 `failed`，进程返回非零。后续堆恢复不能撤销前面的失败。扫描不可用、进程异常或协议握手失败仍立即中止，已有原始记录仅留在本地临时目录。

`--copy-lifetime` 使用另一独立宿主，在已匹配的两个产品调用点登记实际返回数组。专用编译宏启用固定的 60 个 ARC 弱引用槽，每槽仅写入一次；普通和可变 copy 各须覆盖 30 次，并与补偿、按钮销毁计数一致。每个检查点拒绝缺失记录、异常登记和仍可获取的弱引用，后续释放不能撤销失败。弱引用清零表示对象已不能通过 weak 获取，不代表析构全部完成或存储已归还。该插桩会影响堆扫描的可达性判断，因此此模式只验证生命周期与通知，不运行或声明通过整堆检查；全部命令检查点与观察窗口保持。原无插桩通知与全堆检查仍独立运行，原堆增长约束不变；正常产品构建不包含此回调。

手动 AX 工作流的 `heap_diagnostics` 入口只在 macOS 26 arm64 运行五对独立的空目标对照和产品夹具，在相邻配对间交替先后顺序，与 `ax_causal_probe` 互斥。每个实例使用原有空窗口基线和全部检查点，并在首次添加按钮后、读取与订阅前增加检查点；同次活体扫描保存内存图，在 runner 上离线分析对象差分。任何实例失败、超时、摘要缺失、对象差分解析或分配分类不完整都会使调查 job 失败，后续实例的成功不能撤销它。控制台只输出经过字段白名单、枚举、数量和字节上限校验的脱敏摘要。系统符号只允许经过固定 Apple 映像路径及本进程 `dladdr` 元数据双重核对的无序计数；原始内存图、地址、路径、完整分配栈及日志不上传，结束后回收。摘要的 `status` 表示对象差分解析完整度；`symbols_status` 单独记录符号覆盖，未解析或隐藏的系统符号会使其不完整，但不改变产品退出码和对象差分判定。离线分配分类结合基线全堆清单和未压缩的分配历史，区分基线后分配、基线前已存在及身份不确定的对象；地址相等本身不能证明对象身份。`cohorts_status` 单独记录分配分类是否完整；候选地址最多 128 个，额外工具调用共限时 45 秒，无法确认的对象保留为未知。诊断模式使用未压缩的分配日志和完整历史内存图，普通验证模式不变。分类不完整或工具不可用不能覆盖原始堆断言或产品退出码。无目标对照使用 `--heap-control`，保留相同检查点与 AX 读取次数，将添加和移除按钮的位置替换为空窗口 checkpoint；每阶段的目标按钮、累计分配/销毁、两类补偿以及 reader 注册/通知必须为零。对照收据标为 `measured`，不声明产品补偿通过。该入口用于归因，不替代常规 CI 或证明内存问题已修复。

## 有限、可追溯的 CI 证据

每个 macOS job 创建独立 runner 临时目录，原生测试与 Release 构建分别显式指定 `tests.xcresult` / `release.xcresult` 的 `-resultBundlePath`。已有结果目录或符号链接会失败，不清除或覆盖上次失败结果。原生自检每次在 `.build/Temporary/release-readiness.XXXXXX/` 创建独立的 Debug、Release 和包缓存，解析使用本轮 DerivedData，构建设置查询显式指定本轮产品和中间目录。成功、失败或收到 HUP/INT/TERM 时回收本轮缓存和 App，保留 `records/cleanup.json` 及结果 bundle；外部提供的结果目录只用于保存结果，不参与清理。非 CI 本地运行默认结果目录为本轮目录中的 `Results/`。`run-native` 保留原失败退出码；退出成功但缺少任一结果 bundle 也判为失败。

Xcode 的 macOS App 构建会添加 Launch Services 注册步骤，文件回收不能证明注册状态已恢复。CI 临时 runner 没有日常安装版；本机验证结束后须按 [临时产物回收约定](CONTRIBUTING.md#临时产物回收) 恢复日常 App 与 Finder 扩展的实际加载身份，并在清理后验收真实 Finder 菜单。自检脚本的清理收据只记录本轮文件回收结果。

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
