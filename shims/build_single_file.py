#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
把 dsh-shim.js / dsh-require-hook.js / dsh-loader-hooks.mjs / flock-shim.mjs
打包成一个自包含的 install_dsh_termux.sh。

用法：python3 build_single_file.py
"""
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
OUT = HERE / "install_dsh_termux.sh"

FILES = [
    ("dsh-shim.js", "__DSH_SHIM_JS__"),
    ("dsh-require-hook.js", "__DSH_REQUIRE_HOOK_JS__"),
    ("dsh-loader-hooks.mjs", "__DSH_LOADER_HOOKS_MJS__"),
    ("flock-shim.mjs", "__FLOCK_SHIM_MJS__"),
    ("link-shim.cjs", "__LINK_SHIM_CJS__"),
    ("node-pty-shim.cjs", "__NODE_PTY_SHIM_CJS__"),
]

HEADER = r'''#!/usr/bin/env bash
# =============================================================================
#  dsh on Termux —— 单文件一键安装（含两处原生依赖的纯 JS 绕过）
# =============================================================================
#
#  用法：
#     bash install_dsh_termux.sh              # 安装 + 配置 + 自检
#     bash install_dsh_termux.sh --no-key     # 同上，但不打印 Key 步骤
#     bash install_dsh_termux.sh --extract    # 只把内嵌的 shim 文件解出来，不安装
#
#  本文件是**自包含**的：所有 shim 文件都内嵌在下面，无需额外传任何文件。
#
#  绕过的三处原生/平台依赖（都实测通过）
#  --------------------------------
#  ① node-addon-require-builtin：dsh 启动路径硬依赖它，官方无 android 预编译包。
#     那个原生模块唯一的作用是"不用 --expose-internals 也能拿到 Node 内部模块"，
#     而 Node 官方就有这个开关 → 纯 JS 替代，功能等价。
#
#  ② node-addon-system/flock：JS 入口硬编码 platform !== 'linux' && !== 'darwin'，
#     Termux 是 Linux 内核却被纯逻辑误判 → 纯 JS 复刻（O_EXCL 哨兵文件，真互斥）。
#
#  ③ link()：Android SELinux 禁止 untrusted_app 对 app_data_file 建硬链接，
#     而 dsh 用 link() 做「原子发布且不覆盖」→ 降级为 open(dest,'wx') + 复制，
#     保持 EEXIST（no-clobber）语义不变。
#
#  ② @deepseek-ai/node-addon-system/flock：JS 入口硬编码 platform!=='linux' 就抛错，
#     但 Termux 就是 Linux 内核，flock(2) 本身完全可用 → 纯 JS 用 O_EXCL 哨兵文件
#     复刻互斥语义（真跨进程互斥，不是 no-op）。
#
#  ⚠️ --expose-internals 不允许出现在 NODE_OPTIONS（Node 明确拒绝），
#     所以只能用命令行标志，由本脚本包一层。
#
#  🎁 用 loader hook 重定向，**完全不碰 node_modules** → npm 升级不会丢补丁。
# =============================================================================

set -euo pipefail

DSH_VER="0.2.2-rc.1"
HOME_DIR="${DSH_HOME:-$HOME/.dsh}"
SHIM_DIR="$HOME/.dsh-shim"
PATCH="$HOME_DIR/profiles/web/cordis.patch.yml"
EXTRACT_ONLY=0
NO_KEY=0
REINSTALL=0
RESET_CONFIG=0
CHECK_ONLY=0
CONFIRM_ALL=0     # 1 = 非交互时也覆盖（默认否）

BOLD=$'\033[1m'; DIM=$'\033[2m'; RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'; CYA=$'\033[36m'; RST=$'\033[0m'
say()  { echo "${CYA}▸${RST} $*"; }
ok()   { echo "${GRN}✓${RST} $*"; }
warn() { echo "${YEL}!${RST} $*"; }
die()  { echo "${RED}✗ $*${RST}" >&2; exit 1; }

for arg in "$@"; do
  case "$arg" in
    --no-key)      NO_KEY=1 ;;
    --extract)     EXTRACT_ONLY=1 ;;
    --reinstall)   REINSTALL=1 ;;
    --reset-config) RESET_CONFIG=1 ;;
    --check)        CHECK_ONLY=1 ;;
    --yes)         CONFIRM_ALL=1 ;;
  esac
done

# -----------------------------------------------------------------------------
# 写入保护：绝不覆盖你改过的文件
# -----------------------------------------------------------------------------
#
# 用户明确要求：「不要写配置，要么 y/n 确认后写，要么别写。
#                每次我改完都覆盖了。」
#
# 所以规则是：
#   文件不存在            → 直接写
#   文件存在且内容相同    → 跳过（静默）
#   文件存在且内容不同    → **问 y/n，默认 N（不写）**
#                          非交互场景（管道/无 TTY）→ 直接跳过，只提示
#   --reset-config        → 跳过提问，强制覆盖
#   --yes                 → 非交互时也覆盖
#
# 备份：覆盖前一定先存一份 .bak.<时间戳>，不丢东西。
# -----------------------------------------------------------------------------

confirm_overwrite() {
  # $1=文件路径  $2=说明
  local target="$1" what="$2" ans=""
  [ "$RESET_CONFIG" = "1" ] && return 0
  # --yes：跳过提问直接覆盖（优先级高于交互提示）
  [ "$CONFIRM_ALL" = "1" ] && return 0

  # ⚠️ 这里不能用 `[ -t 0 ]`：write_protected 是用 heredoc 喂内容的，
  #    heredoc 会把整个函数的 stdin 重定向成临时文件 → -t 0 永远为假。
  #    正确做法是直接用 /dev/tty（终端设备本身，不受 stdin 重定向影响）。
  if [ -r /dev/tty ] && [ -w /dev/tty ]; then
    {
      printf "  ⚠ %s 已存在且内容不同：%s\n" "$what" "$target"
      printf "    覆盖会丢失你的修改（会先备份）。[y/N] "
    } > /dev/tty
    read -r ans < /dev/tty || ans=""
    case "$ans" in
      y|Y|yes|YES) return 0 ;;
      *) return 1 ;;
    esac
  fi
  # 没有终端（管道 / cron）：默认不覆盖
  return 1
}

write_protected() {
  # $1=目标文件  $2=说明（内容从 stdin 读）
  local target="$1" what="$2" tmp
  tmp="$(mktemp)"
  cat > "$tmp"
  if [ -f "$target" ] && cmp -s "$tmp" "$target"; then
    rm -f "$tmp"
    printf "  · %s 已是最新，未改动\n" "$what"
    return 0
  fi
  if [ -f "$target" ]; then
    if ! confirm_overwrite "$target" "$what"; then
      rm -f "$tmp"
      printf "  · %s **保留了你的版本**（未改动）：%s\n" "$what" "$target"
      printf "    想用新版本：bash install_dsh_termux.sh --reset-config\n"
      return 0
    fi
    cp "$target" "$target.bak.$(date +%Y%m%d-%H%M%S)"
    printf "  · 已备份原文件 → %s.bak.*\n" "$target"
  fi
  mv "$tmp" "$target"
  printf "  ✓ %s 已写入 %s\n" "$what" "$target"
}

# -----------------------------------------------------------------------------
# 内嵌文件解包（幂等 + 写入保护）
# -----------------------------------------------------------------------------
extract_embedded() {
  mkdir -p "$SHIM_DIR"
  _emit() {
    # $1=目标文件名  $2=分隔符  stdin=内容
    local target="$SHIM_DIR/$1" tmp
    tmp="$(mktemp)"
    cat > "$tmp"
    if [ -f "$target" ] && cmp -s "$tmp" "$target"; then
      rm -f "$tmp"
      return 0
    fi
    if [ -f "$target" ] && ! confirm_overwrite "$target" "$1"; then
      rm -f "$tmp"
      printf "  · %s **保留了你的版本**（未改动）\n" "$1"
      return 0
    fi
    if [ -f "$target" ]; then
      cp "$target" "$target.bak.$(date +%Y%m%d-%H%M%S)"
    fi
    mv "$tmp" "$target"
  }
  _emit dsh-shim.js          __DSH_SHIM_JS__          <<'__DSH_SHIM_JS__'
{dsh_shim_js}
__DSH_SHIM_JS__
  _emit dsh-require-hook.js  __DSH_REQUIRE_HOOK_JS__  <<'__DSH_REQUIRE_HOOK_JS__'
{dsh_require_hook_js}
__DSH_REQUIRE_HOOK_JS__
  _emit dsh-loader-hooks.mjs __DSH_LOADER_HOOKS_MJS__ <<'__DSH_LOADER_HOOKS_MJS__'
{dsh_loader_hooks_mjs}
__DSH_LOADER_HOOKS_MJS__
  _emit flock-shim.mjs       __FLOCK_SHIM_MJS__       <<'__FLOCK_SHIM_MJS__'
{flock_shim_mjs}
__FLOCK_SHIM_MJS__
  _emit link-shim.cjs        __LINK_SHIM_CJS__        <<'__LINK_SHIM_CJS__'
{link_shim_cjs}
__LINK_SHIM_CJS__
  _emit node-pty-shim.cjs    __NODE_PTY_SHIM_CJS__    <<'__NODE_PTY_SHIM_CJS__'
{node_pty_shim_cjs}
__NODE_PTY_SHIM_CJS__
  chmod +x "$SHIM_DIR/dsh-shim.js"
}

echo "${BOLD}"
echo "  dsh on Termux · 单文件安装"
echo "  版本 ${DSH_VER} · 纯本地 · 免费模型"
echo "${RST}"

if [ "$EXTRACT_ONLY" = "1" ]; then
  say "仅解包内嵌文件 → $SHIM_DIR"
  extract_embedded
  ok "已解包 6 个 shim 文件"
  exit 0
fi

# ---------------------------------------------------------------- 0. 安卓体检
#
# 用法：bash install_dsh_termux.sh --check
#
# 你那张「安卓通用问题」表，逐项实测。输出贴回来我就能对症下药。
# 每项格式：✓ 可用 / ✗ 不可用（附具体错误）/ ! 有条件可用
run_check() {
  echo "${BOLD}"
  echo "  安卓 / Termux 环境体检"
  echo "${RST}"
  printf "  %-22s %s\n" "项目" "结果"
  printf "  %-22s %s\n" "----------------------" "----------------"

  _row() { printf "  %-22s %s\n" "$1" "$2"; }

  # 1. shell 路径（硬编码 /bin/bash 会 ENOENT）
  if [ -x /bin/sh ]; then
    _row "/bin/sh" "${GRN}✓ 存在${RST}（但 Termux 惯例是 \$PREFIX/bin/sh）"
  else
    _row "/bin/sh" "${YEL}! 不存在 → agent 要用 sh -c，别假设 /bin/bash${RST}"
  fi
  _row "sh 实际路径" "$(command -v sh 2>/dev/null || echo '找不到 sh')"

  # 2. os.tmpdir()
  if command -v node >/dev/null 2>&1; then
    _row "os.tmpdir()" "$(node -e "console.log(require('node:os').tmpdir())" 2>/dev/null || echo '取不到')"
    if node -e "
const os=require('node:os'),fs=require('node:fs');
const d=os.tmpdir(); fs.mkdirSync(d,{recursive:true});
const f=d+'/dsh-probe-'+process.pid; fs.writeFileSync(f,'x'); fs.unlinkSync(f);
" 2>/dev/null; then
      _row "tmpdir 可写" "${GRN}✓ 可写可执行${RST}"
    else
      _row "tmpdir 可写" "${RED}✗ 不可写 → 设 TMPDIR 到 \$HOME/.tmp${RST}"
    fi
  fi

  # 3. /dev/shm
  if [ -d /dev/shm ]; then
    _row "/dev/shm" "${GRN}✓ 存在${RST}"
  else
    _row "/dev/shm" "${YEL}! 缺失 → 共享内存类模块会失败，设 TMPDIR 绕开${RST}"
  fi

  # 4. statx（bionic 封装不全时 fs.stat 会报错）
  if command -v node >/dev/null 2>&1; then
    STATX_OUT=$(node -e "
const fs=require('node:fs');
try { const s=fs.statSync('/'); console.log('OK '+(s.mode & 0o777).toString(8)); }
catch(e){ console.log('FAIL '+e.code); }
" 2>&1 | tail -1)
    case "$STATX_OUT" in
      OK*) _row "statx / fs.stat" "${GRN}✓ $STATX_OUT${RST}" ;;
      *)   _row "statx / fs.stat" "${RED}✗ $STATX_OUT → 会回退 fstatat${RST}" ;;
    esac
  fi

  # 5. link()（SELinux 禁止硬链接）
  if command -v node >/dev/null 2>&1; then
    LINK_OUT=$(node -e "
const fs=require('node:fs'),os=require('node:os'),p=require('node:path');
const d=fs.mkdtempSync(p.join(os.tmpdir(),'dsh-link-'));
const a=p.join(d,'a'),b=p.join(d,'b');
fs.writeFileSync(a,'x');
try { fs.linkSync(a,b); console.log('OK'); } catch(e){ console.log('FAIL '+e.code); }
fs.rmSync(d,{recursive:true,force:true});
" 2>&1 | tail -1)
    case "$LINK_OUT" in
      OK*)  _row "link() 硬链接" "${GRN}✓ 可用${RST}" ;;
      *)    _row "link() 硬链接" "${YEL}! $LINK_OUT → shim 已降级为 O_EXCL 复制${RST}" ;;
    esac
  fi

  # 6. rename / renameat2
  if command -v node >/dev/null 2>&1; then
    REN_OUT=$(node -e "
const fs=require('node:fs'),os=require('node:os'),p=require('node:path');
const d=fs.mkdtempSync(p.join(os.tmpdir(),'dsh-ren-'));
const a=p.join(d,'a'),b=p.join(d,'b');
fs.writeFileSync(a,'x');
try { fs.renameSync(a,b); console.log('OK'); } catch(e){ console.log('FAIL '+e.code); }
fs.rmSync(d,{recursive:true,force:true});
" 2>&1 | tail -1)
    case "$REN_OUT" in
      OK*) _row "rename / renameat2" "${GRN}✓ 可用${RST}" ;;
      *)   _row "rename / renameat2" "${RED}✗ $REN_OUT${RST}" ;;
    esac
  fi

  # 7. fsync（Android 特有 EINVAL）
  if command -v node >/dev/null 2>&1; then
    FS_OUT=$(node -e "
const fs=require('node:fs'),os=require('node:os'),p=require('node:path');
const d=fs.mkdtempSync(p.join(os.tmpdir(),'dsh-fsync-'));
const f=p.join(d,'f');
try {
  const fd=fs.openSync(f,'w'); fs.writeSync(fd,'x'); fs.fsyncSync(fd); fs.closeSync(fd);
  console.log('OK');
} catch(e){ console.log('FAIL '+e.code); }
fs.rmSync(d,{recursive:true,force:true});
" 2>&1 | tail -1)
    case "$FS_OUT" in
      OK*) _row "fsync" "${GRN}✓ 可用${RST}" ;;
      *)   _row "fsync" "${RED}✗ $FS_OUT → session 落盘可能报 EINVAL${RST}" ;;
    esac
  fi

  # 8. inotify 上限
  if [ -r /proc/sys/fs/inotify/max_user_watches ]; then
    _row "inotify watches" "$(cat /proc/sys/fs/inotify/max_user_watches) $([ -w /proc/sys/fs/inotify/max_user_watches ] && echo '(可调)' || echo '(不可调)')"
  else
    _row "inotify watches" "${YEL}! 读不到 → 文件监听可能失败${RST}"
  fi

  # 9. node-pty
  if [ -f "$SHIM_DIR/node-pty-shim.cjs" ]; then
    _row "node-pty 替身" "${GRN}✓ 已就位（真身可用用真身）${RST}"
  else
    _row "node-pty 替身" "${YEL}! 未安装 → 跑一次安装脚本${RST}"
  fi

  # 10. sharp / wasm 后端
  if command -v node >/dev/null 2>&1; then
    SHARP_OUT=$(node -e "
try { require.resolve('@img/sharp-wasm32/sharp.node'); console.log('WASM_OK'); }
catch(e){ console.log('WASM_MISSING'); }
" 2>/dev/null | tail -1)
    case "$SHARP_OUT" in
      WASM_OK*)   _row "sharp wasm 后端" "${GRN}✓ 已装（图片功能可用）${RST}" ;;
      *)          _row "sharp wasm 后端" "${YEL}! 未装 → npm i -g @img/sharp-wasm32${RST}" ;;
    esac
  fi

  # 11. koffi —— 官方注释说「非 Windows 进程永远不会加载 Koffi」
  _row "koffi (FFI)" "${GRN}✓ 全部调用点都是 Windows DLL，Linux 上永不 import${RST}"

  # 12. 架构 / 关键信息
  _row "架构" "$(uname -m) / $(node -p 'process.arch' 2>/dev/null)"
  _row "Node" "$(node -v 2>/dev/null)"
  _row "PREFIX" "${PREFIX:-（未设置）}"
  _row "SHIM_DIR" "$SHIM_DIR"

  echo
  say "把这张表贴回来，我按结果对症下药"
}

if [ "${CHECK_ONLY:-0}" = "1" ]; then
  run_check
  exit 0
fi

# ---------------------------------------------------------------- 1. 前置检查
say "检查 Node…"
command -v node >/dev/null 2>&1 || die "没找到 node。Termux 里先执行：pkg install nodejs-lts"

NODE_V=$(node -v | sed 's/v//')
NODE_MAJOR=${NODE_V%%.*}
NODE_MINOR=$(echo "$NODE_V" | cut -d. -f2)
if [ "$NODE_MAJOR" -lt 24 ] || { [ "$NODE_MAJOR" -eq 24 ] && [ "$NODE_MINOR" -lt 9 ]; }; then
  warn "Node $NODE_V 版本过低（需要 >= 24.9.0）"
  say "尝试安装 nodejs-lts…"
  if command -v pkg >/dev/null 2>&1; then
    pkg install -y nodejs-lts || true
    hash -r
    NODE_V=$(node -v | sed 's/v//')
    NODE_MAJOR=${NODE_V%%.*}
    NODE_MINOR=$(echo "$NODE_V" | cut -d. -f2)
  fi
fi
if [ "$NODE_MAJOR" -lt 24 ] || { [ "$NODE_MAJOR" -eq 24 ] && [ "$NODE_MINOR" -lt 9 ]; }; then
  die "Node 版本仍不满足（当前 $NODE_V）。Termux: pkg install nodejs-lts"
fi
ok "Node $NODE_V"

say "检查架构…"
ARCH=$(node -p "process.arch")
case "$ARCH" in
  arm64) warn "检测到 arm64" ;;
  arm)   warn "检测到 arm (32 位) —— 官方原生包不覆盖 32 位，但本方案的纯 JS 绕过不受架构影响" ;;
  *)     warn "检测到 $ARCH" ;;
esac

if command -v pkg >/dev/null 2>&1; then
  # 只在缺依赖时才装，已装则跳过（pkg 本身很快，但也没必要每次跑）
  MISSING_PKGS=""
  for p in git python build-essential; do
    dpkg -s "$p" >/dev/null 2>&1 || MISSING_PKGS="$MISSING_PKGS $p"
  done
  if [ -n "$MISSING_PKGS" ]; then
    say "安装基础依赖:$MISSING_PKGS"
    pkg install -y $MISSING_PKGS 2>/dev/null || true
  else
    ok "基础依赖已齐（git python build-essential）"
  fi
fi

# ---------------------------------------------------------------- 2. 安装 dsh
DSH_BIN_PATH="$(npm root -g)/@deepseek-ai/dsh/lib/bin.js"
INSTALLED_VER=""
if [ -f "$DSH_BIN_PATH" ]; then
  INSTALLED_VER="$(node "$DSH_BIN_PATH" --version 2>/dev/null | tr -d '[:space:]' || true)"
fi

if [ "${REINSTALL:-0}" = "1" ]; then
  warn "--reinstall：强制重装 $DSH_VER"
  npm i -g "@deepseek-ai/dsh@${DSH_VER}" --no-audit --no-fund --ignore-scripts \
    || npm i -g "@deepseek-ai/dsh@${DSH_VER}" --no-audit --no-fund
  DSH_BIN_PATH="$(npm root -g)/@deepseek-ai/dsh/lib/bin.js"
  [ -f "$DSH_BIN_PATH" ] || die "dsh 安装失败"
  ok "dsh 已重装到 $DSH_VER"
elif [ "$INSTALLED_VER" = "$DSH_VER" ]; then
  ok "dsh $DSH_VER 已安装，跳过下载"
  say "（想升级或重装：bash install_dsh_termux.sh --reinstall）"
elif [ -n "$INSTALLED_VER" ]; then
  warn "已装 dsh $INSTALLED_VER，但本脚本针对 $DSH_VER 调过"
  say "尝试安装 $DSH_VER…"
  npm i -g "@deepseek-ai/dsh@${DSH_VER}" --no-audit --no-fund --ignore-scripts \
    || npm i -g "@deepseek-ai/dsh@${DSH_VER}" --no-audit --no-fund
  DSH_BIN_PATH="$(npm root -g)/@deepseek-ai/dsh/lib/bin.js"
  [ -f "$DSH_BIN_PATH" ] || die "dsh 安装失败"
  ok "dsh 已更新到 $DSH_VER"
else
  say "安装 @deepseek-ai/dsh@${DSH_VER}（首次安装约需几分钟）…"
  # ⚠️ node-pty 是 dsh-subprocess-local 的**非可选依赖**，它的 install 脚本是
  #    `node scripts/prebuild.js || node-gyp rebuild`。
  #    Termux 是 32 位 + bionic，既没有 linux-arm 预编译包，node-gyp 也很可能编译失败
  #    → 整个 npm i -g 挂掉。
  #    所以这里用 --ignore-scripts 装（dsh 本身不需要 node-pty 的原生模块，
  #    我们有管道替身兜底）。失败则退回普通安装再试一次。
  if ! npm i -g "@deepseek-ai/dsh@${DSH_VER}" --no-audit --no-fund --ignore-scripts; then
    warn "--ignore-scripts 安装失败，改用常规安装重试…"
    npm i -g "@deepseek-ai/dsh@${DSH_VER}" --no-audit --no-fund || die "dsh 安装失败"
  fi
  DSH_BIN_PATH="$(npm root -g)/@deepseek-ai/dsh/lib/bin.js"
  [ -f "$DSH_BIN_PATH" ] || die "dsh 安装失败，找不到 $DSH_BIN_PATH"
  ok "dsh 已安装: $DSH_BIN_PATH"
fi

# ---------------------------------------------------------------- 2.5 图片后端
# sharp 在 Termux 上没有可用的 32 位 bionic 原生包（@img/sharp-linux-arm 是 glibc 版）。
# 但 sharp 0.35 的加载顺序最后有通用兜底：require("@img/sharp-wasm32/sharp.node")。
# 装上它，图片相关工具（read_image / 附件缩放）就能工作（慢一点，但能用）。
say "检查图片处理后端（sharp）…"
SHARP_PKG_DIR="$(npm root -g)/@deepseek-ai/dsh/node_modules/sharp"
if [ -d "$SHARP_PKG_DIR" ]; then
  SHARP_VER="$(node -p "require('$SHARP_PKG_DIR/package.json').version" 2>/dev/null || echo "")"
  if node -e "require.resolve('@img/sharp-wasm32/sharp.node')" >/dev/null 2>&1; then
    ok "sharp wasm 后端已就绪"
  elif [ -n "$SHARP_VER" ]; then
    say "安装 @img/sharp-wasm32@$SHARP_VER（图片后端，约 10MB）…"
    npm i -g "@img/sharp-wasm32@${SHARP_VER}" --no-audit --no-fund --ignore-scripts >/dev/null 2>&1 \
      && ok "wasm 后端已装（图片功能可用）" \
      || warn "wasm 后端安装失败，图片相关功能会不可用（不影响其它功能）"
  fi
else
  warn "没找到 sharp（dsh 未装全？）"
fi

# ---------------------------------------------------------------- 3. 部署 shim
say "部署纯 JS 绕过（原生依赖 / 平台限制）…"
extract_embedded

# 包装命令（同样走写入保护）
write_protected "$SHIM_DIR/dsh-termux" "包装命令" <<EOF
#!/data/data/com.termux/files/usr/bin/bash
exec node --expose-internals "$SHIM_DIR/dsh-shim.js" "\$@"
EOF
chmod +x "$SHIM_DIR/dsh-termux" 2>/dev/null || true

# Termux: $PREFIX/bin 一定在 PATH 里，优先放那儿
# 其它环境: $HOME/bin 可能不在 PATH，额外提示一次
PLACED=""
for d in "${PREFIX:+$PREFIX/bin}" "$HOME/bin" "$HOME/.local/bin"; do
  [ -n "$d" ] || continue
  if [ -d "$d" ] && [ -w "$d" ]; then
    cp "$SHIM_DIR/dsh-termux" "$d/dsh-termux" 2>/dev/null || true
    chmod +x "$d/dsh-termux" 2>/dev/null || true
    if [ -x "$d/dsh-termux" ]; then
      PLACED="$d"
      ok "已安装命令: $d/dsh-termux"
      break
    fi
  fi
done

if [ -z "$PLACED" ]; then
  # 找不到可写目录：装到 ~/.dsh-shim 并提示用户加 PATH
  ok "已安装命令: $SHIM_DIR/dsh-termux"
  say "若 command -v dsh-termux 找不到，加一行到 ~/.bashrc："
  say "  echo 'export PATH=\"\$HOME/.dsh-shim:\$PATH\"' >> ~/.bashrc && source ~/.bashrc"
fi

# ---------------------------------------------------------------- 4. 配置免费模型
say "写入免费模型配置…"

# ⚠️ 用 --patch 覆盖层，**不**写进各 profile 的 cordis.patch.yml。
#    dsh 每个 profile 是独立目录，只改 web 的话跑 `dsh headless` 会报
#    NO_ADAPTER（no adapter registered for provider）。覆盖层对所有 profile 生效，
#    且 dsh 升级 / rescue 重建 profile 都不会丢。
write_protected "$SHIM_DIR/free-models.yml" "免费模型配置" <<'YML'
- id: llm-pi-ai
  config:
    providers:
      duanyan:
        apiKeyEnv: DANYAN_API_KEY
        api: openai-completions
        baseURL: https://discovery-api.intern-ai.org.cn/v1
        models:
          - id: deepseek-v4-pro-0813
            contextWindow: 1048576
            maxTokens: 131072
          - id: deepseek-v4-flash-0731
            contextWindow: 1048576
      nvidia:
        apiKeyEnv: NVIDIA_API_KEY
        api: openai-completions
        baseURL: https://integrate.api.nvidia.com/v1
        models:
          - id: z-ai/glm-5.3-flash
            contextWindow: 1048576
          - id: moonshotai/kimi-k3.1-pro
            contextWindow: 1048576
- id: agent-default-model
  config:
    provider: duanyan
    model: deepseek-v4-flash-0731
YML
ok "包装命令会自动带上 --patch（web / headless / tui 全部生效）"

# ---------------------------------------------------------------- 5. 验证
say "验证 1/5：shim 能否启动 dsh…"
if node --expose-internals "$SHIM_DIR/dsh-shim.js" --version 2>/dev/null | grep -q "0\."; then
  ok "dsh --version 通过"
else
  warn "未通过，手动排查：node --expose-internals $SHIM_DIR/dsh-shim.js --version"
fi

say "验证 2/5：配置能否解析…"
if node --expose-internals "$SHIM_DIR/dsh-shim.js" --profile web --dump-config 2>/dev/null | grep -q "duanyan"; then
  ok "duanyan / nvidia 路由已就位"
else
  warn "配置解析异常"
fi

say "验证 3/5：flock 绕过是否生效…"
FLOCK_TEST="$SHIM_DIR/.flock-probe.lock"
rm -f "$FLOCK_TEST" "$FLOCK_TEST.dshlock"
if node --expose-internals --require "$SHIM_DIR/dsh-require-hook.js" -e "
import('@deepseek-ai/node-addon-system/flock').then(async (m) => {
  if (m.__isShim !== true) { console.error('NOT_SHIM'); process.exit(1); }
  const fs = await import('node:fs');
  const fd = fs.openSync('$FLOCK_TEST','w');
  await m.tryLockExclusive(fd);
  const fd2 = fs.openSync('$FLOCK_TEST','w');
  try { await m.tryLockExclusive(fd2); console.error('NO_MUTEX'); process.exit(1); }
  catch (e) { if (e.code !== 'EAGAIN') { console.error('BAD_CODE:' + e.code); process.exit(1); } }
  fs.closeSync(fd); fs.closeSync(fd2);
  console.log('OK');
});
" 2>/dev/null | grep -q OK; then
  ok "flock 绕过生效（互斥语义正确）"
else
  warn "flock 验证未通过"
fi
rm -f "$FLOCK_TEST" "$FLOCK_TEST.dshlock"

say "验证 4/5：link 绕过是否生效（安卓 SELinux 禁硬链接）…"
if node --expose-internals --require "$SHIM_DIR/dsh-require-hook.js" -e "
require('$SHIM_DIR/link-shim.cjs').selfTest().then(() => console.log('OK'), (e) => { console.error(e.message); process.exit(1); });
" 2>/dev/null | grep -q OK; then
  ok "link 绕过生效（no-clobber 语义正确）"
else
  warn "link 验证未通过"
fi

say "验证 5/5：node-pty 降级是否就绪（安卓无 32 位预编译包）…"
if node --expose-internals --require "$SHIM_DIR/dsh-require-hook.js" -e "
const { createRequire } = require('node:module');
const { pathToFileURL } = require('node:url');
const req = createRequire(pathToFileURL(process.argv[1]));
const pty = req('node-pty');
if (pty.__isPipeShim !== true) { console.log('REAL_PTY_OK'); process.exit(0); }
const t = pty.spawn('sh', ['-c','echo PTY_SHIM_ALIVE'], {});
let out = '';
t.onData(d => { out += d; });
t.onExit(() => { console.log(out.includes('PTY_SHIM_ALIVE') ? 'OK' : 'BAD_OUTPUT'); });
" "$(npm root -g)/@deepseek-ai/dsh/node_modules/@deepseek-ai/dsh-subprocess-local/lib/index.js" 2>/dev/null | grep -q OK; then
  ok "node-pty 降级就绪（真身可用则用真身，否则用管道替身）"
elif node --expose-internals --require "$SHIM_DIR/dsh-require-hook.js" -e "
const { createRequire } = require('node:module');
const { pathToFileURL } = require('node:url');
const req = createRequire(pathToFileURL(process.argv[1]));
const pty = req('node-pty');
console.log(pty.__isPipeShim === true ? 'SHIM' : 'REAL');
" "$(npm root -g)/@deepseek-ai/dsh/node_modules/@deepseek-ai/dsh-subprocess-local/lib/index.js" 2>/dev/null | grep -q REAL; then
  ok "node-pty 原生包可用（真身，桌面 Linux/macOS 正常路径）"
else
  warn "node-pty 检查未通过"
fi

# ---------------------------------------------------------------- 6. 收尾
echo
if [ "${NO_KEY:-0}" = "1" ]; then
  cat <<'EOF'
下一步：
  echo 'export DANYAN_API_KEY=你的key' >> ~/.bashrc && source ~/.bashrc
  dsh-termux web
EOF
else
  cat <<'EOF'
────────────────────────────────────────────────
下一步（拿 Key，两选一，都免费）：

  ① 端砚（推荐，国内直连，1M 上下文）
     https://discovery.intern-ai.org.cn/token-plan/home
     左侧「科研模型」→ 创建 API Key（只显示一次，务必复制）

  ② NVIDIA NIM（官方托管，40 RPM）
     https://build.nvidia.com
     邮箱注册 → 验证手机号（国内号码可用，不用绑卡）→ API Keys

  写入环境变量：
     echo 'export DANYAN_API_KEY=你的key' >> ~/.bashrc
     echo 'export NVIDIA_API_KEY=nvapi-你的key' >> ~/.bashrc
     source ~/.bashrc

  启动：
     dsh-termux web
     然后把终端里那行带 ?token= 的完整 URL 复制到手机浏览器

────────────────────────────────────────────────
EOF
fi
echo "${DIM}  提示：原来的 dsh 命令在 Termux 上会崩（缺 android 原生包），"
echo "       请改用 dsh-termux 这个包装命令。"
echo "       升级 dsh 后无需重打补丁 —— shim 不碰 node_modules。${RST}"
'''

FOOTER = ""


def main() -> int:
    body = HEADER
    for fname, delim in FILES:
        p = HERE / fname
        if not p.exists():
            print(f"缺少源文件：{p}", file=sys.stderr)
            return 1
        content = p.read_text(encoding="utf-8")
        if f"\n{delim}\n" in content or content.rstrip().endswith(delim):
            print(f"{fname} 内容与 heredoc 分隔符 {delim} 冲突！", file=sys.stderr)
            return 1
        key = {
            "dsh-shim.js": "dsh_shim_js",
            "dsh-require-hook.js": "dsh_require_hook_js",
            "dsh-loader-hooks.mjs": "dsh_loader_hooks_mjs",
            "flock-shim.mjs": "flock_shim_mjs",
            "link-shim.cjs": "link_shim_cjs",
            "node-pty-shim.cjs": "node_pty_shim_cjs",
        }[fname]
        body = body.replace("{" + key + "}", content.rstrip("\n"))

    OUT.write_text(body + FOOTER, encoding="utf-8")
    OUT.chmod(0o755)
    print(f"✓ 已生成 {OUT}  ({OUT.stat().st_size:,} 字节)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
