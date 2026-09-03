# golden — 样例与出处

| 文件 | 性质 | 出处 |
|---|---|---|
| `session.list.response.json` | 真实验证 | curl 2026-09-03，含完整 SessionMeta/projections |
| `session.create.response.json` | 真实验证 | 同上，`payload:{}` |
| `session.history.response.json` | 真实验证 | 完整一轮 run（40KB，含 chunk 全分态：block-start/text-delta/block-end/usage/finish 与 assistant/message） |
| `session.prompt.accepted.response.json` | 真实验证 | `{mode:"queue",content:[{type:"text",text:…}]}` 实测响应 |
| `session.prompt.badrequest.response.json` | 合成 | 按真实错误信封整理（issues 已精简为示意，非逐字） |
| `mux.live.capture.txt` | 真实验证 | WS `/api/events.mux` 直播日志（先订阅后 prompt；subscribed/queue/event/projection 全类） |

用途：`packages/client_dart` 契约测试（fixture 解析断言，`tool/verify_contract.dart` 11 项全 PASS）；`client_arkts`（鸿蒙立项）复用同一批帧。
