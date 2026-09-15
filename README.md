# dsh-desktop

> 状态：v0.4.0 MVP 已发布（分支 `feat/v0.4-m3` 已 push origin；发版明细见 `RELEASES.md`，打包见 `scripts/package_release.ps1`）。

## 当前定位（v0.4.0 起）

**dsh 管理平台**：安装/升级/启动/停止 dsh 引擎，并提供**自研跨平台原生对话 UI**，直连 dsh 自身结构化 API（REST + SSE），**不加载、不嵌入 dsh web 页面**（不是外壳）。

- 主客户端：Flutter Desktop（Windows 首发，macOS/Linux 随后）——本次发版目标
- 鸿蒙桌面端（ArkTS/ArkUI）：已**立项**，不纳入本次发版（后续其他机器开发验证）
- 详见 `docs/06-迭代开发/20260903-dsh管理平台Gate-A/`（方案设计 v1.1 / 详细设计 v1.0）

## 仓库布局

| 路径 | 说明 |
|---|---|
| `apps/desktop_flutter/` | 主客户端（Flutter，M3 起实建） |
| `apps/probe_cli/` | 协议联调 Dart CLI（M1 原型） |
| `packages/contract/` | L3 协议契约：schema + golden 样例（唯一事实源） |
| `packages/client_dart/` | L3 Dart 客户端实现 |
| `legacy/` | 旧架构归档：`electron/`、`tauri-skeleton/`（不构建，仅供历史参考） |
| `docs/06-迭代开发/` | SPEC 迭代文档 |

## 里程碑（本次发版）

- M1 协议客户端原型：连真实 `dsh web` 完成一轮对话（CLI）
- M2 引擎/实例管理 + 纯 API profile 实测
- M3 v0.4.0 MVP（Windows）：对话工作台 + 实例管理 ✅ 已发布（2026-09-09，tag `v0.4.0`）
- M4 macOS/Linux 发布 + 纯 API profile 切换（若 M2 收益成立）

## 下载

- **v0.4.0 MVP（Windows x64）**：[GitHub Release](https://github.com/Ruffianjiang/dsh-desktop/releases/tag/v0.4.0) · [直接下载 zip](https://github.com/Ruffianjiang/dsh-desktop/releases/download/v0.4.0/dsh-desktop-v0.4.0-mvp-windows-x64.zip)
  - 运行需预装 **Node.js ≥ 20 LTS** 与 **Visual C++ Redistributable 2022 x64**（包未自带 VC 运行库）
  - 界面预览见 Release 资产；发版明细见 `RELEASES.md` 与发布包内 `README.md`

## 历史版本

- v0.1.0–v0.3.0（Electron / Tauri 2 封装 dsh web 外壳）已归档至 `legacy/`，代码与 Release tag 保留可回溯。
