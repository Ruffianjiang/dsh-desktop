import 'dart:async';
import 'dart:io';

import 'package:dsh_client/dsh_client.dart';

/// dsh 协议联调 CLI（M1/T4）。
///
/// 用法：
///   dart run bin/probe.dart list                     # 列会话
///   dart run bin/probe.dart create                   # 新建会话
///   dart run bin/probe.dart history <sessionId>      # 会话事件历史（assistant 文本）
///   dart run bin/probe.dart roundtrip [text]         # 完整一轮：建会话→prompt→WS 流→history 汇总
/// 环境/参数：--base http://127.0.0.1:3080
Future<void> main(List<String> args) async {
  var base = 'http://127.0.0.1:3080';
  final positional = <String>[];
  for (final a in args) {
    if (a.startsWith('--base=')) {
      base = a.substring('--base='.length);
    } else {
      positional.add(a);
    }
  }
  final cmd = positional.isNotEmpty ? positional[0] : 'roundtrip';
  final client = DshClient(baseUrl: base);
  final sessions = SessionApi(client);
  try {
    switch (cmd) {
      case 'list':
        final value = await sessions.list();
        final items = value?['items'] as List? ?? const [];
        stdout.writeln('会话数: ${items.length}');
        for (final it in items.take(10)) {
          final m = (it as Map).cast<String, dynamic>();
          stdout.writeln(
              '  ${m['sessionId']}  running=${m['running']}  blank=${m['blank']}  ${m['cwd']}');
        }
      case 'create':
        final value = await sessions.create();
        stdout.writeln('created: ${value?['sessionId']} (${value?['agentPreset']})');
      case 'history':
        if (positional.length < 2) throw const FormatException('need <sessionId>');
        final value = await sessions.history(positional[1]);
        _printHistoryAssistant(value);
      case 'roundtrip':
        await _roundtrip(sessions, client,
            text: positional.length > 1 ? positional.sublist(1).join(' ') : null);
      default:
        throw FormatException('unknown cmd: $cmd');
    }
  } catch (e) {
    stderr.writeln('ERR: $e');
    exitCode = 1;
  } finally {
    client.close();
  }
}

/// 直播增量：只收 `assistant/chunk` 的 `text-delta`（避免与 block-end/message 重复）。
void _extractLiveDelta(Map<String, dynamic> evt, List<String> out) {
  final data = evt['data'];
  if (evt['type'] != 'assistant/chunk' || data is! Map) return;
  final chunk = data['chunk'];
  if (chunk is! Map) return;
  final cm = chunk.cast<String, dynamic>();
  if (cm['type'] == 'text-delta') {
    out.add((cm['text'] ?? '').toString());
  }
}

/// 从（直播或 history 里的）事件对象中抽取助手文本块，追加到 [out]。
///
/// 实测结构（契约 v0.1 §3）：
///   assistant/chunk   → data.chunk.type ∈ { block-start, text-delta(→chunk.text),
///                        block-end(→chunk.block.text), usage, finish }
///   assistant/message → data.message.content[]（type:"text" 的 text）
void _extractAssistantText(Map<String, dynamic> evt, List<String> out) {
  final type = evt['type'] as String? ?? '';
  final data = evt['data'];
  if (data is! Map) return;
  if (type == 'assistant/message') {
    final msg = data['message'];
    final content = msg is Map ? msg['content'] : data['content'];
    if (content is List) {
      for (final part in content) {
        final pm = part is Map ? part.cast<String, dynamic>() : null;
        if (pm != null && pm['type'] == 'text') {
          out.add((pm['text'] ?? '').toString());
        }
      }
    }
  }
}

Future<void> _roundtrip(SessionApi sessions, DshClient client,
    {String? text}) async {
  final created = await sessions.create();
  final sid = created?['sessionId'] as String;
  stdout.writeln('session: $sid');

  final liveText = <String>[];
  var liveFrames = 0;
  var sawOwnEvent = false;
  var lastFrameAt = DateTime.now();

  // 先挂 WS（先订阅再 prompt 才能收到直播帧；实测 /api/events.mux 为 WebSocket 端点）。
  final sub = client.openStream('/api/events.mux').listen(
    (frame) {
      liveFrames++;
      lastFrameAt = DateTime.now();
      final payload = frame.payload;
      final ptype = payload['type'] as String? ?? frame.method;
      final pSid = payload['sessionId'] as String? ?? '';
      if (pSid == sid && ptype == 'session/event') {
        sawOwnEvent = true;
        final evt = payload['event'];
        if (evt is Map) {
          _extractLiveDelta(evt.cast<String, dynamic>(), liveText);
        }
      }
    },
    onError: (e) => stderr.writeln('\n[ws] $e'),
  );

  final prompt =
      text ?? '请只回复「pong」两个字，不要使用任何工具。';
  stdout.writeln('prompt: $prompt');
  final accepted = await sessions.prompt(sid, prompt);
  stdout.writeln('accepted: ${accepted?['accepted']}');

  // 静默窗口：收到本会话事件后 3s 无新帧视为本轮结束；上限 90s。
  final deadline = DateTime.now().add(const Duration(seconds: 90));
  while (DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 400));
    if (sawOwnEvent &&
        DateTime.now().difference(lastFrameAt) >= const Duration(seconds: 3)) {
      break;
    }
    if (!sawOwnEvent &&
        DateTime.now().difference(lastFrameAt) >= const Duration(seconds: 10)) {
      // 迟迟未收到本会话事件，不再干等（history 兜底）。
      stdout.writeln('[roundtrip] 未观测到本会话事件，转 history 汇总');
      break;
    }
  }
  await sub.cancel();
  await Future<void>.delayed(const Duration(milliseconds: 600)); // 落盘沉降

  final liveJoined = liveText.join();
  stdout.writeln('--- WS 帧数: $liveFrames；本会话事件: $sawOwnEvent；直播直收字符: ${liveJoined.length} ---');
  if (liveJoined.trim().isNotEmpty) {
    stdout.writeln('--- 直播助手文本 ---');
    stdout.writeln(liveJoined.trim());
  }
  final value = await sessions.history(sid);
  _printHistoryAssistant(value);
}

void _printHistoryAssistant(Map<String, dynamic>? value) {
  final events = (value?['events'] as List?) ?? const [];
  var printed = 0;
  for (final it in events) {
        final evt = (it is Map) ? ((it['event'] as Map?)?.cast<String, dynamic>()) : null;    if (evt == null) continue;
    final buf = <String>[];
    _extractAssistantText(evt, buf);
    for (final t in buf) {
      if (t.trim().isEmpty) continue;
      stdout.writeln('[history seq=${evt['seq']}] ${t.trim()}');
      printed++;
    }
  }
  if (printed == 0) stdout.writeln('(history 无 assistant 文本)');
}
