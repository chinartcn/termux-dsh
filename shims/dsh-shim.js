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
