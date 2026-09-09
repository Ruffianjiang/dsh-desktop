import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsh_client/dsh_client.dart';

/// 采集真实工具帧：create → prompt（触发文件工具）→ 全帧落盘。
/// 用法：`dart run tool/probe_tool_frames.dart http://127.0.0.1:<port>`
Future<void> main(List<String> args) async {
  final endpoint = args.isNotEmpty ? args[0] : 'http://127.0.0.1:55143';
  final wsUri = endpoint.replaceFirst('http://', 'ws://');
  final frames = <String>[];
  final done = Completer<void>();

  final ws = await WebSocket.connect('$wsUri/api/events.mux');
  final wsSub = ws.listen((m) {
    if (m is! String) return;
    frames.add(m);
    try {
      final j = jsonDecode(m) as Map;
      final payload = (j['payload'] as Map?) ?? const {};
      final type = payload['type']?.toString();
      final event = payload['event'] as Map?;
      final etype = event?['type']?.toString();
      stdout.writeln('[frame] $type${etype == null ? '' : '/$etype'}');
      if ((etype == 'turn/end' || etype == 'assistant/message') &&
          !done.isCompleted) {
        // 收尾事件出现（工具调用之后）：延迟 2s 收尾，确保后续帧到齐
        Future.delayed(const Duration(seconds: 2), () {
          if (!done.isCompleted) done.complete();
        });
      }
      if (type == 'approval/requested') {
        // 探针会话：自动放行一次（同时采集审批帧形态）
        final client = DshClient(baseUrl: endpoint);
        unawaited(client
            .respondClientResponse(
          rpcId: j['rpcId'].toString(),
          value: {
            'sessionId': payload['sessionId'],
            'approvalId': payload['approvalId'],
            'outcome': 'allowed-once',
          },
        )
            .then((r) {
          stdout.writeln('[approve] $r');
          client.close();
        }));
      }
    } catch (_) {}
  });

  final client = DshClient(baseUrl: endpoint);
  final created = await client.call('session.create', {});
  final sid = created?['value']?['sessionId'] ?? created?['sessionId'];
  stdout.writeln('[session] $sid');

  await client.call('session.prompt', {
    'sessionId': sid,
    'mode': 'queue',
    'content': [
      {
        'type': 'text',
        'text': '请使用文件读取工具查看当前工作目录下的文件列表，'
            '然后告诉我一共有几个文件。'
      }
    ],
  });
  stdout.writeln('[prompt] sent, waiting for tool frames...');

  await done.future.timeout(const Duration(seconds: 120), onTimeout: () {
    stdout.writeln('[warn] 120s 超时，按已有帧收尾');
  });

  // 落盘全部帧
  final out = File('probe_frames.jsonl');
  out.writeAsStringSync(frames.map((f) => jsonEncode(jsonDecode(f))).join('\n'));
  stdout.writeln('[dump] ${frames.length} 帧 -> ${out.absolute.path}');

  // 打印 tool 相关帧全文（call/result + view）
  for (final f in frames) {
    if (f.contains('"tool/') || f.contains('"view"')) {
      stdout.writeln('-----');
      stdout.writeln(f.length > 1500 ? f.substring(0, 1500) : f);
    }
  }
  await ws.close();
  await wsSub.cancel();
  client.close();
  exit(0);
}
