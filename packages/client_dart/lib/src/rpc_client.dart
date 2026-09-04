import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'envelope.dart';

/// 连接状态（Gate-B §3.4）。当前为轻量状态机：成功/失败都会走回 disconnected。
enum ConnState { disconnected, connecting, connected }

/// dsh L3 客户端：REST unary RPC（上行）+ SSE（下行）。
///
/// 传输契约见 packages/contract/schema/api-v0.1.md：
///   - 上行 `POST /api/<method>`，body 为 client-request 信封；
///   - 下行 `GET /api/events.mux|host`，SSE `data:` 帧与空行分帧。
class DshClient {
  DshClient({required String baseUrl, HttpClient? httpClient})
      : _baseUrl = baseUrl.endsWith('/') ? baseUrl.substring(0, baseUrl.length - 1) : baseUrl,
        _http = httpClient ?? HttpClient();

  final String _baseUrl;
  final HttpClient _http;
  final Random _random = Random.secure();
  final _stateController = StreamController<ConnState>.broadcast();

  ConnState _state = ConnState.disconnected;
  ConnState get state => _state;
  Stream<ConnState> get onState => _stateController.stream;

  Uri _uri(String path) => Uri.parse('$_baseUrl$path');

  void _setState(ConnState next) {
    if (next != _state) {
      _state = next;
      // close() 与 openStream 的 finally 存在交错（重连/关闭场景），
      // 控制器已关闭时静默忽略，避免 Bad state 崩溃（M3 实测）。
      if (!_stateController.isClosed) _stateController.add(next);
    }
  }

  /// RFC 4122 v4 UUID（无外部依赖）。
  String _uuid4() {
    final bytes = List<int>.generate(16, (_) => _random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-'
        '${hex.substring(16, 20)}-${hex.substring(20)}';
  }

  /// unary RPC：`POST /api/<method>`，校验 rpcId 回显与信封；非 2xx 抛 [HttpException]。
  Future<Map<String, dynamic>?> call(String method, Map<String, dynamic> payload,
      {Duration timeout = const Duration(seconds: 30)}) async {
    _setState(ConnState.connecting);
    try {
      final message = <String, dynamic>{
        'type': 'client-request',
        'rpcId': _uuid4(),
        'method': method,
        'payload': payload,
      };
      final request = await _http.postUrl(_uri('/api/$method'));
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(message));

      final response = await request.close().timeout(timeout);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw HttpException('transport failure for $method: HTTP ${response.statusCode}',
            uri: _uri('/api/$method'));
      }
      final body = await utf8.decoder.bind(response).join();
      final full = ServerResponse.parse(jsonDecode(body));
      if (full.rpcId != message['rpcId']) {
        throw StateError('rpcId mismatch for $method');
      }
      _setState(ConnState.connected);
      return full.ok ? full.value : throw RpcTransportError(full.error!);
    } catch (_) {
      _setState(ConnState.disconnected);
      rethrow;
    }
  }

  /// 打开下行流（`/api/events.mux` 或 `/api/events.host`），逐帧产出 ServerRequest 信封。
  ///
  /// 实测：该端点要求 WebSocket 升级（HTTP GET → 426 Upgrade Required），
  /// 与参考客户端「HTTP-up / WebSocket-down」一致。每帧为 text 消息：
  /// 直接 JSON 信封，或 `data:` 行 + 空行分帧的 SSE 风格块（兼容两种）。
  Stream<ServerRequestFrame> openStream(String path,
      {Duration? timeout}) {
    WebSocket? ws;
    late final StreamController<ServerRequestFrame> controller;
    controller = StreamController<ServerRequestFrame>(
      onListen: () async {
        try {
          final httpUri = _uri(path).toString();
          final wsUri = httpUri.startsWith('https')
              ? 'wss://${httpUri.substring('https://'.length)}'
              : 'ws://${httpUri.substring('http://'.length)}';
          final socket = await WebSocket.connect(wsUri);
          ws = socket;
          _setState(ConnState.connected);
          await for (final raw in socket) {
            if (raw is! String) continue;
            for (final frame in _decodeFrames(raw)) {
              if (!controller.isClosed) controller.add(frame);
            }
          }
        } catch (e, st) {
          if (!controller.isClosed) controller.addError(e, st);
        } finally {
          _setState(ConnState.disconnected);
          if (!controller.isClosed) controller.close();
        }
      },
      onCancel: () async {
        try {
          await ws?.close();
        } catch (_) {}
        if (!controller.isClosed) controller.close();
      },
    );
    return controller.stream;
  }

  /// 解码单个 WS 文本消息为 0..n 帧：直接 JSON，或 SSE `data:` 行拼接解码。
  List<ServerRequestFrame> _decodeFrames(String raw) {
    final frames = <ServerRequestFrame>[];
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return frames;
    if (trimmed.startsWith('{')) {
      try {
        final decoded = jsonDecode(trimmed);
        if (decoded is Map) {
          frames.add(ServerRequestFrame.parse(decoded));
          return frames;
        }
      } catch (_) {
        // 落到 SSE 风格解析。
      }
    }
    for (final block in trimmed.split('\n\n')) {
      final data = block
          .split('\n')
          .where((line) => line.startsWith('data: '))
          .map((line) => line.substring('data: '.length))
          .join();
      if (data.isEmpty) continue;
      try {
        final decoded = jsonDecode(data);
        if (decoded is Map) frames.add(ServerRequestFrame.parse(decoded));
      } catch (_) {
        // 丢帧不断流。
      }
    }
    return frames;
  }

  void close() {
    _http.close(force: true);
    _stateController.close();
  }

  /// 审批 / ask-user 回写：`POST /api/respond`。
  ///
  /// body 为 **client-response 信封**（`{type, rpcId, result:{ok,value}}`），
  /// 服务端经 pending 表按 rpcId 路由后对 value 做二次解析
  /// （dsh-client-connection client.js:5461 实证）。返回 `{accepted, reason?}`。
  Future<Map<String, dynamic>?> respondClientResponse({
    required String rpcId,
    required Map<String, dynamic> value,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final message = <String, dynamic>{
      'type': 'client-response',
      'rpcId': rpcId,
      'result': {'ok': true, 'value': value},
    };
    final request = await _http.postUrl(_uri('/api/respond'));
    request.headers.contentType = ContentType.json;
    request.write(jsonEncode(message));
    final response = await request.close().timeout(timeout);
    final body = await utf8.decoder.bind(response).join();
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpException('respond failed: HTTP ${response.statusCode}',
          uri: _uri('/api/respond'));
    }
    final decoded = jsonDecode(body);
    return decoded is Map ? decoded.cast<String, dynamic>() : null;
  }
}

/// RPC 业务错误（服务器返回 ok:false）。
class RpcTransportError implements Exception {
  RpcTransportError(this.error);
  final RpcError error;

  @override
  String toString() => error.toString();
}
