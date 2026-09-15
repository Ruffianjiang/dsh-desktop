import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsh_client/src/connection.dart';
import 'package:test/test.dart';

/// DshConnection 集成测试（M3 Gate-B §3.1）：fake WS 服务端验证
/// 订阅→streaming、直播事件、游标去重、断线自动重连。
void main() {
  late HttpServer server;
  final sockets = <WebSocket>[];

  /// 每个新 WS 连接都会收到订阅基线帧（lastSeq 基线 0）。
  setUp(() async {
    server = await HttpServer.bind('127.0.0.1', 0);
    server.listen((req) async {
      final ws = await WebSocketTransformer.upgrade(req);
      sockets.add(ws);
      // 订阅基线帧：**每会话一帧** {sessionId, lastSeq}（契约 v0.2 实证）
      ws.add(_frame(payload: {
        'type': 'session/subscribed',
        'sessionId': 's1',
        'lastSeq': 0,
      }));
    });
  });

  tearDown(() async {
    for (final ws in sockets) {
      await ws.close();
    }
    sockets.clear();
    await server.close(force: true);
  });

  test('连接 → streaming → 事件接收 + seq 去重 + 断线自动重连', () async {
    final conn = DshConnection(endpoint: 'http://127.0.0.1:${server.port}');
    final phases = <ConnPhase>[];
    final sessionEvents = <Map<String, dynamic>>[];
    final phSub = conn.phases.listen(phases.add);
    final evSub = conn.events.listen((f) {
      if (f.payload['type'] == 'session/event') {
        sessionEvents.add(f.payload);
      }
    });

    await conn.start();
    await _waitFor(() => conn.phase == ConnPhase.streaming);
    expect(conn.phase, ConnPhase.streaming);
    expect(phases, contains(ConnPhase.streaming));

    // 直播事件 seq=1
    sockets.first.add(_frame(payload: {
      'type': 'session/event',
      'sessionId': 's1',
      'event': {'seq': 1, 'type': 'assistant/message'},
    }));
    await _waitFor(() => sessionEvents.isNotEmpty);
    expect((sessionEvents.single['event'] as Map)['seq'], 1);

    // 重复 seq=1 → 游标去重，不再投递（留足投递窗口）
    sockets.first.add(_frame(payload: {
      'type': 'session/event',
      'sessionId': 's1',
      'event': {'seq': 1, 'type': 'assistant/message'},
    }));
    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(sessionEvents.length, 1);

    // 服务端断开 → 退避 1s → 重连成功 → 再次 streaming
    for (final ws in List<WebSocket>.of(sockets)) {
      await ws.close();
    }
    await _waitFor(() =>
        conn.phase == ConnPhase.streaming &&
        identical(conn.phase, ConnPhase.streaming) &&
        _streamingCount(phases) >= 2, timeout: const Duration(seconds: 10));
    expect(conn.phase, ConnPhase.streaming);

    // 重连后事件继续可收（新 socket，seq=2 正常推进）
    sockets.last.add(_frame(payload: {
      'type': 'session/event',
      'sessionId': 's1',
      'event': {'seq': 2, 'type': 'assistant/message'},
    }));
    await _waitFor(() => sessionEvents.length >= 2);
    expect((sessionEvents.last['event'] as Map)['seq'], 2);

    await conn.close();
    expect(conn.phase, ConnPhase.disconnected);
    await phSub.cancel();
    await evSub.cancel();
  });
}

int _streamingCount(List<ConnPhase> phases) =>
    phases.where((p) => p == ConnPhase.streaming).length;

String _frame({required Map<String, dynamic> payload}) => jsonEncode({
      'type': 'server-request',
      'rpcId': 'srv-${DateTime.now().microsecondsSinceEpoch}',
      'method': 'session/event',
      'payload': payload,
    });

Future<void> _waitFor(bool Function() cond,
    {Duration timeout = const Duration(seconds: 15)}) async {
  final end = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(end)) {
    if (cond()) return;
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  fail('条件在 ${timeout.inSeconds}s 内未满足');
}
