# DSH Desktop

把 [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) 的 Web UI
（`dsh web` → http://127.0.0.1:3080）包装成 Windows 桌面应用。

仓库内含**两条实现轨道**：

| 轨道 | 位置 | 状态 | 依赖 |
|---|---|---|---|
| **Electron（主轨道，可运行）** | 仓库根目录 `electron/` | ✅ 已验证可启动、可打包 | 仅 Node ≥ 18 |
| Tauri 2 骨架（第二轨） | `tauri-skeleton/` | 源码完整，需 Rust 工具链 | Rust ≥ 1.77 + MSVC Build Tools |

选 Electron 作为主轨道的原因：本机无 Rust / 无 MSVC，安装 VS Build Tools 需管理员
提权 + 约 7GB；Electron 用现有 Node 工具链即可开发与打包。Tauri 版代码完整保留，
在具备工具链的机器上按 `tauri-skeleton/README.md` 即可构建。

## 运行原理

```
┌─ DSH Desktop (Electron) ─────────────────────────┐
│  main.cjs                                        │
│   ├─ spawn("dsh", ["web"])          子进程       │
│   ├─ TCP 探测 127.0.0.1:3080 就绪                │
│   ├─ BrowserWindow.loadURL(3080)    承载 Web UI  │
│   ├─ 托盘：显示窗口 / 退出                        │
│   └─ 退出时 taskkill /T /F 回收子进程树          │
└──────────────────────────────────────────────────┘
```

- 窗口关闭 = 隐藏到托盘（不杀进程）；托盘「退出」才真正退出并回收 `dsh`。
- 端口 3080 已有服务时自动进入 **attach 模式**（复用已有 dsh，不重复拉起）。
- 单实例锁：重复启动会聚焦已有窗口。
- `dsh` 未安装 / 启动失败时，窗口显示错误页 + 内置日志 + 「重试启动」按钮。

## 快速开始

```bash
# 1. 安装依赖（含 Electron 二进制，约 110MB）
npm install

# 2. 安装 DeepSeek Harness CLI（应用运行的前置条件）
npm i -g @deepseek-ai/dsh

# 3. 开发运行
npm start

# 4. 打包 Windows portable 单文件 exe
npm run dist:portable
# 产物：release/DSH-Desktop-<版本>-portable.exe（当前 v0.2.0）

# 5.（可选）NSIS 安装包
npm run dist:nsis
```

> **国内加速**：Electron 二进制默认从 GitHub 下载较慢，`npm install` 前可设置
> `ELECTRON_MIRROR=https://npmmirror.com/mirrors/electron/`
> （PowerShell：`$env:ELECTRON_MIRROR="https://npmmirror.com/mirrors/electron/"`）。

## 环境变量

| 变量 | 作用 | 默认 |
|---|---|---|
| `DSH_BIN` | 指定 dsh 可执行文件路径 | `dsh`（取 PATH） |
| `DSH_PORT` | 指定监听端口 | `3080` |

> 注意：仅当 `DSH_PORT ≠ 3080` 时才会向 `dsh web` 追加 `--port` 参数，
> 该参数是否被 dsh CLI 支持需以 `dsh web --help` 为准。

## 目录结构

```
dsh-desktop/
├── electron/
│   ├── main.cjs        # 主进程：子进程管理 / 托盘 / 单实例 / 错误页
│   ├── preload.cjs     # contextBridge：状态事件 + 重试
│   ├── error.html      # 启动中 / 失败页面（含日志与重试）
│   └── assets/icon.png # 窗口 / 托盘图标
├── build/icon.ico      # 打包图标（electron-builder）
├── scripts/make_icons.py  # 生成占位图标（纯 stdlib）
├── tauri-skeleton/     # Tauri 2 版本（第二轨，见其 README）
└── package.json
```

## Tauri 第二轨

`tauri-skeleton/` 保留了完整的 Tauri 2 实现（Rust supervisor / recorder /
download 模块 + React 前端）。若要启用：

```bash
cd tauri-skeleton
# 需要 Rust + MSVC Build Tools + WebView2（Win11 自带）
pnpm install && python scripts/make_icons.py && pnpm tauri dev
```

## 排障

- **在 WorkBuddy / 类终端沙箱中启动即"假崩溃"**：若 shell 注入了
  `ELECTRON_RUN_AS_NODE=1`（WorkBuddy 自身基于 Electron，会让子进程以纯 Node 模式运行），
  Electron 主进程 API 不会被加载，`require("electron")` 返回的是 exe 路径字符串，
  解构出的 `app` / `BrowserWindow` 全为 `undefined`，报
  `Cannot read properties of undefined (reading 'requestSingleInstanceLock')`。
  **这不是应用 bug**——在普通终端或双击 exe 启动不受影响。
  沙箱内运行请改用：
  ```bash
  env -u ELECTRON_RUN_AS_NODE -u NODE_OPTIONS node node_modules/electron/cli.js .
  ```
  （`NODE_OPTIONS` 里的 `node-language-shim` 也建议一并 unset）

- **`dsh` 找不到**：应用通过 `dsh web` 拉起内核，需 `dsh` 在 PATH 中
  （`npm i -g @deepseek-ai/dsh`）。缺失时会显示错误页并提示安装命令；也可用
  `DSH_BIN` 指向自定义路径。

- **窗口关闭后端口仍占用**：属正常 hide-to-tray 行为；彻底退出请用托盘「退出」，
  应用会以 `taskkill /T /F` 回收 dsh 子进程树。若异常残留，手动
  `taskkill /PID <pid> /T /F` 清理 3080 占用进程即可。

## 已知限制 / Roadmap

- [x] 内核版本对齐校验：启动时探测 `dsh --version`，版本号展示于托盘菜单与 tooltip
      （DSH 仍是 Developer Preview，**预期 breaking changes**，建议固定全局 dsh 版本）
- [x] 托盘「更新 dsh 内核」：执行 `npm i -g @deepseek-ai/dsh@latest` 并自动重启
- [x] GitHub Releases 挂载打包产物（v0.1.0 起）
- [x] 会话录制：托盘「开始/停止录制」，抓取主屏（VP9+系统音频，失败自动降级
      纯视频），流式写入 `Downloads/DSH-Recording-*.webm`；支持命令行
      `DSH-Desktop-<ver>-portable.exe --record` 切换（向已运行实例发指令）
- [x] 应用自身自动更新：托盘「检查应用更新…」查 GitHub Releases latest，下载
      portable exe 到 Downloads，弹窗一键重启升级（`will-quit` 拉起新 exe，
      利用 portable 自解压延迟避开单实例锁）
