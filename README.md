# opencode-termux

在 Termux (Android ARM64) 上一键安装**官方** OpenCode CLI **V2**,纯脚本方案,不发布 npm 分发包。

> 官方 `@opencode/cli-linux-arm64-musl` 包 + `patchelf` 改 interpreter/rpath,
> 运行库取自 Alpine Linux (ld-musl + libstdc++ + libgcc),经本地 DNS 转发器解析。

**V1 用户看这里**:V2 是官方推倒重建的版本,分发方式从 GitHub Releases 改成了
**npm** (下载页只列了 x64,但 npm 上有 `linux-arm64-musl`)。
V1 的适配已归档到 [OpenCodeV1-Termux](https://github.com/xkxxs/OpenCodeV1-Termux) (冻结)。

## 原理

| 组件 | 来源 | 说明 |
|---|---|---|
| `opencode` 二进制 | npm `@opencode/cli-linux-arm64-musl` | 动态链接 musl (非静态),不能直接跑 |
| `ld-musl-aarch64.so.1` | Alpine musl 包 | patchelf 设为 interpreter |
| `libstdc++.so.6` + `libgcc_s.so.1` | Alpine latest-stable 包 | patchelf 设为 rpath (`$PREFIX/lib/musl`) |
| DNS | dns53 转发器 / dns-bootstrap | Android 无 `/etc/resolv.conf`,musl 解析器回退 127.0.0.1:53 无人监听 → 卡死 5s |

**下载走 npm**:先用 `npm view ... dist.tarball` 解析真实 URL (**跟随你配置的 registry**,
比如配了 npmmirror 就直接走它),再 `curl --progress-bar` 下载;失败自动换另一个镜像。

注意:**别直接用官方的 `curl -fsSL https://opencode.ai/v2/install | bash`** ——
它判定 musl 靠 `/etc/alpine-release` 或 `ldd --version | grep musl`,
Termux 两个都不满足,会给你装** glibc 版 **,直接跑不起来。本脚本写死 musl 变体。

## 前置要求

- Termux + aarch64 (ARM64)
- 有 root: dns53 原生方案 (推荐)
- 无 root: 自动改用 dns-bootstrap + proot 兜底

## 一行命令安装

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/xkxxs/opencode-termux/main/install.sh)
```

国内网络拉不动 `raw.githubusercontent.com` 时,改用镜像:

```bash
# jsDelivr CDN
bash <(curl -fsSL https://cdn.jsdelivr.net/gh/xkxxs/opencode-termux@main/install.sh)

# 或 gh-proxy
bash <(curl -fsSL https://gh-proxy.com/https://raw.githubusercontent.com/xkxxs/opencode-termux/main/install.sh)
```

## 脚本做了什么

| 步骤 | 说明 |
|---|---|
| 环境检查 | 仅支持 Termux + aarch64 |
| 依赖安装 | `pkg install patchelf nodejs-lts sudo/proot` (有 root 装 sudo, 无 root 自动装 proot) |
| musl 运行库 | 从 Alpine 获取 ld-musl + libstdc++ + libgcc (已存在则跳过) |
| DNS 修复 | 有 root: dns53 转发器 + `.bashrc` 常驻; 无 root: dns-bootstrap 实测校验 + proot 绑定; `dns53-aaaa on|off|status` 切换 AAAA 屏蔽 |
| 安装 OpenCode | opencode.ai API 查最新版 (npm view 兜底) → 下载 tarball → patchelf ×2 → 验证 → 换入 |
| 生成 wrapper | `~/.local/bin/opencode`: 启动前自动查版更新、`opencode update` 完整升级流程、关掉官方自动更新、修复 `~/.opencode/bin` PATH 陷阱 |
| 验证 | `opencode --version` |

## 使用

```bash
opencode                     # 启动: 先检查最新版, 非最新自动更新再启动
opencode update              # 更新到最新版
opencode update --force      # 已最新也强制重装
bash ~/.check_dns.sh         # DNS 一键诊断
node ~/.local/bin/dnsq.js api.deepseek.com   # 单点解析测试
bash <(curl -fsSL …/install.sh) --uninstall  # 卸载
```

> ⚠️ 用 `opencode update` (或 `upgrade`),**不要**让官方自己更新:
> 官方更新只替换文件、不重跑 patchelf,更新完 interpreter 变回 `/lib/ld-musl-aarch64.so.1` 就跑不起来了。
> 本 wrapper 已 `export OPENCODE_DISABLE_AUTOUPDATE=1` 关掉官方的自动更新,
> 并接管了 `update` / `upgrade` 两个子命令,内置完整流程 (查版 → 下载 → patchelf → 验证 → 原子换入)。

## 历史会话在哪

从 V1 升上来后可能以为"历史没了"——**数据没丢,是 V2 的首屏不显示历史列表**
(V1 首屏会列出上次的 Session / Continue, V2 首屏只有 logo + 输入框)。

会话都存在 `~/.local/share/opencode/opencode.db` (V2 迁移 V1 数据时就地保留):

```bash
opencode -c                 # 继续上一次会话 (最常用)
opencode -s <session-id>    # 继续指定会话
opencode api session.list   # 列出所有会话 id
opencode --continue         # 同 -c
```

升级前想保险可以备份: `cp ~/.local/share/opencode/opencode.db ~/opencode.db.bak`
(我这边的库有 1.4GB, 注意磁盘)。

## 后台服务

V2 默认会拉起一个**后台服务** (`opencode serve --service`,监听 127.0.0.1 随机端口),
跨多次调用复用,会话/项目状态都在它上面。实测**在 Termux 上能正常起来**(不像 codex 的
app-server daemon 那样卡死),TUI 也正常。

不想要常驻进程的话可以加 `--standalone` (走进程内私有服务,用完就退):

```bash
opencode --standalone        # 或 OPENCODE_STANDALONE=1 由 wrapper 自动附加
```

## 配置模型 (DeepSeek 等)

OpenCode 支持 Anthropic 兼容端点:

```bash
export ANTHROPIC_BASE_URL=https://api.deepseek.com/anthropic
export ANTHROPIC_AUTH_TOKEN=sk-你的APIKey
export ANTHROPIC_MODEL=deepseek-v4-flash
# 持久化: 追加到 ~/.bashrc
```

## 常见问题

| 症状 | 原因 | 解决 |
|---|---|---|
| `cannot execute: required file not found` | 二进制 interpreter 不存在 | 重跑 `bash install.sh` (自动 patchelf) |
| `Error relocating libtermux-exec-ld-preload.so: __register_atfork` | termux-exec 的 LD_PRELOAD hook (Bionic) 被 musl 加载 | wrapper 已 `unset LD_PRELOAD` |
| API 请求恰好卡 5s 超时 | DNS 卡死 (musl 读不到 resolv.conf) | dns53/dns-bootstrap 已自动处理; `bash ~/.check_dns.sh` 诊断 |
| `-S: error while loading shared libraries` | Termux 命令在特定 shell 的怪癖 | 用完整路径调用或重登 shell |
| glibc 版 Segfault | 用错了非 musl 构建 (官方脚本在 Termux 上就会选错) | 本方案写死 musl 变体,不要直接跑官网的 install 脚本 |
| 更新后突然 `cannot execute: required file not found` | 被官方自动更新替换成了没打补丁的二进制 | wrapper 已关掉官方自动更新; 出问题时重跑 `opencode update --force` |
| V1 的会话历史 | V2 会迁移 V1 数据 | 默认共用 `~/.local/share/opencode`,升级后历史仍在 |

## V1 → V2

| | V1 (已归档) | V2 (本仓库) |
|---|---|---|
| 分发 | GitHub Releases (+ gh-proxy) | **npm** `@opencode/cli-linux-arm64-musl` |
| 版本查询 | GitHub API | `opencode.ai/update/api/latest/cli/npm` |
| 架构服务 | 无 | 后台服务 (`serve --service`) / `--standalone` |
| 仓库 | [OpenCodeV1-Termux](https://github.com/xkxxs/OpenCodeV1-Termux) | 本仓库 |

## 许可证

MIT
