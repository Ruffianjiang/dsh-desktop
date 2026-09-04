# packages/dsh_manager — L2 引擎管理层（纯 Dart）

对应 Gate-B v1.0 §4。实现：

| 模块 | 文件 | 说明 |
|---|---|---|
| 领域模型 | `lib/src/models.dart` | InstanceConfig / InstanceStatus / InstanceState |
| 环境探测 | `lib/src/node_env.dart` | 找 node + dsh CLI JS 入口（`DSH_CLI`/`DSH_NODE` 可覆盖；Windows 走 `where dsh.cmd`） |
| 实例守护 | `lib/src/supervisor.dart` | spawn → 健康就绪轮询 → 优雅停止（竞态安全） |
| 注册表 | `lib/src/registry.dart` | `~/.dsh-desktop/instances.json` 持久化（schemaVersion） |

自检：`tool/selfcheck_manager.dart`（真实起停一轮 dsh，6 项断言，M2/T6 出口）。

说明：`InstanceConfig.port` 当前用于健康探测；dsh 实例端口参数映射与「多实例不同端口」待 M2 收口。
