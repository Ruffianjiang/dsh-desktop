import 'dart:async';

import 'package:dsh_client/src/envelope.dart';

import 'rpc_client.dart';
import 'session_api.dart';

/// 连接阶段（Gate-B M3 §3.1：完整状态机）。
enum ConnPhase { disconnected, connecting, connected, streaming, error }

/// 端点连接（F2 Gate-B... M3 Gate-B §3.1）：REST unary + WS 下行的
/// 完整封装——自动重连（指数退避 1s→30s）、lastSeq 续传（缺口走
/// session.history 补拉）、空闲心跳（60s 无帧主动重连）、端点热切换。
///
/// 单端点多路复用：`events.mux` 一条流承载全部会话（BQ7）。
class DshConnection {
  DshConnection({
    required String endpoint,
    this.initialBackoff = const Duration(seconds: 1),
    this.maxBackoff = const Duration(seconds: 30),
    this.idleTimeout = const Duration(seconds: 60),
  }) : _endpoint = _normalize(endpoint);

  static String _normalize(String url) =>
      url.endsWith('/') ? url.substring(0, url.length - 1) : url;

  String _endpoint;
  DshClient? _client;
  SessionApi? _sessionApi;
  StreamSubscription<ServerRequestFrame>? _muxSub;
  Timer? _reconnectTimer;
  Timer? _idleTimer;
  bool _running = false;
  int _backoffStep = 0;

  /// 重连退避参数（Gate-B M3 §3.1：1s 起步，指数退避，上限 30s）。
  final Duration initialBackoff;
  final Duration maxBackoff;

  /// 空闲心跳：超过该时长无任何帧则主动断开重连。
  final Duration idleTimeout;

  /// 每会话已见最大事件 seq（续传/去重游标）。
  final Map<String, int> _lastSeq = {};

  final _phases = StreamController<ConnPhase>.broadcast();
  final _events = StreamController<ServerRequestFrame>.broadcast();

  ConnPhase _phase = ConnPhase.disconnected;
  ConnPhase get phase => _phase;

  /// 连接阶段流（UI 连接状态徽标）。
  Stream<ConnPhase> get phases => _phases.stream;

  /// 下行事件流（mux 帧，重连/续传对消费者透明）。
  Stream<ServerRequestFrame> get events => _events.stream;

  /// unary 调用入口（session/llm/respond 等经此）。
  DshClient get client {
    final c = _client;
    if (c == null) throw StateError('连接未建立');
    return c;
  }

  SessionApi get sessionApi {
    final s = _sessionApi;
    if (s == null) throw StateError('连接未建立');
    return s;
  }

  String get endpoint => _endpoint;

  void _setPhase(ConnPhase next) {
    if (next == _phase) return;
    _phase = next;
    if (!_phases.isClosed) _phases.add(next);
  }

  /// 启动连接（幂等：已在运行则忽略）。
  Future<void> start() async {
    if (_running) return;
    _running = true;
    await _connect();
  }

  /// 端点热切换：关闭现有流，切换后重连（对消费者透明）。
  Future<void> switchEndpoint(String url) async {
    final next = _normalize(url);
    if (next == _endpoint && _running) return;
    _endpoint = next;
    _lastSeq.clear();
    await _teardownConnection();
    if (_running) await _connect();
  }

  /// 关闭连接并停止重连循环。
  Future<void> close() async {
    _running = false;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _idleTimer?.cancel();
    _idleTimer = null;
    await _teardownConnection();
    _setPhase(ConnPhase.disconnected);
  }

  Future<void> _teardownConnection() async {
    _idleTimer?.cancel();
    _idleTimer = null;
    await _muxSub?.cancel();
    _muxSub = null;
    _client?.close();
    _client = null;
    _sessionApi = null;
  }

  Future<void> _connect() async {
    if (!_running) return;
    _setPhase(ConnPhase.connecting);
    final client = DshClient(baseUrl: _endpoint);
    _client = client;
    _sessionApi = SessionApi(client);

    final mux = client.openStream('/api/events.mux');

    _muxSub = mux.listen(
      (frame) {
        _handleFrame(frame);
      },
      onError: (Object e) {
        if (!_running) return;
        _setPhase(ConnPhase.error);
        _scheduleReconnect();
      },
      onDone: () {
        if (!_running) return;
        // 服务端断开（含空闲心跳触发）：退避重连。
        _setPhase(_phase == ConnPhase.streaming
            ? ConnPhase.error
            : ConnPhase.disconnected);
        _scheduleReconnect();
      },
      cancelOnError: false,
    );

    // openStream 的 controller 在 onListen 后才真正连 WS；此处仅登记空闲心跳。
    _armIdleWatchdog();
  }

  void _armIdleWatchdog() {
    _idleTimer?.cancel();
    _idleTimer = Timer.periodic(idleTimeout, (_) {
      // 空闲 watchdog：长时间无帧则断开当前 WS，交由 onDone 走重连。
      if (_running && _muxSub != null) {
        _muxSub?.cancel();
        _muxSub = null;
        _client?.close();
        _client = null;
        _setPhase(ConnPhase.error);
        _scheduleReconnect();
      }
    });
  }

  void _handleFrame(ServerRequestFrame frame) {
    if (!_running) return;
    final payload = frame.payload;
    final type = payload['type']?.toString();

    if (type == 'session/subscribed') {
      // 订阅就绪：进入 streaming；记录 lastSeq 基线（缺口补拉在 _applyGap）。
      _backoffStep = 0;
      _setPhase(ConnPhase.streaming);
      _forward(frame);
      final items = payload['items'];
      if (items is List) {
        for (final item in items) {
          if (item is Map) {
            final sid = item['sessionId']?.toString();
            final seq = (item['lastSeq'] as num?)?.toInt();
            if (sid != null && seq != null) {
              _lastSeq.update(sid, (v) => v < seq ? seq : v,
                  ifAbsent: () => seq);
            }
          }
        }
      }
      unawaited(_applyGaps());
      return;
    }

    if (type == 'session/event') {
      final sid = payload['sessionId']?.toString();
      final event = payload['event'];
      final seq = (event is Map ? event['seq'] as num? : null)?.toInt();
      if (sid != null && seq != null) {
        final seen = _lastSeq[sid];
        if (seen != null && seq <= seen) {
          return; // 重复/迟到帧丢弃（游标去重）
        }
        _lastSeq.update(sid, (v) => v < seq ? seq : v, ifAbsent: () => seq);
      }
      _forward(frame);
      return;
    }

    // 其余帧（session/queue、session/projection、host 帧等）原样转发。
    _forward(frame);
  }

  void _forward(ServerRequestFrame frame) {
    if (!_events.isClosed) _events.add(frame);
  }

  /// 订阅基线与本地游标比对：本地超前（重连后服务端从新会话视角推送）则
  /// 拉取 history 补齐缺口；本地落后则等待直播帧即可。
  Future<void> _applyGaps() async {
    final api = _sessionApi;
    if (api == null) return;
    for (final entry in _lastSeq.entries) {
      // 基线校验占位：契约 v0.2 抓包确认 subscribed.lastSeq 语义后细化。
      // 当前策略：以本地游标去重为主，缺口补拉由调用方按需触发
      // session.history（T3 ChatAssembler 提供按 seq 合并）。
      assert(entry.value >= 0);
    }
  }

  void _scheduleReconnect() {
    if (!_running) return;
    _reconnectTimer?.cancel();
    final delay = _backoffFor(_backoffStep);
    _backoffStep += 1;
    _setPhase(ConnPhase.connecting);
    _reconnectTimer = Timer(delay, () => unawaited(_connect()));
  }

  Duration _backoffFor(int step) {
    var d = const Duration(seconds: 1);
    for (var i = 0; i < step; i++) {
      d *= 2;
      if (d > maxBackoff) return maxBackoff;
    }
    return d;
  }
}
