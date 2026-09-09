import 'dart:async';
import 'dart:io';

import 'package:dsh_client/dsh_client.dart';
import 'package:dsh_manager/dsh_manager.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'settings_store.dart';

/// 全局 providers（M3 Gate-B §5.2；T9 修正 Gate-A 20260909）。
///
/// 依赖方向：UI → providers → L2(dsh_manager)/L3(dsh_client)；
/// UI ↔ dsh 唯一通道是 L3 客户端（实例面板消费 L2 事件流属进程管理域）。

/// Node + dsh 环境探测（引擎页/实例页共用）。
/// F1-1（Gate-A 20260909）：托管 prefix 优先于全局 PATH——安装即生效。
final nodeEnvProvider = FutureProvider<NodeEnv>((ref) => NodeEnv.probe(
      managedPrefix: InstallService.computeDefaultPrefix(),
    ));

/// L2 实例管理器单例（聚合全部实例事件；keepAlive 常驻）。
///
/// 注意：仅**创建时**读取一次引擎环境（ref.read，不随 nodeEnv 重建）——
/// 否则安装托管引擎后重建管理器会丢失在跑实例。引擎热替换走
/// [InstanceManager.updateEnv]（引擎页安装/升级成功后调用）。
final instanceManagerProvider = FutureProvider<InstanceManager>((ref) async {
  final env = await ref.read(nodeEnvProvider.future);
  return InstanceManager(env: env);
});

/// 实例事件流：状态/心跳/退出事件驱动实例页局部刷新（不轮询）。
final instanceEventsProvider = StreamProvider<InstanceEvent>((ref) async* {
  final manager = await ref.watch(instanceManagerProvider.future);
  yield* manager.events;
});

/// F1 安装服务（npm 可执行文件由 node 同目录推导；代理沿用进程环境）。
final installServiceProvider = FutureProvider<InstallService>((ref) async {
  final env = await ref.watch(nodeEnvProvider.future);
  final npmDir = File(env.nodePath).parent.path;
  final sep = Platform.pathSeparator;
  final npm = Platform.isWindows ? '$npmDir${sep}npm.cmd' : '$npmDir${sep}npm';
  return InstallService(
    nodeExecutable: env.nodePath,
    npmExecutable: npm,
    proxy: Platform.environment['HTTPS_PROXY'],
  );
});

/// 托管 prefix 下的已装 dsh 版本（null = 未安装）。
final installedVersionProvider = FutureProvider<String?>((ref) async {
  final svc = await ref.watch(installServiceProvider.future);
  return svc.detectInstalled(svc.defaultPrefix);
});

/// npm 版本目录（引擎页版本列表；走 registry HTTP，代理注入）。
final versionCatalogProvider = FutureProvider<VersionCatalog>((ref) {
  return VersionCatalog.fetchHttp(
    '@deepseek-ai/dsh',
    registry: 'https://registry.npmjs.org/',
    proxy: Platform.environment['HTTPS_PROXY'],
  );
});

// ---------------------------------------------------------------------------
// 连接管理（M3-T5；T9 修正 F2-1/F2-2 Gate-A 20260909）
// ---------------------------------------------------------------------------

/// 活动端点目标：绑定实例 ID（URL 实时派生，重启换端口自动跟随）或手动 URL
/// （高级用法）。二者互斥。
class ActiveTarget {
  const ActiveTarget.instance(this.instanceId)
      : manualUrl = null,
        isManual = false;

  const ActiveTarget.manual(this.manualUrl)
      : instanceId = null,
        isManual = true;

  final String? instanceId;
  final String? manualUrl;
  final bool isManual;
}

/// 活动端点选择（D8 端点模型）：null = 未选择。
/// 由实例详情「设为活动端点」/ 对话页实例下拉设置；手输端点为手动模式。
class ActiveEndpoint extends Notifier<ActiveTarget?> {
  @override
  ActiveTarget? build() => null;

  void selectInstance(String id) => state = ActiveTarget.instance(id);

  void selectManual(String url) => state = ActiveTarget.manual(url);

  void clear() => state = null;
}

final activeEndpointProvider =
    NotifierProvider<ActiveEndpoint, ActiveTarget?>(ActiveEndpoint.new);

/// 活动端点的实时 URL：实例模式随实例状态派生（监听实例事件，
/// 重启换端口自动跟随）；手动模式原样返回。
final activeEndpointUrlProvider = Provider<String?>((ref) {
  final target = ref.watch(activeEndpointProvider);
  if (target == null) return null;
  final manual = target.manualUrl;
  if (manual != null && manual.isNotEmpty) return manual;
  final iid = target.instanceId;
  if (iid == null) return null;
  ref.watch(instanceEventsProvider); // 实例事件驱动重算
  final mgr = ref.watch(instanceManagerProvider).value;
  if (mgr == null) return null;
  final cfg = mgr.registry.get(iid);
  if (cfg == null) return null;
  final port = mgr.stateOf(iid)?.port ?? cfg.port;
  return 'http://${cfg.host}:$port';
});

/// L3 连接（跟随活动端点 URL 重建；旧连接 dispose 时自动关闭）。
final connectionProvider = Provider<DshConnection?>((ref) {
  final url = ref.watch(activeEndpointUrlProvider);
  if (url == null) return null;
  final conn = DshConnection(endpoint: url);
  ref.onDispose(() => conn.close());
  unawaited(conn.start());
  return conn;
});

/// 连接阶段流（UI 连接徽标）。
final connPhaseStreamProvider = StreamProvider<ConnPhase>((ref) {
  final conn = ref.watch(connectionProvider);
  if (conn == null) return const Stream.empty();
  return conn.phases;
});

/// 下行事件流（mux 帧；重连/续传对消费者透明）。
final connectionEventsProvider = StreamProvider<ServerRequestFrame>((ref) {
  final conn = ref.watch(connectionProvider);
  if (conn == null) return const Stream.empty();
  return conn.events;
});

// ---------------------------------------------------------------------------
// 审批（M3-T7）：approval/requested → 队列 → respond（allowed-once/rejected）
// ---------------------------------------------------------------------------

/// 一条待审批请求（来自 `approval/requested` 帧）。
class ApprovalRequest {
  const ApprovalRequest({
    required this.frameRpcId,
    required this.sessionId,
    required this.approvalId,
    required this.toolName,
    this.reason,
  });

  /// `approval/requested` 信封的 rpcId（respond 经 pending 表按它路由）。
  final String frameRpcId;
  final String sessionId;
  final String approvalId;
  final String toolName;
  final String? reason;
}

/// 待审批队列（FIFO；`approval/resolved` 帧到达时移除对应项）。
class PendingApprovals extends Notifier<List<ApprovalRequest>> {
  @override
  List<ApprovalRequest> build() {
    ref.listen(connectionEventsProvider, (_, next) {
      next.whenData((frame) {
        final p = frame.payload;
        final type = p['type']?.toString();
        if (type == 'approval/requested') {
          final req = ApprovalRequest(
            frameRpcId: frame.rpcId,
            sessionId: p['sessionId']?.toString() ?? '',
            approvalId: p['approvalId']?.toString() ?? '',
            toolName: p['toolName']?.toString() ?? 'tool',
            reason: p['reason']?.toString(),
          );
          // 同 approvalId 幂等
          if (!state.any((a) => a.approvalId == req.approvalId)) {
            state = [...state, req];
          }
        } else if (type == 'approval/resolved') {
          final aid = p['approvalId']?.toString();
          state = state.where((a) => a.approvalId != aid).toList();
        }
      });
    });
    return const [];
  }

  void dismiss(String approvalId) =>
      state = state.where((a) => a.approvalId != approvalId).toList();
}

final pendingApprovalsProvider =
    NotifierProvider<PendingApprovals, List<ApprovalRequest>>(
        PendingApprovals.new);
// 审批回写在对话页执行（WidgetRef 读取 connectionProvider +
// client.respondClientResponse），受理失败的项由页面 dismiss 出队。

// ---------------------------------------------------------------------------
// 设置（M3-T8）：持久化 + 模型只读
// ---------------------------------------------------------------------------

/// 设置持久化（JSON：~/.dsh-desktop/settings.json）。
final settingsStoreProvider = Provider<SettingsStore>((ref) => SettingsStore());

/// 应用设置（设置页）。
class AppSettingsController extends Notifier<AppSettings> {
  @override
  AppSettings build() => ref.read(settingsStoreProvider).load();

  /// 更新并落盘。
  void update(AppSettings next) {
    ref.read(settingsStoreProvider).save(next);
    state = next;
  }
}

final appSettingsProvider =
    NotifierProvider<AppSettingsController, AppSettings>(
        AppSettingsController.new);

/// 模型只读（per-session：`session.models`，契约 v0.2 实证）。
final sessionModelsProvider = FutureProvider.family<Map<String, dynamic>?,
    String>((ref, sessionId) async {
  final conn = ref.watch(connectionProvider);
  if (conn == null) return null;
  return conn.sessionApi.models(sessionId);
});
