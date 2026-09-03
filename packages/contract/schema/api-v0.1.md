# dsh API 契约 v0.1（实测子集）

> 来源：2026-09-03 对本机 dsh 0.1.1-rc.2（`web` profile，127.0.0.1:3080）真实抓包 + `@deepseek-ai/dsh-client-connection` 源码交叉验证。
> golden 样例见 `../golden/`。注意：dsh 为 rc 版本，契约可能随上游漂移（Gate-A R1）；本文件描述**本次实测形态**。

## 1. 传输与信封

- Base：`http://<host>:<port>`，默认 `127.0.0.1`。
- 上行：`POST /api/<method>`，`Content-Type: application/json`。
- 下行（实测为 **WebSocket**）：`GET /api/events.mux`（会话/agent 事件）、`GET /api/events.host`（host 事件）均要求 WS 升级——普通 HTTP GET 返回 **426 Upgrade Required**；连接 `ws://<host>:<port>/api/events.mux` 后，**每条 WS text 消息 = 一个 ServerRequest JSON 信封**（每个信封含 `payload`；`payload.type` 即消息类型）。注：编译产物中旧「SSE streaming fetch」逻辑与实际服务端行为不符，以 WS 为准（与 `dsh-client-connection` 「HTTP-up / WebSocket-down」描述一致）。
- 请求信封（client → server）：
  ```json
  { "type": "client-request", "rpcId": "<uuid>", "method": "session.list", "payload": {} }
  ```
- 响应信封（server → client）：
  ```json
  { "type": "server-response", "rpcId": "<uuid>", "result": { "ok": true, "value": { ... } } }
  ```
  失败时：`"result": { "ok": false, "error": { "code": "bad-request", "message": "…", "details": { "issues": [ …zod issues… ] } } }`
- 下行帧信封（server → client，WS）：
  ```json
  { "type": "server-request", "rpcId": "<uuid>", "method": "session/event",
    "payload": { "type": "session/event", "sessionId": "<sid>", "event": { … } } }
  ```
- 未知 method → HTTP 404 明文 `not found`（非 JSON 信封）。

## 2. 实测方法（payload 已跑通，value 按响应）

| 方法 | payload（实测） | value（实测） |
|---|---|---|
| `session.list` | `{}` | `{ items: [ SessionMeta ] }`；`SessionMeta = { sessionId, updatedAt, running, blank, cwd, agentPreset, projections }` |
| `session.create` | `{}`（可带 `agentPreset`） | `{ sessionId, agentPreset }` |
| `session.history` | `{ sessionId, beforeSeq?, maxMessages? }` | `{ events: [ { event: SessionEvent } ] }` |
| `session.prompt` | `{ sessionId, mode: "queue"\|"steer", content: [ { type:"text", text:"…" } ] }` | `{ accepted: true }` |
| `session.cancel` | `{ sessionId }` | 未实测（源码：callUnary session.cancel） |
| `session.list/search/create/history/models/selectModel/rename/fork/prompt/attachment/updateQueue/cancel` | — | 方法全集见 `dsh-client-connection` 源码 `sessions = {…}` |
| `subagent.list/history/prompt/interrupt` | — | 同上 `subagents = {…}`（首版 P1） |

## 3. 会话事件（history 与 WS 直播同源，2026-09-03 实测）

运行会按序产生事件；事件 type 样例：
`permission/preset`、`sandbox/mode`、`approval/policy`、`agent/inbox/spliced`、`turn/start|end`、`step/start|end`、`user/message`、`assistant/chunk`、`assistant/message`、`session/title`、`session/title-llm-request`、`request/header`、`request/context`、`usage`。

**assistant/chunk**（流式，`event.data.chunk.type` 分态）：
| chunk.type | 内容 |
|---|---|
| `block-start` | `{ index, blockType }` |
| `text-delta` | `{ index, text }` —— 增量文本（UI 流式渲染用） |
| `block-end` | `{ index, block: { type:"text", text } }` |
| `usage` | `{ inputTokens, outputTokens, cacheReadTokens, reasoningTokens }` |
| `finish` | `{ reason }` |

**assistant/message**（落盘完整消息）：
```json
{ "turn":1, "step":1, "message": { "role":"assistant",
  "content":[ { "type":"text", "text":"…" } ], "source":{ "kind":"model", "provider":"…", "model":"…" }, "id":"…" } }
```

**WS 下行帧类型**（`payload.type`，带 `sessionId`）：
| type | 含义 |
|---|---|
| `session/subscribed` | 各会话订阅就绪（含 lastSeq；连上即逐个推送） |
| `session/queue` | prompt 入队/队列清空（items） |
| `session/event` | 会话事件（上述 event 结构，`payload.event`） |
| `session/projection` | 会话投影更新（title/sessionStats/contextPressure/…，`payload.key`+`value`） |

## 4. golden 清单

| 文件 | 内容 |
|---|---|
| `session.list.response.json` | 真实 list 响应（含完整 SessionMeta/projections） |
| `session.create.response.json` | 真实 create 响应 |
| `session.history.response.json` | 完整一轮 run 的 40KB 事件历史（金标准，含全部 chunk 分态） |
| `session.prompt.accepted.response.json` | prompt 接受响应（合成 rpcId，内容同实测） |
| `session.prompt.badrequest.response.json` | 校验失败信封（issues 已精简为示意） |
| `mux.live.capture.txt` | WS `/api/events.mux` 直播原始日志（先订阅后 prompt；含 subscribed/queue/event/projection） |

## 5. 待补（T4 后 / Gate-B 细化）

1. `session.prompt` `mode:"steer"` 语义、附件 `session.attachment`、`/api/respond` 应答流。
2. host 流 `/api/events.host` 帧；断线重连/游标续订语义。
3. 泛化 JSON Schema + OpenAPI（供 Dart/ArkTS 双端代码生成）。
