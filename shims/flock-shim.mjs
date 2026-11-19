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
