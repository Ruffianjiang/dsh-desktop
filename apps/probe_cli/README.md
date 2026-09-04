# apps/probe_cli — 协议联调 CLI（M1）

纯 Dart console：连真实 `dsh web`（或已启动实例）→ 建会话 → 发消息 → SSE 流式输出。
T4 目标：完成一轮对话（M1 出口）。依赖 `packages/contract` + `packages/client_dart`。
