# packages/contract — L3 协议契约（唯一事实源）

描述 dsh 服务端 `/api/*` 契约的子集：资源/RPC（OpenAPI 风格）与 SSE 帧（JSON Schema），
外加 golden 样例（真实抓取/构造帧），供 `client_dart`（本次发版）与 `client_arkts`（鸿蒙立项）双端对拍。

- `schema/` — 首版子集 schema（session / chat / event）
- `golden/` — 真实样例帧（来源见各文件头注释）

状态：M1 建设中（Gate-B v1.0，§3）。
