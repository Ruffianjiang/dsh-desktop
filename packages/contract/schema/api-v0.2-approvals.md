# dsh API 契约 v0.2 增补：审批（approvals）域

> 来源：2026-09-04 对 `@deepseek-ai/dsh-client-connection`（随 dsh 0.1.1-rc.2 分发）源码
> `lib/client.js` 的 schema 交叉验证（approvals 域 zod + events 域 MuxFrame union）。
> 真实帧抓包待 T7 实测后补充 golden（`respond.approval.*`）。

## 1. mux 下行帧（MuxFrame union，payload 槽位）

| type | payload 字段 | 说明 |
|---|---|---|
| `approval/requested` | `sessionId`、`approvalId`（ApprovalRequestId，string ≥1）、`toolName`、`callId?`、`reason?` | 工具待审批；**信封 rpcId 即回写路由键** |
| `approval/resolved` | `sessionId`、`approvalId`、`outcome: allowed-once\|rejected\|cancelled\|unavailable` | 审批已了结（含被取消） |
| `question/requested` | `sessionId`、`questions: [{id, question, header?, detail?, options?:[{label,description?}], multiSelect?, intent?}]`（intent: `{kind:'plan-review', approve:string}`） | ask-user 提问（UI P1） |
| `question/resolved` | `sessionId`、`questionRpcId`、`outcome: answered\|cancelled` | 提问已回写 |
| `session/subscribed` | **`sessionId`、`lastSeq`（每会话一帧，非 items 列表）** | 订阅基线（T5 修正项） |
| `session/event` | `sessionId`、`event`、`view?: {for:'call'\|'result', view:{card:string}}` | 工具轨迹 host 视图随帧/历史条目附带 |

## 2. 审批回写：`POST /api/respond`

- body 为 **client-response 信封**（非 client-request）：
  ```json
  { "type": "client-response", "rpcId": "<approval/requested 信封 rpcId>",
    "result": { "ok": true,
      "value": { "sessionId": "...", "approvalId": "...", "outcome": "allowed-once|rejected" } } }
  ```
- 服务端按 pending 表以 rpcId 路由，对 `value` 做二次解析（approvals 域 zod）；
- 响应（非信封）：`{ "accepted": true }` 或 `{ "accepted": false, "reason": "not-pending|bad-response" }`；
- 受理后 mux 广播 `approval/resolved`（outcome 同 value.outcome）。

## 3. 工具轨迹（M3-T7 UI 数据源）

- history 条目：`{event, view?}`；mux `session/event` 帧亦带 `view?`；
- `view = {for:'call'|'result', view:{card:string}}` —— `card` 为 host 生成的
  工具卡片文本（名称/参数/结果摘要），UI 直接展示，无需自行解析工具参数；
- 工具事件类型：`tool/call`、`tool/result`。

## 4. 其他更正（相对 v0.1）

- `session/subscribed`：v0.1 记录为「逐个推送」聚合帧，实际为**每会话一帧**；
- `session.models`：per-session（payload `{sessionId}`），非全局；
- `session.history` value：`{events:[{event,view?}], hasMore, projections?:{asOfSeq, values}}`；
- 模型切换：`session.selectModel`（payload `{sessionId, provider, model, reasoningEffort?}`）。
