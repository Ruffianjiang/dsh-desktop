import 'dart:async';

import 'package:dsh_client/src/envelope.dart';

import 'rpc_client.dart';
import 'session_api.dart';

/// 连接阶段（Gate-B M3 §3.1：完整状态机）。
enum ConnPhase { disconnected, connecting, connected, streaming, error }

/// 端点连接（M3 Gate-B §3.1；T9 实机修正 F2-4 Gate-A 20260909）：REST unary +
/// WS 下行的完整封装——自动重连（指数退避 1s→30s）、lastSeq 续传（缺口走
/// session.history 补拉）、端点热切换。
///
/// 单端点多路复用：`events.mux` 一条流承载全部会话（BQ7）。
///
/// **streaming 语义（实机回归修正）**：mux WS 为事件驱动推帧——无 running
/// 会话时服务器连上后静默（session/subscribed 仅在会话创建/启动运行时下发），
/// 故 WS 握手成功即进入 streaming（= 传输就绪），不以首帧为门槛；
/// 空闲 watchdog 移除（静默是常态，实例存活性由 L2 HealthProbe 保障）。
class DshConnection {
  DshConnection({
    required String endpoint,
    this.initialBackoff = const Duration(seconds: 1),
    this.maxBackoff = const Duration(seconds: 30),
  }) : _endpoint = _normalize(endpoint);

  static String _normalize(String url) =>
      url.endsWith('/') ? url.substring(0, url.length - 1) : url;

  String _endpoint;
  DshClient? _client;
  SessionApi? _sessionApi;
  StreamSubscription<ServerRequestFrame>? _muxSub;
  Timer? _reconnectTimer;
  bool _running = false;
  int _backoffStep = 0;

  /// 重连退避参数（Gate-B M3 §3.1：1s 起步，指数退避，上限 30s）。
  final Duration initialBackoff;
  final Duration maxBackoff;

  /// 每会话已见最大事件 seq（续传/去重游标）。
  final Map<String, int> _lastSeq = {};

  /// 最近一次连接失败原因（F2-3 错误可见化；error/重连相位可读，恢复后清空）。
  String? _lastError;

  String? get lastError => _lastError;

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
    await _teardownConnection();
    _setPhase(ConnPhase.disconnected);
  }

  Future<void> _teardownConnection() async {
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

    final mux =
        client.openStream('/api/events.mux', onOpen: _onTransportOpen);

    _muxSub = mux.listen(
      (frame) {
        _handleFrame(frame);
      },
      onError: (Object e) {
        if (!_running) return;
        _lastError = e.toString();
        _setPhase(ConnPhase.error);
        _scheduleReconnect();
      },
      onDone: () {
        if (!_running) return;
        // 服务端断开：退避重连。
        _lastError = '连接被关闭（服务端断开）';
        _setPhase(_phase == ConnPhase.streaming
            ? ConnPhase.error
            : ConnPhase.disconnected);
        _scheduleReconnect();
      },
      cancelOnError: false,
    );
  }

  /// WS 握手成功即传输就绪（F2-4，实机回归 2026-09-09）：mux WS 为事件驱动
  /// 推帧——无 running 会话时服务器连上后静默，不能以首帧判就绪。
  void _onTransportOpen() {
    _backoffStep = 0;
    _lastError = null;
    _setPhase(ConnPhase.streaming);
  }

  void _handleFrame(ServerRequestFrame frame) {
    if (!_running) return;
    final payload = frame.payload;
    final type = payload['type']?.toString();

    if (type == 'session/subscribed') {
      // 订阅就绪：进入 streaming；**每会话一帧** {sessionId, lastSeq}
      //（dsh-client-connection events.schema 实证，非 items 列表）。
      _backoffStep = 0;
      _lastError = null; // 恢复 streaming 后清空失败原因
      _setPhase(ConnPhase.streaming);
      _forward(frame);
      final sid = payload['sessionId']?.toString();
      final serverSeq = (payload['lastSeq'] as num?)?.toInt();
      if (sid != null && serverSeq != null) {
        _lastSeq.update(sid, (v) => v < serverSeq ? serverSeq : v,
            ifAbsent: () => serverSeq);
      }
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
