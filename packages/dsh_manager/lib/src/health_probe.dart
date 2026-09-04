/// 持续健康探针（F2 Gate-B v1.0 §5）：TCP + HTTP GET，3s 间隔，连续失败触发僵死自愈。
library;

import 'dart:async';
import 'dart:io';

/// 心跳结果。
typedef HeartbeatCallback = void Function(bool ok, int? latencyMs, String? reason);

/// 持续健康探针。
///
/// - `attach` 后按 [interval] 周期探测；ok 重置失败计数，fail 连续
///   [failureThreshold] 次即回调 [onZombie]（由 Supervisor 杀进程走守护路径）
///   并自动 detach；
/// - `detach` 后定时器取消、计数复位（stopping/stopped 必须处于 detach 态，
///   防 F2 Gate-A RF2-1 竞态）。
class HealthProbe {
  HealthProbe({
    required this.onHeartbeat,
    required this.onZombie,
    this.interval = const Duration(seconds: 3),
    this.failureThreshold = 3,
    this.tcpTimeout = const Duration(milliseconds: 800),
    this.httpTimeout = const Duration(seconds: 2),
  });

  final HeartbeatCallback onHeartbeat;
  final void Function() onZombie;
  final Duration interval;
  final int failureThreshold;
  final Duration tcpTimeout;
  final Duration httpTimeout;

  Timer? _timer;
  bool _detached = true;
  bool _checking = false;
  int _fails = 0;
  String _host = '127.0.0.1';
  int _port = 0;
  HttpClient? _client;

  /// 开始对目标端点周期探测（重复 attach 会先 detach）。
  /// [instanceId] 供宿主记录归属（探针事件由 Supervisor 组装，探针自身不发事件）。
  void attach({required String instanceId, required String host, required int port}) {
    detach();
    _detached = false;
    _host = host;
    _port = port;
    _fails = 0;
    _client = HttpClient()..connectionTimeout = httpTimeout;
    _timer = Timer.periodic(interval, (_) => unawaited(_tick()));
  }

  /// 停止探测并复位状态。
  void detach() {
    _detached = true;
    _timer?.cancel();
    _timer = null;
    _fails = 0;
    _client?.close(force: true);
    _client = null;
  }

  /// 单次探测。host/port 缺省时用 attach 的目标（供自检直接调用）。
  Future<({bool ok, int? latencyMs, String? reason})> pingOnce(
      {String? host, int? port}) async {
    final h = host ?? _host;
    final p = port ?? _port;
    final sw = Stopwatch()..start();

    // 1) TCP 预检：快速区分「端口死了」与「HTTP 层异常」。
    Socket? sock;
    try {
      sock = await Socket.connect(h, p, timeout: tcpTimeout);
    } catch (e) {
      return (ok: false, latencyMs: null, reason: 'tcp:${e.runtimeType}');
    } finally {
      sock?.destroy();
    }

    // 2) HTTP GET /（就绪判据 200–499，与启动期 _awaitReady 一致；
    //    不用 /api/events.* —— SSE 会挂住连接）。
    final client = _client ?? (HttpClient()..connectionTimeout = httpTimeout);
    final ownsClient = identical(client, _client);
    try {
      final req = await client.getUrl(Uri.parse('http://$h:$p/'));
      final res = await req.close().timeout(httpTimeout);
      await res.drain<void>();
      final ok = res.statusCode >= 200 && res.statusCode < 500;
      return (
        ok: ok,
        latencyMs: sw.elapsedMilliseconds,
        reason: ok ? null : 'status:${res.statusCode}',
      );
    } catch (e) {
      return (
        ok: false,
        latencyMs: sw.elapsedMilliseconds,
        reason: 'http:${e.runtimeType}',
      );
    } finally {
      if (!ownsClient) client.close(force: true);
    }
  }

  Future<void> _tick() async {
    if (_detached || _checking) return; // 防重入（上一轮未完成则跳过）
    _checking = true;
    try {
      final r = await pingOnce();
      if (_detached) return; // 探测期间被 detach，丢弃本次结果
      if (r.ok) {
        _fails = 0;
        onHeartbeat(true, r.latencyMs, null);
      } else {
        _fails += 1;
        onHeartbeat(false, r.latencyMs, r.reason);
        if (_fails >= failureThreshold) {
          _fails = 0;
          detach();
          onZombie();
        }
      }
    } finally {
      _checking = false;
    }
  }

  /// 释放资源（等同 detach，此后实例不可再用）。
  void dispose() => detach();
}
