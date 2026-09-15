import 'dart:async';
import 'dart:io';

import 'package:dsh_client/dsh_client.dart';

/// T9 实机回归（修正后复验）：DshConnection 对真实实例应
/// ① 连接后 ~1s 内进入 streaming（不等首帧）；② REST create 后收到帧。
Future<void> main(List<String> args) async {
  final endpoint = args.isNotEmpty ? args[0] : 'http://127.0.0.1:54272';
  stdout.writeln('[regress] endpoint=$endpoint');

  final conn = DshConnection(endpoint: endpoint);
  final watch = Stopwatch()..start();
  var frames = 0;
  final subs = <StreamSubscription<void>>[];
  subs.add(conn.phases.listen((p) {
    stdout.writeln(
        '[phase] +${watch.elapsedMilliseconds}ms $p lastError=${conn.lastError}');
  }));
  subs.add(conn.events.listen((f) {
    frames++;
    if (frames <= 4) {
      stdout.writeln(
          '[frame] type=${f.payload['type']} sessionId=${f.payload['sessionId']}');
    }
  }));
  await conn.start();

  // 等 streaming（应 < 2s）
  final sw2 = Stopwatch()..start();
  while (conn.phase != ConnPhase.streaming && sw2.elapsed.inSeconds < 8) {
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  stdout.writeln(
      '[check] streaming-reached=${conn.phase == ConnPhase.streaming} '
      'in=${sw2.elapsedMilliseconds}ms');

  // 触发活动：REST 创建会话
  try {
    await conn.sessionApi.create().timeout(const Duration(seconds: 8));
    stdout.writeln('[rest] session.create ok');
  } catch (e) {
    stdout.writeln('[rest] session.create FAIL: $e');
  }

  await Future<void>.delayed(const Duration(seconds: 5));
  stdout.writeln(
      '[summary] phase=${conn.phase} frames=$frames lastError=${conn.lastError}');
  final pass = conn.phase == ConnPhase.streaming && frames > 0;
  stdout.writeln('[result] ${pass ? 'PASS' : 'FAIL'}');
  await conn.close();
  for (final s in subs) {
    await s.cancel();
  }
  exit(0);
}
