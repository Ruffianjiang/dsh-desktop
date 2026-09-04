# DeepSeek Harness Desktop (Tauri 2)

把 [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) 的 Web UI
（`dsh web` → http://127.0.0.1:3080）包装成桌面软件的 Tauri 2 骨架。

桌面主进程负责拉起 `dsh web` 子进程、管理端口、承载 WebView，并在窗口关闭时
正确回收子进程，避免孤儿进程。这是社区桌面壳（anywhere-labs 的 Electron 版、
各 Tauri 2 版）的通用模式。

> ⚠️ **版本对齐警告**：DSH 仍是 Developer Preview（`@deepseek-ai/dsh@0.1.0-rc.6`），
> 官方**不保证兼容性、预期 breaking changes**。桌面壳与内核必须**锁定同一版本/commit**，
> 否则 `dsh web` 的 API 一变，WebView 就白屏。建议通过 Git submodule 钉死某个 commit，
> 并在外壳里做内核版本校验。

## 目录结构

```
dsh-desktop-tauri/
├── .gitmodules              # 钉死上游 deepseek-harness（submodule，不 fork）
├── package.json             # 前端（React + Vite + Tauri CLI）
├── vite.config.ts
├── index.html
├── src/                     # React 前端：加载 iframe + 状态轮询 + 录制按钮
│   ├── App.tsx
│   ├── App.css
│   └── main.tsx
├── scripts/
│   └── make_icons.py        # 生成占位图标（PNG/ICO/ICNS）
└── src-tauri/               # Rust 后端（Tauri 2）
    ├── Cargo.toml
    ├── build.rs
    ├── tauri.conf.json      # ★ CSP 已放行 127.0.0.1:3080（frame-src/connect-src）
    ├── capabilities/default.json
    └── src/
        ├── main.rs
        ├── lib.rs           # 命令注册 + 系统托盘
        ├── supervisor.rs    # ★ 进程生命周期：spawn/kill/`Drop` 回收
        ├── recorder.rs      # 录制参考模块（scap/cpal/ffmpeg 占位）
        └── download.rs      # submodule 初始化 + 构建 dsh
```

## 环境依赖

- **Node ≥ 22.19**（匹配 DSH 要求）
- **Rust 工具链**（stable，≥ 1.77）
- **pnpm**（DSH 用 pnpm workspace）
- **Tauri CLI**：`pnpm add -g @tauri-apps/cli` 或 `cargo install tauri-cli`
- **Tauri 系统依赖**：见 https://tauri.app/start/prerequisites/ （Windows 需
  Microsoft C++ Build Tools；WebVIew2 运行时）
- 全局 `dsh` 命令（推荐）：`npm i -g @deepseek-ai/dsh`

## 快速开始

```bash
# 1. 生成占位图标（否则 tauri build 缺图标）
python scripts/make_icons.py

# 2. 拉取并钉死上游内核（仅首次）
git submodule update --init --recursive
cd dsh && git checkout <某次 rc commit> && cd ..

# 3. 安装前端依赖
pnpm install

# 4. 开发模式（前端热更 + Rust 重新编译）
pnpm tauri dev

# 5. 打包（注意用 tauri 而非 cargo build --release）
pnpm tauri build
```

## 两种 dsh 来源（任选其一）

1. **系统全局 `dsh`**（默认，最简单）：`npm i -g @deepseek-ai/dsh`，
   外壳直接 `spawn("dsh", ["web"])`。
2. **构建 submodule**（版本可控）：保持 `.gitmodules` 钉死 commit，让
   `download::ensure_dsh_binary()` 在首次启动时 `pnpm install && pnpm build`，
   产物在 `dsh/dist/dsh`。可用 `DSH_BIN=./dsh/dist/dsh` 覆盖二进制路径。

## 关键环境变量

| 变量 | 作用 | 默认 |
|---|---|---|
| `DSH_BIN` | 指定 dsh 可执行文件路径 | `dsh`（取 PATH） |
| `DSH_PORT` | 指定监听端口（窗口关闭后若被占会自动 +1 探测） | `3080` |

## 架构要点

- **supervisor.rs**：封装 `dsh web` 子进程。`start()` 仅在端口≠默认时追加
  `--port`；`wait_for_ready()` 通过 TCP 探测 `127.0.0.1:port` 判断就绪；
  实现 `Drop` 保证窗口关闭时 `kill` 子进程，杜绝孤儿进程。
- **lib.rs**：Tauri `State` 持有 `supervisor` / `recorder`；暴露
  `start_dsh` / `stop_dsh` / `dsh_status` / `dsh_url` / `toggle_record` 五个
  command；`setup` 中创建带「退出」菜单的系统托盘。
- **recorder.rs**：录制参考模块，当前为 no-op 桩。真实实现接 `scap`（屏幕）+
  `cpal`（音频）+ `ffmpeg`（封装）。前端「开始录制」按钮已接 `toggle_record`。
- **download.rs**：submodule 初始化与构建逻辑，确保 dsh 二进制存在。
- **前端 App.tsx**：挂载即自动 `start_dsh`，每 1s 轮询 `dsh_status`；就绪后
  用 `<iframe src="http://127.0.0.1:port">` 承载 Web UI。

## 二次开发：接入你自己的 Bundle / Plugin

DSH 的扩展点是 **Cordis 插件体系**，不是改内核。桌面壳应：

1. 在 submodule 里编写你的 **Bundle + Plugin**（自定义 `Provider` 接你的模型/
   工具，或桌面原生能力插件），通过 `cordis.patch.yml` 挂到插件树。
2. 桌面壳只负责「把内核跑起来 + 承载 WebView + 加系统级能力」（托盘、自动更新、
   文件对话框、通知），**不要 fork 改内核源码**。

示例：在 `dsh/packages/` 下新增一个包，注册为 Cordis 插件，再在 `Profile` 里启用
它即可，无需改动本桌面壳。

## 已知限制 / 后续

- `dsh web --port` 参数依赖 DSH 实际支持；若不支持，端口 fallback 会失效
  （默认 3080 不受影响）。请以 `dsh web --help` 为准调整 `supervisor.rs`。
- 图标为占位蓝色方块，发布前请替换为正式品牌图标。
- recorder 为桩实现，接真实捕获需引入 scap/cpal 并配置 Tauri capability。
- 未做自动更新（下载/解压新版 dsh 二进制），如需可参考社区壳的 `download.rs` 扩展。
