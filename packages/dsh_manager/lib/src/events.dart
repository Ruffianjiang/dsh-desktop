/// 实例事件契约（F2 Gate-B v1.0 §3）：UI 仅凭事件流驱动状态面板。
library;

import 'models.dart';

/// 守护（Guardian）对一次进程退出的处置。
enum GuardianAction {
  /// 主动 stop，守护不介入。
  none,

  /// 守护已排定退避重启（首次 1s，指数退避，上限 30s）。
  scheduled,

  /// 连续失败达上限（3 次），转 `crashed` 终态，需手动 start 复位。
  gaveUp,
}

/// 实例事件基类（sealed：新增事件类型必须显式扩展，防 switch 漏处理）。
sealed class InstanceEvent {
  InstanceEvent(this.instanceId) : at = DateTime.now();

  /// 所属实例（[InstanceConfig.id]）。
  final String instanceId;

  /// 事件发生时刻。
  final DateTime at;
}

/// 实例状态迁移。覆盖全部六态迁移（含 created→starting）。
final class InstanceStatusChanged extends InstanceEvent {
  InstanceStatusChanged({
    required String instanceId,
    required this.from,
    required this.to,
    this.pid,
    this.port,
  }) : super(instanceId);

  final InstanceStatus from;
  final InstanceStatus to;

  /// to == starting/running 时有值。
  final int? pid;

  /// 实际监听端口（含 port==0 自动分配结果）。
  final int? port;

  @override
  String toString() =>
      'StatusChanged($instanceId: $from→$to pid=$pid port=$port)';
}

/// 心跳结果（运行期 3s 一次；ok=false 连续 3 次触发僵死自愈）。
final class InstanceHeartbeat extends InstanceEvent {
  InstanceHeartbeat({
    required String instanceId,
    required this.ok,
    this.latencyMs,
    this.reason,
  }) : super(instanceId);

  final bool ok;

  /// ok=true 时为 TCP+HTTP 往返耗时。
  final int? latencyMs;

  /// ok=false 时的失败原因（tcp:…/http:…/status:…）。
  final String? reason;

  @override
  String toString() =>
      'Heartbeat($instanceId: ok=$ok ${latencyMs ?? '-'}ms ${reason ?? ''})';
}

/// 进程退出。每次进程退出恰好一条（主动停止 action == none）。
final class InstanceExited extends InstanceEvent {
  InstanceExited({
    required String instanceId,
    required this.exitCode,
    required this.action,
  }) : super(instanceId);

  final int? exitCode;
  final GuardianAction action;

  @override
  String toString() => 'Exited($instanceId: code=$exitCode action=$action)';
}
