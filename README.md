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
# 产物：release/DSH-Desktop-0.1.0-portable.exe

# 5.（可选）NSIS 安装包
npm run dist:nsis
```

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

## 已知限制 / Roadmap

- [ ] 自动更新（下载新版 dsh 二进制）
- [ ] 会话录制（Tauri 版已有 recorder 桩；Electron 版可接 desktopCapturer）
- [ ] 内核版本对齐校验：DSH 仍是 Developer Preview（`@deepseek-ai/dsh@0.1.0-rc.6`），
      **预期 breaking changes**，建议固定全局 dsh 版本
- [ ] GitHub Releases 挂载打包产物
