import 'dart:convert';
import 'dart:io';

import 'package:dsh_client/dsh_client.dart';

/// 回放真实采集帧（probe_frames.jsonl）验证 ChatAssembler 聚合：
/// 工具 call/result 应聚合为一卡（title=查看视图，detail=结果正文）。
Future<void> main(List<String> args) async {
  final file = File(args.isNotEmpty ? args[0] : 'probe_frames.jsonl');
  final state = ChatState();
  final assembler = ChatAssembler();
  var toolCalls = 0, toolResults = 0;
  for (final line in file.readAsStringSync().split('\n')) {
    if (line.trim().isEmpty) continue;
    final j = jsonDecode(line) as Map;
    final payload = (j['payload'] as Map?) ?? const {};
    if (payload['type'] != 'session/event') continue;
    final event = (payload['event'] as Map?)?.cast<String, dynamic>();
    if (event == null) continue;
    if (event['type'] == 'tool/call') toolCalls++;
    if (event['type'] == 'tool/result') toolResults++;
    final view = (payload['view'] as Map?)?.cast<String, dynamic>();
    assembler.applyEvent(state, event, view: view);
  }
  stdout.writeln(
      '[input] tool/call=$toolCalls tool/result=$toolResults lastSeq=${state.lastSeq}');
  for (final m in state.messages) {
    stdout.writeln('== ${m.role.name} status=${m.status.name}');
    for (final b in m.blocks) {
      if (b.type == ChatBlockType.toolCall) {
        stdout.writeln(
            '  [tool] title="${b.text}" kind=${b.toolKind} detail=${b.toolDetail?.length ?? 0}B');
        if (b.toolDetail != null) {
          final head = b.toolDetail!
              .substring(0, b.toolDetail!.length.clamp(0, 120));
          stdout.writeln('      head: ${head.replaceAll('\n', ' | ')}');
        }
      } else {
        stdout.writeln(
            '  [${b.type.name}] ${b.text.length}B closed=${b.closed} head=${b.text.isEmpty ? '-' : b.text.substring(0, b.text.length.clamp(0, 60)).replaceAll('\n', ' | ')}');
      }
    }
  }
  exit(0);
}
