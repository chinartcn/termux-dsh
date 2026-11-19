#!/usr/bin/env bash
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
/**
 * node-addon-require-builtin 的纯 JS 替代实现（Android / Termux 专用）
 * =================================================================
 *
 * 背景
 * ----
 * DeepSeek Harness (dsh) 的启动路径硬依赖 `node-addon-require-builtin`，
 * 这个包用 N-API 探测 Node 内部私有状态来拿到 `requireBuiltin()`。
 * 官方只发布了 darwin / linux(glibc|musl) / win32 的预编译包，
 * **没有 android 包**（npm 上 `node-addon-require-builtin-android-arm64` 不存在）。
 * 所以在 Termux 上 `dsh web` 会直接崩在：
 *
 *   Error: dsh: host preparation failed: No usable native binding found for
 *   node-addon-require-builtin-android-arm (auto)
 *
 * 原理
 * ----
 * 原生 addon 的唯一目的，是**在不开 `--expose-internals` 的情况下**
 * 拿到 Node 的内部模块。dsh 实际只用到 5 个内部模块：
 *
 *   internal/modules/esm/loader
 *   internal/modules/cjs/loader
 *   internal/modules/helpers
 *   internal/modules/esm/utils
 *   internal/modules/esm/resolve
 *
 * 而 Node 官方提供了公开开关 `--expose-internals`，
 * 开启后 `require('internal/...')` 直接可用 —— **功能完全等价，无需原生编译**。
 *
 * 用法
 * ----
 *   node --expose-internals ./dsh-shim.js            # 启动 shim
 *   或者
 *   NODE_OPTIONS="--expose-internals" node ...       # 让 shim 自动生效
 *
 * 本文件会在被加载时，把 `node-addon-require-builtin` 的 require
 * 劫持到纯 JS 实现，然后加载真正的 dsh 入口。
 *
 * 用法（Termux 上）：
 *   node --expose-internals /path/to/dsh-shim.js web
 */

'use strict';

const Module = require('node:module');

// ---------------------------------------------------------------------------
// 1. 纯 JS 的 requireBuiltin 实现
// ---------------------------------------------------------------------------

/**
 * 拿到一个 Node 内部模块。
 * 与原生 addon 的 requireBuiltin 行为一致：透传 id，返回模块导出对象。
 */
function requireBuiltin(moduleId) {
  if (typeof moduleId !== 'string' || moduleId.length === 0) {
    throw new TypeError('requireBuiltin(id): id must be a non-empty string');
  }
  // Node 内部模块只认 'internal/...' 前缀
  if (!moduleId.startsWith('internal/')) {
    throw new Error(`requireBuiltin(id): unsupported internal module id: ${moduleId}`);
  }
  return require(moduleId);
}

function isAllowedInternalId(moduleId) {
  return typeof moduleId === 'string' && moduleId.startsWith('internal/');
}

function getBindingInfo() {
  return {
    backend: 'js-shim',
    abi: 'expose-internals',
    bindingPath: __filename,
    note: 'pure-JS fallback for platforms without a native binding (e.g. Android/Termux)',
  };
}

// ---------------------------------------------------------------------------
// 2. 劫持 require，让 dsh 拿到我们的纯 JS 实现
// ---------------------------------------------------------------------------

const shimApi = {
  requireBuiltin,
  isAllowedInternalId,
  getBindingInfo,
};
// default 指向自身（避免自引用 TDZ）
shimApi.default = shimApi;

const originalLoad = Module._load;
Module._load = function patchedLoad(request, parent, isMain) {
  if (request === 'node-addon-require-builtin' || request === 'node-addon-internal-loader') {
    return shimApi;
  }
  return originalLoad.apply(this, arguments);
};

// ---------------------------------------------------------------------------
// 3. 自检：确认 --expose-internals 确实生效，且 dsh 需要的接口齐全
// ---------------------------------------------------------------------------

function selfCheck() {
  const problems = [];
  let esmModule, cjsModule, cjsHelpers, esmUtils, esmResolve;
  try {
    esmModule = requireBuiltin('internal/modules/esm/loader');
    cjsModule = requireBuiltin('internal/modules/cjs/loader');
    cjsHelpers = requireBuiltin('internal/modules/helpers');
    esmUtils = requireBuiltin('internal/modules/esm/utils');
    esmResolve = requireBuiltin('internal/modules/esm/resolve');
  } catch (err) {
    problems.push(
      '无法 require 内部模块 —— 启动命令缺少 --expose-internals？\n' +
      `  ${err.message}`
    );
    return problems;
  }

  const esm = esmModule.getOrInitializeCascadedLoader();
  const modern = 'getOrCreateModuleJob' in esm;

  if (typeof esm.resolveSync !== 'function') {
    problems.push('esm.resolveSync 不可用');
  }
  if (typeof Reflect.get(esm, modern ? 'getOrCreateModuleJob' : 'getModuleJobForImport') !== 'function') {
    problems.push('esm 的模块 job 接口不可用');
  }
  if (!modern && typeof Reflect.get(esm, 'resolve') !== 'function') {
    problems.push('esm.resolve 不可用');
  }
  if (typeof cjsModule.Module._resolveFilename !== 'function') {
    problems.push('cjs.Module._resolveFilename 不可用');
  }
  if (typeof cjsHelpers.getCjsConditions !== 'function') {
    problems.push('cjsHelpers.getCjsConditions 不可用');
  }
  if (typeof esmUtils.getDefaultConditions !== 'function') {
    problems.push('esmUtils.getDefaultConditions 不可用');
  }
  if (typeof esmResolve.defaultResolve !== 'function') {
    problems.push('esmResolve.defaultResolve 不可用');
  }

  return problems;
}

// ---------------------------------------------------------------------------
// 4. 引导真正的 dsh
// ---------------------------------------------------------------------------

/**
 * 在 profile 名之后插入 `--patch <file>`。
 *
 * dsh 的命令行形状：
 *   dsh [--profile] <name> [启动器选项] [app 选项]
 * 启动器选项（--patch / --dump-config 等）必须出现在 app 选项之前，
 * 否则会被 app 抢走。
 *
 * profile 名有两种写法：
 *   1. 位置参数：dsh web --port 3080          → 名字是第一个非 '-' 开头的参数
 *   2. --profile 值：dsh --profile headless X  → 名字是 '--profile' 后面那个
 *   3. --profile=值：dsh --profile=headless X  → 名字和 flag 同一个 token
 */
function insertPatch(args, patchPath) {
  const patch = ['--patch', patchPath];

  // 情况 3：--profile=xxx
  const eqIndex = args.findIndex((a) => a.startsWith('--profile='));
  if (eqIndex >= 0) {
    return [...args.slice(0, eqIndex + 1), ...patch, ...args.slice(eqIndex + 1)];
  }

  // 情况 2：--profile xxx
  const flagIndex = args.indexOf('--profile');
  if (flagIndex >= 0 && args.length > flagIndex + 1) {
    return [
      ...args.slice(0, flagIndex + 2),
      ...patch,
      ...args.slice(flagIndex + 2),
    ];
  }

  // 情况 1：位置参数
  const nameIndex = args.findIndex((a) => !a.startsWith('-'));
  if (nameIndex >= 0) {
    return [
      ...args.slice(0, nameIndex + 1),
      ...patch,
      ...args.slice(nameIndex + 1),
    ];
  }

  // 没有 profile 名（比如只 --version）：放在最前面
  return [...patch, ...args];
}

function main() {
  const problems = selfCheck();
  if (problems.length > 0) {
    console.error('❌ dsh-shim 自检失败：\n  - ' + problems.join('\n  - '));
    console.error('\n提示：必须用 --expose-internals 启动，例如');
    console.error('  node --expose-internals /path/to/dsh-shim.js web');
    process.exit(1);
  }

  const args = process.argv.slice(2);

  // ---- 找到 dsh 的真实入口 ----
  const fs = require('node:fs');
  const path = require('node:path');

  const candidates = [];

  // 1) 环境变量显式指定（最高优先级）
  if (process.env.DSH_BIN) candidates.push(process.env.DSH_BIN);

  // 2) 从若干常见位置按 require 解析（能正确处理 exports 字段）
  const resolveRoots = [
    __dirname,
    process.cwd(),
    ...(process.env.NODE_PATH || '')
      .split(path.delimiter)
      .filter(Boolean)
      .map((p) => path.resolve(p)),
  ];
  for (const root of resolveRoots) {
    try {
      const createRequire = require('node:module').createRequire(
        path.join(root, 'noop.js')
      );
      candidates.push(createRequire.resolve('@deepseek-ai/dsh/lib/bin.js'));
    } catch { /* 该 root 下没装，继续找 */ }
  }

  // 3) Termux / npm 全局安装的固定位置
  const globalRoots = [
    path.dirname(process.execPath) + '/../lib/node_modules',
    '/data/data/com.termux/files/usr/lib/node_modules',
    '/usr/lib/node_modules',
    '/usr/local/lib/node_modules',
    path.join(process.env.HOME || '', '.npm-global/lib/node_modules'),
  ];
  for (const root of globalRoots) {
    candidates.push(path.join(root, '@deepseek-ai/dsh/lib/bin.js'));
  }

  const binPath = candidates.find((p) => {
    try { return p && fs.existsSync(p); } catch { return false; }
  });

  if (!binPath) {
    console.error('❌ 找不到 dsh 入口。');
    console.error('   候选位置都试过了：');
    candidates.forEach((c) => console.error('     - ' + c));
    console.error('\n   请用环境变量显式指定：');
    console.error('   export DSH_BIN=$(npm root -g)/@deepseek-ai/dsh/lib/bin.js');
    process.exit(1);
  }

  console.error(`[shim] dsh 入口: ${binPath}`);
  console.error('[shim] 模式: 纯 JS requireBuiltin（--expose-internals）');

  // 把用户参数接回去，让 dsh 正常解析 profile / 子命令
  process.argv = [process.argv[0], binPath, ...args];

  // dsh 的 bin.js 用 `import.meta.main` 判断"是否作为主入口运行"，
  // 通过 import() 动态加载时该标志为 false，CLI 不会自动执行。
  // 所以这里改为直接 spawn 一个子进程运行真正的 bin.js。
  //
  // 子进程参数：
  //   --expose-internals          内部模块访问（替代原生 addon 的唯一用途）
  //   --require dsh-require-hook   CJS 预加载：劫持 requireBuiltin + 注册 loader hook
  //
  // ⚠️ 不要改成 `--import` 注册 hook：实测 `--import` 对 ESM 静态 import 不生效，
  //    必须在 CJS 里调 module.register()。
  const { spawn } = require('node:child_process');
  const loaderPath = path.join(__dirname, 'dsh-require-hook.js');
  const freeModelsPath = path.join(__dirname, 'free-models.yml');

  // -------------------------------------------------------------------------
  // 自动注入免费模型配置（--patch 覆盖层）
  // -------------------------------------------------------------------------
  //
  // 为什么用 --patch 而不是直接改 profile 的 cordis.patch.yml：
  //   dsh 的每个 profile（web / headless / tui …）是**各自独立**的目录，
  //   每个都有自己的 cordis.patch.yml。只改 web 的话，
  //   跑 `dsh headless` 会报 `NO_ADAPTER: no adapter registered for provider ...`。
  //
  //   --patch 是**启动器级覆盖层**，任何 profile 都能吃到，且不碰 profile 文件
  //   —— 以后 dsh 升级、rescue 重建 profile 都不会丢。
  //
  // 插入位置很讲究：必须紧跟在 profile 名后面。
  //   dsh web --port 3080              →  dsh web --patch <file> --port 3080
  //   dsh --profile headless "你好"    →  dsh --profile headless --patch <file> 你好
  // 如果插到最后，`--patch` 会被当成 app 自己的参数吃掉（或者落到任务文本后面）。
  let finalArgs = args;
  if (fs.existsSync(freeModelsPath)) {
    finalArgs = insertPatch(args, freeModelsPath);
  }

  // 把 hook 通过 NODE_OPTIONS 传给**孙进程**（dsh 自己还会再 spawn 子进程，
  // 例如 dsh-subprocess-local）。--require 允许放进 NODE_OPTIONS，
  // 而 --expose-internals 不允许，所以这里只传 --require。
  const childEnv = { ...process.env, DSH_SHIM_ACTIVE: '1' };
  const existingNodeOptions = process.env.NODE_OPTIONS || '';
  const requireOption = `--require ${JSON.stringify(loaderPath)}`;
  childEnv.NODE_OPTIONS = existingNodeOptions
    ? `${existingNodeOptions} ${requireOption}`
    : requireOption;

  const child = spawn(
    process.execPath,
    ['--expose-internals', '--require', loaderPath, binPath, ...finalArgs],
    { stdio: 'inherit', env: childEnv }
  );
  child.on('exit', (code, signal) => {
    if (signal) process.kill(process.pid, signal);
    else process.exit(code ?? 0);
  });
  child.on('error', (err) => {
    console.error('❌ 无法启动 dsh 子进程：', err.message);
    process.exit(1);
  });
}

main();
__DSH_SHIM_JS__
  _emit dsh-require-hook.js  __DSH_REQUIRE_HOOK_JS__  <<'__DSH_REQUIRE_HOOK_JS__'
/**
 * dsh require 钩子（配合 dsh-shim.js 使用）
 * =================================================================
 *
 * 作用：劫持 `require('node-addon-require-builtin')`，
 *       让它返回纯 JS 实现，从而在**没有 Android 原生预编译包**的
 *       设备（Termux / 安卓）上也能启动 DeepSeek Harness。
 *
 * 加载方式（由 dsh-shim.js 的子进程完成）：
 *   node --expose-internals --require ./dsh-require-hook.js <dsh-bin> <args...>
 *
 * 原理：原生 addon 的唯一作用是在**不开** --expose-internals 的情况下
 *      拿到 Node 的内部模块。开启 --expose-internals 后，
 *      require('internal/...') 直接可用，功能完全等价。
 */

'use strict';

const Module = require('node:module');
const path = require('node:path');

function requireBuiltin(moduleId) {
  if (typeof moduleId !== 'string' || moduleId.length === 0) {
    throw new TypeError('requireBuiltin(id): id must be a non-empty string');
  }
  if (!moduleId.startsWith('internal/')) {
    throw new Error(`requireBuiltin(id): unsupported internal module id: ${moduleId}`);
  }
  return require(moduleId);
}

function isAllowedInternalId(moduleId) {
  return typeof moduleId === 'string' && moduleId.startsWith('internal/');
}

function getBindingInfo() {
  return {
    backend: 'js-shim',
    abi: 'expose-internals',
    bindingPath: __filename,
    note: 'pure-JS fallback for platforms without a native binding (Android/Termux)',
  };
}

const shimApi = {
  requireBuiltin,
  isAllowedInternalId,
  getBindingInfo,
};
shimApi.default = shimApi;

const originalLoad = Module._load;
Module._load = function patchedLoad(request, parent, isMain) {
  if (request === 'node-addon-require-builtin' || request === 'node-addon-internal-loader') {
    return shimApi;
  }
  // ---------------------------------------------------------------------
  // node-pty 降级
  // ---------------------------------------------------------------------
  // node-pty 的预编译包只有 darwin/linux-arm64/linux-x64/win32，
  // **没有 linux-arm（32 位），更没有 android** → Termux 永远加载不了。
  //
  // 实测：agent 的 bash 工具走管道（ctx.subprocess.spawn），不需要 node-pty；
  //       但 spawnTerminal()（交互式终端）会因缺原生 binding 直接抛错。
  // 所以这里：**能加载真身就用真身，加载不了就换成管道替身**，
  // 不让 dsh 直接崩在 "no usable native binding" 上。
  if (request === 'node-pty') {
    try {
      return originalLoad.apply(this, arguments);
    } catch (err) {
      try {
        const shim = require(path.join(__dirname, 'node-pty-shim.cjs'));
        process.emitWarning(
          `[dsh-shim] node-pty 原生模块不可用（${err && err.message}），已降级为管道实现：` +
          '交互式终端会失去 isatty / 真 resize / 线路规程。',
          'dsh-shim'
        );
        return shim;
      } catch (shimErr) {
        // 连替身都加载不了：把原始错误抛回去，至少信息明确
        throw err;
      }
    }
  }
  return originalLoad.apply(this, arguments);
};

// ---------------------------------------------------------------------------
// link 绕过 —— 安卓 SELinux 禁止硬链接
// ---------------------------------------------------------------------------
//
// 症状：EACCES: permission denied, link
// 根因：Android SELinux 不允许 untrusted_app 对 app_data_file 建硬链接，
//       而 dsh 用 link() 做「原子发布且不覆盖」。
// 方案：link 失败时降级为 open(dest,'wx') 独占创建 + 复制，保持 EEXIST 语义。
{
  const linkShimPath = path.join(__dirname, 'link-shim.cjs');
  try {
    require(linkShimPath).install();
  } catch (err) {
    process.emitWarning(
      `[dsh-shim] link 绕过安装失败：${err && err.message}`,
      'dsh-shim'
    );
  }
}

// ---------------------------------------------------------------------------
// ESM loader hook —— 拦截 flock 等静态 ESM 导入
// ---------------------------------------------------------------------------
//
// 实测结论（重要，别改）：
//   - Module._load 补丁 **拦不到** ESM 的 import
//   - `node --import hooks.mjs` 对 dynamic import 不生效，对静态 import 也不稳
//   - ✅ 在 CJS 预加载里调用 `module.register()`，**可以**拦到静态 ESM import
//
// 所以这里必须用 register()，而不是 --import。
{
  const fs = require('node:fs');
  const { pathToFileURL } = require('node:url');

  const hooksPath = path.join(__dirname, 'dsh-loader-hooks.mjs');
  if (fs.existsSync(hooksPath)) {
    try {
      Module.register(hooksPath, pathToFileURL(__filename).href);
    } catch (err) {
      // 注册失败不致命：flock 会退回原生路径，报错也更直观
      process.emitWarning(
        `[dsh-shim] loader hook 注册失败：${err && err.message}`,
        'dsh-shim'
      );
    }
  }
}
__DSH_REQUIRE_HOOK_JS__
  _emit dsh-loader-hooks.mjs __DSH_LOADER_HOOKS_MJS__ <<'__DSH_LOADER_HOOKS_MJS__'
/**
 * dsh 的 ESM loader hook —— 把 flock 拦到纯 JS 实现
 * =================================================================
 *
 * 为什么需要它
 * ------------
 * dsh 的 `session-persistence-jsonl` 用 ESM 静态导入：
 *
 *   import { tryLockExclusive } from "@deepseek-ai/node-addon-system/flock";
 *
 * 实测结论（重要）：
 *   - `Module._load` 补丁 **拦不到** ESM 的 import（实验证实 intercepted=null）
 *   - `module.register()` 的 loader hook **可以**拦到（实验证实生效）
 *
 * 所以这里用 loader hook 做 specifier 重定向，把
 *   @deepseek-ai/node-addon-system/flock
 * 重定向到我们自己的纯 JS 实现。
 *
 * 附带好处：完全不碰 node_modules，npm 升级不会把补丁冲掉。
 */

import { pathToFileURL } from 'node:url';
import { existsSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const SHIM = join(HERE, 'flock-shim.mjs');

/** 需要拦截的 specifier */
const TARGETS = new Set(['@deepseek-ai/node-addon-system/flock']);

/**
 * @param {string} specifier 导入说明符
 * @param {object} context 解析上下文
 * @param {Function} nextResolve 下一个解析器
 */
export async function resolve(specifier, context, nextResolve) {
  if (TARGETS.has(specifier)) {
    if (!existsSync(SHIM)) {
      // shim 不在就别拦截，让原始错误照常暴露
      return nextResolve(specifier, context);
    }
    return {
      url: pathToFileURL(SHIM).href,
      shortCircuit: true,
      format: 'module',
    };
  }
  return nextResolve(specifier, context);
}
__DSH_LOADER_HOOKS_MJS__
  _emit flock-shim.mjs       __FLOCK_SHIM_MJS__       <<'__FLOCK_SHIM_MJS__'
/**
 * flock 的纯 JS 替代实现（Android / Termux 专用）
 * =================================================================
 *
 * 背景
 * ----
 * dsh 的会话写入需要 POSIX `flock(2)` 互斥锁，原生实现在
 * `@deepseek-ai/node-addon-system/flock`。它的 JS 入口有一道平台守卫：
 *
 *   if (platform !== 'linux' && platform !== 'darwin') {
 *     throw new Error(`flock is not supported on ${platform}-${arch}`)
 *   }
 *
 * Termux 上 Node 报 `process.platform === 'android'`，于是**必然踩雷**：
 *
 *   本轮运行失败  flock is not supported on android-arm
 *
 * 但这纯粹是字符串判断的问题 —— Termux 跑的就是 Linux 内核，
 * `flock(2)` 系统调用本身完全可用。所以这里用纯 JS 复刻它的语义。
 *
 * 语义对齐
 * --------
 * 原生版的契约（见 native/system/packages/entry/src/flock.ts）：
 *   - 对调用方传入的 fd 尝试**非阻塞**排他锁
 *   - 成功 → resolve
 *   - 锁被占用 → reject，且 error.code 为 'EAGAIN'（调用方据此判定为争用）
 *   - 其他系统错误 → reject，带 errno
 *
 * 实现方式
 * --------
 * 1. 通过 `/proc/self/fd/<fd>` 反查出 fd 对应的真实路径（Linux/Android 通用）
 * 2. 在同目录创建一个 `<path>.dshlock` 哨兵文件，用 `open(path, 'wx')`
 *    —— O_CREAT|O_EXCL 是**原子**操作，内核保证只有一个进程能成功
 * 3. 已存在 → 说明有人持锁 → 抛 EAGAIN
 * 4. 释放：调用方 close(fd) 时锁自动失效。但哨兵文件需要清理，
 *    所以这里注册一个 fd→哨兵路径的映射，并提供 release()；
 *    同时用 process exit hook 兜底清理
 *
 * 与原生版的差异（诚实说明）
 * ------------------------
 * - 原生 flock 是**内核级**锁：进程崩溃时内核自动释放。
 *   本实现是哨兵文件：进程被 kill -9 时文件会残留。
 *   → 缓解：启动时清理陈旧哨兵（判断 mtime 超过 N 秒且无对应活跃进程）。
 * - 原生 flock 作用于 fd（同一 inode 的不同 fd 互斥）；
 *   本实现作用于路径。对 dsh 的用途（session.lock 单文件独占）完全等价。
 *
 * 对 dsh 的实际语义
 * -----------------
 * dsh 只在「写 session 文件」时用它防止两个 dsh 进程同时写同一个 session。
 * 单进程场景下本来就是串行的，所以本实现能给出正确行为；
 * 若你真开两个 dsh 实例写同一个工作区，仍会正确报争用（EAGAIN）。
 */

import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';

/** fd → 哨兵文件路径 */
const heldLocks = new Map();

/** 哨兵文件后缀 */
const SUFFIX = '.dshlock';

/**
 * 通过 /proc 反查 fd 对应的文件路径。
 * @param {number} fd 文件描述符
 * @returns {string|undefined} 真实路径；无法反查时返回 undefined
 */
function pathOfFd(fd) {
  try {
    const link = fs.readlinkSync(`/proc/self/fd/${fd}`);
    // Android/Termux 上部分路径带 " (deleted)" 后缀，去掉它
    return link.replace(/\s\(deleted\)$/, '');
  } catch {
    return undefined;
  }
}

/**
 * 判断某个哨兵文件是否是"陈旧"的（持锁进程已不存在）。
 * @param {string} lockPath 哨兵文件路径
 * @returns {boolean} true 表示可以安全清理
 */
function isStale(lockPath) {
  try {
    const stat = fs.statSync(lockPath);
    // 记录了 pid 的哨兵：检查该进程是否还活着
    const raw = fs.readFileSync(lockPath, 'utf8');
    const pid = Number.parseInt(raw.trim(), 10);
    if (Number.isInteger(pid) && pid > 0) {
      try {
        process.kill(pid, 0);   // 信号 0 = 只检查存在性
        return false;           // 进程还活着 → 锁有效
      } catch (err) {
        if (err && err.code === 'EPERM') return false;  // 存在但无权限 → 视为有效
        return true;            // ESRCH → 进程没了 → 陈旧
      }
    }
    // 没有 pid 信息：超过 5 分钟视为陈旧
    return Date.now() - stat.mtimeMs > 5 * 60 * 1000;
  } catch (err) {
    if (err && err.code === 'ENOENT') return true;  // 已经没了
    return false;
  }
}

/**
 * 清理本进程持有的所有哨兵文件（进程退出时兜底）。
 */
function releaseAll() {
  for (const [, lockPath] of heldLocks) {
    try { fs.unlinkSync(lockPath); } catch { /* 已经不在了 */ }
  }
  heldLocks.clear();
}
process.on('exit', releaseAll);
for (const sig of ['SIGINT', 'SIGTERM', 'SIGHUP']) {
  process.on(sig, () => { releaseAll(); process.exit(0); });
}

/**
 * 尝试对 fd 获得非阻塞排他锁。
 *
 * @param {number} fd 调用方持有的文件描述符
 * @returns {Promise<void>} 获得锁则 resolve；被占用则 reject（code='EAGAIN'）
 */
export async function tryLockExclusive(fd) {
  const target = pathOfFd(fd);
  if (target === undefined) {
    // 反查不到路径（例如 fd 已关闭）：无法保证互斥，直接报错让调用方决定
    throw Object.assign(new Error('flock: cannot resolve fd path on this platform'), {
      code: 'ERR_FLOCK_UNSUPPORTED_PLATFORM',
      syscall: 'flock',
    });
  }

  const lockPath = target + SUFFIX;

  // 先清理可能残留的陈旧哨兵
  if (fs.existsSync(lockPath) && isStale(lockPath)) {
    try { fs.unlinkSync(lockPath); } catch { /* 竞态：别人先清了 */ }
  }

  let lockFd;
  try {
    // 'wx' = O_CREAT|O_EXCL|O_WRONLY，内核保证原子性：
    // 同一时刻只有一个进程能创建成功。
    lockFd = fs.openSync(lockPath, 'wx');
  } catch (err) {
    if (err && (err.code === 'EEXIST')) {
      // 有人持锁 → 上游据此判定为争用
      throw Object.assign(new Error('EAGAIN: flock failed'), {
        code: 'EAGAIN',
        errno: -11,
        syscall: 'flock',
      });
    }
    throw Object.assign(err, { syscall: 'flock' });
  }

  try {
    // 写入自己的 pid，便于后续判断陈旧
    fs.writeSync(lockFd, String(process.pid));
    fs.closeSync(lockFd);
  } catch {
    try { fs.closeSync(lockFd); } catch { /* ignore */ }
  }

  heldLocks.set(fd, lockPath);
}

/**
 * 释放某个 fd 上持有的锁。
 * @param {number} fd 文件描述符
 */
export function releaseLock(fd) {
  const lockPath = heldLocks.get(fd);
  if (lockPath === undefined) return;
  heldLocks.delete(fd);
  try { fs.unlinkSync(lockPath); } catch { /* 已经不在了 */ }
}

// 与原生版导出同名，调用方 import { tryLockExclusive } 即可
export default { tryLockExclusive, releaseLock };

// 便于外部检查是否已被替换
export const __isShim = true;
export const __platform = process.platform;
export const __arch = process.arch;
export const __host = os.hostname();
export const __path = path.sep;
__FLOCK_SHIM_MJS__
  _emit link-shim.cjs        __LINK_SHIM_CJS__        <<'__LINK_SHIM_CJS__'
/**
 * link 绕过：安卓 SELinux 禁止 untrusted_app 创建硬链接
 * =================================================================
 *
 * 症状（dsh 0.2.2-rc.1 在 Termux 上实测）：
 *   本轮运行失败  EACCES: permission denied, link
 *   '/data/data/com.termux/files/home/.dsh/sessions/<sid>/session.v4.jsonl.zstd.<16hex>.tmp'
 *   -> '.../session.v4.jsonl.zstd'
 *
 * 根因：
 *   dsh 用 `link(tmp, final)` 做「原子发布且不覆盖已有文件」（no-clobber）。
 *   Android 的 SELinux 策略禁止 untrusted_app 对 app_data_file 创建硬链接，
 *   所以 Termux 里 link() 必然 EACCES（桌面 Linux 上则完全正常）。
 *
 * 官方调用点（已核对源码）：
 *   dsh-session-persistence-jsonl/lib/index.js
 *     - materializePosix()      → link(tmp, finalPath)   发布 session 日志
 *     - publishCurrentExclusive()→ link(staged, current) 发布 current 指针
 *   dsh-fs-local / dsh-attachment-local 也会 import link。
 *
 * 替代方案（保持 no-clobber 语义不变）：
 *   真 link()  →  失败(EACCES/EPERM/EXDEV)  →  open(dest, 'wx') 独占创建 + 复制内容
 *
 *   open(dest,'wx') 用 O_CREAT|O_EXCL，是**内核级原子**的：
 *     - 目标已存在 → 抛 EEXIST（dsh 正是靠这个判断"有人抢先发布"）
 *     - 目标不存在 → 独占创建
 *   唯一差别：内容是"边复制边可见"，不是瞬间出现。
 *   对 session 日志 / current 指针文件，这个差别可以接受。
 *
 * 关键实现约束：
 *   - dsh 用 `import { link } from "node:fs/promises"`（ESM 静态导入）。
 *     实测：在 CJS 预加载里改 fs.promises.link，ESM 门面会在**之后**才创建，
 *     因此能吃到 patch（ESM 门面对内置模块是惰性快照）。
 *   - 所以本模块必须在 dsh 的 ESM 入口被加载**之前**执行 —— 由
 *     dsh-require-hook.js 在 --require 阶段调用 install() 完成。
 */

'use strict';

const fs = require('node:fs');
const fsp = require('node:fs/promises');

// 这些 errno 说明"这个平台不让硬链接"，可以安全降级
const FALLBACK_CODES = new Set(['EACCES', 'EPERM', 'EXDEV', 'EMLINK', 'ENOSYS', 'ENOTSUP']);

let stats = {
  attempted: 0,
  fallback: 0,
  failed: 0,
};

function isFallbackError(error) {
  return Boolean(error) && FALLBACK_CODES.has(error.code);
}

/**
 * 复制内容到新建的独占文件句柄。
 * 出错时清掉半截文件，避免留下损坏的目标文件。
 */
async function copyIntoExclusive(handle, sourcePath) {
  let source;
  try {
    source = await fsp.open(sourcePath, 'r');
  } catch (error) {
    await handle.close().catch(() => {});
    throw error;
  }
  try {
    const buffer = Buffer.alloc(64 * 1024);
    for (;;) {
      const { bytesRead } = await source.read(buffer, 0, buffer.length, null);
      if (bytesRead === 0) break;
      await handle.write(buffer, 0, bytesRead);
    }
    await handle.sync();
  } catch (error) {
    await handle.close().catch(() => {});
    throw error;
  } finally {
    await source.close().catch(() => {});
  }
}

/** 降级实现：独占创建 + 复制，语义上等价于 link() 的 no-clobber。 */
async function fallbackLink(existingPath, newPath) {
  const handle = await fsp.open(newPath, 'wx');
  try {
    await copyIntoExclusive(handle, existingPath);
  } catch (error) {
    await fsp.rm(newPath, { force: true }).catch(() => {});
    throw error;
  }
  await handle.close();
}

/**
 * 真 link 的引用。
 * install() 时抓取 —— 之后 fsp.link 会被换成 safeLink，
 * 绝不能在 safeLink 内部动态读 fsp.link（会无限递归）。
 */
let realPromiseLink = null;
let realLink = null;
let realLinkSync = null;

async function safeLink(existingPath, newPath) {
  stats.attempted += 1;
  try {
    return await realPromiseLink(existingPath, newPath);
  } catch (error) {
    if (!isFallbackError(error)) {
      stats.failed += 1;
      throw error;
    }
    stats.fallback += 1;
    return fallbackLink(existingPath, newPath);
  }
}

function safeLinkSync(existingPath, newPath) {
  stats.attempted += 1;
  try {
    return realLinkSync(existingPath, newPath);
  } catch (error) {
    if (!isFallbackError(error)) {
      stats.failed += 1;
      throw error;
    }
    stats.fallback += 1;
    // 同步版：独占创建 + 复制
    let fd;
    try {
      fd = fs.openSync(newPath, 'wx');
    } catch (openError) {
      // 目标已存在 → 保持 EEXIST 语义
      throw openError;
    }
    try {
      fs.copyFileSync(existingPath, newPath, fs.constants.COPYFILE_FICLONE);
    } catch (error) {
      fs.closeSync(fd);
      fs.rmSync(newPath, { force: true });
      throw error;
    }
    fs.closeSync(fd);
    return undefined;
  }
}

/**
 * 安装补丁。幂等：重复调用只生效一次。
 */
function install() {
  if (fsp.__dshLinkShimInstalled) return;
  fsp.__dshLinkShimInstalled = true;

  // 必须在覆盖之前抓住真身
  realPromiseLink = fsp.link;
  realLink = fs.link;
  realLinkSync = fs.linkSync;

  // node:fs/promises —— dsh 主要走这条
  Object.defineProperty(fsp, 'link', {
    value: safeLink,
    writable: true,
    enumerable: true,
    configurable: true,
  });

  // node:fs 回调版
  fs.link = function patchedLink(existingPath, newPath, callback) {
    safeLink(existingPath, newPath).then(
      () => callback && callback(null),
      (error) => callback && callback(error)
    );
  };
  fs.linkSync = safeLinkSync;

  // 保留原始引用，方便排查
  fsp.__dshLinkShim = {
    realPromiseLink,
    realLink,
    realLinkSync,
    stats,
  };
}

module.exports = {
  install,
  safeLink,
  safeLinkSync,
  fallbackLink,
  selfTest,
  stats,
};

/**
 * 自检：验证两件事
 *   ① 接线正确 —— ESM 门面拿到的 link 就是被 patch 过的那个
 *   ② 降级语义正确 —— 独占创建（目标已存在 → EEXIST）+ 内容完整
 */
async function selfTest() {
  const os = require('node:os');
  const path = require('node:path');

  // ① 接线
  if (!fsp.__dshLinkShimInstalled) {
    throw new Error('link 绕过未安装');
  }
  const ns = await import('node:fs/promises');
  if (ns.link !== fsp.link) {
    throw new Error('ESM 门面未取到被 patch 的 link');
  }

  // ② 降级语义（直接测 fallbackLink，绕开真 link）
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'dsh-link-selftest-'));
  try {
    const src = path.join(dir, 'src.txt');
    const dst = path.join(dir, 'dst.txt');
    fs.writeFileSync(src, 'link-probe');

    await fallbackLink(src, dst);
    if (fs.readFileSync(dst, 'utf8') !== 'link-probe') {
      throw new Error('降级后内容不完整');
    }
    try {
      await fallbackLink(src, dst);
      throw new Error('目标已存在时未抛 EEXIST');
    } catch (error) {
      if (error.code !== 'EEXIST') {
        throw new Error(`EEXIST 语义被破坏: ${error.code}`);
      }
    }
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
  return true;
}
__LINK_SHIM_CJS__
  _emit node-pty-shim.cjs    __NODE_PTY_SHIM_CJS__    <<'__NODE_PTY_SHIM_CJS__'
/**
 * node-pty 管道替身
 * =================================================================
 *
 * 背景（实测）：
 *   dsh-subprocess-local 用 `createLazyRequire("node-pty", ...)` 拿终端实现。
 *   createLazyRequire 内部是 **CJS require** → 能被 Module._load 补丁拦到。
 *
 *   node-pty 的预编译二进制只有：
 *     darwin-arm64 / darwin-x64 / linux-arm64 / linux-x64 / win32-*
 *   **没有 linux-arm（32 位），更没有 android。**
 *   而 Termux 的 nodejs-lts 是 32 位 armeabi-v7a → node-pty 永远加载不了。
 *
 *   重要结论（实测）：**agent 跑命令根本不需要 node-pty**。
 *     - dsh-bash-local 用的是 `ctx.subprocess.spawn()`（管道）
 *     - node-pty 只被 `spawnTerminal()` 用（交互式终端）
 *     - agent 的工具清单里没有 terminal 工具
 *   所以 node-pty 坏掉时，**bash 工具照常工作**。
 *
 *   但 `spawnTerminal()` 一旦被调用就会抛错（no usable native binding），
 *   让交互式终端功能直接崩。这个替身把它降级成管道实现：
 *     - 能跑非交互命令，输出正常
 *     - 失去 isatty（颜色/进度条/需要 TTY 的程序会退化）
 *     - 失去真 resize（TIOCSWINSZ）
 *     - 失去线路规程（Ctrl-C 不再由 PTY 生成 SIGINT）
 *
 *   真 PTY 方案（Python 桥接）见 DSH_ON_TERMUX.md，需要时再上。
 *
 * 安装方式：在 dsh-require-hook.js 里 patch Module._load：
 *   真的 node-pty 能加载 → 用真的（桌面 Linux / macOS 不受影响）
 *   加载不了 → 用这个管道替身
 */

'use strict';

const { spawn: childSpawn } = require('node:child_process');

const SIGNAL_MAP = {
  SIGHUP: 1,
  SIGINT: 2,
  SIGQUIT: 3,
  SIGKILL: 9,
  SIGTERM: 15,
  SIGWINCH: 28,
};

/**
 * 最小 IPty 实现：pipe 版的 node-pty。
 * API 对齐 node-pty：onData / onExit / write / resize / kill / pause / resume
 */
class PipePty {
  constructor(file, args, options = {}) {
    const opts = options || {};
    this._dataSubs = new Set();
    this._exitSubs = new Set();
    this._paused = false;
    this._exited = false;
    this._exitInfo = null;
    this._pendingData = [];

    const env = opts.env ? { ...process.env, ...opts.env } : process.env;
    const spawnOpts = {
      cwd: opts.cwd || process.cwd(),
      env,
      stdio: ['pipe', 'pipe', 'pipe'],
      // 独立进程组：kill 时能连带子进程
      detached: process.platform !== 'win32',
      windowsHide: true,
    };
    if (opts.name) spawnOpts.name = opts.name;

    this._proc = childSpawn(file, args || [], spawnOpts);
    this.pid = this._proc.pid ?? -1;

    this._proc.stdout?.on('data', (chunk) => this._push(chunk));
    this._proc.stderr?.on('data', (chunk) => this._push(chunk));
    this._proc.on('error', (err) => {
      this._push(`\r\n[pty-shim] ${err.message}\r\n`);
      this._finish(1, 0);
    });
    this._proc.on('close', (code, signal) => {
      const exitCode = typeof code === 'number' ? code : 0;
      const sig = signal ? (SIGNAL_MAP[signal] ?? 0) : 0;
      this._finish(exitCode, sig);
    });
  }

  _push(chunk) {
    const text = chunk.toString('utf8');
    if (!text) return;
    if (this._dataSubs.size === 0) {
      // 还没有订阅者：缓存起来，等 onData 注册时补发
      this._pendingData.push(text);
      return;
    }
    for (const cb of this._dataSubs) {
      try {
        cb(text);
      } catch {
        /* 订阅者自己的错不该弄垮终端 */
      }
    }
  }

  _finish(exitCode, signal) {
    if (this._exited) return;
    this._exited = true;
    this._exitInfo = { exitCode, signal };
    for (const cb of this._exitSubs) {
      try {
        cb(this._exitInfo);
      } catch {
        /* 同上 */
      }
    }
    this._exitSubs.clear();
  }

  onData(cb) {
    this._dataSubs.add(cb);
    if (this._pendingData.length) {
      for (const text of this._pendingData.splice(0)) {
        try {
          cb(text);
        } catch {
          /* 同上 */
        }
      }
    }
    return {
      dispose: () => {
        this._dataSubs.delete(cb);
      },
    };
  }

  onExit(cb) {
    if (this._exited) {
      queueMicrotask(() => cb(this._exitInfo));
      return { dispose() {} };
    }
    this._exitSubs.add(cb);
    return {
      dispose: () => {
        this._exitSubs.delete(cb);
      },
    };
  }

  write(data) {
    if (!this._proc.stdin || this._exited) return;
    try {
      this._proc.stdin.write(typeof data === 'string' ? data : Buffer.from(data));
    } catch {
      /* 管道已关闭 */
    }
  }

  /** 没有真 PTY 就没法改窗口大小。这里至少不报错。 */
  resize(cols, rows) {
    void cols;
    void rows;
  }

  kill(signal) {
    if (this._exited) return;
    const name = signal || 'SIGHUP';
    const sig = typeof name === 'number' ? name : SIGNAL_MAP[name] ?? 'SIGHUP';
    try {
      if (process.platform !== 'win32' && this._proc.pid) {
        // 负号 = 整个进程组，连带子进程
        try {
          process.kill(-this._proc.pid, sig);
        } catch {
          this._proc.kill(sig);
        }
      } else {
        this._proc.kill(sig);
      }
    } catch {
      /* 已经死了 */
    }
  }

  pause() {
    this._paused = true;
    this._proc.stdout?.pause();
    this._proc.stderr?.pause();
  }

  resume() {
    this._paused = false;
    this._proc.stdout?.resume();
    this._proc.stderr?.resume();
  }

  /** node-pty 特有：查询底层进程状态 */
  get process() {
    return this._proc.pid ? String(this._proc.pid) : undefined;
  }
}

/**
 * node-pty 的模块接口。dsh 只用 spawn()，但把其余都补上以防万一。
 */
const api = {
  spawn(file, args, options) {
    return new PipePty(file, args, options);
  },
  fork(file, args, options) {
    return new PipePty(file, args, options);
  },
  open() {
    throw new Error('[pty-shim] open() 不支持');
  },
  createTerminal() {
    throw new Error('[pty-shim] createTerminal() 不支持');
  },
  native: null,
  __isPipeShim: true,
};

module.exports = api;
module.exports.default = api;
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
  for p in git python; do
    dpkg -s "$p" >/dev/null 2>&1 || MISSING_PKGS="$MISSING_PKGS $p"
  done
  if [ -n "$MISSING_PKGS" ]; then
    say "安装基础依赖:$MISSING_PKGS"
    pkg install -y $MISSING_PKGS 2>/dev/null || true
  else
    ok "基础依赖已齐（git python）"
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
