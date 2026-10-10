# QuickFile v0.1 Beta 冻结与分发规则

QuickFile 0.1.0 尚未发布，完整运行与分发准入尚未通过。当前路线是本机开发候选及源码自编译测试；面向普通用户的安装包须完成 Developer ID、公证和默认安全设置新机器验收后才能放行。源码版本以 [project.yml](project.yml) 为准，不能据此推断已安装产物或验收状态。

## 冻结范围与安全边界

冻结期间只接收文件安全、创建位置、权限、扩展不可用、崩溃和阻塞核心流程的修复。新入口及工具扩展留待后续版本。

目标平台为 macOS 13+，构建包含 Intel 与 Apple Silicon；具体系统、架构和存储兼容性须分别实机验收。本地文件夹、iCloud、外接卷和网络卷不能合并为同一项通过。Finder 菜单采用默认文件名；精确 `.gitignore` 等名称可由主 App 的无扩展名模板输入。

含文件继承 ACL 的目标、忽略文件所有权的卷，以及无法提供当前用户私有暂存区的环境会安全拒绝创建。共享目录中的写入诊断也可能因无法保护探针条目而拒绝，不能据此概括为目录绝对不可写。卷改名后旧授权可能需要在主 App 刷新，不承诺所有卷都无需重新确认。

创建错位置、覆盖或损坏原文件时立即停止该候选的使用与分发，保留匿名证据，修复并重建后重新验收。

## 源码自编译与注册设备测试

1. 使用测试者自己的 Apple 账号/团队，确认两个 Target 的 Bundle ID、App Group 和设备能力可用。个人团队能力取决于账号状态，不保证所有账号都能使用默认标识。
2. 按 [README.md](README.md) 生成工程并 Clean 构建。若需替换标识，同步修改主 App、扩展、App Group 及配置断言，保留 App Sandbox。
3. 核对嵌入扩展、版本/build、各 Target 的 Bundle ID、团队、App Group、权限及双架构，并执行严格签名检查；记录自己的产物哈希和环境。
4. 在系统默认安全设置下安装、启动并启用扩展。拒绝安装或启动时保留错误原文并停止该项，不关闭 Gatekeeper、移除隔离属性、重签包或用注册修复掩盖失败。
5. 按 [测试指南](BETA_TEST_GUIDE.md) 和 [29 项验收清单](RELEASE_CHECKLIST.md) 填写自己的结果。开发签名只覆盖构建者或同时被主 App 与扩展描述文件覆盖的注册设备，不能代替普通用户分发验收。

## 普通用户分发准入

- 固定源码基线、工具链、依赖和构建参数；每个新候选递增 build，主 App 与扩展一致，营销版本使用数字格式，Beta 标记写在发布材料中。
- Clean Archive，使用 Developer ID 导出，完成公证和装订；核对最终产物的签名、权限、嵌入扩展、双架构与 SHA-256。导出配置见 [Developer ID 配置](Release/ExportOptions-DeveloperID.plist)；[注册设备配置](Release/ExportOptions-RegisteredDevices.plist) 只用于对应开发测试范围。
- 签名证书及所需描述文件的有效期覆盖整个测试窗口，注册设备范围必须同时覆盖两个 Target；同团队或签名完整不能替代 App ID、证书与描述文件授权匹配。
- 用最终分发文件，在默认安全设置的新机器完成下载、安装、首次启动、扩展启用、授权与创建闭环。
- 完成 P0，并按 P1 记录系统、架构、存储与发布准备范围。性能、长期内存、完整诊断、无窗口 Desktop、Mac 重启/注销及 HTTPS 跨版本更新的缺口不得由旧候选或 CI 结果代替。

## 产物检查与记录

对实际导出的 App 执行只读检查，路径为示例：

```bash
python3 Scripts/verify-beta-artifact.py .build/Temporary/beta-release/Export/QuickFile.app \
  --mode developer-id \
  --output .build/Temporary/beta-release/developer-id.json
```

注册设备开发测试使用 `--mode registered-devices`。默认 `--min-valid-days 8` 可按实际窗口调整，但 `0` 只证明即时运行条件，不能作为七天候选证据。`fail` 或 `unknown` 不作为放行；脚本检查也不能替代新机器和完整实机验收。

每个候选保留构建输入、签名、安装及清理收据，公开记录只用匿名路径，不公开个人 Team、设备标识、证书、描述文件、书签或数据恢复备份。源码、签名或包内容改变后更新身份，重验受影响项及安装/启动闭环。临时产物回收按 [CONTRIBUTING.md](CONTRIBUTING.md) 执行。

准入完成后分阶段使用 [七天反馈模板](BETA_FEEDBACK.md) 收集真实使用情况。邀请、设备注册、上传和发布须有相应授权；准备材料不表示已经分发。

官方参考：[Developer ID](https://developer.apple.com/developer-id/)、[注册 Mac 设备分发](https://help.apple.com/xcode/mac/current/en.lproj/dev295cc0fae.html)、[公证工作流](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)。
