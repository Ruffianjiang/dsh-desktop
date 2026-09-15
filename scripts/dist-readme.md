# DSH Desktop v0.4.0 (MVP · Windows x64)

> DeepSeek Harness 管理平台桌面客户端。安装 / 升级 / 启动 / 停止 dsh 引擎，
> 并提供自研跨平台原生对话 UI，直连 dsh 结构化 API（REST + SSE）。

## 运行环境要求

| 依赖 | 说明 |
|---|---|
| **操作系统** | Windows 10 / 11 x64 |
| **Node.js** | **必须预装**，`node` 在 PATH 中且版本 ≥ dsh 引擎要求（建议 ≥ 20 LTS）。本程序**不包含** Node.js 运行时。 |
| **Visual C++ 运行时** | **未随包分发**——目标机需安装 **Visual C++ Redistributable for Visual Studio 2022 (x64)**；本机已装 Visual Studio 则已满足。 |
| **dsh 引擎** | 由本程序负责安装到托管目录 `~/.dsh-desktop/engine`，或从 PATH 探测现有 dsh。 |

## 安装与启动

1. 解压 `dsh-desktop-v0.4.0-mvp-windows-x64.zip` 到任意目录（路径不要含中文 / 空格以外的非常规字符）。
2. 确认本机已安装 Node.js：命令行执行 `node -v` 应输出版本号。
   - 若未安装或版本过低，请先从 <https://nodejs.org> 安装 ≥ 20 LTS，再启动本程序。
3. 双击 `dsh_desktop.exe` 启动。
4. 首次启动后在「引擎」页完成 dsh 引擎安装（托管前缀 `~/.dsh-desktop/engine`）；
   若本机已有 dsh 且位于 PATH，程序会自动探测复用。

## 功能范围（v0.4.0 MVP）

- 实例管理：列出 / 启动 / 停止 dsh 实例，活动端点**绑定实例**并随实例重启自动跟随端口。
- 对话工作台：连接运行中实例，支持工具调用卡片（call/result 聚合、可展开详情）、
  思考过程折叠、Markdown 渲染、Token 用量与速率统计行。
- 系统集成：引擎检测闭环（托管前缀优先 + 安装热替换），自动连接运行中实例。

## 已知限制（MVP）

- 仅 Windows 首发；macOS / Linux 于后续里程碑（M4）。
- 鸿蒙桌面端已立项，未纳入本次发版。
- 老旧 Electron / Tauri「封装 dsh web 外壳」路线（v0.1.0–v0.3.0）已归档至 `legacy/`。

## 反馈与问题

详见仓库 `docs/` 目录与 `RELEASES.md`。
