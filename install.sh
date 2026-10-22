#!/data/data/com.termux/files/usr/bin/bash
# ============================================================
# opencode-termux — 在 Termux (Android aarch64) 上一键安装官方 OpenCode CLI V2
# 方案: 官方 musl 动态链接版 + patchelf 只改 interpreter, 原生直跑 (无需 proot)
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
#   + libstdc++.so.6 + libgcc_s.so.1, 再用 patchelf 只改二进制的一项:
#     interpreter → ~/.local/opencode/ld-musl-aarch64.so.1 (私有 loader 副本)
#   运行库不走 rpath, 由 wrapper 用 LD_LIBRARY_PATH=$PREFIX/lib/musl 提供。
#   改 rpath 会让二进制在无 root 的 Termux 上 SIGSEGV (exit 139), 所以不做。
#
#   DNS: musl 把 "/etc/resolv.conf" 编译死在 loader 里, 而 Android 的 /etc
#   是只读的 /system/etc (没有该文件) → 回退 127.0.0.1:53 无人监听 → 超时。
#   无 root 又不能监听 53 端口。解法: 私有 loader 副本里把该字符串原地改成
#   /sdcard/.oc-resolv (够短且 App 可写), wrapper 每次启动同步真实 DNS 配置。
#   因此安装时必须拿到共享存储权限 (termux-setup-storage 两阶段, 见下)。
#   proot 只作为极端情况的兜底, 正常路径完全不使用。
# ============================================================
set -euo pipefail

# ---------- 常量 ----------
PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
HOME_DIR="${HOME:-/data/data/com.termux/files/home}"
OPENCODE_DIR="$HOME_DIR/.local/opencode"
REAL_BIN="$OPENCODE_DIR/opencode"
VERSION_FILE="$OPENCODE_DIR/.version"
MODE_FILE="$OPENCODE_DIR/.mode"   # native (patchelf) / proot-bind
WRAPPER_PATH="$HOME_DIR/.local/bin/opencode"
# 本脚本所在目录: 有本地仓库时优先使用仓库里的 dns53/ 组件
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || true)"
INTERP="$PREFIX/lib/ld-musl-aarch64.so.1"
RPATH="$PREFIX/lib/musl"
# 私有 loader 副本: 唯一目的是把编译死的 "/etc/resolv.conf" 原地改成
# /sdcard/.oc-resolv (Android 上无 root 唯一够短的可写路径)。系统 loader 不动。
MUSL_LOADER="$OPENCODE_DIR/ld-musl-aarch64.so.1"
RESOLV_SRC="$PREFIX/etc/resolv.conf"
RESOLV_SHIM="/sdcard/.oc-resolv"
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

# 不用 patchelf 的备选方案: 二进制保持原样, 由 proot 把 musl 运行库绑定
# 到二进制原本要找的标准路径上。用来绕开 patchelf 0.19.2 把大二进制改坏
# 的问题 (见 install_opencode 里的说明)。
proot_bind_run() {
    local bin="$1"; shift
    local opts=() fake=""
    if kernel_needs_proot; then
        opts+=(-k 5.10.0)
        fake="$(fake_osrelease)"
        if [ -n "$fake" ] && [ -f "$fake" ]; then
            opts+=(-b "$fake:/proc/sys/kernel/osrelease")
        fi
    fi
    opts+=(-b "${INTERP}:/lib/ld-musl-aarch64.so.1")
    if [ -f "${RPATH}/libstdc++.so.6" ]; then
        opts+=(-b "${RPATH}/libstdc++.so.6:/usr/lib/libstdc++.so.6")
    fi
    if [ -f "${RPATH}/libgcc_s.so.1" ]; then
        opts+=(-b "${RPATH}/libgcc_s.so.1:/usr/lib/libgcc_s.so.1")
    fi
    if [ -f "${PREFIX}/etc/resolv.conf" ]; then
        opts+=(-b "${PREFIX}/etc/resolv.conf:/etc/resolv.conf")
    fi
    proot "${opts[@]}" env -u LD_PRELOAD "SSL_CERT_FILE=${SSL_CERT_FILE:-$PREFIX/etc/tls/cert.pem}" "$bin" "$@"
}

# ---------- 私有 musl loader + DNS shim ----------
# musl 的解析器把 "/etc/resolv.conf" 编译死在 loader 里, 而 Android 的 /etc
# 是只读的 /system/etc, 没有该文件 → 回退 127.0.0.1:53 并超时。无 root 又不能
# 监听 53 端口, 所以只改路径: 在 app 私有目录放一份 loader 副本, 把字符串
# 原地替换成 /sdcard/.oc-resolv (字符串后有 6 个 NUL 填充字节, 最长 22 字符;
# app 私有目录的路径都超过这个长度, 所以只能选 /sdcard)。系统 loader 不动。
sync_resolv_shim() {
    [ -f "$RESOLV_SRC" ] || return 0
    cmp -s "$RESOLV_SRC" "$RESOLV_SHIM" 2>/dev/null && return 0
    cp -f "$RESOLV_SRC" "$RESOLV_SHIM" 2>/dev/null || return 1
}

ensure_musl_loader() {
    local src="$INTERP" off
    [ -f "$src" ] || { warn "找不到 musl loader: $src"; return 1; }
    mkdir -p "$OPENCODE_DIR"

    # 系统 loader 升级后自动重建私有副本
    if [ -f "$MUSL_LOADER" ] && \
       [ "$(sha256sum "$MUSL_LOADER" 2>/dev/null | cut -d' ' -f1)" != "$(sha256sum "$src" | cut -d' ' -f1)" ]; then
        rm -f "$MUSL_LOADER"
    fi
    if [ ! -f "$MUSL_LOADER" ]; then
        cp -f "$src" "$MUSL_LOADER" || return 1
        chmod 755 "$MUSL_LOADER"
        off=$(grep -aboF '/etc/resolv.conf' "$MUSL_LOADER" | head -1 | cut -d: -f1)
        [ -n "$off" ] || { rm -f "$MUSL_LOADER"; warn "loader 里找不到 /etc/resolv.conf 字符串"; return 1; }
        printf '%s\0' "$RESOLV_SHIM" | dd of="$MUSL_LOADER" bs=1 seek="$off" conv=notrunc 2>/dev/null || return 1
        grep -qaF "$RESOLV_SHIM" "$MUSL_LOADER" || { rm -f "$MUSL_LOADER"; return 1; }
    fi
    sync_resolv_shim || warn "写不进 $RESOLV_SHIM (存储权限?), DNS 可能不可用"
    return 0
}

# ---------- patchelf 补丁 ----------
# 只改 interpreter, 绝对不要 --set-rpath:
#   rpath + musl + Android 的组合会让这个 206MB 的 Bun 二进制一跑就 SIGSEGV
#   (exit 139; patchelf 0.19.2 / 0.19.1 都一样)。运行库改由 wrapper 用
#   LD_LIBRARY_PATH=$RPATH 提供。
# $1=二进制 $2=未打补丁的原始副本
patch_and_verify() {
    local bin="$1" orig="$2"
    cp -f "$orig" "$bin" || return 1
    patchelf --set-interpreter "$MUSL_LOADER" "$bin" 2>/dev/null || return 1
    env -u LD_PRELOAD "LD_LIBRARY_PATH=$RPATH" \
        "SSL_CERT_FILE=${SSL_CERT_FILE:-$CERT_FILE}" \
        "$bin" --version >/dev/null 2>&1 || return 1
    return 0
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

# $1=版本 $2=输出文件: 带进度条下载; 每次下载后校验完整性, 不通过就换源。
# 背景同 install.sh: registry.npmjs.org 下 96MB 的包会被截断 (实测 4.3MB),
# 而 curl 有时仍以 0 退出 → tar 解出残缺二进制 → patchelf 失败 → 验证时
# 跑坏 ELF 段错误。所以必须校验大小 + gzip -t, 不通过就换源。
download_tgz() {
    local ver="$1" out="$2"
    local expect="" u="" alt="" got="" x="" urls=()
    expect="$(npm view "$NPM_PKG@$ver" dist.size 2>/dev/null | tail -1)" || expect=""
    u="$(npm view "$NPM_PKG@$ver" dist.tarball 2>/dev/null | tail -1)" || u=""
    if [ -n "$u" ]; then
        case "$u" in
            *registry.npmjs.org*)     alt="${u/registry.npmjs.org/registry.npmmirror.com}"
                                      urls+=("$alt" "$u") ;;
            *registry.npmmirror.com*) alt="${u/registry.npmmirror.com/registry.npmjs.org}"
                                      urls+=("$u" "$alt") ;;
            *) urls+=("$u") ;;
        esac
    fi
    while read -r x; do urls+=("$x"); done < <(fallback_tarball_urls "$ver")

    for u in "${urls[@]}"; do
        curl -fSL --progress-bar --connect-timeout 15 --max-time 900 "$u" -o "$out" || continue
        got="$(stat -c%s "$out" 2>/dev/null || echo 0)"
        if [ -n "$expect" ] && [ "$got" != "$expect" ]; then
            echo "!! 下载不完整 (${got} / 期望 ${expect} 字节), 换源重试…" >&2
            continue
        fi
        if ! gzip -t "$out" 2>/dev/null; then
            echo "!! tarball 校验失败 (gzip -t 未通过), 换源重试…" >&2
            continue
        fi
        return 0
    done
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
# 刚装的 Termux 默认官方源, 国内经常慢/不可达。本函数对候选源逐个探测 + 测速,
# 再按"新鲜度优先、速度兜底"选一个自动切换 (幂等; 切换后 apt update 失败会回滚)。
#
# 排序规则 —— 每一条都是实测踩出来的:
#   1) 可用性: HTTP 200 **且 Release 里能解析出 Date: 字段**
#      华为云是反例: /termux/... 路径下 Release 与 Packages 都返回 200, 内容却是
#      一个 12KB 的 HTML 页面。只校验状态码的话它会被算进候选。
#   2) 绝对陈旧: Release 日期距今超过 MIRROR_MAX_AGE 的直接判废。
#      腾讯云实测停留在 4 个月前 (2831 包 vs 官方 3009 包, python 3.13 vs 3.14)。
#   3) 新鲜度优先: Release 日期落后"最新的那个候选"超过 MIRROR_FRESH_GRACE 就不要。
#      实测 2026-10-19 —— 快慢和新鲜度并不一致:
#        官方/清华      python 3.14.8   nodejs 26.4.0-1   patchelf 0.19.2
#        中科大/阿里云  python 3.14.6-1 (其余同上)
#        腾讯云         python 3.13.13  nodejs 26.3.1    patchelf 0.19.0
#      只看速度很容易切到一个包版本偏旧的源。
#   4) 落在宽限窗口内的多个候选 → 选最快的。
MIRROR_FRESH_GRACE="${MIRROR_FRESH_GRACE:-43200}"   # 12 小时
MIRROR_MAX_AGE="${MIRROR_MAX_AGE:-2592000}"         # 30 天

# $1=Release 文件路径 → 输出 Unix 时间戳; 解析不出返回非零
release_ts() {
    local d
    d=$(awk -F': ' '/^Date: /{print $2; exit}' "$1" 2>/dev/null) || d=""
    [ -n "$d" ] || return 1
    date -d "$d" +%s 2>/dev/null || return 1
}

fix_mirror() {
    local sources_file="$PREFIX/etc/apt/sources.list"
    [ -f "$sources_file" ] || { warn "未找到 apt 源文件, 跳过镜像适配"; return; }

    # 候选: "显示名 base URL" (路径各不相同, 已逐个实测 HTTP 200)
    local candidates=(
        "官方 https://packages.termux.dev/apt/termux-main"
        "清华 https://mirrors.tuna.tsinghua.edu.cn/termux/apt/termux-main"
        "中科大 https://mirrors.ustc.edu.cn/termux/apt/termux-main"
        "阿里云 https://mirrors.aliyun.com/termux/termux-main"
        "北大 https://mirrors.pku.edu.cn/termux/termux-main"
        "南科大 https://mirrors.sustech.edu.cn/termux/apt/termux-main"
        "南阳理工 https://mirror.nyist.edu.cn/termux/apt/termux-main"
    )

    local work entry name url code ts age t1 t2 t i cut
    work=$(mktemp -d "${TMPDIR:-$PREFIX/tmp}/mirror.XXXXXX")
    # shellcheck disable=SC2064
    trap "rm -rf '$work'" RETURN

    local now n=0 newest=0
    local -a NAMES=() URLS=() TIMES=() STAMPS=()
    now=$(date +%s)

    for entry in "${candidates[@]}"; do
        name="${entry%% *}"
        url="${entry##* }"
        code=$(curl -s -o "$work/rel" -w '%{http_code}' \
            --connect-timeout 5 --max-time 15 "$url/dists/stable/Release" 2>/dev/null) || code=000
        if [ "$code" != "200" ]; then
            info "跳过 $name (Release HTTP $code)"
            continue
        fi
        # 关键在于必须解析得出 Date —— 挡掉返回 HTML 却给 200 的假源
        ts=$(release_ts "$work/rel") || {
            info "跳过 $name (Release 里没有 Date 字段 —— 多半是个返回网页的假源)"
            continue
        }
        age=$(( now - ts ))
        if [ "$age" -gt "$MIRROR_MAX_AGE" ]; then
            info "跳过 $name (同步于 $(( age / 86400 )) 天前, 太陈旧)"
            continue
        fi
        t1=$(curl -s -o /dev/null -w '%{time_total}' \
            --connect-timeout 5 --max-time 15 "$url/dists/stable/Release" 2>/dev/null) || t1=999
        t2=$(curl -s -o /dev/null -w '%{time_total}' \
            --connect-timeout 5 --max-time 15 "$url/dists/stable/Release" 2>/dev/null) || t2=999
        t=$(printf '%s\n%s\n' "$t1" "$t2" | sort -n | head -1)
        info "候选 $name: ${t}s, 同步于 $(( age / 3600 )) 小时前"
        [ "$ts" -gt "$newest" ] && newest=$ts
        NAMES+=("$name"); URLS+=("$url"); TIMES+=("$t"); STAMPS+=("$ts")
        n=$(( n + 1 ))
    done

    if [ "$n" -eq 0 ]; then
        warn "所有候选源都不可用, 保持当前配置 (可手动: pkg change-repo)"
        return
    fi

    # 只保留"新鲜度落在宽限窗口内"的, 再从中选最快的
    local best_name="" best_url="" best_t=999999 best_ts=0
    cut=$(( newest - MIRROR_FRESH_GRACE ))
    i=0
    while [ "$i" -lt "$n" ]; do
        if [ "${STAMPS[$i]}" -ge "$cut" ]; then
            t="${TIMES[$i]}"
            if [ -z "$best_url" ] || awk "BEGIN{exit !($t < $best_t)}"; then
                best_name="${NAMES[$i]}"; best_url="${URLS[$i]}"; best_t="$t"; best_ts="${STAMPS[$i]}"
            fi
        fi
        i=$(( i + 1 ))
    done

    if [ -z "$best_url" ]; then
        warn "候选源的同步时间都超出宽限窗口, 保持当前配置"
        return
    fi
    ok "选定源: $best_name (${best_t}s, 同步于 $(( (now - best_ts) / 3600 )) 小时前)"

    # 当前已是选定源 → 不动
    if grep -qF "$best_url" "$sources_file" 2>/dev/null; then
        ok "当前源已是选定源, 无需切换"
        return
    fi

    local backup="$sources_file.bak.$(date +%s)"
    cp "$sources_file" "$backup"
    warn "切换源: $(grep -oE 'https://[^ ]+' "$sources_file" | head -1) → $best_name"
    {
        echo "# 由 install.sh 自动切换 (选定: $best_name ${best_t}s, Release $(( (now - best_ts) / 3600 )) 小时前)"
        echo "deb $best_url stable main"
    } > "$sources_file"

    if DEBIAN_FRONTEND=noninteractive apt update -y >/dev/null 2>&1; then
        ok "apt update 成功 ($best_name), 原配置备份: $(basename "$backup")"
    else
        warn "apt update 失败, 已自动回滚到原配置"
        cp "$backup" "$sources_file"
        DEBIAN_FRONTEND=noninteractive apt update -y >/dev/null 2>&1 || true
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
# 原生方案只需要 patchelf (改 interpreter) + nodejs (dns-bootstrap 探测 DNS)。
# 不需要 root, 也不需要 proot —— proot 只在极端情况下自动兜底。
install_dependencies() {
    local need=()
    command -v patchelf >/dev/null || need+=(patchelf)
    command -v node >/dev/null || need+=(nodejs-lts)
    command -v npm >/dev/null || need+=(nodejs-lts)
    command -v curl >/dev/null || need+=(curl)
    if [ ${#need[@]} -gt 0 ]; then
        info "安装依赖: ${need[*]}"
        pkg install -y "${need[@]}" || fail "依赖安装失败, 请先手动执行 pkg update && pkg upgrade"
    else
        ok "依赖已就绪 (patchelf $(patchelf --version 2>/dev/null | grep -oE '[0-9.]+'), node $(node --version))"
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
    local idx="$1" pkg="$2" out="$3" ver="" m i
    ver="$(alpine_version "$idx" "$pkg")" || true
    if [ -z "$ver" ]; then
        warn "解析 $pkg 版本号失败, 下面是 tar 的真实输出:"
        tar -xzOf "$idx" APKINDEX >/dev/null || true
        fail "无法从 APKINDEX 解析 $pkg 的版本号"
    fi
    # 版本号来自 alpine_select_mirror 选中的镜像, 优先从同一镜像取, 保证索引与包一致
    local mirrors=()
    [ -n "${ALPINE_BASE:-}" ] && mirrors+=("$ALPINE_BASE")
    for m in "${ALPINE_MIRRORS[@]}"; do
        [ "$m" = "${ALPINE_BASE:-}" ] && continue
        mirrors+=("$m")
    done
    for m in "${mirrors[@]}"; do
        if curl -fsSL --connect-timeout 10 --max-time 120 "$m/$pkg-$ver.apk" -o "$out"; then
            info "$pkg-$ver.apk ← $(apk_mirror_host "$m")"
            return 0
        fi
        warn "$pkg-$ver.apk 下载失败: $(apk_mirror_host "$m")"
    done
    fail "$pkg.apk 下载失败 (已试 ${#mirrors[@]} 个镜像)"
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
    cp "$work/usr/lib/libgcc_s.so.1" "$RPATH/"
    # Alpine 的 libstdc++ 版本号会变 (6.0.32 / 6.0.34 …), 不能硬编码:
    # 取目录里匹配 libstdc++.so.6.* 的真实文件, 再按惯用名 libstdc++.so.6 安装一份
    local so_real=""
    for so_real in "$work/usr/lib/libstdc++.so.6".*; do :; done
    [ -f "$so_real" ] || so_real="$work/usr/lib/libstdc++.so.6"
    [ -f "$so_real" ] || fail "libstdc++.apk 内容异常 (找不到 libstdc++.so.6)"
    cp "$so_real" "$RPATH/libstdc++.so.6"
    cp "$so_real" "$RPATH/$(basename "$so_real")"
    chmod +x "$RPATH/libstdc++.so.6" "$RPATH/$(basename "$so_real")" "$RPATH/libgcc_s.so.1"
    rm -rf "$work"
    ok "C++ 运行库已安装到 $RPATH"
}

# ---------- dns53 独立组件 ----------
# dns53 (musl 程序的 DNS 兜底) 不再内嵌在本脚本、也不再写入任何 agent 目录,
# 而是作为独立组件安装到 ~/.local/share/dns53, 源码与安装器见仓库 dns53/。
# 其他 agent 可复用同一目录, 也可直接运行:
#   bash ~/.local/share/dns53/install.sh
DNS53_DIR="${XDG_DATA_HOME:-$HOME_DIR/.local/share}/dns53"
DNS53_RAW_BASES=(
    # gh-proxy 缓存约几分钟; jsDelivr 约 12 小时; raw 实时但国内网络不稳定
    "https://gh-proxy.com/https://raw.githubusercontent.com/xkxxs/opencode-termux/main/dns53"
    "https://cdn.jsdelivr.net/gh/xkxxs/opencode-termux@main/dns53"
    "https://raw.githubusercontent.com/xkxxs/opencode-termux/main/dns53"
)
DNS53_FILES=(install.sh VERSION root.sh dns53.js dns-bootstrap.js dnsq.js check_dns.sh dns53-aaaa)

fetch_dns53_payload() {
    local dst="$1" base f all
    mkdir -p "$dst"
    for base in "${DNS53_RAW_BASES[@]}"; do
        all=1
        for f in "${DNS53_FILES[@]}"; do
            if ! curl -fsSL --connect-timeout 10 --max-time 60 "$base/$f" -o "$dst/$f"; then
                all=0
                break
            fi
        done
        if [ "$all" = "1" ]; then
            return 0
        fi
        warn "dns53 组件下载失败, 换源: $base"
    done
    return 1
}

install_dns53() {
    local src="" tmp=""
    if [ -n "${SCRIPT_DIR:-}" ] && [ -f "$SCRIPT_DIR/dns53/install.sh" ]; then
        src="$SCRIPT_DIR/dns53"
        info "dns53 组件: 使用本地仓库 dns53/"
    else
        tmp="$(mktemp -d "${TMPDIR:-$PREFIX/tmp}/dns53.XXXXXX")" || tmp=""
        if [ -n "$tmp" ] && fetch_dns53_payload "$tmp"; then
            src="$tmp"
            info "dns53 组件: 已从仓库下载"
        else
            if [ -n "$tmp" ]; then rm -rf "$tmp"; fi
            tmp=""
            if [ -f "$DNS53_DIR/install.sh" ]; then
                src="$DNS53_DIR"
                warn "dns53 组件下载失败, 沿用已安装版本"
            else
                warn "dns53 组件获取失败, 跳过 DNS 配置 (可稍后重跑本脚本)"
                return 0
            fi
        fi
    fi
    if ! bash "$src/install.sh"; then
        warn "dns53 组件安装异常 (详见上方输出)"
    fi
    if [ -n "$tmp" ]; then rm -rf "$tmp"; fi
}

# ---------- 安装官方 OpenCode ----------
install_opencode() {
    info "查询最新版本 (opencode.ai API, npm 兜底)…"
    local version=""
    version=$(oc_latest_version) || true
    [ -n "$version" ] || fail "无法获取最新版本 (网络问题?)"
    info "最新版本: $version"

    # 私有 loader + DNS shim 每次安装都确认一遍 (自愈: 文件被删/系统升级后可恢复)
    ensure_musl_loader || warn "私有 loader 未就绪, 退回系统 loader (DNS 可能不可用)"

    local installed="" cur_mode=""
    [ -f "$VERSION_FILE" ] && installed=$(cat "$VERSION_FILE" 2>/dev/null || true)
    [ -f "$MODE_FILE" ] && cur_mode=$(cat "$MODE_FILE" 2>/dev/null || true)
    if [ -x "$REAL_BIN" ] && [ "$installed" = "$version" ] && [ "$cur_mode" = "native" ]; then
        # 已是 native: 顺手确认 interpreter 仍指向私有 loader (老版本装的可能指向系统 loader)
        if [ -f "$REAL_BIN.orig" ] && \
           ! patchelf --print-interpreter "$REAL_BIN" 2>/dev/null | grep -qx "$MUSL_LOADER"; then
            info "二进制 interpreter 不是私有 loader, 重新打补丁…"
            if patch_and_verify "$REAL_BIN" "$REAL_BIN.orig"; then
                ok "已重新打补丁 (native)"
            else
                warn "重新打补丁失败, 保留现状"
            fi
        fi
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
    if ! download_tgz "$version" "$work/cli.tgz"; then
        # API 有时先于 npm 发布版本号 (例如 2.1.2 尚未上传), 此时保留现有版本
        if [ -x "$REAL_BIN" ] && [ -n "$installed" ]; then
            warn "v$version 下载失败 (npm/镜像可能尚未发布), 保留已安装的 v$installed"
            return 0
        fi
        fail "下载失败 (npm 与各镜像均不可用)"
    fi

    tar xzf "$work/cli.tgz" -C "$work" || fail "解压失败"
    # V2 的 tarball 内路径是 package/bin/opencode
    local new_bin="$work/package/bin/opencode"
    [ -f "$new_bin" ] || fail "tarball 内未找到 package/bin/opencode"
    chmod +x "$new_bin"

    # 留一份未打补丁的原始二进制 (之后的 update/自愈都从它重新打)
    cp "$new_bin" "$work/opencode.orig"

    # 打补丁必须验证: patchelf 的退出码为 0 也可能产出坏二进制 (历史上 0.19.2
    # 加 rpath 就会 SIGSEGV), 所以补丁后直接跑 --version。正常路径是原生直跑。
    local mode=native verify_log="$work/verify.log"
    if patch_and_verify "$new_bin" "$work/opencode.orig"; then
        ok "补丁验证通过: 原生直跑, 无需 proot"
    else
        warn "原生直跑失败, 退回 proot 绑定运行库模式"
        info "二进制保持官方原样 (只把 interpreter 指回系统 loader), 由 proot 绑定运行库"
        if ! command -v proot >/dev/null 2>&1; then
            info "安装 proot…"
            pkg install -y proot || true
        fi
        command -v proot >/dev/null 2>&1 \
            || fail "该兜底模式需要 proot, 但安装失败。请手动: pkg install proot"
        cp -f "$work/opencode.orig" "$work/opencode.proot"
        patchelf --set-interpreter "$INTERP" "$work/opencode.proot" 2>/dev/null || true
        chmod +x "$work/opencode.proot"
        new_bin="$work/opencode.proot"
        mode=proot-bind
        local verify_ok=0
        proot_bind_run "$new_bin" --version >"$verify_log" 2>&1 && verify_ok=1
        if [ "$verify_ok" -ne 1 ]; then
            warn "proot 绑定模式下也无法运行, 最后一次输出:"
            sed 's/^/    /' "$verify_log" 2>/dev/null | head -20
            fail "新二进制验证失败, 已放弃替换"
        fi
        ok "proot 绑定模式验证通过"
    fi

    mkdir -p "$OPENCODE_DIR"
    mv -f "$new_bin" "$REAL_BIN"
    chmod +x "$REAL_BIN"
    # 保留未打补丁的原件: 自愈 / 后续 update 需要
    cp -f "$work/opencode.orig" "$REAL_BIN.orig"
    chmod +x "$REAL_BIN.orig" 2>/dev/null || true
    echo "$version" > "$VERSION_FILE"
    echo "$mode" > "$MODE_FILE"
    ok "OpenCode $version 已安装 (运行模式: $mode)"
}

# ---------- PATH ----------
# 默认 shell 是 zsh 时不会读 ~/.bashrc, 只写 .bashrc 等于没装进 PATH。
# 按 $SHELL / 已安装的 zsh / 已有的 .zshrc 判断, 两个 rc 文件都幂等写入。
ensure_path_rc() {
    local rc
    local -a rcs=("$HOME_DIR/.bashrc")
    if [ "$(basename "${SHELL:-bash}")" = "zsh" ] \
       || [ -f "$HOME_DIR/.zshrc" ] \
       || command -v zsh >/dev/null 2>&1; then
        rcs+=("$HOME_DIR/.zshrc")
    fi
    for rc in "${rcs[@]}"; do
        [ -e "$rc" ] || : > "$rc"
        if ! grep -q '\.local/bin' "$rc" 2>/dev/null; then
            echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$rc"
            info "~/.local/bin 已加入 PATH ($rc)"
        fi
    done
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
#   运行库       → LD_LIBRARY_PATH=$PREFIX/lib/musl (libstdc++, libgcc_s)
#
# 注意: **不要**用 patchelf --set-rpath。bionic patchelf 0.19.2 打 rpath 会
# 产出退出码 0 但运行时 SIGSEGV 的坏二进制 (实测 exit 139)。只打 interpreter +
# 设 LD_LIBRARY_PATH 即可, 无需 proot, 也无需 glibc 版 patchelf。
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
MODE_FILE="$BIN_DIR/.mode"      # native (patchelf) / proot-bind
INTERP="$PREFIX/lib/ld-musl-aarch64.so.1"
RPATH="$PREFIX/lib/musl"
MUSL_LIBS="$PREFIX/lib/musl"     # native 模式的 LD_LIBRARY_PATH
# DNS: musl 硬编码读 /etc/resolv.conf, Android 上该文件不存在 → 解析回退
# 127.0.0.1:53 并超时。无 root 造不出 /etc/resolv.conf, 于是用一份私有
# loader 副本, 把内部硬编码的路径就地改写成 $RESOLV_SHIM (详见 ensure_musl_loader)。
MUSL_LOADER="$BIN_DIR/ld-musl-aarch64.so.1"   # 私有 loader 副本 (仅 opencode 使用)
RESOLV_SRC="$PREFIX/etc/resolv.conf"
RESOLV_SHIM="/sdcard/.oc-resolv"
# V2 起官方走 npm 分发 (不再是 GitHub Releases)
NPM_PKG="@opencode/cli-linux-arm64-musl"
UPDATE_API="https://opencode.ai/update/api/latest/cli/npm"
# dns53 独立组件 (与 agent 目录解耦)
DNS53_DIR="${XDG_DATA_HOME:-$HOME_DIR/.local/share}/dns53"
DNS_BOOT="$DNS53_DIR/dns-bootstrap.js"

# root 判定: 有 root 不等于装了 Termux 的 sudo 包 (Magisk/KernelSU 只提供 su)。
# dns53 安装器探测后会把模式 (direct|sudo|su|none) 缓存到 $DNS53_DIR/.root_mode,
# 这里优先读缓存, 避免每次启动都探测 su 而触发授权弹窗; 缓存缺失时才退回 sudo -n。
root_available() {
    local mode
    mode="$(cat "$DNS53_DIR/.root_mode" 2>/dev/null || true)"
    if [ -n "$mode" ]; then
        [ "$mode" != "none" ]
        return
    fi
    [ "$(id -u 2>/dev/null)" = "0" ] && return 0
    command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null && return 0
    return 1
}

# dns53 是否真在跑: 看它 90s 内有没有写心跳文件 (普通用户可读, 不需要 su)
# 只看 root_available 会误判: 有 root 但 dns53 没起来时, 跳过了无 root 兜底 → DNS 全挂
dns53_alive() {
    local f="$DNS53_DIR/.alive" now mt
    [ -f "$f" ] || return 1
    now=$(date +%s)
    mt=$(stat -c %Y "$f" 2>/dev/null || echo 0)
    [ $((now - mt)) -lt 90 ]
}

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

# $1=版本 $2=输出文件: 带进度条下载 + 大小/gzip 校验, 不通过自动换镜像
# (npmjs 曾出现 curl 退出码 0 但只下了 4.3MB / 96MB 的截断包 → 必须校验内容)
download_asset() {
    local ver="$1" out="$2"
    local expect="" url="" alt="" u="" got=""
    local -a urls=()
    expect="$(npm view "$NPM_PKG@$ver" dist.size 2>/dev/null | tail -1)" || expect=""
    url="$(npm view "$NPM_PKG@$ver" dist.tarball 2>/dev/null | tail -1)" || url=""
    if [ -n "$url" ]; then
        case "$url" in
            *registry.npmjs.org*)     alt="${url/registry.npmjs.org/registry.npmmirror.com}"
                                      urls+=("$alt" "$url") ;;
            *registry.npmmirror.com*) alt="${url/registry.npmmirror.com/registry.npmjs.org}"
                                      urls+=("$url" "$alt") ;;
            *) urls+=("$url") ;;
        esac
    fi
    while read -r u; do urls+=("$u"); done < <(fallback_tarball_urls "$ver")

    for u in "${urls[@]}"; do
        curl -fSL --progress-bar --connect-timeout 15 --max-time 900 "$u" -o "$out" || continue
        got="$(stat -c%s "$out" 2>/dev/null || echo 0)"
        if [ -n "$expect" ] && [ "$got" != "$expect" ]; then
            echo "!! 下载不完整 (${got} / 期望 ${expect} 字节), 换源重试…" >&2
            continue
        fi
        if ! gzip -t "$out" 2>/dev/null; then
            echo "!! tarball 校验失败 (gzip -t 未通过), 换源重试…" >&2
            continue
        fi
        return 0
    done
    return 1
}

# 无 root 时的 resolv.conf 会随网络切换 (Wi-Fi/移动数据/DNS 变化) 失效。
# 有 root 走 dns53 常驻, 不需要这段; 无 root 每 5 分钟重测并重写一次。
refresh_dns_nonroot() {
    [ -f "$DNS_BOOT" ] || return 0
    command -v node >/dev/null 2>&1 || return 0
    if root_available && dns53_alive; then return 0; fi
    local conf="$PREFIX/etc/resolv.conf" now mt
    now=$(date +%s)
    if [ -f "$conf" ]; then
        mt=$(stat -c %Y "$conf" 2>/dev/null || echo 0)
        if [ $(( now - mt )) -lt 300 ]; then return 0; fi
    fi
    if command -v timeout >/dev/null 2>&1; then
        timeout 8 node "$DNS_BOOT" >/dev/null 2>&1 || true
    else
        node "$DNS_BOOT" >/dev/null 2>&1 || true
    fi
}

# ---- DNS 兜底 (无 root / 无 proot) --------------------------------------
# musl 的解析器把 "/etc/resolv.conf" 编译死在 loader 里; Android 的 /etc 是
# /system/etc 的只读挂载, 没有 resolv.conf。文件打不开时 musl 回退到
# 127.0.0.1:53, 那里没人监听 → 每次解析都要等超时 (表现为
# "getaddrinfo ETIMEOUT")。
#
# 解法: 复制一份 loader 到私有目录, 把里面那个字符串就地改写成
# $RESOLV_SHIM —— 该字符串后面正好有 6 字节 NUL 填充, 因此路径最长 22 字符。
# 所有 app 私有目录都超过 22 字符, /sdcard/.oc-resolv 是唯一够短的可写路径
# (实测 musl 能正常从 FUSE 读取)。系统 $PREFIX/lib/ld-musl-aarch64.so.1 不动。
ensure_musl_loader() {
    local src="$PREFIX/lib/ld-musl-aarch64.so.1" off=""
    if [ -f "$MUSL_LOADER" ] && grep -qaF "$RESOLV_SHIM" "$MUSL_LOADER"; then return 0; fi
    [ -f "$src" ] || return 1
    mkdir -p "$BIN_DIR" 2>/dev/null || return 1
    cp -f "$src" "$MUSL_LOADER" || return 1
    off="$(grep -aboF '/etc/resolv.conf' "$MUSL_LOADER" 2>/dev/null | head -1 | cut -d: -f1)"
    if [ -n "$off" ]; then
        # 就地覆盖 (不改变文件长度, 否则 ELF 偏移全废)
        printf '%s\0' "$RESOLV_SHIM" | dd of="$MUSL_LOADER" bs=1 seek="$off" conv=notrunc 2>/dev/null || true
    fi
    chmod +x "$MUSL_LOADER" 2>/dev/null || true
    grep -qaF "$RESOLV_SHIM" "$MUSL_LOADER"
}

# dns-bootstrap 会在网络切换后重写 $PREFIX/etc/resolv.conf, 同步到 shim 路径。
sync_resolv_shim() {
    [ -f "$RESOLV_SRC" ] || return 0
    cmp -s "$RESOLV_SRC" "$RESOLV_SHIM" && return 0
    cp -f "$RESOLV_SRC" "$RESOLV_SHIM" 2>/dev/null || true
}

# 存储权限: DNS shim 放在 /sdcard/.oc-resolv (见 ensure_musl_loader), 需要
# 共享存储权限。
# 注意 termux-setup-storage 是两阶段的:
#   第 1 次 → 只弹 Android 权限窗 (用户点"允许")
#   第 2 次 → 权限到位后才会在 Termux 里问 "Do you want to continue? (y/n)"
#            (重建 ~/storage 软链)
# 两次都用 printf 'y' 喂 stdin, 所以不会像直接调用那样卡在交互提问上。
ensure_storage_access() {
    local probe="/sdcard/.oc-write-test.$$" mark="$BIN_DIR/.storage-denied" i age ok=0
    ( : >"$probe" ) 2>/dev/null && { rm -f "$probe" "$mark" 2>/dev/null; return 0; }
    # 5 分钟内已经请求过且失败 → 不再重复弹窗/等待, 免得每次启动都卡
    if [ -f "$mark" ]; then
        age=$(( $(date +%s) - $(stat -c %Y "$mark" 2>/dev/null || echo 0) ))
        [ "$age" -lt 300 ] && return 1
    fi
    command -v termux-setup-storage >/dev/null 2>&1 || return 1
    echo "→ 需要存储权限 (DNS 配置放在 $RESOLV_SHIM), 正在请求…" >&2
    printf 'y\n' | termux-setup-storage >/dev/null 2>&1 || true   # 第 1 次: 弹权限窗
    for i in $(seq 1 20); do                                       # 等用户点"允许"
        ( : >"$probe" ) 2>/dev/null && { ok=1; break; }
        sleep 1
    done
    rm -f "$probe" 2>/dev/null
    if [ "$ok" = 1 ]; then
        rm -f "$mark" 2>/dev/null
        # 第 2 次: 权限到位后它才会问 y/n, 顺便把 ~/storage 软链建好
        printf 'y\n' | termux-setup-storage >/dev/null 2>&1 || true
        return 0
    fi
    mkdir -p "$BIN_DIR" 2>/dev/null && : >"$mark" 2>/dev/null
    echo "!! 存储权限未授予 → musl 读不到 DNS 配置, 联网会超时。" >&2
    echo "   请在手机上点“允许”(App 需在前台), 或手动执行: termux-setup-storage" >&2
    return 1
}

# 运行 opencode 二进制。
#   native 模式: 直接跑 (interp 已指向 Termux musl loader, 运行库走
#                LD_LIBRARY_PATH)。不需要 proot —— 进程能看到真实内核
#                (6.6.x-...-android...), Bun 会自行禁用有问题的
#                epoll_pwait2 路径。proot 仅作最后兜底。
#   proot-bind:  二进制未打补丁, 必须经 proot 把 musl 运行库绑到标准路径;
#                直接跑会因 /lib/ld-musl-aarch64.so.1 不存在而 ENOENT。
run_opencode() {
    local bin="$1"; shift
    local _env=(env -u LD_PRELOAD "LD_LIBRARY_PATH=$MUSL_LIBS" \
                    "SSL_CERT_FILE=${SSL_CERT_FILE:-$PREFIX/etc/tls/cert.pem}")
    local mode
    mode="$(cat "$MODE_FILE" 2>/dev/null || echo native)"

    if [ "$mode" = "native" ]; then
        "${_env[@]}" "$bin" "$@" && return 0
        if command -v proot >/dev/null 2>&1; then proot_bind_run "$bin" "$@"; return; fi
        return 1
    fi

    if command -v proot >/dev/null 2>&1; then
        proot_bind_run "$bin" "$@"
    else
        "${_env[@]}" "$bin" "$@"
    fi
}

# 历史遗留的兜底判断, 仅供 proot 分支使用。
# 旧说法: Bun 在"报告的内核 >= 5.11"时走 epoll_pwait2, 返回 ENOSYS 时无兜底
# → 空指针段错误 (bun#32489), 于是用 proot -k 5.10.0 把内核降到 5.10。
# 现状 (opencode 2.1.2 / Bun 1.4.2): 该崩溃已无法复现 —— 内置 Bun 含
# PR #32490 修复 (uname 带 -android 时直接不用 epoll_pwait2), 且本机 seccomp
# 并未拦截 syscall 441 (返回 EINVAL = 调用成功)。因此 native 模式不再走 proot。
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

# 不用 patchelf 的备选方案 (对应 install.sh 的 proot-bind 模式):
# 二进制保持官方原样, 由 proot 把 musl 运行库绑到它原本要找的标准路径。
proot_bind_run() {
    local bin="$1"; shift
    local opts=() fake=""
    if kernel_needs_proot; then
        opts+=(-k 5.10.0)
        fake="$(fake_osrelease)"
        if [ -n "$fake" ] && [ -f "$fake" ]; then
            opts+=(-b "$fake:/proc/sys/kernel/osrelease")
        fi
    fi
    opts+=(-b "${INTERP}:/lib/ld-musl-aarch64.so.1")
    if [ -f "${RPATH}/libstdc++.so.6" ]; then
        opts+=(-b "${RPATH}/libstdc++.so.6:/usr/lib/libstdc++.so.6")
    fi
    if [ -f "${RPATH}/libgcc_s.so.1" ]; then
        opts+=(-b "${RPATH}/libgcc_s.so.1:/usr/lib/libgcc_s.so.1")
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

GLIBC_PATCHELF="$PREFIX/glibc/bin/patchelf"

# 确保 glibc 版 patchelf (0.19.1) 可用 —— 0.19.2 会把该二进制改坏。
# 首次安装会下载约 33MB、占用约 214MB 磁盘。
install_glibc_patchelf() {
    if command -v grun >/dev/null 2>&1 && [ -x "$GLIBC_PATCHELF" ]; then
        return 0
    fi
    echo "==> 安装 glibc 版 patchelf (0.19.1, 能正确处理该二进制)…" >&2
    echo "    (需下载约 33MB、占用约 214MB 磁盘, 首次会慢一些)" >&2
    pkg install -y patchelf-glibc glibc glibc-runner gcc-libs-glibc >/dev/null 2>&1 || true
    command -v grun >/dev/null 2>&1 && [ -x "$GLIBC_PATCHELF" ]
}

# 打补丁 + 验证。$1=二进制 $2=未打补丁的原始副本 $3=bionic|glibc
# 每次都从原始副本重新打, 避免上一次的产物残留。
patch_and_verify() {
    local bin="$1" orig="$2" kind="$3"
    local -a PE=(patchelf)
    [ "$kind" = "glibc" ] && PE=(grun "$GLIBC_PATCHELF")

    cp -f "$orig" "$bin" || return 1
    # 只打 interpreter。**不要加 --set-rpath**: patchelf 0.19.2 在加 rpath 时
    # 会写出运行时 SIGSEGV 的坏文件 (退出码却是 0)。运行库改用 LD_LIBRARY_PATH。
    # interpreter 指向私有 loader 副本 (它读 /sdcard/.oc-resolv, 见上)。
    ensure_musl_loader 2>/dev/null || true
    local interp="$MUSL_LOADER"
    [ -f "$interp" ] || interp="$INTERP"
    "${PE[@]}" --set-interpreter "$interp" "$bin" 2>/dev/null || return 1

    # 验证 = 原生直跑(不经 proot), 这才代表真正可用
    env -u LD_PRELOAD "LD_LIBRARY_PATH=$MUSL_LIBS" \
        "SSL_CERT_FILE=${SSL_CERT_FILE:-$PREFIX/etc/tls/cert.pem}" \
        "$bin" --version >/dev/null 2>&1 && return 0
    return 1
}

# 下载 → 解压 → 打补丁 → 验证 → 原子换入。失败返回 1 (保留旧二进制)。
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
    # 留一份未打补丁的原始二进制
    cp "$NEW_BIN" "$TMP/opencode.orig" || return 1

    # 打补丁必须验证: patchelf 退出码 0 不代表产物可运行。
    # 现在只打 interpreter (rpath 会让 0.19.2 产出 SIGSEGV 的坏文件),
    # 运行库由 LD_LIBRARY_PATH 提供, 因此 bionic patchelf 即可胜任。
    # glibc 分支保留作最后手段。
    local mode=native
    echo "==> 打补丁: interpreter (运行库走 LD_LIBRARY_PATH) …"
    if patch_and_verify "$NEW_BIN" "$TMP/opencode.orig" bionic; then
        echo "==> 补丁验证通过 (bionic patchelf, 原生直跑 OK)"
    elif install_glibc_patchelf && patch_and_verify "$NEW_BIN" "$TMP/opencode.orig" glibc; then
        echo "==> 补丁验证通过 (glibc 版 patchelf $(grun "$GLIBC_PATCHELF" --version 2>/dev/null | head -1))"
    else
        echo "!! 补丁后的二进制无法原生运行" >&2
        echo "==> 改用 proot 绑定运行库模式…" >&2
        if ! command -v proot >/dev/null 2>&1; then
            pkg install -y proot >/dev/null 2>&1 || true
        fi
        if command -v proot >/dev/null 2>&1 && proot_bind_run "$TMP/opencode.orig" --version >/dev/null 2>&1; then
            mode=proot-bind
            NEW_BIN="$TMP/opencode.orig"
            chmod +x "$NEW_BIN"
            echo "==> proot 绑定模式验证通过" >&2
        else
            echo "!! 新二进制无法运行, 已回滚(旧版保留)" >&2
            return 1
        fi
    fi

    # 保留这一版未打补丁的原件 (回滚 / 重新打补丁时用), 否则每次升级后
    # opencode.orig 还停留在旧版本
    cp -f "$TMP/opencode.orig" "$REAL_BIN.orig" 2>/dev/null || true
    mv -f "$NEW_BIN" "$REAL_BIN" || return 1
    chmod +x "$REAL_BIN"
    echo "$VERSION" > "$VERSION_FILE"
    echo "$mode" > "$MODE_FILE"
    echo "✓ 更新完成: $(run_opencode "$REAL_BIN" --version) (模式: $mode)"
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
        # 无 root: resolv.conf 会随网络切换过期, 定期(5 分钟)重测重写
        refresh_dns_nonroot
        # musl 实际读的是 /sdcard/.oc-resolv (见 ensure_musl_loader), 先保证它存在且最新
        ensure_musl_loader 2>/dev/null || true
        ensure_storage_access || true
        if root_available && dns53_alive; then
            # root + dns53 常驻: 明确指向本地转发器, 避免沿用上次网络残留的上游 DNS
            printf 'nameserver 127.0.0.1\n' > "$RESOLV_SHIM" 2>/dev/null || true
        else
            # dns53 不在 (没起来/已退出): 回退到 dns-bootstrap 实测出的可用上游
            sync_resolv_shim
        fi
        # 自动更新: 启动前快速检查最新版本 (短超时, 网络差时静默跳过),
        # 非最新则自动更新; 更新失败不阻塞, 用现有版本启动。
        if [ "${OPENCODE_NO_AUTO_UPDATE:-0}" != "1" ]; then
            LATEST="$(latest_version 10)" || true
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
        # exec 不能调 bash 函数, 内联逻辑
        RUN_MODE="$(cat "$MODE_FILE" 2>/dev/null || echo native)"
        # --standalone: 进程内私有服务, 用完就退, 不连常驻后台服务。
        #   OPENCODE_STANDALONE=1 → 强制 standalone
        #   OPENCODE_STANDALONE=0 → 强制后台服务
        #   未设置 → proot-bind 模式默认 standalone, native 模式用官方默认
        #
        # 为什么 proot-bind 要默认 standalone: 该模式下后台服务
        # (opencode serve --service) 起来后客户端能拿到结果, 但进程**不退出**
        # —— 表现为 TUI 里输入 /exit 或按 Ctrl+C 后一直停在
        # "Starting background server…", 只能杀进程。standalone 无此问题。
        if [ "${OPENCODE_STANDALONE:-unset}" = "unset" ] && [ "$RUN_MODE" = "proot-bind" ]; then
            OPENCODE_STANDALONE=1
        fi
        # 注意: 部分子命令不接受 --standalone (如 `opencode api GET ...` 会报
        # "Unrecognized flag"), 所以只在没有子命令时附加
        case "${1:-}" in
            api|serve|update|upgrade|auth|models|session|export|import|install|uninstall|acp|mcp|plugin|stats|web|github) : ;;
            *)
                if [ "${OPENCODE_STANDALONE:-0}" = "1" ] \
                   && ! printf '%s\n' "$@" | grep -qx -- '--standalone'; then
                    set -- --standalone "$@"
                fi
                ;;
        esac
        if [ "$RUN_MODE" = "native" ]; then
            # 原生直跑: interp 已指向 Termux musl loader, 运行库走 LD_LIBRARY_PATH。
            # 没有 proot 层 → 进程能看到真实内核 (6.6.x-...-android...),
            # Bun 会自行禁用有问题的 epoll_pwait2 (见 kernel_needs_proot 注释)。
            exec env -u LD_PRELOAD "LD_LIBRARY_PATH=$MUSL_LIBS" \
                "SSL_CERT_FILE=${SSL_CERT_FILE:-$PREFIX/etc/tls/cert.pem}" \
                "$REAL_BIN" "$@"
        elif [ "$RUN_MODE" = "proot-bind" ] && command -v proot >/dev/null 2>&1; then
            # 未打补丁的官方二进制: 靠 proot 把运行库绑到标准路径
            OSOPT=()
            if kernel_needs_proot; then
                FAKE_OS="$(fake_osrelease)"
                if [ -n "$FAKE_OS" ] && [ -f "$FAKE_OS" ]; then
                    OSOPT=(-k 5.10.0 -b "$FAKE_OS:/proc/sys/kernel/osrelease")
                else
                    OSOPT=(-k 5.10.0)
                fi
            fi
            LIBOPT=(-b "${INTERP}:/lib/ld-musl-aarch64.so.1")
            [ -f "${RPATH}/libstdc++.so.6" ] && LIBOPT+=(-b "${RPATH}/libstdc++.so.6:/usr/lib/libstdc++.so.6")
            [ -f "${RPATH}/libgcc_s.so.1" ] && LIBOPT+=(-b "${RPATH}/libgcc_s.so.1:/usr/lib/libgcc_s.so.1")
            DNSOPT=()
            [ -f "${PREFIX}/etc/resolv.conf" ] && DNSOPT+=(-b "${PREFIX}/etc/resolv.conf:/etc/resolv.conf")
            exec proot "${OSOPT[@]}" "${LIBOPT[@]}" "${DNSOPT[@]}" "$REAL_BIN" "$@"
        elif kernel_needs_proot && command -v proot >/dev/null 2>&1; then
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
        elif root_available; then
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

    ensure_path_rc

    # PATH 陷阱: 官方安装脚本 (opencode.ai/install) 创建的 ~/.opencode/bin
    # 排在 PATH 前面, 里面可能是跑不起来的 glibc 版; 换成 wrapper 副本
    if [ -d "$HOME_DIR/.opencode/bin" ]; then
        if [ -x "$HOME_DIR/.opencode/bin/opencode" ]; then
            if ! head -3 "$HOME_DIR/.opencode/bin/opencode" | grep -q 'opencode wrapper'; then
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
    local ver mode
    ver=$(OPENCODE_NO_AUTO_UPDATE=1 PATH="$HOME_DIR/.local/bin:$PATH" "$WRAPPER_PATH" --version 2>/dev/null) \
        || fail "验证失败: opencode 无法运行"
    mode=$(cat "$MODE_FILE" 2>/dev/null || echo unknown)
    ok "安装成功: $ver (运行模式: $mode)"
    if [ "$mode" = "native" ]; then
        [ -f "$MUSL_LOADER" ] && ok "私有 musl loader: $MUSL_LOADER" \
            || warn "私有 musl loader 缺失, DNS 可能不可用"
        [ -s "$RESOLV_SHIM" ] && ok "DNS 配置: $RESOLV_SHIM" \
            || warn "DNS shim 缺失 ($RESOLV_SHIM), 联网可能超时"
    fi
}

# ---------- 卸载 ----------
uninstall() {
    warn "将卸载 OpenCode 并移除 wrapper…"
    rm -f "$WRAPPER_PATH"
    rm -rf "$OPENCODE_DIR"
    rm -f "$RESOLV_SHIM"
    if [ -d "$HOME_DIR/.opencode/bin" ]; then
        rm -f "$HOME_DIR/.opencode/bin/opencode"
    fi
    ok "已卸载"
    warn "dns53 独立组件已保留 — codex 等其他 musl 程序可能依赖它"
    warn "如需一并移除: bash ~/.local/share/dns53/install.sh --uninstall"
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

# ---------- 共享存储权限 ----------
# 无 root 时 DNS 兜底依赖 /sdcard/.oc-resolv (musl 只认 loader 里编译死的路径,
# 而 app 私有目录的路径都超过 22 字符的字符串上限, 只有 /sdcard 够短)。
# 所以安装阶段就要拿到共享存储权限。
#
# termux-setup-storage 是两阶段的, 必须调两次:
#   第 1 次 → 只弹 Android 权限窗 (用户点"允许")
#   第 2 次 → 权限到位后才会在 Termux 里问 "Do you want to continue? (y/n)"
#            (重建 ~/storage 软链)
# 两次都用 printf 'y' 喂 stdin, 避免脚本卡在交互提问上。
ensure_storage_permission() {
    local probe="/sdcard/.oc-write-test.$$" i ok=0
    if ( : >"$probe" ) 2>/dev/null; then
        rm -f "$probe" 2>/dev/null
        ok "存储权限已就绪"
        return 0
    fi
    if ! command -v termux-setup-storage >/dev/null 2>&1; then
        warn "缺少 termux-setup-storage, 跳过存储权限检查"
        return 1
    fi
    info "需要存储权限 (DNS 配置放在 /sdcard/.oc-resolv), 请在手机上点“允许”…"
    printf 'y\n' | termux-setup-storage >/dev/null 2>&1 || true
    for i in $(seq 1 60); do
        ( : >"$probe" ) 2>/dev/null && { ok=1; break; }
        sleep 1
    done
    rm -f "$probe" 2>/dev/null
    if [ "$ok" = 1 ]; then
        # 第 2 次: 权限到位后才会问 y/n, 顺便把 ~/storage 软链建好
        printf 'y\n' | termux-setup-storage >/dev/null 2>&1 || true
        ok "存储权限已授予"
        return 0
    fi
    warn "未获得存储权限: 继续安装, 但 opencode 联网时 DNS 会超时"
    warn "  请在手机上允许 Termux 的存储权限, 或手动执行 termux-setup-storage"
    return 1
}

# ---------- 主流程 ----------
case "${1:-}" in
    --uninstall) uninstall ;;
esac

info "opencode-termux 安装脚本 — 仅支持 Termux aarch64"
check_environment
ensure_storage_permission || true
fix_mirror
upgrade_packages
install_dependencies
install_musl_libs
install_dns53
install_opencode
write_wrapper
verify
show_guide
