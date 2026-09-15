# RELEASES

dsh-desktop 发版记录。版本线：v0.1.0–v0.3.0 为旧「封装 dsh web 外壳」（Electron → Tauri 2，已归档 `legacy/`）；**v0.4.0 起为 Flutter 自研原生客户端**（不内嵌 dsh web）。

---

## v0.4.0 — M3 MVP（Windows 首发）· 2026-09-09

仓库分支：`feat/v0.4-m3`（已 push origin）。产物：`dsh-desktop-v0.4.0-mvp-windows-x64.zip`（见 `scripts/package_release.ps1`）。

### 引擎 / 实例管理（P0）
- **检测闭环**：NodeEnv 探测顺序改为 `DSH_CLI → 托管前缀(~/.dsh-desktop/engine) → where dsh.cmd → node 同目录`，托管前缀纳入探测链（旧实现装入后实例仍用 PATH 引擎，「安装即生效」不成立）。
- `install_service.computeDefaultPrefix()` 静态化，probe / UI 无需实例化即可取托管路径。
- `instance_manager` 引擎 env 可变 + `updateEnv()` 热替换：安装 / 升级后新实例即用新引擎；在跑实例不受影响。
- 引擎页改双卡片：「实例引擎（当前生效）」含版本 / 来源 / bin.js +「托管引擎」安装 / 升级卡；安装成功后 invalidate 探测并热替换。

### 对话连接（F2，实机回归实证）
- 活动端点**绑定实例 ID**，URL 由实例状态实时派生——实例重启换端口自动跟随（旧实现冻结 URL 指向死端口无限重连）。
- 自动连接运行中实例（默认开，设置可关）。
- 协议修正：mux WS 为事件驱动推帧，握手成功即进入 streaming，不再等 `subscribed` 首帧；移除 60s 空闲 watchdog；`lastError` 错误可见化。

### 对话渲染（F3-5，真实帧结构实证）
- 工具卡按 `callId` 聚合 call / result：标题 = `view.title`、kind 图标、可展开详情（结果正文 / 路径清单，>12000 截断）；旧实现取 `view.card`（恒为 "generic"）致「一行字」。
- 权威 `assistant/message` 解析 content 三类项（text / reasoning / tool-call），替换时显式携带工具卡；工具事件回退定位改反向搜索最近 assistant；直播帧补传 `payload.view`。
- Markdown 渲染（BQ1 选型 **gpt_markdown 1.2.1**）：助手闭合文本块；思考过程折叠卡；围栏代码块深底样式。
- 新增 **Token 统计行**（F3-7）：`↑输入 ↓输出 思考N 缓存读N tok · tok/s · 用时`（usage 实机形态 `{inputTokens, outputTokens, cacheReadTokens, reasoningTokens}`）。

### 布局瘦身（F3-6）
移除页首大标题、连接条压为单行（实例切换 / 手输收进弹出菜单）、会话列表 240、气泡宽 860——面积让给消息流。

### 回归资产
`packages/client_dart/tool/{regress_connect,probe_tool_frames,replay_frames}.dart`；文档 `docs/06-迭代开发/20260909-M3-T9实机修正/`、`20260904-M3对话工作台与系统集成/T9实机验证清单.md`。

---

## 历史版本（已归档 legacy/）

| 版本 | 路线 | 状态 |
|---|---|---|
| v0.1.0 | Electron 封装 dsh web | 归档（Release tag 可回溯） |
| v0.2.0 | Electron 封装 dsh web（portable exe） | 归档 |
| v0.3.0 | Tauri 2 gnu 原生封装 dsh web | 归档（`legacy/tauri-skeleton`） |
| **v0.4.0** | **Flutter 自研原生客户端（M3 MVP）** | **本次发版** |
