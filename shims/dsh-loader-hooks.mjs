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
