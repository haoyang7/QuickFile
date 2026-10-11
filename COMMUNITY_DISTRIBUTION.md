# 免费自行分发

QuickFile 提供实验性的 community 构建流程，不需要 Apple 开发者会员、签名证书或 provisioning profile。产物采用 ad-hoc 签名，保留主 App 和 Finder 扩展的 App Sandbox、Hardened Runtime、App Group 及目录书签权限。它没有 Developer ID 身份，也没有经过 Apple 公证；可构建、签名完整与普通用户机器上可运行须分别验证。

## 构建与检查

使用 [README](README.md) 中的 Xcode、XcodeGen 工具链，在仓库根目录执行：

```bash
./Scripts/build-community.sh \
  --output .build/Packages/community-candidate \
  --release-tag v0.1.0-beta.1
```

输出目录必须尚不存在。脚本锁定已有 `Package.resolved`，构建 arm64 / x86_64 Release，使用 `QUICKFILE_COMMUNITY` 排除 Sparkle 调用，并在确认两个架构都只链接系统动态库后移除副本中的 Sparkle。主应用不再需要 Sparkle 的 Mach 服务例外权限。不能将普通构建直接重签后视为 community 包：Hardened Runtime 的动态库验证可能阻止 ad-hoc 主程序加载第三方 framework。

打包脚本拒绝带 profile 或已完成应用签名的输入。`CODE_SIGNING_ALLOWED=NO` 构建可能保留链接器生成的 ad-hoc 标记；仅在它没有 Team、证书、权限、Info 绑定或资源封装时接受。脚本先签扩展、后签宿主，逐架构检查签名、权限、版本与动态库依赖。它不修改输入 App，不覆盖已有输出；DMG 只读挂载复验成功、镜像卸载后才发布本地输出目录，包含：

- `QuickFile-<tag>.dmg`：压缩只读镜像，当前候选对外文件名为 `QuickFile-v0.1.0-beta.1.dmg`，其中 `<tag>` 本身包含 `v`；内含 `QuickFile.app` 及指向 `/Applications` 的快捷方式
- 对应 `.sha256` 校验文件
- `artifact-check.json`：脱敏产物检查收据
- `INSTALL.txt`：安装与验证范围说明

GitHub Actions 在这四项本地产物之外生成第五项 `build-provenance.json`，记录源码 SHA、Actions run、工具链及四项资产的 SHA-256；本地构建命令不会生成这份 GitHub 来源收据。

DMG 使用系统 `hdiutil` 创建 HFS+ / UDZO 镜像，不需要额外打包依赖。检查包括镜像内部校验、挂载后 App 的逐架构签名与完整文件清单、安装快捷方式及输入未改动。挂载不打开 Finder 或运行应用；卸载失败或挂载状态不明时不交付，保留独立 `.build/Temporary/community-dmg-*/` 中的镜像供恢复，并返回错误。

Xcode 会注册构建中的临时 App。脚本退出时按路径注销本轮副本，重新登记已有的 `/Applications/QuickFile.app` 及其扩展，再回收构建缓存和中间 App；不切换扩展开关。若注册恢复或回收失败，脚本返回失败并记录残留。私有构建日志及清理收据留在本轮 `.build/Temporary/community-build.*/records/`。脚本不会安装、上传或发布应用。每个新候选仍须递增 build，并保留源码、依赖与工具链记录。

独立复验挂载或复制出的 App：

```bash
python3 Scripts/verify-community-artifact.py \
  .build/Temporary/community-check/QuickFile.app \
  --output .build/Temporary/community-check/artifact-check.json
```

校验和用于检查下载字节是否一致，ad-hoc 签名用于检查包的内部完整性；二者不能证明发布者身份。分发页应使用固定 HTTPS 地址并提供对应版本说明与校验和。

普通用户的下载、安装、首次打开、Finder 扩展和权限排障按[安装指南](INSTALLATION.md)执行。普通安装只需 DMG 和对应 `.sha256`；其余收据可按需查看。`build-provenance.json` 用于确认候选的源码、工作流运行和四项主要资产身份；它不替代签名、公证或完整实机验收。

## GitHub Actions 打包

`codex/**` 分支构建从 `project.yml` 唯一的 `MARKETING_VERSION` 推导 `v<版本>` 作为 artifact 文件名，不沿用旧 Beta 标签，也不代表已发布该版本。标签事件保留实际标签，手动运行使用显式 `release_tag`；缺失、重复或格式错误的营销版本会使分支打包失败。产物版本与标签仍须通过一致性检查。

`.github/workflows/community-dmg.yml` 复用 `Scripts/build-community.sh --release-tag ...` 生成发布候选。入口包括 `workflow_dispatch`（输入 `release_tag`，默认 `v0.1.0-beta.1`；工作流先存在于默认分支后，Actions 界面才可手动运行）、推送 `v*` 标签，以及首次 `codex/**` 分支对列出的构建文件进行 bootstrap 的 push；分支 push 受 workflow 的 `paths` 过滤。每次只上传一个包含五项文件的 Actions artifact，不自动创建或公开 GitHub Release。维护者应从该 artifact 取出 `build-provenance.json`，核对源码 SHA、run、工具链和四项主要资产哈希，再决定是否把同一组文件上传到草稿 Release。

## GitHub Releases 发布流程

GitHub Releases 只承载维护者手动发布的 community 候选；Actions artifact 只是打包结果，不是公开 Release、自动更新或准入判断流程。正式 v0.1 只有在[发布清单](RELEASE_CHECKLIST.md)的全部 P0 已在同一候选上补齐，且没有待测、受阻或不通过时才能发布。实验预发布若保留缺口，维护者必须在候选记录和发布说明中逐项写明并明确接受；这不改变正式版 P0 门槛。`artifact-check.json` 只证明产物层，artifact-only 回执、签名完整或绿色 CI 均不能直接放行。

发布上传必须使用同一次 GitHub Actions artifact；先确保固定标签已经存在且指向本次候选提交，再核对营销版本、内部 build、源码/run/工具链身份和四项资产的逐项哈希。对外 DMG 文件名只包含 release tag，不包含内部 build：

```bash
set -euo pipefail
TAG='v0.1.0-beta.1'
VERSION=0.1.0
BUILD='78'  # internal build in About and receipts; not part of the public DMG name
OUTPUT=.build/Packages/community-candidate
DMG="QuickFile-${TAG}.dmg"

test -f "$OUTPUT/build-provenance.json"
test -f "$OUTPUT/$DMG"
test -f "$OUTPUT/$DMG.sha256"
test -f "$OUTPUT/artifact-check.json"
test -f "$OUTPUT/INSTALL.txt"
python3 - "$OUTPUT" "$TAG" "$BUILD" <<'PY'
import hashlib
import json
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1])
tag = sys.argv[2]
build = sys.argv[3]
if re.fullmatch(r"v0\.1\.0(?:-beta\.[1-9][0-9]*)?", tag) is None:
    raise SystemExit("invalid release tag")
payload = json.loads((root / "build-provenance.json").read_text(encoding="utf-8"))
commit = payload.get("source_commit")
if not isinstance(commit, str) or re.fullmatch(r"[0-9a-f]{40}", commit) is None:
    raise SystemExit("provenance source_commit must be exactly 40 lowercase hex characters")
if payload.get("release_tag") != tag:
    raise SystemExit("provenance release_tag does not match TAG")
if payload.get("internal_build") != build:
    raise SystemExit("provenance internal_build does not match BUILD")
records = payload.get("assets")
expected = {
    f"QuickFile-{tag}.dmg",
    f"QuickFile-{tag}.dmg.sha256",
    "artifact-check.json",
    "INSTALL.txt",
}
if (not isinstance(records, list) or len(records) != 4
        or any(not isinstance(record, dict) for record in records)
        or {record.get("name") for record in records} != expected):
    raise SystemExit("provenance assets must name exactly the four delivery files")
for record in records:
    path = root / record["name"]
    if not path.is_file():
        raise SystemExit(f"missing delivery asset: {record['name']}")
    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    if record.get("sha256") != digest or record.get("bytes") != path.stat().st_size:
        raise SystemExit(f"provenance hash or size mismatch: {record['name']}")
run = payload.get("run")
run_id = run.get("run_id") if isinstance(run, dict) else None
if not isinstance(run_id, str) or re.fullmatch(r"[1-9][0-9]{0,19}", run_id) is None:
    raise SystemExit("provenance run_id is invalid")
print("provenance source, tag, build, asset names, hashes and sizes match")
PY
COMMIT=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["source_commit"])' "$OUTPUT/build-provenance.json")
test "$(git rev-parse "${TAG}^{commit}")" = "$COMMIT"
test "$(gh api "repos/haoyang7/QuickFile/commits/$TAG" --jq .sha)" = "$COMMIT"
RUN_ID=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["run"]["run_id"])' "$OUTPUT/build-provenance.json")
test "$(gh api "repos/haoyang7/QuickFile/actions/runs/$RUN_ID" --jq .head_sha)" = "$COMMIT"
test "$(gh api "repos/haoyang7/QuickFile/actions/runs/$RUN_ID" --jq .conclusion)" = success
test "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$OUTPUT/artifact-check.json")" = "$VERSION"
test "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["build"])' "$OUTPUT/artifact-check.json")" = "$BUILD"
```

用固定标签创建草稿并一次上传五项资产：

```bash
# Stable v0.1.0 or a distinct v0.1.0-beta.N experimental prerelease.
if [[ "$TAG" == 'v0.1.0' ]]; then
  PRERELEASE_ARGS=()
  EXPECTED_PRERELEASE=false
elif [[ "$TAG" =~ ^v0\.1\.0-beta\.[1-9][0-9]*$ ]]; then
  PRERELEASE_ARGS=(--prerelease)
  EXPECTED_PRERELEASE=true
else
  echo "error: use v0.1.0 or a v0.1.0-beta.N tag" >&2
  exit 2
fi
RELEASE_NOTES=.build/Temporary/community-release-notes.md
test -s "$RELEASE_NOTES"
gh release create "$TAG" --repo haoyang7/QuickFile --verify-tag --draft \
  "${PRERELEASE_ARGS[@]}" \
  --title "QuickFile ${TAG} community" \
  --notes-file "$RELEASE_NOTES" \
  "$OUTPUT/$DMG" "$OUTPUT/$DMG.sha256" \
  "$OUTPUT/artifact-check.json" "$OUTPUT/INSTALL.txt" \
  "$OUTPUT/build-provenance.json"
```

运行上一步前，将准确的草稿说明写入 `.build/Temporary/community-release-notes.md`。说明必须列出：ad-hoc 签名、未公证以及可能需要逐应用批准；没有 Sparkle，升级为手动覆盖安装；本候选实际验收的系统/架构支持范围；以及尚未验收的跨机器启动、Finder 集成、升级、Gatekeeper 或其他具体 P0/P1、系统和卷范围。预期的 macOS 13.0+、Apple Silicon 与 Intel 不能替代当前候选的实测范围。

实验预发布必须使用带 `-beta.N` 的独立标签（例如 `v0.1.0-beta.1`）并在创建草稿时设置 `--prerelease`；不得复用稳定的 `v0.1.0` 标签。发布前还要确认远端 `isPrerelease` 与 `$EXPECTED_PRERELEASE` 一致，最后的 `--draft=false` 只发布已核对的当前类型。

维护者先检查草稿仍处于 draft、资产数量恰为五项，再从远端下载同一组资产复核校验和；校验失败、资产缺失或说明范围不准确时不得发布：

```bash
test "$(gh release view "$TAG" --repo haoyang7/QuickFile --json isDraft --jq .isDraft)" = true
test "$(gh release view "$TAG" --repo haoyang7/QuickFile --json assets --jq '.assets | length')" = 5
test "$(gh release view "$TAG" --repo haoyang7/QuickFile --json isPrerelease --jq .isPrerelease)" = "$EXPECTED_PRERELEASE"
VERIFY_DIR=$(mktemp -d .build/Temporary/community-release-verify.XXXXXX)
gh release download "$TAG" --repo haoyang7/QuickFile --dir "$VERIFY_DIR" \
  --pattern "$DMG" --pattern "$DMG.sha256" \
  --pattern artifact-check.json --pattern INSTALL.txt \
  --pattern build-provenance.json
for asset in "$DMG" "$DMG.sha256" artifact-check.json INSTALL.txt build-provenance.json; do
  test -f "$VERIFY_DIR/$asset"
  cmp "$OUTPUT/$asset" "$VERIFY_DIR/$asset"
done
(cd "$VERIFY_DIR" && shasum -a 256 -c "$DMG.sha256")
```

维护者确认固定标签、版本/build、五项远端资产、`build-provenance.json`、校验和及发布说明均匹配后，才按已核对的类型公开发布：

```bash
gh release edit "$TAG" --repo haoyang7/QuickFile --draft=false
```

## 安装、权限与升级验收

普通用户完整步骤见[安装指南](INSTALLATION.md)。下载后先核对校验和，备份旧应用和数据，退出旧版，将 `QuickFile.app` 拖到“应用程序”快捷方式，推出镜像后从“应用程序”启动。首次打开优先使用系统“隐私与安全性 → 仍要打开”逐应用批准；不要求允许任何来源、关闭 Gatekeeper 或 SIP。

仅对可信官方发布文件且已核对校验和的手动排障可定向执行 `xattr -dr com.apple.quarantine /Applications/QuickFile.app`；`xattr -cr /Applications/QuickFile.app` 会递归清除全部扩展属性，范围更宽。二者都不是签名或公证，也不授予 Finder 目录权限，不得作为默认安全设置验收通过的依据。当前用户拥有该 App 写权限时通常无需管理员权限；若出现 `Operation not permitted`，先核对文件所有权和路径并按系统提示处理，不把 `sudo` 作为默认步骤。

macOS 对没有发布身份的 App Group 访问可能再次要求用户确认，具体行为需要按系统版本、首次启动和每次升级分别记录。Finder 扩展开关和目录授权分开处理；macOS 15 及以后按“通用 → 登录项与扩展”查找，较早系统使用系统设置搜索 Finder 扩展并参阅 [Apple 官方说明](https://support.apple.com/guide/mac-help/mtusr003/mac)。授权面板取消或系统拒绝时保留错误，不通过伪造 Team、关闭沙盒、禁用动态库验证或换成普通共享目录来绕过；QuickFile 不需要完全磁盘访问。

每个最终 DMG 在默认安全设置的另一台 Mac 上至少验证：

1. 浏览器下载、首次打开、App Group 访问、Finder 扩展启用。
2. 主 App 选择目录并创建文件；保存目录授权，退出重开后使用授权。
3. Finder 实际创建文件；主 App 退出、Finder 重启后仍能读模板并使用授权。
4. 覆盖升级后核对实际加载版本，确认模板、持久书签及跨进程目录授权可用。签名身份改变后可能需要重新授权，不能用旧候选测试代替。
5. 按 [发布清单](RELEASE_CHECKLIST.md) 验证文件安全、错误路径及支持环境。清理中间副本后复验 Finder 菜单，流程见 [CONTRIBUTING](CONTRIBUTING.md)。

产物检查收据只声明 artifact 层结果，不声明跨机器、Finder、升级或 Gatekeeper 已通过。尚未完成这些实测时，应标明实验候选及缺口。

## 版本检查

当前 community 构建不含 Sparkle，不进行在线检查、下载或安装；“检查更新”菜单禁用，升级采用手动覆盖安装。

免费分发可以使用固定 HTTPS 版本清单或 GitHub Releases API 查询版本，不依赖 Apple 会员。后续接入时需为查询组件配置沙盒出站网络权限，比较单调递增的 build，区分稳定版和预发布版，限制响应大小及下载链接来源，处理超时和限流，再由用户打开发布页下载。查询版本与自动替换应用是独立能力；此流程尚未实现版本查询客户端。

Developer ID 的签名、公证及 Sparkle 发布流程继续使用 [BETA_RELEASE](BETA_RELEASE.md) 和 [UPDATES](UPDATES.md) 中对应检查，不用 community 产物检查替代。
