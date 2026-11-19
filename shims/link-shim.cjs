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
