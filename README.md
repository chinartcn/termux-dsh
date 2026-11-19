# termux-dsh

**在安卓手机（Termux）上跑 DeepSeek Harness (dsh) —— 一个 `.sh` 文件，五堵墙全翻，全程零编译。**

dsh（DeepSeek Harness）是"给模型装上手脚"的 agent 框架：能读文件、写文件、跑命令、连续干活。
官方**不支持安卓**，直接装会在启动时崩。这套方案把它在 Termux 上跑通了，并且**真机实测**：
对话能回、bash 工具能执行命令、session 能落盘。

和其它教程最大的不同：**不装编译器、不跑 `node-gyp`、不产生任何 `.node` 文件**。
所有原生依赖都用纯 JS 实现替换掉了（原理和证据见 [为什么不用编译任何原生模块](#为什么不用编译任何原生模块)）。
这应该是目前公开的、开箱即用的 dsh-on-Termux 零编译方案。

```bash
bash install_dsh_termux.sh
```

---

## 目录

- [30 秒上手](#30-秒上手)
- [为什么不用编译任何原生模块](#为什么不用编译任何原生模块)
- [已知限制（纯 JS 的代价）](#已知限制纯-js-的代价)
- [⚠️ 必读注意事项](#️-必读注意事项)
- [它长什么样](#它长什么样)
- [实战：拿它干真活](#实战拿它干真活2026-11-19-真机数据)
- [五堵墙](#五堵墙)
- [探索过程（完整实录）](#探索过程完整实录)
- [全部命令](#全部命令)
- [文件说明](#文件说明)
- [安全提醒](#安全提醒)
- [致谢](#致谢)

---

## 30 秒上手

**前置**：手机上装了 [Termux](https://f-droid.org/packages/com.termux/)。

```bash
# 1. 基础环境（不需要 build-essential / clang）
pkg install -y nodejs-lts git python

# 2. 装 dsh（只传一个 .sh 文件！~64KB，自包含）
bash install_dsh_termux.sh

# 3. 配 Key（二选一，都免费，见下）
echo 'export DANYAN_API_KEY=你的key' >> ~/.bashrc && source ~/.bashrc

# 4. 起
dsh-termux web
```

终端会打印一行带 `?token=` 的 URL，**整行复制**到手机浏览器：

```
dsh web: http://127.0.0.1:3080/?token=ScV--0EE0aUTwGbZsxlu4YBmnKqWkPQ1_mJQhAvY964
```

> ⚠️ **必须用 `dsh-termux`，不能用原版 `dsh`**。原版在 Termux 上启动即崩。

### 免费 Key 从哪来

| 端点 | 地址 | 说明 |
|---|---|---|
| **端砚**（推荐） | `https://discovery.intern-ai.org.cn/token-plan/home` | 上海人工智能实验室「墨点计划」，国内直连，1M 上下文。左侧「科研模型」→ 创建 API Key（**只显示一次**） |
| **NVIDIA NIM** | `https://build.nvidia.com` | 免费端点，要手机号验证。⚠️ 下架很勤，仅作兜底 |

配置是**覆盖层**（`~/.dsh-shim/free-models.yml`），`dsh-termux` 会自动加 `--patch`，
所以 **web / headless / tui 三个 profile 全部生效**，也不会被 dsh 升级冲掉。

---

## 为什么不用编译任何原生模块

绝大多数「在 Termux 上跑 XX」的教程，第一步都是 `pkg install build-essential`，
然后对着 `node-gyp` 的编译日志等十分钟，最后大概率等来一个 `clang: error`。
本方案从装到跑，**一次编译器都没调用过**。

这不是"碰巧没编"，而是设计如此：dsh 用到的原生依赖，**没有一个是真正必需的**。

### 三条可以直接复核的实测证据

```bash
# ① 整个 dsh 安装树里零个编译产物
find ~/.dsh ~/.local/share/pnpm -name '*.node' 2>/dev/null | wc -l
# → 0

# ② 启动入口是纯 JS，不是二进制
cat "$(command -v dsh-termux)"
# → exec node --expose-internals ~/.dsh-shim/dsh-shim.js "$@"

# ③ 补丁全部在 node_modules 之外，且都是文本文件
ls ~/.dsh-shim/
# → dsh-shim.js  dsh-require-hook.js  dsh-loader-hooks.mjs  flock-shim.mjs
#    link-shim.cjs  node-pty-shim.cjs  dsh-termux  ...
```

第 ③ 点顺带解决了一个老问题：社区常见做法是直接改 `node_modules` 里的文件，
`npm i -g` 一升级就被覆盖回去。这套方案**从头到尾不写过 `node_modules`**。

### 替换清单

| 原生依赖 | 它本来干什么 | 纯 JS 替代 | 代价 |
|---|---|---|---|
| `node-addon-require-builtin` | 不开 `--expose-internals` 时拿 Node 内部模块 | `--expose-internals` + `requireBuiltin()` | **无**，功能等价 |
| `@deepseek-ai/node-addon-system/flock` | 跨进程文件锁 | `O_EXCL` 哨兵文件 | **无**，真跨进程互斥 |
| `fs.link()` | 原子发布文件 | `open(dest, 'wx')` + 复制 | **无**，`EEXIST` 语义不变 |
| `node-pty` | 交互式终端 | 管道替身 | 有，见下节 |
| `sharp` | 图像处理 | `@img/sharp-wasm32` | 内存/速度，可接受 |

四行「无」，一行「有代价」——代价那行不藏，见 [已知限制](#已知限制纯-js-的代价)。

### 三种架构，同一个结论

关键不是"安卓没有预编译包"，而是**预编译包存在与否，跟本方案的成败无关**。
这决定了它不会被某一种机型限定：

| 环境 | 原生包为什么用不了 | 本方案 |
|---|---|---|
| **Android 32 位**（`arm` / armeabi-v7a） | node-pty 压根没有 `linux-arm` 预编译包 | ✅ 纯 JS |
| **Android 64 位**（`arm64`） | 有 `linux-arm64/pty.node`，但它是 **glibc** 链接的，Termux 是 **bionic**，照样加载失败 | ✅ 纯 JS |
| **桌面 Linux / macOS** | 预编译包能正常加载 | ✅ shim 检测到可用就**不劫持**，直接用真模块 |

最后一行很重要：这不是一个"为安卓写死"的补丁。
在能加载真模块的平台上它自动让路，不影响上游行为。

---

## 已知限制（纯 JS 的代价）

把话说前面：**这是降级运行，不是等效运行。**

### ① 交互式终端降级成管道

`spawnTerminal()` 拿到的是管道替身，不是真 PTY：

- `isatty()` 为假 → 颜色、进度条、需要 TTY 的程序（`vim`、`less`、`top`）会退化
- 不能 `resize`（没有 `TIOCSWINSZ`）
- `Ctrl-C` 不会由 PTY 生成 `SIGINT`，得直接 kill 进程

**但 agent 干活不受影响**：dsh 的 bash 工具走的是 `ctx.subprocess.spawn()`（管道），
工具清单里也没有 terminal 工具。所以"让模型读文件、跑命令"这条主链路是完整的——
实测的 `ls -la`、写文件、跑 Python，全部正常。

真 PTY 的 Python 桥接方案在 [`docs/DSH_ON_TERMUX.md`](docs/DSH_ON_TERMUX.md) 里，
需要 TUI 时再上，不是必需。

### ② sharp 走 WASM

图像处理比原生版慢、占内存更多。dsh 的日常对话用不到，只有处理图片时才相关。

### ③ 打开的是 Node 内部模块

`--expose-internals` 让 `internal/...` 可见，权限高于默认状态。
只在跑 dsh 时用，别把这个标志的 node 拿去跑别的不可信代码（下方安全提醒有展开）。

---

## ⚠️ 必读注意事项

### ① 必须开「完全权限」，否则会报错

Web UI 左下角有个**权限模式**下拉，默认不是「完全权限」。

**不开完全权限，agent 调工具会被直接拒绝**，报错长这样：

```
本轮运行失败  tool call rejected: approval required
```

正确设置：**左下角权限模式 → 完全权限**（截图里显示「完全权限」时一切正常）。
批准策略保持默认即可。

> 开了完全权限意味着 agent 跑命令**不再逐条问你**。请只在信任的目录里用（见下方安全提醒）。

### ② 别跑 npm 提示你的那条 `--allow-scripts` 命令

npm 装完可能会提示：

```
npm warn install-scripts  node-pty@1.2.0-beta.15 (install: node scripts/prebuild.js || node-gyp rebuild; ...)
```

**不要执行它建议的 `npm install -g --allow-scripts=...`**。
node-pty 在 Termux 上会触发 `node-gyp` 编译，bionic 下几乎必挂，**整个 npm install 会失败**。
安装器已经用 `--ignore-scripts` 绕开了，node-pty 也有纯 JS 替身兜底。

### ③ 任何写入都要你同意

安装器**不会静默写任何文件**——新建和覆盖都要先点头：

| 情况 | 行为 |
|---|---|
| **文件不存在** | **弹 `[y/N/a]`，默认 N（新建也要同意）** |
| 内容相同 | 跳过（本来就不用写，不打扰） |
| **内容不同** | **弹 `[y/N/a]`，默认 N；同意后先备份再覆盖** |
| 提问时回 `a` | 本次运行剩余文件全部同意 |
| 没终端（管道 / cron） | 一律不写，只提示 |
| `--reset-config` | 强制覆盖（先自动备份 `.bak.<时间戳>`） |
| `--yes` | 本次全部同意（显式传入才算） |

> 一个都没同意时，安装器连 `~/.dsh-shim` 目录都不会建，并在结尾提示「有 N 个文件未写入」。

改坏了想还原：删掉 `~/.dsh-shim/free-models.yml` 重跑，或 `bash install_dsh_termux.sh --reset-config`。

### ④ 重跑很快（幂等）

```bash
bash install_dsh_termux.sh     # 第二次跑：1.2 秒，不重复下载
```

版本号匹配就**完全跳过** dsh 下载；shim 文件逐字节比对，内容相同不重写。

### ⑤ `/bin/sh` 不存在

Termux 的 shell 在 `$PREFIX/bin/sh`，`/bin/sh` **不存在**。
别让 agent 假设 `/bin/bash`（dsh 的 bash 工具本身用 `sh -c`，没问题）。

### ⑥ 存储权限

要读写 `/storage/...` 下的目录（SD 卡、共享存储），先执行：

```bash
termux-setup-storage
```

### ⑦ Node 版本必须 ≥ 24.9.0

dsh 的 `engines` 要求。Termux 里 `pkg install nodejs-lts`（24.x）或 `nodejs`（26.x）都够。
安装器会自己检查，不够就提示装。

### ⑧ 升级 dsh 后补丁还在

所有补丁都**不碰 `node_modules`**：
`link` / `flock` 走 loader hook，`requireBuiltin` 走 CJS 预加载劫持。
`npm i -g @deepseek-ai/dsh` 升级完直接能用，不用重打补丁。

### ⑨ 体检脚本

想知道你手机上哪项受限，跑：

```bash
bash install_dsh_termux.sh --check
```

逐项实测 `statx` / `renameat2` / `fsync` / `link()` / `/dev/shm` / `os.tmpdir()` /
inotify 上限 / node-pty / sharp / koffi。**只读不写**，跑多少次都不影响配置。

---

## 它长什么样

真机（Termux / 安卓 32 位 / Node 26）实测：

```
你 → "hi"
它 → Hi! Ready when you are.
     Note for this session: approvals are off, so anything needing one will be
     rejected outright rather than prompting.

你 → "ls一下"
它 → 执行了命令
     → 当前目录 /data/data/com.termux/files/home/test 是空的 —— 只有 . 和 ..，
       没有任何文件或子目录。
     → 需要我在这里创建点什么，还是去别的目录看看？
```

轨迹面板里能看到完整的工具调用：

```
工具   bash
参数   {"command":"ls -la","description":"list files in current directory"}
结果   drwx------  2 u0_a479 u0_a479 3488 Nov 19 06:24 .
       drwx------ 33 u0_a479 u0_a479 3488 Nov 19 12:32 ..
Schema "Execute a bash command (/bin -c) and return its stdout/stderr."
```

链路：**对话 → 调模型 → 调工具 → 跑命令 → 结果回灌 → 上下文累积 → session 落盘**。全通。

---

## 实战：拿它干真活

不是玩具。真机上跑过**连续 1 小时以上的长任务（198 步）**，全程稳定无崩溃：

```
✅ 对话正常、工具调用正常
✅ bash 工具执行命令、返回真实输出
✅ session 正常落盘（session.v4.jsonl.zstd + session.lock）
✅ 13.5M token，缓存命中 97%
```

### 从长任务里学到的三件事

**① 它能正确判断自己做不到什么。**
遇到无 GPU 环境无法编译 shader 的步骤时，它没有假装能做、也没留下坏文件，
而是识别出环境限制并把这一步交回给你。这比"跑通"更重要。

**② 后台任务是原生的。** 长时间任务用 `job_list` / `job_output` / `job_kill` 管，不阻塞主流程。

**③ 97% 缓存命中是长任务的命根子。** 没有缓存机制，长任务的开销会失控。

### 长任务要注意的

```bash
# 终端/进程被杀后，session 还在磁盘上（~/.dsh/sessions/）
dsh-termux headless --session-id session-xxxx "继续"

# 看有哪些 session
ls ~/.dsh/sessions/*/session-*/

# 后台任务状态
dsh-termux job list
```

⚠️ **手机内存紧张时 Android 会杀 Termux**。长任务开始前：
- 把 Termux 加进「电池优化」白名单（设置 → 应用 → Termux → 电池 → 不受限制）
- 保持屏幕常亮或用 `termux-wake-lock`

---

## 五堵墙

dsh 官方不支持安卓。启动到能干活，中间要翻五堵墙。每一堵都是**读源码读出来的**，不是猜的。

| # | 报错原文 | 根因 | 解法 |
|---|---|---|---|
| ① | `No usable native binding found for node-addon-require-builtin-android-arm` | 官方无 android 预编译包。那个原生 addon 唯一作用就是"不用 `--expose-internals` 也能拿 Node 内部模块" | `--expose-internals` + 纯 JS `requireBuiltin` 替代，**功能等价** |
| ② | `本轮运行失败 flock is not supported on android-arm` | JS 入口硬编码 `platform !== 'linux' && platform !== 'darwin'`，而 Termux 是 **Linux 内核**，被纯逻辑误判 | 纯 JS 复刻：`O_EXCL` 哨兵文件实现**真跨进程互斥** |
| ③ | `EACCES: permission denied, link` | **Android SELinux 禁止 untrusted_app 对 app_data_file 建硬链接**。dsh 用 `link()` 做「原子发布且不覆盖」 | 降级为 `open(dest,'wx')` + 复制。`O_EXCL` 是内核级原子，**EEXIST 语义完全不变** |
| ④ | node-pty 加载失败 | 预编译只有 `darwin-*` / `linux-arm64` / `linux-x64` / `win32-*`，**没有 32 位，更没有 android** | 实测 agent 的 bash 走**管道**根本不需要它 → 只加管道替身兜底 |
| ⑤ | sharp 加载失败 | `@img/sharp-linux-arm` 是 **glibc** 版，Termux 是 bionic | sharp 加载顺序最后有通用兜底 `require("@img/sharp-wasm32/sharp.node")` → 装 WASM 版（约 10MB） |

### 每堵墙的验证方式

**不是"应该能行"，是有对照实验。** 搭一个假的 OpenAI SSE 服务器，让 dsh 真的跑完一轮对话，
再把真 `link()` 模拟成安卓的 EACCES：

| 条件 | 结果 |
|---|---|
| 正常 Linux | ✅ 对话成功，`session.v4.jsonl.zstd` 落盘 |
| **模拟安卓 EACCES + 无 shim** | ❌ `dsh: EACCES: permission denied, link`，**只剩 `session.lock`** |
| **模拟安卓 EACCES + 有 shim** | ✅ 对话成功，`session.v4.jsonl.zstd` 正常落盘 |

对照组复现的报错和真机**一字不差**。有它能写、没它写不出 —— 因果关系钉死。

### 三个关键的技术细节（别自己改）

**① `--expose-internals` 不允许放进 `NODE_OPTIONS`**
```
node: --expose-internals is not allowed in NODE_OPTIONS
```
只能走命令行标志 → 所以必须包一层 `dsh-termux`。

**② `Module._load` 补丁拦不到 ESM 的 import**
实测 `intercepted: null`。dsh 用 ESM 静态导入
（`import { tryLockExclusive } from "@deepseek-ai/node-addon-system/flock"`），
**唯一可行的是 `module.register()` 的 loader hook**，而且必须在 **CJS 预加载里**调
（`node --import hooks.mjs` 对静态 import 不生效）。

**③ 内置模块的 ESM 门面是惰性快照**
在 CJS 预加载里改 `require('node:fs/promises').link`，
之后 ESM 的 `import { link } from 'node:fs/promises'` 拿到的就是改过的值。
（这条是墙③ 能成立的前提，实测过。）

---

## 探索过程（完整实录）

### 阶段一：想清楚"为什么需要 agent"

原来的做法是**传代** —— 上下文快满 → 导出整份对话记录 → 发给下一代。
问题不在记忆（文件和 Gitee 都在），而在**投递**：4 万字单次输入、7 天不活跃长对话不续接。

agent 时代这个约束消失了：记忆放文件系统，**换模型 = 换值班员，档案不动**。
所以目标从"传代工具"转向"让 dsh 在手机上跑起来"。

### 阶段二：定位墙

第一版直接在 Termux 装 dsh，撞墙：

```
dsh: host preparation failed: No usable native binding found for node-addon-require-builtin-android-arm (auto)
```

`npm i -g` 装出来的 `node_modules` 里全是平台相关的原生包。
逐个查 `package.json` 的 `optionalDependencies`，发现预编译矩阵**完全不含 android**。

### 阶段三：纯 JS 替代（不碰 node_modules）

社区方案是直接改 `node_modules` 里的文件 —— **每次 `npm i -g` 都被覆盖**。
改成拦截层：

```
dsh-termux (包装命令)
  └─ node --expose-internals --require dsh-require-hook.js <dsh-bin> <args>
       ├─ 劫持 node-addon-require-builtin  → 纯 JS requireBuiltin
       ├─ module.register()               → ESM loader hook
       │     └─ flock 重定向到本地实现
       └─ patch fs.promises.link           → 安卓降级
```

顺带发现 dsh 的 `bin.js` 用 `import.meta.main` 判断主入口，
用 `import()` 动态加载时 CLI **不执行**（静默无输出，我第一版就栽在这）→ 必须 spawn 子进程。

### 阶段四：逐堵墙验证

- **墙② flock**：先在沙箱模拟（`NARB_DISABLE_OPTIONAL_PACKAGE=1`），
  跑 `--version` → 配置解析 → web server → headless → **session 真实落盘**。
- **墙③ link**：读源码定位到 `dsh-session-persistence-jsonl` 的
  `materializePosix()` / `publishCurrentExclusive()` 两处 `link()` 调用。
  然后搭假 OpenAI 服务器 + 假模型发 tool_call，做上面那组对照实验。
- **墙④ node-pty**：**先证伪再动手**。查 `dsh-bash-local` 用的是
  `ctx.subprocess.spawn()`（管道），node-pty 只被 `spawnTerminal()` 用，
  而 agent 工具清单里没有 terminal → **不需要真 PTY**，
  于是否掉了"Python PTY 桥接"这类重型方案，只留一个管道替身兜底。
- **墙⑤ sharp**：查 sharp 0.35.5 的 `dist/sharp.cjs`，发现加载顺序最后
  有 `require("@img/sharp-wasm32/sharp.node")`。再模拟 Termux 的目录结构
  验证 node 的模块查找能走到 `$PREFIX/lib/node_modules` → 全局装就能被找到。

### 阶段五：回到真实需求

用户反馈：「不要写配置，要么 y/n 确认后写，要么别写。每次我改完都覆盖了。」

于是给安装器加了写入保护层。实现时踩了个坑：一开始用 `[ -t 0 ]` 判断是否交互，
但写文件用的是 heredoc，**heredoc 会把整个函数的 stdin 重定向成临时文件**，
`-t 0` 永远是假 → 提示永远不出现。是用 Python pty 精确复现交互才抓到的，
改用 `/dev/tty` 才正确。

### 阶段六：真机跑通

2026-11-19，Termux / 安卓 32 位 armeabi-v7a / Node 26：

```
你 → "ls一下"     →  执行了命令  →  当前目录是空的
工具 bash {"command":"ls -la"}  →  返回目录列表
```

五堵墙全过。**记忆档案从"一堆 txt"变成了"有手有脚的家谱"**。

---

## 全部命令

```bash
# 安装（只传这一个文件）
bash install_dsh_termux.sh

# 选项
bash install_dsh_termux.sh --check         # 安卓环境体检（只读）
bash install_dsh_termux.sh --extract        # 只解包 shim，不安装
bash install_dsh_termux.sh --no-key         # 不打印 Key 步骤
bash install_dsh_termux.sh --reinstall      # 强制重装 dsh
bash install_dsh_termux.sh --reset-config   # 强制覆盖配置（先备份）
bash install_dsh_termux.sh --yes            # 本次全部同意（先备份）

# 用
dsh-termux web                    # Web UI
dsh-termux headless "任务描述"    # 无头，跑完退出
dsh-termux tui                    # 终端 UI
dsh-termux rescue --from-default-profile web   # 配置搞坏了，重置

# 底层
node --expose-internals --require ~/.dsh-shim/dsh-require-hook.js \
     $(npm root -g)/@deepseek-ai/dsh/lib/bin.js <args>

# 看配置
cat ~/.dsh-shim/free-models.yml
```

环境变量：
- `DANYAN_API_KEY` —— 端砚（推荐）
- `NVIDIA_API_KEY` —— NVIDIA NIM
- `DSH_HOME` —— 配置与凭据目录（默认 `~/.dsh`）
- `DSH_TELEMETRY_DISABLED` —— 关遥测（介意就设）

---

## 文件说明

```
termux-dsh/
├── install_dsh_termux.sh      ← 【只需要这一个】自包含安装器（64KB，内嵌 6 个 shim）
├── README.md                  ← 本文件
├── docs/
│   └── DSH_ON_TERMUX.md       ← 深度长文：每堵墙的根因、源码位置、实测证据
└── shims/                     ← 源码（开发用，手机上不用传）
    ├── dsh-shim.js            入口包装：定位 dsh、spawn 子进程带 --expose-internals
    ├── dsh-require-hook.js    CJS 预加载：劫持 requireBuiltin + 注册 loader hook + link 降级
    ├── dsh-loader-hooks.mjs   ESM loader hook：flock 重定向
    ├── flock-shim.mjs         纯 JS flock 替代（O_EXCL 哨兵文件，真互斥）
    ├── link-shim.cjs          link 降级（O_EXCL 独占创建 + 复制，保持 EEXIST 语义）
    ├── node-pty-shim.cjs      node-pty 管道替身（真身可用用真身）
    └── build_single_file.py   把上面 6 个重新打包成单文件
```

改了 shim 想重新打包：

```bash
cd shims && python3 build_single_file.py
```

生成器会**校验解包结果与源文件逐字节一致**（heredoc 最容易在这里被变量展开搞坏）。

---

## 安全提醒

dsh 官方 SAFETY.md 原话，不是吓唬你：

- dsh 是**开发者预览版**，**未经安全审计**
- **会执行模型生成的代码和命令**
- 本地 RPC **无鉴权**（只靠 Host 头检查，不是认证层）
- 插件是**未签名代码**，装了等于让它在你进程里跑任意代码
- 官方建议：**一次性虚拟机/容器**、保留备份、最小权限

**对手机的意义**：别在 Termux 根目录跑；工作目录限定在你信任的目录；
别把别的 App 的 Key 放进来。

> 额外提醒：`--expose-internals` 打开了 Node 的内部模块访问权限，比默认状态权限更高。
> **只在跑 dsh 时用，别把带这个标志的 node 拿去跑别的不可信代码。**

还有一条：`--host 0.0.0.0` 会被 dsh **直接拒绝**，报错原文：

> `--host 0.0.0.0 is an unspecified (wildcard) address, which is not supported:
> binding every interface would expose remote code execution to the network`

**这是故意的安全设计，不是 bug。** 手机上用 `127.0.0.1` 就行。

---

## 致谢

- [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness)（MIT，开发者预览）
- [Termux](https://f-droid.org/packages/com.termux/)
- 上海人工智能实验室「墨点计划」（端砚免费端点）
- NVIDIA NIM（免费端点）

本仓库的方案基于对 dsh 源码的逐行阅读 + 对照实验验证，欢迎提 issue 补充。

## License

MIT
