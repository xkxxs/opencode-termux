#!/data/data/com.termux/files/usr/bin/bash
# ============================================================
# opencode-termux — 在 Termux (Android aarch64) 上一键安装官方 OpenCode CLI V2
# 方案: 官方 musl 动态链接版 + patchelf 改 interpreter/rpath
#
# 用法:
#   bash <(curl -fsSL https://raw.githubusercontent.com/xkxxs/opencode-termux/main/install.sh)
#   bash <(curl -fsSL …/install.sh) --uninstall
#
# V1 vs V2:
#   V1 走 GitHub Releases, V2 起官方改用 npm 分发 —— 本仓库跟随 V2;
#   V1 版本已归档到 xkxxs/OpenCodeV1-Termux (冻结)。
#
# 原理:
#   官方 @opencode/cli-linux-arm64-musl 是动态链接 musl (非静态!),
#   Android 没有 musl 运行环境, 需从 Alpine 获取 ld-musl-aarch64.so.1
#   + libstdc++.so.6 + libgcc_s.so.1, 再用 patchelf 改二进制:
#     interpreter → /usr/lib/ld-musl-aarch64.so.1
#     rpath       → /usr/lib/musl
#
#   DNS: musl 解析器读不到 /etc/resolv.conf (Android 没有), 回退
#   127.0.0.1:53 无人监听 → 卡死 5s。有 root 用 dns53 转发器;
#   无 root 用 dns-bootstrap 实测校验 + proot 绑定 resolv.conf。
# ============================================================
set -euo pipefail

# ---------- 常量 ----------
PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
HOME_DIR="${HOME:-/data/data/com.termux/files/home}"
OPENCODE_DIR="$HOME_DIR/.local/opencode"
REAL_BIN="$OPENCODE_DIR/opencode"
VERSION_FILE="$OPENCODE_DIR/.version"
WRAPPER_PATH="$HOME_DIR/.local/bin/opencode"
INTERP="$PREFIX/lib/ld-musl-aarch64.so.1"
RPATH="$PREFIX/lib/musl"
CERT_FILE="$PREFIX/etc/tls/cert.pem"
# V2 起官方改用 npm 分发, 不再走 GitHub Releases (V1 仍在 GitHub 发版,
# 已归档到 xkxxs/OpenCodeV1-Termux)。musl ARM64 平台包:
NPM_PKG="@opencode/cli-linux-arm64-musl"
# 注意: 官方 install 脚本判定 musl 靠 /etc/alpine-release 或 ldd|grep musl,
# Termux 两个都不满足 → 它会误选 glibc 包。这里直接写死 musl 变体。
UPDATE_API="https://opencode.ai/update/api/latest/cli/npm"

# ---------- 颜色 ----------
RED='\033[0;31m'; GRN='\033[0;32m'; YEL='\033[1;33m'; BLU='\033[1;36m'; NC='\033[0m'
ok()   { echo -e "${GRN}✓${NC} $*"; }
info() { echo -e "${BLU}▸${NC} $*"; }
warn() { echo -e "${YEL}⚠${NC} $*"; }
fail() { echo -e "${RED}✗${NC} $*"; exit 1; }

# ---------- proot 兜底 (含 Bun 的 epoll_pwait2 段错误规避) ----------
# V2 是 Bun 编译的单文件二进制。Bun 在"报告的内核 >= 5.11"时会走
# epoll_pwait2, 而该 syscall 在部分内核返回 ENOSYS 时 Bun 没有兜底 →
# 空指针 → SIGSEGV (signal 11, 见 bun#32489)。表现为:
#   proot info: vpid 1: terminated with signal 11
# 解法: 用 proot -k 5.10.0 把进程看到的内核版本降到 5.10, Bun 就会退回
# epoll_pwait。副作用只是 proot 内 uname 显示 5.10。
kernel_needs_proot() {
    local maj min
    maj="$(uname -r | cut -d. -f1 | tr -dc '0-9')"
    min="$(uname -r | cut -d. -f2 | tr -dc '0-9')"
    [ -z "$maj" ] && return 1
    [ "$maj" -gt 5 ] && return 0
    if [ "$maj" -eq 5 ] && [ -n "$min" ] && [ "$min" -ge 11 ]; then return 0; fi
    return 1
}

# Bun 判断内核版本的两个来源都要伪造:
#   proot -k 5.10.0          只改 uname 系统调用
#   -b 假 osrelease 文件      改 /proc/sys/kernel/osrelease (proot -k 不管这个!)
# 只做前者没用 —— Bun 读的是 /proc 那份, 于是仍然走 epoll_pwait2 崩溃。
fake_osrelease() {
    local f="$OPENCODE_DIR/.fake-osrelease"
    mkdir -p "$OPENCODE_DIR" 2>/dev/null || return 0
    printf '5.10.0\n' >"$f" 2>/dev/null || return 0
    printf '%s' "$f"
}

# $1=二进制, 其余=参数: 统一走 proot (-k 5.10.0 + 伪 osrelease + 必要时绑 resolv.conf)
proot_run() {
    local bin="$1"; shift
    local opts=(-k 5.10.0)
    local fake
    fake="$(fake_osrelease)"
    if [ -n "$fake" ] && [ -f "$fake" ]; then
        opts+=(-b "$fake:/proc/sys/kernel/osrelease")
    fi
    if [ -f "${PREFIX}/etc/resolv.conf" ]; then
        opts+=(-b "${PREFIX}/etc/resolv.conf:/etc/resolv.conf")
    fi
    proot "${opts[@]}" env -u LD_PRELOAD "SSL_CERT_FILE=${SSL_CERT_FILE:-$PREFIX/etc/tls/cert.pem}" "$bin" "$@"
}

# ---------- 下载 ----------
# 官方 API 形如 {"channel":"latest",...,"version":"2.0.32",...}
oc_latest_version() {
    local v=""
    v="$(curl -fsSL --max-time 20 "$UPDATE_API" 2>/dev/null \
        | sed -n 's/.*"version":"\([^"]*\)".*/\1/p' | head -1)" || v=""
    if [ -z "$v" ]; then
        v="$(npm view @opencode/cli version 2>/dev/null | tail -1)" || v=""
    fi
    printf '%s' "$v"
}

# $1=版本 → 输出两个候选直连 URL (npm view 不可用时的兜底)
fallback_tarball_urls() {
    local name="${NPM_PKG##*/}" scope="${NPM_PKG%/*}"
    printf 'https://registry.npmmirror.com/%s/%s/-/%s-%s.tgz\n' "$scope" "$name" "$name" "$1"
    printf 'https://registry.npmjs.org/%s/%s/-/%s-%s.tgz\n' "$scope" "$name" "$name" "$1"
}

# $1=版本 $2=输出文件: 带进度条下载, 失败自动换镜像
download_tgz() {
    local ver="$1" out="$2" url="" alt="" u
    url="$(npm view "$NPM_PKG@$ver" dist.tarball 2>/dev/null | tail -1)" || url=""
    if [ -n "$url" ]; then
        curl -fSL --progress-bar --connect-timeout 15 --max-time 900 "$url" -o "$out" && return 0
        case "$url" in
            *registry.npmjs.org*)     alt="${url/registry.npmjs.org/registry.npmmirror.com}" ;;
            *registry.npmmirror.com*) alt="${url/registry.npmmirror.com/registry.npmjs.org}" ;;
        esac
        if [ -n "$alt" ] && [ "$alt" != "$url" ]; then
            warn "直连失败, 换镜像重试…"
            curl -fSL --progress-bar --connect-timeout 15 --max-time 900 "$alt" -o "$out" && return 0
        fi
    fi
    warn "取不到 tarball URL, 改用固定 URL 规则直连…"
    while read -r u; do
        curl -fSL --progress-bar --connect-timeout 15 --max-time 900 "$u" -o "$out" && return 0
    done < <(fallback_tarball_urls "$ver")
    return 1
}

# ---------- 环境检查 ----------
check_environment() {
    if [ "$(uname -o 2>/dev/null || true)" != "Android" ] && [ ! -x "$PREFIX/bin/pkg" ]; then
        fail "此脚本仅支持 Termux (Android)。普通 Linux 请直接: curl -fsSL https://opencode.ai/install | bash"
    fi
    [ "$(uname -m)" = "aarch64" ] || fail "仅支持 aarch64 (ARM64) 架构, 当前: $(uname -m)"
    command -v curl >/dev/null || { info "安装 curl…"; pkg install -y curl; }
    info "环境检查通过 (Termux aarch64)"
}

# ---------- 镜像源适配 ----------
# 刚装的 Termux 默认官方源, 国内经常慢/不可达。对候选源逐个"探测 + 测速",
# 自动切换到最快的可用源 (幂等; 切换后 apt update 失败会自动回滚)。
#
# 踩过的两个坑 (都实际造成过故障):
#   1) 各家镜像的路径不一样: 有的是 /termux/apt/termux-main, 有的是
#      /termux/termux-main —— 不能假定同一个模式, 否则会拿到 404。
#   2) 测速必须同时校验 HTTP 状态码: 只看 %{time_total} 的话, 404 的响应也
#      很快, 会被误判成"最快"并切过去, 结果 apt update 直接失败。
fix_mirror() {
    local sources_file="$PREFIX/etc/apt/sources.list"
    [ -f "$sources_file" ] || { warn "未找到 apt 源文件, 跳过镜像适配"; return; }

    # 候选: "显示名 base URL" (路径各不相同, 已逐个实测 HTTP 200)
    local candidates=(
        "官方 https://packages.termux.dev/apt/termux-main"
        "阿里云 https://mirrors.aliyun.com/termux/termux-main"
        "清华 https://mirrors.tuna.tsinghua.edu.cn/termux/apt/termux-main"
        "中科大 https://mirrors.ustc.edu.cn/termux/apt/termux-main"
        "北大 https://mirrors.pku.edu.cn/termux/termux-main"
        "华为云 https://mirrors.huaweicloud.com/termux/termux-main"
    )

    local entry name url r1 code t1 t2 t
    local best_name="" best_url="" best_t=999999
    for entry in "${candidates[@]}"; do
        name="${entry%% *}"
        url="${entry##* }"
        r1="$(curl -s -o /dev/null -w '%{http_code} %{time_total}' \
            --connect-timeout 4 --max-time 10 "$url/dists/stable/Release" 2>/dev/null || echo '000 999')"
        code="${r1%% *}"; t1="${r1##* }"
        if [ "$code" != "200" ]; then
            info "跳过 $name (Release 不可用: HTTP $code)"
            continue
        fi
        # 再测一次取较快值
        t2="$(curl -s -o /dev/null -w '%{time_total}' \
            --connect-timeout 4 --max-time 10 "$url/dists/stable/Release" 2>/dev/null || echo 999)"
        t="$(printf '%s\n%s\n' "$t1" "$t2" | sort -n | head -1)"
        info "测速 $name: ${t}s"
        if awk "BEGIN{exit !($t < $best_t)}"; then
            best_name="$name"; best_url="$url"; best_t="$t"
        fi
    done

    if [ -z "$best_url" ]; then
        warn "所有候选源都不可用, 保持当前配置 (可手动: pkg change-repo)"
        return
    fi
    ok "最快可用源: $best_name (${best_t}s)"

    # 当前已是最快 → 不动
    if grep -qF "$best_url" "$sources_file" 2>/dev/null; then
        ok "当前源已是最快, 无需切换"
        return
    fi

    local backup="$sources_file.bak.$(date +%s)"
    cp "$sources_file" "$backup"
    warn "切换源: $(grep -oE 'https://[^ ]+' "$sources_file" | head -1) → $best_name"
    {
        echo "# 由 install.sh 自动切换 (最快源: $best_name ${best_t}s)"
        echo "deb $best_url stable main"
    } > "$sources_file"

    if DEBIAN_FRONTEND=noninteractive apt update -y; then
        ok "apt update 成功 ($best_name), 原配置备份: $(basename "$backup")"
    else
        warn "apt update 失败, 已自动回滚到原配置"
        cp "$backup" "$sources_file"
        DEBIAN_FRONTEND=noninteractive apt update -y || true
    fi
}

upgrade_packages() {
    info "更新软件包索引并升级全部软件包…"
    info "提示: 全新 Termux 首次升级可能耗时数分钟 (下载量大), 请耐心等待, 不要打断"
    if DEBIAN_FRONTEND=noninteractive pkg upgrade -y; then
        ok "软件包已是最新"
    else
        warn "pkg upgrade 未完全成功, 请稍后重试 (pkg upgrade -y)"
    fi
}

# ---------- 依赖 ----------
install_dependencies() {
    local need=()
    command -v patchelf >/dev/null || need+=(patchelf)
    command -v node >/dev/null || need+=(nodejs-lts)
    command -v npm >/dev/null || need+=(nodejs-lts)
    # 有 root → dns53 原生方案; 无 root → proot 兜底
    if command -v sudo >/dev/null 2>&1; then
        if ! sudo -n true 2>/dev/null; then need+=(proot); fi
    else
        need+=(sudo)
    fi
    if [ ${#need[@]} -gt 0 ]; then
        info "安装依赖: ${need[*]}"
        pkg install -y "${need[@]}" || fail "依赖安装失败, 请先手动执行 pkg update && pkg upgrade"
    else
        ok "依赖已就绪 (patchelf $(patchelf --version 2>/dev/null | grep -oE '[0-9.]+'), node $(node --version))"
    fi
    if ! sudo -n true 2>/dev/null; then
        if ! command -v proot >/dev/null 2>&1; then
            info "未检测到 root, 安装 proot 兜底…"
            pkg install -y proot || true
        fi
        # 无 root 时 musl 二进制会被 seccomp 拦截 (Bad system call / Segmentation fault),
        # 没有 proot 就跑不起来 → 在这里早失败, 别等到验证阶段才段错误。
        command -v proot >/dev/null 2>&1 \
            || fail "无 root 环境必须用 proot 才能运行 musl 二进制, 但 proot 安装失败。请手动: pkg install proot"
        warn "未检测到 root: 将使用 proot 兜底方案 (性能略降)"
    fi
}

# ---------- musl 运行库 (Alpine) ----------
# ---------- Alpine 源: 动态版本 + 多镜像回退 ----------
# 不能硬编码 apk 版本号: Alpine 的 edge 是滚动分支, 旧版本会被直接轮掉
# (musl-1.2.6-r2 在 edge 已经 404 了), 所以固定用 latest-stable 分支,
# 并从 APKINDEX.tar.gz (解压出来是纯文本索引) 取当前版本号。
ALPINE_MIRRORS=(
    "https://mirrors.tuna.tsinghua.edu.cn/alpine/latest-stable/main/aarch64"
    "https://mirrors.aliyun.com/alpine/latest-stable/main/aarch64"
    "https://mirrors.ustc.edu.cn/alpine/latest-stable/main/aarch64"
    "https://dl-cdn.alpinelinux.org/alpine/latest-stable/main/aarch64"
)

apk_mirror_host() { local h="${1#https://}"; printf '%s' "${h%%/*}"; }

# $1=索引保存路径; 成功后把选中的镜像放进 ALPINE_BASE
alpine_select_mirror() {
    local m
    for m in "${ALPINE_MIRRORS[@]}"; do
        if curl -fsSL --connect-timeout 8 --max-time 30 "$m/APKINDEX.tar.gz" -o "$1"; then
            ALPINE_BASE="$m"
            ok "Alpine 镜像: $(apk_mirror_host "$m")"
            return 0
        fi
        warn "镜像不可用: $(apk_mirror_host "$m")"
    done
    fail "所有 Alpine 镜像都取不到 APKINDEX (网络问题?)"
}

# $1=索引路径 $2=包名 → 当前版本号; 解析失败则输出空串。
# 关键: 不能让 set -e 因为 pipeline 非零而"静默"退出 —— 曾出现过
# "没有任何报错、脚本直接结束" 的情况 (某些 tar 不认 apk 的扩展头会报错退出)。
alpine_version() {
    local idx="$1" pkg="$2" out=""
    # 注意: awk 打完就 exit, tar 会收到 SIGPIPE(141); 在 pipefail 下整条 pipeline 非零,
    # 若写成 `out=$(...) || out=""` 会把已经取到的值清空, 且 set -e 会让脚本"静默结束"。
    # 因此一律用 `|| true`: 保留已捕获的输出, 只吃掉非零退出码。
    out=$( { tar -xzOf "$idx" APKINDEX 2>/dev/null || true; } \
        | awk -F: -v p="$pkg" '$1=="P" && $2==p {f=1; next} f && $1=="V" {print $2; exit}') || true
    # 回退: 用 gzip 先解压再喂给 tar, 绕开 tar 对 APK-TOOLS.checksum.SHA1 扩展头的处理差异
    [ -n "$out" ] || out=$( { gzip -dc "$idx" 2>/dev/null || true; } | tar -xOf - APKINDEX 2>/dev/null \
        | awk -F: -v p="$pkg" '$1=="P" && $2==p {f=1; next} f && $1=="V" {print $2; exit}') || true
    printf '%s' "$out"
}

# $1=索引路径 $2=包名 $3=输出文件
alpine_fetch_apk() {
    local idx="$1" pkg="$2" out="$3" ver="" m
    ver="$(alpine_version "$idx" "$pkg")" || true
    if [ -z "$ver" ]; then
        warn "解析 $pkg 版本号失败, 下面是 tar 的真实输出:"
        tar -xzOf "$idx" APKINDEX >/dev/null || true
        fail "无法从 APKINDEX 解析 $pkg 的版本号"
    fi
    for m in "${ALPINE_MIRRORS[@]}"; do
        if curl -fsSL --connect-timeout 10 --max-time 120 "$m/$pkg-$ver.apk" -o "$out"; then
            info "$pkg-$ver.apk ← $(apk_mirror_host "$m")"
            return 0
        fi
        warn "$pkg-$ver.apk 下载失败: $(apk_mirror_host "$m")"
    done
    fail "$pkg.apk 下载失败 (已试 ${#ALPINE_MIRRORS[@]} 个镜像)"
}

# 需要: ld-musl-aarch64.so.1 + libstdc++.so.6 + libgcc_s.so.1
# 已存在则跳过 (幂等)
install_musl_libs() {
    if [ -x "$INTERP" ] && [ -f "$RPATH/libstdc++.so.6" ] && [ -f "$RPATH/libgcc_s.so.1" ]; then
        ok "musl 运行库已就绪 (ld-musl + libstdc++ + libgcc)"
        return
    fi

    local work idx
    work=$(mktemp -d "${TMPDIR:-$PREFIX/tmp}/musl.XXXXXX")
    idx="$work/APKINDEX.tar.gz"
    alpine_select_mirror "$idx"

    info "获取 musl 动态链接器 (Alpine musl 包)…"
    alpine_fetch_apk "$idx" musl "$work/musl.apk"
    (cd "$work" && tar xzf musl.apk) || fail "musl.apk 解压失败"
    [ -f "$work/lib/ld-musl-aarch64.so.1" ] || fail "musl.apk 内容异常"
    cp "$work/lib/ld-musl-aarch64.so.1" "$PREFIX/lib/"
    chmod +x "$PREFIX/lib/ld-musl-aarch64.so.1"
    ok "ld-musl-aarch64.so.1 已安装"

    info "获取 C++ 运行库 (Alpine libgcc + libstdc++)…"
    mkdir -p "$RPATH"
    alpine_fetch_apk "$idx" libgcc "$work/libgcc.apk"
    alpine_fetch_apk "$idx" "libstdc++" "$work/libstdcxx.apk"
    (cd "$work" && tar xzf libgcc.apk && tar xzf libstdcxx.apk) || fail "C++ 库解压失败"
    cp "$work/usr/lib/libgcc_s.so.1" "$work/usr/lib/libstdc++.so.6"* "$RPATH/" 2>/dev/null || {
        cp "$work/usr/lib/libgcc_s.so.1" "$RPATH/"
        cp "$work/usr/lib/libstdc++.so.6.0.32" "$RPATH/libstdc++.so.6"
        cp "$work/usr/lib/libstdc++.so.6.0.32" "$RPATH/libstdc++.so.6.0.32"
    }
    chmod +x "$RPATH/"libstdc++.so.6* "$RPATH/libgcc_s.so.1"
    rm -rf "$work"
    ok "C++ 运行库已安装到 $RPATH"
}

# ---------- DNS 修复 ----------
# musl 解析器读不到 /etc/resolv.conf (Android 没有), 回退 127.0.0.1:53
# 有 root → dns53 本地转发器 + .bashrc 常驻
# 无 root → dns-bootstrap 实测校验 + proot 绑定 resolv.conf (wrapper 运行时自动选择)
fix_dns() {
    local dns53="$HOME_DIR/.local/bin/dns53.js"
    local dnsboot="$HOME_DIR/.local/bin/dns-bootstrap.js"
    mkdir -p "$HOME_DIR/.local/bin"

    if ! command -v sudo >/dev/null 2>&1 || ! sudo -n true 2>/dev/null; then
        info "未检测到 root, 使用 dns-bootstrap + proot 兜底"
        info "dns-bootstrap 会自动实测候选 DNS 应答质量 (SERVFAIL/空/被过滤全判废), 只写入真实可用的 resolv.conf"
        cat > "$dnsboot" << 'DNSBOOT_EOF'
#!/usr/bin/env node
// dns-bootstrap — 无 root 环境下的 DNS 自动校验器
// 背景: musl 程序 (codex/opencode) 解析器读不到 /etc/resolv.conf (Android 没有)。
//       有 root 时 dns53.js 监听 127.0.0.1:53 转发解析; 无 root 绑不了特权端口,
//       只能让 musl 直接查 resolv.conf 里的公网 DNS。
//       本脚本解决后者: 实际探测当前网络 → 逐个实测公网 DNS 应答质量
//       (SERVFAIL/空应答/CNAME-only 全判废) → 只把"实测通过"的写进 resolv.conf,
//       再交给 proot 绑定。网络被拦截时给出明确报错, 不再静默卡 5 秒。
// 用法:
//   node dns-bootstrap.js            # 单次校验并重写 resolv.conf (wrapper 启动前用)
//   node dns-bootstrap.js --daemon   # 常驻: 每 60s 重测重写 (开机/打开终端时拉起)
const dgram = require('dgram');
const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');

const PUBLIC_DNS = ['223.5.5.5', '119.29.29.29', '114.114.114.114', '2400:3200::1', '2402:4e00::'];
// 测速用域名: 主测 API 域名; 若主域名本身被网络过滤, 回退测国内域名判断网络是否可用
const PROBE_DOMAINS = ['api.deepseek.com', 'www.baidu.com'];
const TIMEOUT_MS = 2500;
const RESOLV = process.env.DNS_RESOLV_CONF ||
  `${process.env.PREFIX || '/data/data/com.termux/files/usr'}/etc/resolv.conf`;
const LOG = process.env.DNS_BOOTSTRAP_LOG ||
  `${process.env.HOME || '/data/data/com.termux/files/home'}/.codex/dns-bootstrap.log`;
const log = (m) => { try { fs.appendFileSync(LOG, `${new Date().toISOString()} ${m}\n`); } catch (_) {} };

// 探测手机当前网络 DNS (与 dns53 同一套逻辑, 无 root 也能跑 dumpsys)
function discoverPhoneDns() {
  const servers = [];
  try {
    const props = execFileSync('/system/bin/getprop', [], { encoding: 'utf8', timeout: 3000 });
    for (const line of props.split('\n')) {
      const m = line.match(/^\[net\.\S+\.dns\d+\]:\s*\[([0-9.]+)\]/);
      if (m) servers.push(m[1]);
    }
  } catch (_) {}
  if (servers.length === 0) {
    try {
      const out = execFileSync('/system/bin/dumpsys', ['connectivity'], { encoding: 'utf8', timeout: 5000 });
      const blocks = out.split('NetworkAgentInfo{').slice(1);
      const scored = [];
      for (const b of blocks) {
        const dm = b.match(/DnsAddresses:\s*\[([^\]]*)\]/);
        if (!dm) continue;
        const ips = [];
        let hit;
        const re = /(\d{1,3}(?:\.\d{1,3}){3})/g;
        while ((hit = re.exec(dm[1]))) ips.push(hit[1]);
        if (!ips.length) continue;
        const score = (b.includes('TRANSPORT_PRIMARY') ? 0 : 1) + (b.includes('INTERNET') && b.includes('VALIDATED') ? 0 : 2);
        scored.push([score, ips]);
      }
      scored.sort((a, b) => a[0] - b[0]);
      for (const [, ips] of scored) servers.push(...ips);
    } catch (_) {}
  }
  return [...new Set(servers)].filter((ip) => ip !== '127.0.0.1' && ip !== '0.0.0.0');
}

// DNS 查询 (UDP 53, 非特权端口即可发起)
function queryDNS(server, host, timeout = TIMEOUT_MS) {
  return new Promise((resolve) => {
    const sock = dgram.createSocket(server.includes(':') ? 'udp6' : 'udp4');
    const id = Buffer.from([Math.floor(Math.random() * 256), Math.floor(Math.random() * 256)]);
    const q = Buffer.alloc(12 + 2 + host.length + 4);
    id.copy(q, 0);
    q[5] = 1; // RD
    let off = 12;
    for (const part of host.split('.')) { q[off++] = part.length; q.write(part, off); off += part.length; }
    q[off++] = 0; q[off++] = 0; q[off++] = 1; q[off++] = 0; q[off++] = 1; // A IN
    const t0 = Date.now();
    const timer = setTimeout(() => { try { sock.close(); } catch (_) {} resolve({ ok: false, reason: 'timeout', ms: Date.now() - t0 }); }, timeout);
    sock.on('message', (resp) => {
      clearTimeout(timer);
      resolve({ ok: !badAnswer(resp), ms: Date.now() - t0, raw: resp });
      try { sock.close(); } catch (_) {}
    });
    sock.on('error', () => { clearTimeout(timer); try { sock.close(); } catch (_) {} resolve({ ok: false, reason: 'error', ms: Date.now() - t0 }); });
    sock.send(q, 53, server);
  });
}

// 应答校验: 返回 true = 应答有问题 (与 dns53 的 isBadResponse 同套标准)
// 坏应答: 报文过短 / SERVFAIL / rcode=0 无答案 / 查 A 却只回 CNAME 不附地址 (ISP 过滤)
function badAnswer(resp) {
  if (resp.length < 12) return true;
  const rcode = resp.readUInt16BE(2) & 0x0f;
  if (rcode === 2) return true;
  if (rcode !== 0 && rcode !== 3) return true; // 只放行 NOERROR / NXDOMAIN
  const qd = resp.readUInt16BE(4);
  const an = resp.readUInt16BE(6);
  if (an === 0) return rcode === 0; // NOERROR 无答案 = 被过滤; NXDOMAIN 合法
  let off = 12;
  const skipName = (p) => {
    let hops = 0;
    while (off < p.length && p[off] !== 0) {
      if ((p[off] & 0xc0) === 0xc0) { off += 2; return; }
      off += p[off] + 1;
      if (++hops > 32) break;
    }
    off++;
  };
  for (let i = 0; i < qd && off < resp.length; i++) { skipName(resp); off += 4; }
  for (let i = 0; i < an && off + 10 <= resp.length; i++) {
    skipName(resp);
    const type = resp.readUInt16BE(off);
    const len = resp.readUInt16BE(off + 8);
    off += 10 + len;
    if (type === 1 || type === 28) return false; // 有 A/AAAA 记录
  }
  return true; // 只有 CNAME/NS 等 → 过滤特征
}

// 对单个服务器实测: 主域名失败再试备域名, 任一通过即为可用
async function probe(server) {
  for (const host of PROBE_DOMAINS) {
    const r = await queryDNS(server, host);
    if (r.ok) return { ip: server, ms: r.ms, host, ok: true };
  }
  return { ip: server, ms: Infinity, ok: false };
}

async function runOnce() {
  const phone = discoverPhoneDns();
  const candidates = [...phone, ...PUBLIC_DNS];
  const uniq = [];
  for (const ip of candidates) if (!uniq.includes(ip)) uniq.push(ip);
  if (uniq.length === 0) uniq.push(...PUBLIC_DNS);

  const results = await Promise.all(uniq.map((ip) => probe(ip)));
  const good = results.filter((r) => r.ok).sort((a, b) => a.ms - b.ms);

  for (const r of results) {
    log(`probe ${r.ip}: ${r.ok ? `OK ${r.ms}ms via ${r.host}` : 'FAILED'}`);
  }

  const comment = [];
  if (phone.length) comment.push(`# phone dns: ${phone.join(', ')}`);
  const top = good.slice(0, 3);
  const body = top.length
    ? top.map((r) => `nameserver ${r.ip}`).join('\n') + '\n'
    : 'nameserver 223.5.5.5\nnameserver 119.29.29.29\nnameserver 2400:3200::1\nnameserver 2402:4e00::\n';

  fs.mkdirSync(path.dirname(RESOLV), { recursive: true });
  fs.writeFileSync(RESOLV, `${comment.join('\n')}\n# auto-written by dns-bootstrap.js @ ${new Date().toISOString()}\n${body}`);
  log(`resolv.conf updated: ${top.map((r) => r.ip).join(', ') || 'NONE (fallback public)'}`);

  return good.length;
}

async function main() {
  const daemon = process.argv.includes('--daemon');
  const doOnce = async () => {
    try {
      const n = await runOnce();
      if (n === 0) log('ALL upstreams failed — network DNS likely blocked');
    } catch (e) {
      log(`error: ${e.message}`);
      process.exitCode = 1;
    }
  };
  if (daemon) {
    await doOnce();
    log('daemon started (poll every 60s)');
    setInterval(() => { doOnce(); }, 60000);
  } else {
    await doOnce();
  }
}

main();
DNSBOOT_EOF
        chmod +x "$dnsboot"
        info "dns-bootstrap.js 已写入: $dnsboot"

        node "$dnsboot" || warn "当前网络 DNS 全部不可用 (53 被拦截?), 已回退公共 DNS 写入 resolv.conf"
        info "如需原生直跑方案, 请在 Magisk 中授权 Termux 后重跑本脚本"
        return
    fi

    ok "root 可用, 使用 dns53 原生方案"
    cat > "$dns53" << 'DNS53_EOF'
#!/usr/bin/env node
// dns53 — 本地 DNS 转发器 (127.0.0.1:53)
// 背景: musl 程序 (codex/opencode) 解析器读不到 /etc/resolv.conf (Android 没有),
//       回退到默认 127.0.0.1:53, 而手机上没人监听该端口 → DNS 卡死 → 5s 超时。
// 方案: 在 127.0.0.1:53 上监听 UDP, 优先转发到手机当前使用的 DNS (延迟更低),
//       再依次回退到公共 DNS (IPv4: 阿里/腾讯/114; IPv6: 阿里/CNNIC/移动), 回传响应。
// 运行: sudo node dns53.js  (53 是特权端口)
const dgram = require('dgram');
const fs = require('fs');
const { execFileSync } = require('child_process');

// 公共兜底 DNS (手机 DNS 探测缺失时使用): IPv4 与 IPv6 各自独立
const PUBLIC_DNS4 = [
  ['223.5.5.5', 53],      // 阿里
  ['119.29.29.29', 53],   // 腾讯
  ['114.114.114.114', 53],// 114
];
const PUBLIC_DNS6 = [
  ['2400:3200::1', 53],   // 阿里 IPv6
  ['2402:4e00::', 53],    // 腾讯 DNSPod IPv6
  ['2408:8899::8', 53],   // 移动 IPv6
];
const TIMEOUT_MS = 1500;
// AAAA 屏蔽开关 (默认开启): 屏蔽后客户端只走 IPv4,
// 避免境外 IPv6 不可达导致连接卡死 (如 OpenAI 域名)。
// 境内 IPv6 可用时, 可设 DNS53_DISABLE_AAAA=0 关闭屏蔽。
const DISABLE_AAAA = process.env.DNS53_DISABLE_AAAA !== '0';
// 固定路径: sudo 运行时 HOME 会变成 .suroot, 不能用 HOME 推导
const LOG = process.env.DNS53_LOG || '/data/data/com.termux/files/home/.codex/dns53.log';
const log = (m) => {
  try {
    fs.appendFileSync(LOG, `${new Date().toISOString()} ${m}\n`);
  } catch (_) {}
};
// 日志轮转: 超过 2MB 截掉前半 (调试期高频查询日志会涨)
function rotateLog() {
  try {
    const st = fs.statSync(LOG);
    if (st.size > 2 * 1024 * 1024) {
      const content = fs.readFileSync(LOG, 'utf8');
      fs.writeFileSync(LOG, content.slice(Math.floor(content.length / 2)));
      log('LOG ROTATED');
    }
  } catch (_) {}
}
setInterval(rotateLog, 60000);

let UPSTREAMS = [...PUBLIC_DNS4, ...PUBLIC_DNS6];

// 探测手机当前 DNS: 同时收集 IPv4 与 IPv6 (优先默认网络)
function discoverPhoneDns() {
  const v4 = [];
  const v6 = [];
  try {
    // 老版本 Android: getprop net.*.dnsN
    const props = execFileSync('/system/bin/getprop', [], { encoding: 'utf8', timeout: 3000 });
    for (const line of props.split('\n')) {
      const m = line.match(/^\[net\.\S+\.dns\d+\]:\s*\[([0-9a-fA-F:.]+)\]/);
      if (m) {
        if (m[1].includes(':')) v6.push(m[1]); else v4.push(m[1]);
      }
    }
  } catch (_) {}
  if (v4.length === 0 && v6.length === 0) {
    try {
      // 现代 Android: dumpsys connectivity 的 DnsAddresses。
      // 优先默认网络 (TRANSPORT_PRIMARY), 再收集所有 INTERNET+VALIDATED 网络,
      // 避免个别机型/网络下主网络块 DnsAddresses 为空时拿不到 DNS。
      const out = execFileSync('/system/bin/dumpsys', ['connectivity'], { encoding: 'utf8', timeout: 5000 });
      const blocks = out.split('NetworkAgentInfo{').slice(1);
      const scored = [];
      for (const b of blocks) {
        const dm = b.match(/DnsAddresses:\s*\[([^\]]*)\]/);
        if (!dm) continue;
        const a4 = [];
        const a6 = [];
        for (const token of dm[1].split(/[\s,]+/)) {
          const ip = token.replace(/^\//, '');
          if (!ip) continue;
          if (/^\d{1,3}(?:\.\d{1,3}){3}$/.test(ip)) a4.push(ip);
          else if (/^[0-9a-fA-F:.]+$/.test(ip) && ip.includes(':')) a6.push(ip);
        }
        if (!a4.length && !a6.length) continue;
        const score = (b.includes('TRANSPORT_PRIMARY') ? 0 : 1) + (b.includes('INTERNET') && b.includes('VALIDATED') ? 0 : 2);
        scored.push([score, a4, a6]);
      }
      scored.sort((a, b) => a[0] - b[0]);
      for (const [, a4, a6] of scored) {
        v4.push(...a4);
        v6.push(...a6);
      }
    } catch (_) {}
  }
  return {
    v4: [...new Set(v4)].filter((ip) => ip !== '127.0.0.1' && ip !== '0.0.0.0'),
    v6: [...new Set(v6)].filter((ip) => ip !== '::1' && ip !== '::'),
  };
}

// 刷新上游: 手机 DNS 在前 (v4/v6 各自), 公共 DNS 兜底 (每分钟一次, 网络切换后自动跟随)
function refreshDns() {
  const phone = discoverPhoneDns();
  if (phone.v4.length === 0 && phone.v6.length === 0) return;
  const merged = [];
  const add = (ip) => {
    if (!merged.some((s) => s[0] === ip)) merged.push([ip, 53]);
  };
  for (const ip of [...phone.v4, ...PUBLIC_DNS4.map((s) => s[0])]) add(ip);
  for (const ip of [...phone.v6, ...PUBLIC_DNS6.map((s) => s[0])]) add(ip);
  if (JSON.stringify(merged) !== JSON.stringify(UPSTREAMS)) {
    UPSTREAMS = merged;
    log(`dns servers: ${merged.map((s) => s[0]).join(', ')}`);
  }
}

// 连续空应答计数: 记录各上游的连续"被过滤"次数, 达到阈值后降级到底部
const strikes = new Map();
const MAX_STRIKES = 3;

// 判断应答是否有效: 返回 true = 应答异常, 应换下一个上游。
// 覆盖: 报文过短 / SERVFAIL / A 查询 rcode=0 但答案为空 / A 查询只回 CNAME 没给 A
//       (中国 ISP DNS 常见过滤手法: 剥离 CNAME 链末端的地址记录)。
// 注意: AAAA 查询 (qtype=28) 一律放行 —— 域名没有 IPv6 记录时 NOERROR+0 答案、
//       部分上游对 AAAA 返回 NOTIMP 都是正常现象, 应由客户端自行回退 A 记录。
function isBadResponse(resp, qtype) {
  if (resp.length < 12) return true;
  const flags = resp.readUInt16BE(2);
  const rcode = flags & 0x0f;
  if (rcode === 2) return true; // SERVFAIL
  if (qtype === 28) return false; // AAAA: 空/NOTIMP/CNAME-only 均合法, 不判坏
  if (rcode !== 0 && rcode !== 3) return true; // NOTIMP/REFUSED 等 → 判坏换上游
  const qd = resp.readUInt16BE(4);
  const an = resp.readUInt16BE(6);
  if (an === 0) return true; // A 查询 rcode=0 但无任何答案 = 被过滤
  if (qtype !== 1) return false; // 非 A 查询, 只做基本校验
  // 逐条解析答案区, 看是否含有 A 记录
  let off = 12;
  const skipName = (p) => {
    let hops = 0;
    while (off < p.length && p[off] !== 0) {
      if ((p[off] & 0xc0) === 0xc0) { off += 2; return; }
      off += p[off] + 1;
      if (++hops > 32) break;
    }
    off++;
  };
  for (let i = 0; i < qd && off < resp.length; i++) { skipName(resp); off += 4; }
  for (let i = 0; i < an && off + 10 <= resp.length; i++) {
    skipName(resp);
    const type = resp.readUInt16BE(off);
    const len = resp.readUInt16BE(off + 8);
    off += 10 + len;
    if (type === 1) return false; // 找到 A 记录, 应答有效
  }
  return true; // A 查询答案区只有 CNAME/NS 等, 没有地址记录
}

// 降级: 把 host 移到列表末尾, 下次刷新会按新的手机 DNS 顺序重建
function demote(host) {
  const idx = UPSTREAMS.findIndex((s) => s[0] === host);
  if (idx > 0) {
    const [s] = UPSTREAMS.splice(idx, 1);
    UPSTREAMS.push(s);
    log(`demoted bad upstream ${host}`);
  }
}

// 从查询报文解析 qtype (跳过问题名, 不受 EDNS 附加区影响)
function queryType(msg) {
  if (msg.length < 16) return 0;
  let off = 12;
  let hops = 0;
  while (off < msg.length && msg[off] !== 0) {
    if ((msg[off] & 0xc0) === 0xc0) return 0; // 压缩指针不出现于查询
    off += msg[off] + 1;
    if (++hops > 32) return 0;
  }
  if (off >= msg.length) return 0;
  off++; // root label
  if (off + 4 > msg.length) return 0;
  return (msg[off] << 8) | msg[off + 1];
}

// 从查询报文解析域名 (与 queryType 共用同一套偏移, 保证一致性)
function queryName(msg) {
  if (msg.length < 12) return null;
  let off = 12;
  let name = '';
  while (off < msg.length && msg[off] !== 0) {
    const len = msg[off++];
    if (off + len > msg.length) return null;
    name += (name ? '.' : '') + msg.slice(off, off + len).toString();
    off += len;
  }
  if (off >= msg.length) return null;
  return name;
}

// IPv6 地址字符串 → 16 字节 (处理 :: 简写与 IPv4 内嵌)
function ipv6ToBytes(ip) {
  const buf = Buffer.alloc(16);
  const v4m = ip.match(/(.*):([0-9.]+)$/);
  let head, tail;
  if (v4m && v4m[2].includes('.')) {
    head = v4m[1]; tail = v4m[2].split('.').map(Number);
  } else {
    head = ip; tail = [];
  }
  const [hs, ts] = head.split('::');
  let h = hs ? hs.split(':').filter(Boolean) : [];
  const t = ts ? ts.split(':').filter(Boolean) : [];
  while (h.length + t.length + (tail.length ? 2 : 0) < 8) h.push('0');
  const all = h.concat(t);
  all.forEach((part, i) => { if (part !== undefined) buf.writeUInt16BE(parseInt(part, 16) || 0, i * 2); });
  if (tail.length) {
    tail.forEach((b, i) => { buf.writeUInt8(b, 12 + i); });
  }
  return buf;
}

// 构造 DNS 应答: 复用客户端查询报文, 填上答案
function buildResponse(msg, answers) {
  const qnameLen = msg.length - 12;
  const resp = Buffer.alloc(12 + qnameLen + answers.length * 16);
  msg.copy(resp, 0, 0, 12 + qnameLen);
  resp[2] |= 0x80; // QR
  resp[3] |= 0x80; // RA
  resp[6] = answers.length >> 8; resp[7] = answers.length & 0xff;
  let off = 12 + qnameLen;
  for (const a of answers) {
    resp.writeUInt16BE(0xc00c, off); off += 2; // 指针 → 问题名
    resp.writeUInt16BE(a.type, off); off += 2;
    resp.writeUInt16BE(1, off); off += 2;      // IN
    resp.writeUInt32BE(60, off); off += 4;     // TTL
    if (a.type === 1) {
      resp.writeUInt16BE(4, off); off += 2;
      for (const b of a.ip.split('.').map(Number)) resp.writeUInt8(b, off++);
    } else {
      resp.writeUInt16BE(16, off); off += 2;
      ipv6ToBytes(a.ip).copy(resp, off); off += 16;
    }
  }
  return resp;
}

const netd = require('dns'); // node 内置解析 (走 bionic/netd, 不受 UDP 53 封锁影响)

// 最后兜底: UDP 上游失败时, 用系统解析 (netd) 回答 (onDone 通知调用方)
function netdFallback(msg, rinfo, qtype, onDone, qid) {
  const host = queryName(msg);
  if (!host || (qtype !== 1 && qtype !== 28)) {
    log(`netd fallback q${qid}: unsupported query (qtype=${qtype})`);
    if (onDone) onDone();
    return;
  }
  const family = qtype === 1 ? 4 : 6;
  const t1 = Date.now();
  netd.lookup(host, { family, timeout: 5000 }, (err, ip) => {
    if (onDone) onDone();
    if (err) {
      // NXDOMAIN 或解析失败: 回 rcode=3 (合法应答, 客户端正常处理)
      const resp = Buffer.alloc(12 + msg.length - 12);
      msg.copy(resp, 0, 0, msg.length);
      resp[2] |= 0x80; // QR
      resp[3] = (resp[3] & 0x70) | 0x80 | 0x03; // RA + rcode=NXDOMAIN
      server.send(resp, rinfo.port, rinfo.address);
      log(`netd fallback q${qid} ${host} → NXDOMAIN/err ${err.code || err.message} (${Date.now() - t1}ms)`);
      return;
    }
    const resp = buildResponse(msg, [{ type: qtype, ip }]);
    server.send(resp, rinfo.port, rinfo.address);
    log(`netd fallback q${qid} ${host} → ${ip} (${family === 4 ? 'A' : 'AAAA'}) ${Date.now() - t1}ms`);
  });
}

const server = dgram.createSocket('udp4');

server.on('message', (msg, rinfo) => {
  const qtype = queryType(msg);
  const qid = msg.readUInt16BE(0).toString(16);
  const qhost = queryName(msg) || '?';
  const t0 = Date.now();
  log(`>> q${qid} ${qhost} type=${qtype === 1 ? 'A' : qtype === 28 ? 'AAAA' : qtype} from ${rinfo.address}`);
  // AAAA 屏蔽: 直接回 NOERROR+0 答案 (合法"无 IPv6 记录"), 不走上游
  if (qtype === 28 && DISABLE_AAAA) {
    const resp = Buffer.alloc(msg.length);
    msg.copy(resp, 0, 0, msg.length);
    resp[2] |= 0x80; // QR
    resp[3] |= 0x80; // RA
    server.send(resp, rinfo.port, rinfo.address);
    log(`<< q${qid} ${qhost} AAAA suppressed (IPv6 disabled) ${Date.now() - t0}ms`);
    return;
  }
  let done = false;
  let netdStarted = false;
  // 任一上游失败 → 立即启动 netd 兜底 (netd 与上游竞争, 先回先赢, done 防双发)
  const startNetd = () => {
    if (netdStarted || done) return;
    netdStarted = true;
    log(`>> q${qid} netd fallback started (${Date.now() - t0}ms in)`);
    netdFallback(msg, rinfo, qtype, () => { done = true; }, qid);
  };
  let i = 0;
  const tryNext = () => {
    if (done) return;
    if (i >= UPSTREAMS.length) { startNetd(); return; }
    const [host, port] = UPSTREAMS[i++];
    const t1 = Date.now();
    const tag = `q${qid}->${host}`;
    const sock = dgram.createSocket(host.includes(':') ? 'udp6' : 'udp4');
    let doneHere = false;
    const finish = (fn) => {
      if (doneHere) return;
      doneHere = true;
      clearTimeout(timer);
      sock.close();
      fn();
    };
    const timer = setTimeout(() => finish(() => { log(`timeout ${tag} (${Date.now() - t1}ms)`); startNetd(); }), TIMEOUT_MS);
    sock.on('message', (resp) => {
      if (doneHere) return;
      if (isBadResponse(resp, qtype)) {
        finish(() => {
          const n = (strikes.get(host) || 0) + 1;
          strikes.set(host, n);
          if (n >= MAX_STRIKES) { strikes.delete(host); demote(host); }
          log(`bad response ${tag} (${Date.now() - t1}ms, strike ${n}/${MAX_STRIKES})`);
          startNetd();
        });
        return;
      }
      finish(() => {
        if (strikes.has(host)) strikes.delete(host);
        done = true;
        server.send(resp, rinfo.port, rinfo.address);
        log(`<< q${qid} ${qhost} OK via ${host} (${Date.now() - t1}ms, total ${Date.now() - t0}ms)`);
      });
    });
    sock.on('error', (e) => finish(() => { log(`error ${tag}: ${e.message} (${Date.now() - t1}ms)`); startNetd(); }));
    sock.send(msg, port, host, (e) => {
      if (e) finish(() => { log(`send error ${tag}: ${e.message}`); startNetd(); });
    });
  };
  tryNext();
});

server.on('error', (e) => {
  log(`server error: ${e.message}`);
  if (process.stderr.isTTY) console.error(`dns53 server error: ${e.message}`);
  // 端口被占等致命错误: 占着没意义, 直接退出 (避免僵尸进程)
  process.exit(1);
});
server.bind(53, '127.0.0.1', () => {
  refreshDns();
  log('dns53 listening on 127.0.0.1:53');
  if (process.stdout.isTTY) console.log('dns53 listening on 127.0.0.1:53');
  setInterval(refreshDns, 60000);
});

DNS53_EOF
    chmod +x "$dns53"
    info "dns53.js 已更新: $dns53"
    cat > "$HOME_DIR/.local/bin/dns53-aaaa" << 'AAAA_EOF'
#!/data/data/com.termux/files/usr/bin/bash
# dns53-aaaa — 一键切换 dns53 的 AAAA 屏蔽
# 用法: dns53-aaaa on|off|status
set -euo pipefail

D53="$HOME/.local/bin/dns53.js"
LOG="$HOME/.codex/dns53.log"

get_pid() {
  sudo -n pgrep -f '^node .*dns5[3]\.js' 2>/dev/null | head -1
}

show_status() {
  local pid mode
  pid=$(get_pid)
  if [ -z "$pid" ]; then
    echo "dns53 未运行"
    return
  fi
  mode=$(sudo -n cat "/proc/$pid/environ" 2>/dev/null | tr '\0' '\n' | sed -n 's/^DNS53_DISABLE_AAAA=//p')
  if [ "$mode" = "0" ]; then
    echo "关闭（放行 AAAA/IPv6）| PID $pid"
  else
    echo "开启（屏蔽 AAAA，只走 IPv4）| PID $pid"
  fi
}

restart() {
  local val="$1" label="$2"
  sudo -n pkill -f '^node .*dns5[3]\.js' 2>/dev/null || true
  sleep 1
  sudo -n env DNS53_DISABLE_AAAA="$val" nohup node "$D53" > "$LOG" 2>&1 &
  sleep 1
  echo "✓ $label"
  show_status
}

case "${1:-status}" in
  on)  restart 1 "AAAA 屏蔽已开启（默认，只走 IPv4）" ;;
  off) restart 0 "AAAA 屏蔽已关闭（放行 IPv6）" ;;
  status) show_status ;;
  *) echo "用法: dns53-aaaa on|off|status" >&2; exit 1 ;;
esac
AAAA_EOF
    chmod +x "$HOME_DIR/.local/bin/dns53-aaaa"
    info "dns53-aaaa 切换脚本已生成: ~/.local/bin/dns53-aaaa"

    if ! grep -q 'dns53' "$HOME_DIR/.bashrc" 2>/dev/null; then
        cat >> "$HOME_DIR/.bashrc" << 'BASHRC_EOF'

# ===== DNS 转发器常驻 (dns53) =====
# 背景: musl 程序 (codex/opencode) 的解析器读不到 /etc/resolv.conf (Android 没有),
#       回退到 127.0.0.1:53, 而手机无人监听 → DNS 卡死 5s 超时。
# dns53.js 在本机 53 端口监听, 转发到阿里/腾讯/电信 DNS, 是这些程序的唯一出路。
# 每次打开 Termux 终端检查一次, 没在跑就拉起 (root 绑定特权端口)。
if ! sudo -n pgrep -f "dns5[3].js" > /dev/null 2>&1; then
    sudo -n nohup node "$HOME/.local/bin/dns53.js" > "$HOME/.codex/dns53.log" 2>&1 &
    sleep 1
fi
BASHRC_EOF
        info "dns53 常驻逻辑已写入 ~/.bashrc"
    fi

    if ! sudo -n pgrep -f "dns5[3].js" > /dev/null 2>&1; then
        sudo -n nohup node "$dns53" > "$HOME_DIR/.codex/dns53.log" 2>&1 &
        sleep 1
        ok "DNS 转发器已启动 (127.0.0.1:53)"
    else
        ok "DNS 转发器已在运行"
    fi

    # 诊断工具
    local dnsq="$HOME_DIR/.local/bin/dnsq.js"
    local check="$HOME_DIR/.check_dns.sh"
    cat > "$dnsq" << 'DNSQ_EOF'
#!/usr/bin/env node
// dnsq.js — 经 127.0.0.1:53 (dns53 转发链) 查询域名 A 记录
// 用法: node dnsq.js <host>
const { Resolver } = require('dns').promises;
const host = process.argv[2];
if (!host) { console.error('usage: node dnsq.js <host>'); process.exit(2); }
const r = new Resolver({ servers: ['127.0.0.1'], timeout: 3000, retries: 0 });
const t0 = Date.now();
r.resolve4(host).then((ips) => {
  console.log(`  ${host} → OK IPs=[${ips.join(',')}] (${Date.now() - t0}ms)`);
  process.exit(0);
}).catch((e) => {
  console.log(`  ${host} → ★ ${e.code || 'ERR'} (${Date.now() - t0}ms)`);
  process.exit(1);
});
DNSQ_EOF
    cat > "$check" << 'CHECK_EOF'
#!/usr/bin/env bash
# check_dns.sh — 一键判断"DNS 问题 vs 网络/服务器问题"
# 用法: bash ~/.check_dns.sh [域名...]
DNSQ=/data/data/com.termux/files/home/.local/bin/dnsq.js
LOG=/data/data/com.termux/files/home/.codex/dns53.log
HOSTS=(api.deepseek.com api.anthropic.com opencode.ai www.baidu.com)
[ $# -gt 0 ] && HOSTS=("$@")

echo "═══ 诊断 $(date '+%F %T') ═══"

echo "── dns53 状态 ──"
if sudo -n ss -ulnp 2>/dev/null | grep -q "127.0.0.1:53"; then
  echo "运行中"
else
  echo "★ 未运行! 请重开终端或手动: sudo nohup node ~/.local/bin/dns53.js &"
fi
grep 'dns servers:' "$LOG" 2>/dev/null | tail -1 || echo "(无日志)"

echo "── 域名解析 (经 127.0.0.1:53 / dns53 转发) ──"
for h in "${HOSTS[@]}"; do
  timeout 6 node "$DNSQ" "$h" || true
done

echo "── HTTPS 连通性 ──"
for u in https://api.deepseek.com/v1 https://api.anthropic.com/v1 https://opencode.ai https://www.baidu.com; do
  printf "  %s → " "$u"
  curl -s -o /dev/null -w "%{http_code} %{time_total}s\n" --max-time 8 "$u" || echo "★ 超时/失败"
done

echo "── 最近 12 条 dns53 日志 ──"
tail -12 "$LOG" 2>/dev/null || echo "无日志文件"
CHECK_EOF
    chmod +x "$dnsq" "$check"
    ok "诊断工具已安装: ~/.check_dns.sh (用法: bash ~/.check_dns.sh)"
}

# ---------- 安装官方 OpenCode ----------
install_opencode() {
    info "查询最新版本 (opencode.ai API, npm 兜底)…"
    local version=""
    version=$(oc_latest_version) || true
    [ -n "$version" ] || fail "无法获取最新版本 (网络问题?)"
    info "最新版本: $version"

    local installed=""
    [ -f "$VERSION_FILE" ] && installed=$(cat "$VERSION_FILE" 2>/dev/null || true)
    if [ -x "$REAL_BIN" ] && [ "$installed" = "$version" ]; then
        ok "已是最新版本 $version, 跳过下载"
        return
    fi

    local work
    work=$(mktemp -d "${TMPDIR:-$PREFIX/tmp}/opencode.XXXXXX")
    # 双引号: 路径在设置时立即展开成字面量。
    # 单引号版本会在函数返回时才求值, 而 RETURN trap 会泄漏到调用方
    # (调用方返回时再次触发), 那时 $work 已出作用域 → set -u 报 unbound variable。
    trap "rm -rf '$work'" RETURN
    info "下载 $NPM_PKG v$version (约 96MB 包 / 206MB 二进制)…"
    download_tgz "$version" "$work/cli.tgz" || fail "下载失败 (npm 与各镜像均不可用)"

    tar xzf "$work/cli.tgz" -C "$work" || fail "解压失败"
    # V2 的 tarball 内路径是 package/bin/opencode
    local new_bin="$work/package/bin/opencode"
    [ -f "$new_bin" ] || fail "tarball 内未找到 package/bin/opencode"
    chmod +x "$new_bin"

    info "patchelf: interpreter → $INTERP"
    patchelf --set-interpreter "$INTERP" "$new_bin" || fail "patchelf interpreter 失败"
    info "patchelf: rpath → $RPATH"
    patchelf --set-rpath "$RPATH" "$new_bin" || fail "patchelf rpath 失败"

    # 验证能跑才替换。
    # 无 root 时 musl 二进制会被 Android seccomp 拦截 (Bad system call /
    # Segmentation fault), 必须走 proot。按顺序尝试:
    #   1) 原生直跑 (有 root / 内核允许时可用)
    #   2) proot + 绑定 resolv.conf (仅当该文件存在 —— 不存在时 proot -b 会直接失败)
    #   3) proot 不绑定 (降级)
    # 全部失败时把真实输出打出来, 否则只剩一句"验证失败"没法排查。
    local verify_log="$work/verify.log"
    local verify_ok=0
    # 内核 >= 5.11 时连原生直跑都会段错误 (Bun epoll_pwait2), 直接用 proot -k 5.10.0
    if kernel_needs_proot; then
        info "内核 $(uname -r) >= 5.11: 用 proot -k 5.10.0 规避 Bun 的 epoll_pwait2 崩溃"
    else
        env -u LD_PRELOAD "SSL_CERT_FILE=${SSL_CERT_FILE:-$PREFIX/etc/tls/cert.pem}" \
            "$new_bin" --version >"$verify_log" 2>&1 && verify_ok=1
    fi
    if [ "$verify_ok" -eq 0 ] && command -v proot >/dev/null 2>&1; then
        proot_run "$new_bin" --version >"$verify_log" 2>&1 && verify_ok=1
    fi
    if [ "$verify_ok" -ne 1 ]; then
        warn "新二进制无法运行 (proot: $(command -v proot >/dev/null 2>&1 && echo 有 || echo 无), 内核: $(uname -r)), 最后一次尝试的输出:"
        sed 's/^/    /' "$verify_log" 2>/dev/null | head -20
        [ -f "${PREFIX}/etc/resolv.conf" ] || warn "缺少 ${PREFIX}/etc/resolv.conf (dns-bootstrap 未成功写入?)"
        fail "新二进制验证失败 (无 root 请确保已安装 proot), 已放弃替换"
    fi

    mkdir -p "$OPENCODE_DIR"
    mv -f "$new_bin" "$REAL_BIN"
    chmod +x "$REAL_BIN"
    echo "$version" > "$VERSION_FILE"
    ok "OpenCode $version 已安装"
}

# ---------- 启动 wrapper ----------
write_wrapper() {
    mkdir -p "$HOME_DIR/.local/bin"
    cat > "$WRAPPER_PATH" << 'WRAPPER_EOF'
#!/data/data/com.termux/files/usr/bin/bash
# ============================================================
# opencode wrapper for Termux (OpenCode V2)
# ~/.local/bin/opencode
#
# Official OpenCode V2 musl build (npm: @opencode/cli-linux-arm64-musl), patched:
#   interpreter → Termux musl loader (ld-musl-aarch64.so.1)
#   rpath       → Termux musl libs (libstdc++, libgcc_s)
#
# Usage:
#   opencode [args...]          run opencode (patched); 启动前自动
#                               检查最新版本, 非最新则自动更新再启动
#   opencode update [--force]   重新下载官方包 → patchelf → 验证 → 原子换入
#   opencode upgrade            同 update (这两个子命令由本 wrapper 接管,
#                               否则官方会用它自己的二进制覆盖我们打过补丁
#                               的那份, 导致再次无法运行)
#
# Env:
#   OPENCODE_NO_AUTO_UPDATE=1   skip auto-update check on startup
# ============================================================
set -euo pipefail

PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
HOME_DIR="$HOME"
BIN_DIR="$HOME_DIR/.local/opencode"
REAL_BIN="$BIN_DIR/opencode"
VERSION_FILE="$BIN_DIR/.version"
INTERP="$PREFIX/lib/ld-musl-aarch64.so.1"
RPATH="$PREFIX/lib/musl"
# V2 起官方走 npm 分发 (不再是 GitHub Releases)
NPM_PKG="@opencode/cli-linux-arm64-musl"
UPDATE_API="https://opencode.ai/update/api/latest/cli/npm"

export SSL_CERT_FILE="${SSL_CERT_FILE:-$PREFIX/etc/tls/cert.pem}"
# V2 自带自动更新: 它会下载官方原始二进制直接替换, 而那份没有经过
# patchelf (interpreter 还是 /lib/ld-musl-aarch64.so.1) → 在 Termux 上又跑不起来。
# 所以关掉官方的, 统一由本 wrapper 接管: opencode update
export OPENCODE_DISABLE_AUTOUPDATE=1

# termux-exec's LD_PRELOAD hook lib is Bionic-compiled; the musl
# dynamic linker can't relocate it. opencode doesn't need it.
unset LD_PRELOAD

# 官方 API: {"channel":"latest",...,"version":"2.0.32",...}; 失败再用 npm view。
# 参数: $1 = API 超时(默认20)
latest_version() {
    local timeout="${1:-20}" v=""
    v="$(curl -fsSL --max-time "$timeout" "$UPDATE_API" 2>/dev/null \
        | sed -n 's/.*"version":"\([^"]*\)".*/\1/p' | head -1)" || v=""
    if [ -z "$v" ]; then
        v="$(npm view @opencode/cli version --fetch-timeout=10000 --fetch-retries=0 2>/dev/null | tail -1)" || v=""
    fi
    printf '%s' "$v"
}

# $1=版本 → 两个候选直连 URL (npm view 不可用时的兜底)
fallback_tarball_urls() {
    local name="${NPM_PKG##*/}" scope="${NPM_PKG%/*}"
    printf 'https://registry.npmmirror.com/%s/%s/-/%s-%s.tgz\n' "$scope" "$name" "$name" "$1"
    printf 'https://registry.npmjs.org/%s/%s/-/%s-%s.tgz\n' "$scope" "$name" "$name" "$1"
}

# $1=版本 $2=输出文件: 带进度条下载, 失败自动换镜像
download_asset() {
    local ver="$1" out="$2" url="" alt="" u
    url="$(npm view "$NPM_PKG@$ver" dist.tarball 2>/dev/null | tail -1)" || url=""
    if [ -n "$url" ]; then
        curl -fSL --progress-bar --connect-timeout 15 --max-time 900 "$url" -o "$out" && return 0
        case "$url" in
            *registry.npmjs.org*)     alt="${url/registry.npmjs.org/registry.npmmirror.com}" ;;
            *registry.npmmirror.com*) alt="${url/registry.npmmirror.com/registry.npmjs.org}" ;;
        esac
        if [ -n "$alt" ] && [ "$alt" != "$url" ]; then
            echo "!! 直连失败, 换镜像重试…" >&2
            curl -fSL --progress-bar --connect-timeout 15 --max-time 900 "$alt" -o "$out" && return 0
        fi
    fi
    while read -r u; do
        curl -fSL --progress-bar --connect-timeout 15 --max-time 900 "$u" -o "$out" && return 0
    done < <(fallback_tarball_urls "$ver")
    return 1
}

# 运行 opencode 二进制。优先级:
#   1) 内核 >= 5.11 → 必须 proot -k 5.10.0 (Bun epoll_pwait2 会段错误,
#      这条优先于 root —— 即使有 root, 原生直跑同样会崩)
#   2) 有 root → 原生直跑
#   3) 无 root → proot (seccomp 会拦 musl 的系统调用)
run_opencode() {
    local bin="$1"; shift
    local _env="env -u LD_PRELOAD SSL_CERT_FILE=${SSL_CERT_FILE:-$PREFIX/etc/tls/cert.pem}"
    if kernel_needs_proot && command -v proot >/dev/null 2>&1; then
        proot_run "$bin" "$@"
    elif command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
        $_env "$bin" "$@"
    elif command -v proot >/dev/null 2>&1; then
        proot_run "$bin" "$@"
    else
        $_env "$bin" "$@"
    fi
}

# Bun 编译的二进制在"报告的内核 >= 5.11"时走 epoll_pwait2, 该 syscall 返回
# ENOSYS 时 Bun 无兜底 → 空指针段错误 (bun#32489), 现象:
#   proot info: vpid 1: terminated with signal 11
# 规避: proot -k 5.10.0 把看到的内核降到 5.10 → Bun 退回 epoll_pwait。
kernel_needs_proot() {
    local maj min
    maj="$(uname -r | cut -d. -f1 | tr -dc '0-9')"
    min="$(uname -r | cut -d. -f2 | tr -dc '0-9')"
    [ -z "$maj" ] && return 1
    [ "$maj" -gt 5 ] && return 0
    if [ "$maj" -eq 5 ] && [ -n "$min" ] && [ "$min" -ge 11 ]; then return 0; fi
    return 1
}

# 同上: -k 只改 uname, /proc/sys/kernel/osrelease 得靠绑定假文件一起喂
fake_osrelease() {
    local f="$BIN_DIR/.fake-osrelease"
    mkdir -p "$BIN_DIR" 2>/dev/null || return 0
    printf '5.10.0\n' >"$f" 2>/dev/null || return 0
    printf '%s' "$f"
}

# $1=二进制, 其余=参数: proot -k 5.10.0 (+ 伪 osrelease, + resolv.conf 存在时绑定)
proot_run() {
    local bin="$1"; shift
    local opts=(-k 5.10.0)
    local fake
    fake="$(fake_osrelease)"
    if [ -n "$fake" ] && [ -f "$fake" ]; then
        opts+=(-b "$fake:/proc/sys/kernel/osrelease")
    fi
    if [ -f "${PREFIX}/etc/resolv.conf" ]; then
        opts+=(-b "${PREFIX}/etc/resolv.conf:/etc/resolv.conf")
    fi
    proot "${opts[@]}" env -u LD_PRELOAD "SSL_CERT_FILE=${SSL_CERT_FILE:-$PREFIX/etc/tls/cert.pem}" "$bin" "$@"
}

# 本地已记录版本; 无记录时从二进制本身探测 (可能为空)
current_version() {
    if [ -f "$VERSION_FILE" ]; then
        cat "$VERSION_FILE"
    else
        run_opencode "$REAL_BIN" --version 2>/dev/null \
            | grep -oE '[0-9]+(\.[0-9]+){1,3}' | head -n1 || true
    fi
}

# 版本比较: 去掉 v 前缀, $1 >= $2 返回 0
version_ge() {
    local a="${1#v}" b="${2#v}"
    [ "$(printf '%s\n%s\n' "$a" "$b" | sort -V | tail -n1)" = "$a" ]
}

# 下载 → 解压 → patchelf → 验证 → 原子换入。失败返回 1 (保留旧二进制)。
do_update() {
    local VERSION="$1"
    echo "==> 下载 $NPM_PKG v$VERSION (约 96MB 包 / 206MB 二进制) …"
    local TMP
    TMP="$(mktemp -d "${TMPDIR:-$HOME}/.opencode-update.XXXXXX")" || return 1
    # 同上: 双引号立即展开路径, 避免 RETURN trap 泄漏到调用方后 $TMP 未绑定
    trap "rm -rf '$TMP'" RETURN
    if ! download_asset "$VERSION" "$TMP/cli.tgz"; then
        echo "!! 下载失败(npm 与各镜像均不可用)" >&2
        return 1
    fi

    if ! tar xzf "$TMP/cli.tgz" -C "$TMP"; then
        echo "!! 解压失败" >&2
        return 1
    fi
    # V2 的 tarball 内路径是 package/bin/opencode
    local NEW_BIN="$TMP/package/bin/opencode"
    [ -f "$NEW_BIN" ] || { echo "!! tarball 内未找到 package/bin/opencode" >&2; return 1; }
    chmod +x "$NEW_BIN"
    echo "==> patchelf: interpreter + rpath …"
    patchelf --set-interpreter "$INTERP" "$NEW_BIN" || return 1
    patchelf --set-rpath "$RPATH" "$NEW_BIN" || return 1

    # 验证能跑再替换; 失败则保留旧二进制
    if ! run_opencode "$NEW_BIN" --version >/dev/null 2>&1; then
        echo "!! 新二进制无法运行, 已回滚(旧版保留)" >&2
        return 1
    fi
    mv -f "$NEW_BIN" "$REAL_BIN" || return 1
    chmod +x "$REAL_BIN"
    echo "$VERSION" > "$VERSION_FILE"
    echo "✓ 更新完成: $(run_opencode "$REAL_BIN" --version)"
}

case "${1:-}" in
    --update|-u|update|upgrade)
        FORCE=0
        if [ "${2:-}" = "--force" ] || [ "${2:-}" = "-f" ]; then FORCE=1; fi

        command -v patchelf >/dev/null 2>&1 \
            || { echo "缺少 patchelf: pkg install patchelf" >&2; exit 1; }

        echo "== 检查最新版本 …"
        VERSION="$(latest_version)"
        [ -n "$VERSION" ] || { echo "!! 无法获取最新版本(网络问题?)" >&2; exit 1; }

        CURRENT="$(current_version)"
        if [ "$FORCE" -eq 0 ] && [ -n "$CURRENT" ] && version_ge "$CURRENT" "$VERSION"; then
            echo "✓ 已是最新 ($CURRENT)"
            exit 0
        fi

        do_update "$VERSION" || exit 1
        ;;
    *)
        # 自动更新: 启动前快速检查最新版本 (短超时, 网络差时静默跳过),
        # 非最新则自动更新; 更新失败不阻塞, 用现有版本启动。
        if [ "${OPENCODE_NO_AUTO_UPDATE:-0}" != "1" ]; then
            LATEST="$(latest_version 10 6)" || true
            if [ -n "$LATEST" ]; then
                CURRENT="$(current_version)"
                if [ -z "$CURRENT" ] || ! version_ge "$CURRENT" "$LATEST"; then
                    echo "→ 检测到新版本 $LATEST (当前 ${CURRENT:-未知}), 自动更新…"
                    if do_update "$LATEST"; then
                        echo "→ 更新完毕, 继续启动 opencode…"
                    else
                        echo "!! 自动更新失败, 继续使用现有版本启动" >&2
                    fi
                fi
            fi
        fi
        # 不想留常驻后台服务时: OPENCODE_STANDALONE=1 自动附加 --standalone
        # (进程内私有服务, 用完就退)。用户自己传过则不重复加。
        if [ "${OPENCODE_STANDALONE:-0}" = "1" ] \
           && ! printf '%s\n' "$@" | grep -qx -- '--standalone'; then
            set -- --standalone "$@"
        fi
        # exec 不能调 bash 函数, 内联 proot 逻辑 (与 run_opencode 同优先级:
        # 内核 >= 5.11 优先走 proot -k 5.10.0, 否则有 root 直跑, 无 root 走 proot)
        if kernel_needs_proot && command -v proot >/dev/null 2>&1; then
            FAKE_OS="$(fake_osrelease)"
            OSOPT=()
            if [ -n "$FAKE_OS" ] && [ -f "$FAKE_OS" ]; then
                OSOPT=(-b "$FAKE_OS:/proc/sys/kernel/osrelease")
            fi
            if [ -f "${PREFIX}/etc/resolv.conf" ]; then
                exec proot -k 5.10.0 "${OSOPT[@]}" \
                    -b "${PREFIX}/etc/resolv.conf:/etc/resolv.conf" "$REAL_BIN" "$@"
            else
                exec proot -k 5.10.0 "${OSOPT[@]}" "$REAL_BIN" "$@"
            fi
        elif command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
            exec "$REAL_BIN" "$@"
        elif command -v proot >/dev/null 2>&1; then
            if [ -f "${PREFIX}/etc/resolv.conf" ]; then
                exec proot -b "${PREFIX}/etc/resolv.conf:/etc/resolv.conf" "$REAL_BIN" "$@"
            else
                exec proot "$REAL_BIN" "$@"
            fi
        else
            exec "$REAL_BIN" "$@"
        fi
        ;;
esac
WRAPPER_EOF
    chmod +x "$WRAPPER_PATH"

    if ! grep -q '\.local/bin' "$HOME_DIR/.bashrc" 2>/dev/null; then
        echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$HOME_DIR/.bashrc"
        info "~/.local/bin 已加入 PATH (~/.bashrc)"
    fi

    # PATH 陷阱: 官方安装脚本 (opencode.ai/install) 创建的 ~/.opencode/bin
    # 排在 PATH 前面, 里面可能是跑不起来的 glibc 版; 换成 wrapper 副本
    if [ -d "$HOME_DIR/.opencode/bin" ]; then
        if [ -x "$HOME_DIR/.opencode/bin/opencode" ]; then
            if ! head -1 "$HOME_DIR/.opencode/bin/opencode" | grep -q 'opencode wrapper'; then
                warn "检测到官方脚本残留 (~/.opencode/bin/opencode, 非 wrapper), 替换…"
            fi
            cp "$WRAPPER_PATH" "$HOME_DIR/.opencode/bin/opencode"
            chmod +x "$HOME_DIR/.opencode/bin/opencode"
            info "已同步 wrapper 到 ~/.opencode/bin (PATH 陷阱修复)"
        fi
    fi
    ok "启动 wrapper 已生成: $WRAPPER_PATH"
}

# ---------- 验证 ----------
verify() {
    local ver
    ver=$(PATH="$HOME_DIR/.local/bin:$PATH" "$WRAPPER_PATH" --version 2>/dev/null) \
        || fail "验证失败: opencode 无法运行"
    ok "安装成功: $ver"
}

# ---------- 卸载 ----------
uninstall() {
    warn "将卸载 OpenCode 并移除 wrapper…"
    rm -f "$WRAPPER_PATH"
    rm -rf "$OPENCODE_DIR"
    if [ -d "$HOME_DIR/.opencode/bin" ]; then
        rm -f "$HOME_DIR/.opencode/bin/opencode"
    fi
    ok "已卸载"
    warn "DNS 转发器 (dns53) 已保留 — codex 等其他 musl 程序可能依赖它"
    warn "如需一并移除: rm ~/.local/bin/dns53.js 并删除 ~/.bashrc 中的 dns53 常驻块"
    exit 0
}

# ---------- 配置指引 ----------
show_guide() {
    echo
    echo "=============================================================="
    echo "  安装完成! 下一步: 配置模型"
    echo "=============================================================="
    echo
    echo "  OpenCode 支持 Anthropic 兼容端点 (DeepSeek 提供):"
    echo "    export ANTHROPIC_BASE_URL=https://api.deepseek.com/anthropic"
    echo "    export ANTHROPIC_AUTH_TOKEN=sk-你的APIKey"
    echo "    export ANTHROPIC_MODEL=deepseek-v4-flash"
    echo "    (持久化: 追加到 ~/.bashrc)"
    echo
    echo "  常用命令:"
    echo "    opencode                  启动"
    echo "    opencode update           更新到最新版"
    echo "    opencode update --force   已最新也强制重装"
    echo "    重跑本脚本即更新           (bash <(curl -fsSL …/install.sh))"
    echo "    重跑本脚本 --uninstall    卸载"
    echo
    echo "  官方文档: https://opencode.ai/docs"
    echo "=============================================================="
}

# ---------- 主流程 ----------
case "${1:-}" in
    --uninstall) uninstall ;;
esac

info "opencode-termux 安装脚本 — 仅支持 Termux aarch64"
check_environment
fix_mirror
upgrade_packages
install_dependencies
install_musl_libs
fix_dns
install_opencode
write_wrapper
verify
show_guide
