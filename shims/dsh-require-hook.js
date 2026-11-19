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
