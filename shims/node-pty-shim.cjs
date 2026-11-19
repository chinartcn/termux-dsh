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
