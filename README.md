# opencode-termux

在 Termux (Android ARM64) 上一键安装**官方** OpenCode CLI (sst/opencode),纯脚本方案,不发布 npm 分发包。

> 官方 `opencode-linux-arm64-musl` 构建 + `patchelf` 改 interpreter/rpath,
> 运行库取自 Alpine Linux (ld-musl + libstdc++ + libgcc),经本地 DNS 转发器解析。

## 原理

| 组件 | 来源 | 说明 |
|---|---|---|
| `opencode` 二进制 | [sst/opencode](https://github.com/sst/opencode) 官方 musl 构建 | 动态链接 musl (非静态),不能直接跑 |
| `ld-musl-aarch64.so.1` | Alpine musl 包 | patchelf 设为 interpreter |
| `libstdc++.so.6` + `libgcc_s.so.1` | Alpine v3.20 包 | patchelf 设为 rpath (`/usr/lib/musl`) |
| DNS | dns53 转发器 / dns-bootstrap | Android 无 `/etc/resolv.conf`,musl 解析器回退 127.0.0.1:53 无人监听 → 卡死 5s |

**下载走 gh-proxy 镜像** (mirror 优先, GitHub 直连兜底),国内可装。

## 前置要求

- Termux + aarch64 (ARM64)
- 有 root: dns53 原生方案 (推荐)
- 无 root: 自动改用 dns-bootstrap + proot 兜底

## 一行命令安装

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/xkxxs/opencode-termux/main/install.sh)
```

## 脚本做了什么

| 步骤 | 说明 |
|---|---|
| 环境检查 | 仅支持 Termux + aarch64 |
| 依赖安装 | `pkg install patchelf nodejs-lts sudo/proot` (有 root 装 sudo, 无 root 自动装 proot) |
| musl 运行库 | 从 Alpine 获取 ld-musl + libstdc++ + libgcc (已存在则跳过) |
| DNS 修复 | 有 root: dns53 转发器 + `.bashrc` 常驻; 无 root: dns-bootstrap 实测校验 + proot 绑定 |
| 安装 OpenCode | GitHub API 查最新版 (mirror 优先) → 下载 musl tarball → patchelf ×2 → 验证 → 换入 |
| 生成 wrapper | `~/.local/bin/opencode`: 启动前自动查版更新、`opencode update` 完整升级流程、修复 `~/.opencode/bin` PATH 陷阱 |
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

> ⚠️ 不要用 opencode 官方的 `opencode upgrade` 命令:它只替换文件、不重跑 patchelf,更新即变砖。
> 本 wrapper 的 `opencode update` 内置完整流程 (查版 → 下载 → patchelf → 验证 → 原子换入)。

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
| glibc 版 Segfault | 用错了非 musl 构建 | 本方案用 musl 版,不要用 `opencode-linux-arm64.tar.gz` |

## 许可证

MIT
