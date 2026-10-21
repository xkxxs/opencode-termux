# opencode-termux

在 Termux (Android ARM64) 上一键安装**官方** OpenCode CLI **V2**,纯脚本方案,不发布 npm 分发包。

> 官方 `@opencode/cli-linux-arm64-musl` 包 + `patchelf` **只改 interpreter**,
> 运行库取自 Alpine Linux (ld-musl + libstdc++ + libgcc),**原生直跑, 不需要 proot**。

**无 root / 无 proot**:DNS 通过一份“私有 musl loader 副本 + `/sdcard/.oc-resolv`”
解决,安装时会请求共享存储权限。详见下文[为什么不用 proot](#为什么不用-proot)。

**V1 用户看这里**:V2 是官方推倒重建的版本,分发方式从 GitHub Releases 改成了
**npm** (下载页只列了 x64,但 npm 上有 `linux-arm64-musl`)。
V1 的适配已归档到 [OpenCodeV1-Termux](https://github.com/xkxxs/OpenCodeV1-Termux) (冻结)。

## 原理

| 组件 | 来源 | 说明 |
|---|---|---|
| `opencode` 二进制 | npm `@opencode/cli-linux-arm64-musl` | 动态链接 musl (非静态),不能直接跑 |
| `ld-musl-aarch64.so.1` | Alpine musl 包 | 装到 `$PREFIX/lib`,patchelf 设为 interpreter |
| `ld-musl-aarch64.so.1` 私有副本 | 上面的 loader 复制到 `~/.local/opencode/` | 只把编译死的 `"/etc/resolv.conf"` 原地改写成 `/sdcard/.oc-resolv` (系统 loader 不动) |
| `libstdc++.so.6` + `libgcc_s.so.1` | Alpine latest-stable 包 | 由 wrapper 用 `LD_LIBRARY_PATH=$PREFIX/lib/musl` 提供,**不写 rpath** |
| DNS | `dns53/` 独立组件 + `/sdcard/.oc-resolv` | Android 无 `/etc/resolv.conf`,musl 回退 `127.0.0.1:53` 无人监听 → 超时;见下节 |

**下载走 npm**:先用 `npm view ... dist.tarball` 解析真实 URL (**跟随你配置的 registry**,
比如配了 npmmirror 就直接走它),再 `curl --progress-bar` 下载;失败自动换另一个镜像。

注意:**别直接用官方的 `curl -fsSL https://opencode.ai/v2/install | bash`** ——
它判定 musl 靠 `/etc/alpine-release` 或 `ldd --version | grep musl`,
Termux 两个都不满足,会给你装** glibc 版 **,直接跑不起来。本脚本写死 musl 变体。

## 为什么不用 proot

以前无 root 只能靠 proot 把运行库和 `resolv.conf` 绑到标准路径,代价是:

- 每次启动多一层 ptrace 拦截(慢);
- 后台服务在 proot 下退出时会卡住(只能退回 `--standalone`);
- 部分机型的 seccomp 会拦 `epoll_pwait2`,还要额外伪装内核版本。

现在两步就够了:

1. **不打 rpath。** `patchelf --set-rpath` 配 musl 在 Android 上会让这个 206MB 的
   Bun 二进制一跑就 SIGSEGV(exit 139)。运行库改用 `LD_LIBRARY_PATH` 提供。
2. **私有 loader + 短路径。** musl 把 `/etc/resolv.conf` 编译死在 loader 里,而
   Android 的 `/etc` 是只读的 `/system/etc`。无 root 又不能监听 53 端口。
   于是复制一份 loader,把字符串原地改成 `/sdcard/.oc-resolv`——字符串后面只有
   6 个 NUL 填充字节,最长 22 字符,app 私有目录的路径都更长,**只有 `/sdcard` 够短**。
   wrapper 每次启动把真实 DNS 配置同步到这个文件。

所以需要**共享存储权限**(安装脚本会自动请求)。proot 代码只作为极端情况的兜底保留,
正常路径完全不会用到。

## 前置要求

- Termux + aarch64 (ARM64)
- **共享存储权限** —— 安装脚本会自动调 `termux-setup-storage` 请求
  (两阶段:先弹系统权限窗,再在 Termux 里确认 `y` 建 `~/storage`),请点“允许”。
  DNS 配置要放在 `/sdcard/.oc-resolv`,没有权限会**联网超时**
- 不需要 root,也不需要 proot(proot 仅作极端情况兜底)

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
| 存储权限 | `termux-setup-storage` 两阶段请求(已在则跳过),DNS 配置需要 `/sdcard` 可写 |
| 依赖安装 | `pkg install patchelf nodejs-lts curl`(不需要 sudo,也不需要 proot) |
| musl 运行库 | 从 Alpine 获取 ld-musl + libstdc++ + libgcc (已存在则跳过) |
| 私有 loader | 复制 `ld-musl-aarch64.so.1` 到 `~/.local/opencode/`,把 `/etc/resolv.conf` 改写成 `/sdcard/.oc-resolv` |
| DNS 修复 | 安装独立的 `dns53` 组件到 `~/.local/share/dns53`;wrapper 启动时同步 `/sdcard/.oc-resolv` |
| 安装 OpenCode | opencode.ai API 查最新版 (npm view 兜底) → 下载 tarball → **只打 interpreter** → 原生直跑验证 → 换入 |
| 生成 wrapper | `~/.local/bin/opencode`: 原生直跑、自动查版更新、`opencode update` 完整升级流程、关掉官方自动更新、修复 `~/.opencode/bin` PATH 陷阱 |
| 验证 | `opencode --version`,并报告运行模式 / loader / DNS shim |

## 使用

```bash
opencode                     # 启动: 先检查最新版, 非最新自动更新再启动
opencode update              # 更新到最新版
opencode update --force      # 已最新也强制重装
bash ~/.local/share/dns53/check_dns.sh       # DNS 一键诊断
node ~/.local/share/dns53/dnsq.js api.deepseek.com   # 单点解析测试
bash <(curl -fsSL …/install.sh) --uninstall  # 卸载
```

> ⚠️ 用 `opencode update` (或 `upgrade`),**不要**让官方自己更新:
> 官方更新只替换文件、不重跑 patchelf,更新完 interpreter 变回 `/lib/ld-musl-aarch64.so.1` 就跑不起来了。
> 本 wrapper 已 `export OPENCODE_DISABLE_AUTOUPDATE=1` 关掉官方的自动更新,
> 并接管了 `update` / `upgrade` 两个子命令,内置完整流程 (查版 → 下载 → patchelf → 验证 → 原子换入)。

## dns53 独立组件

DNS 兜底不再写进任何 agent 目录(旧版放在 `~/.local/bin` / `~/.codex`),而是作为独立组件
安装在 `~/.local/share/dns53`,codex、opencode 等所有 musl 程序共用同一份。仓库里的
`dns53/` 是该组件的源码与安装器,主 `install.sh` 只负责获取并调用它。

```
~/.local/share/dns53/
├── dns53.js            # 有 root: 本地 53 端口转发器
├── dns-bootstrap.js    # 无 root: 实测校验后写 resolv.conf
├── dnsq.js             # 单点解析测试
├── check_dns.sh        # 一键诊断
├── dns53-aaaa          # AAAA 屏蔽开关: on|off|status
├── install.sh          # 安装/升级器
├── root.sh             # root 后端探测 (sudo / su)
├── VERSION             # 组件版本
└── logs/               # dns53.log / dns-bootstrap.log
```

- 删除 `~/.codex`、`~/.config/opencode` 等 agent 目录**不会**影响 DNS。
- 安装/升级: `bash ~/.local/share/dns53/install.sh`
- 查看状态: `bash ~/.local/share/dns53/install.sh --status`
- 卸载(只删组件,不动 agent 目录): `bash ~/.local/share/dns53/install.sh --uninstall`
- AAAA 开关: `bash ~/.local/share/dns53/dns53-aaaa off`
- 版本保护: 安装器默认拒绝用旧版本覆盖新版本,`--force` 可强制。

### root 判定

dns53 需要 root 才能监听 `127.0.0.1:53`。Android 上**有 root 不等于装了 Termux 的 `sudo` 包**
(Magisk / KernelSU 只提供 `su`),所以判定按能力顺序进行,并缓存结果:

| 顺序 | 条件 | 执行方式 |
|---|---|---|
| 1 | `id -u` 为 0 | 直接执行 |
| 2 | `sudo -n true` 成功 | `sudo -n`(不弹窗) |
| 3 | `su -c 'id -u'` 返回 0 | `su -c` |
| 4 | 都不满足 | 无 root → `dns-bootstrap` |

探测结果缓存在 `~/.local/share/dns53/.root_mode`(`direct|sudo|su|none`),避免每次开 shell
都去探测 `su` 触发授权弹窗。root 状态变化后,重跑 `bash ~/.local/share/dns53/install.sh --status`
会重新探测并更新缓存。

> `su -c` 首次会弹 Magisk/KernelSU 授权框,授权一次(建议选"永久")后不再弹。
> 不想看到弹窗也可以 `pkg install sudo`,走第 2 条。

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

### proot-bind 兜底模式下默认走 standalone

正常安装都是 `native` 模式(`cat ~/.local/opencode/.mode`),只有原生直跑验证失败时
才会退到 **proot-bind**。该模式下 wrapper 会**自动附加 `--standalone`**,原因:

该模式下后台服务虽然能起来、也能正常返回结果,但**客户端干完活不退出** ——
表现为 TUI 里 `/exit` 或 Ctrl+C 之后一直停在 "Starting background server…",
只能杀进程。实测对比 (真 pty,发 Ctrl+C 计时):

| 模式 | Ctrl+C 之后 |
|---|---|
| `--standalone` | **0.6 秒干净退出** |
| 后台服务 | 29 秒仍未退出,只能强杀 |

代价:每次启动重新起一次进程内服务,不能跨终端共享同一个会话实例。
想强行用后台服务:`OPENCODE_STANDALONE=0 opencode`。

> `native` 模式 (patchelf 正常时) 仍用官方默认的后台服务。若你遇到同样的
> 退出卡住,加 `OPENCODE_STANDALONE=1` 即可。

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
| `cannot execute: required file not found` | 二进制 interpreter 不存在 | 重跑 `bash install.sh` (自动打补丁 + 重建私有 loader) |
| `Error relocating libtermux-exec-ld-preload.so: __register_atfork` | termux-exec 的 LD_PRELOAD hook (Bionic) 被 musl 加载 | wrapper 已 `unset LD_PRELOAD` |
| API 请求恰好卡 5s 超时 / `getaddrinfo ETIMEOUT` | musl 读不到 DNS 配置 | 检查 `/sdcard/.oc-resolv` 是否存在、存储权限是否给了;`bash ~/.local/share/dns53/check_dns.sh` 诊断 |
| 启动时提示 `需要存储权限` 或弹权限窗 | 共享存储权限未授予,写不进 `/sdcard/.oc-resolv` | 允许 Termux 的存储权限,或手动 `termux-setup-storage`;`~/.local/opencode/.storage-denied` 会缓存 5 分钟避免反复弹窗 |
| `-S: error while loading shared libraries` | Termux 命令在特定 shell 的怪癖 | 用完整路径调用或重登 shell |
| glibc 版 Segfault | 用错了非 musl 构建 (官方脚本在 Termux 上就会选错) | 本方案写死 musl 变体,不要直接跑官网的 install 脚本 |
| 更新后突然 `cannot execute: required file not found` | 被官方自动更新替换成了没打补丁的二进制 | wrapper 已关掉官方自动更新; 出问题时重跑 `opencode update --force` |
| `opencode` 启动后一直用 proot / 很慢 | 落到了 proot-bind 兜底模式 | `cat ~/.local/opencode/.mode`;重跑 `opencode update --force` 或 `bash install.sh` 回到 native |
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
