import 'dart:convert';
import 'dart:io';

import 'package:dsh_client/src/assemble.dart';
import 'package:test/test.dart';

/// ChatAssembler golden 测试（M3 Gate-B §4.3）：
/// 40KB 真实 history 装载 + 直播重放等价性。
void main() {
  final goldenFile = File(
      '../contract/golden/session.history.response.json');
  final raw =
      jsonDecode(goldenFile.readAsStringSync()) as Map<String, dynamic>;
  final value = (raw['result'] as Map)['value'] as Map<String, dynamic>;
  // 直接使用 history 条目原始形态 {event, view?}（applyAll 兼容两者）
  final history = (value['events'] as List)
      .map<Map<String, dynamic>>((e) => (e as Map).cast<String, dynamic>())
      .toList();

  test('golden 装载：user 消息文本正确', () {
    final state = ChatAssembler().applyAll(history);
    final user = state.messages.where((m) => m.role == ChatRole.user).toList();
    expect(user, isNotEmpty);
    expect(user.first.plainText, 'Reply with exactly OK. Do not use tools.');
  });

  test('golden 装载：assistant 权威落定 "OK" 且 done', () {
    final state = ChatAssembler().applyAll(history);
    final assistant =
        state.messages.where((m) => m.role == ChatRole.assistant).toList();
    expect(assistant, isNotEmpty);
    expect(assistant.last.plainText, 'OK');
    expect(assistant.last.status, MessageStatus.done);
    expect(assistant.last.blocks.map((b) => b.type),
        everyElement(ChatBlockType.text));
  });

  test('golden 装载：非消息事件不进消息流（approval/policy 等）', () {
    final state = ChatAssembler().applyAll(history);
    // golden 含 approval/policy、request/header、session/title 等，
    // 但消息数只应为 user(≤2) + assistant(1)
    expect(state.messages.length, lessThanOrEqualTo(3));
    expect(state.messages.every((m) => m.blocks.isNotEmpty), isTrue);
  });

  test('游标：lastSeq == 事件最大 seq', () {
    final state = ChatAssembler().applyAll(history);
    final maxSeq = history
        .map((e) =>
            ((e['event'] as Map)['seq'] as num?)?.toInt() ?? 0)
        .reduce((a, b) => a > b ? a : b);
    expect(state.lastSeq, maxSeq);
  });

  test('等价性：逐事件 applyEvent 与 applyAll 结果一致', () {
    final a = ChatAssembler().applyAll(history);
    final b = ChatState();
    final asm = ChatAssembler();
    for (final entry in history) {
      final event = (entry['event'] as Map).cast<String, dynamic>();
      final view = (entry['view'] as Map?)?.cast<String, dynamic>();
      asm.applyEvent(b, event, view: view);
    }
    expect(b.messages.length, a.messages.length);
    for (var i = 0; i < a.messages.length; i++) {
      expect(b.messages[i].id, a.messages[i].id);
      expect(b.messages[i].role, a.messages[i].role);
      expect(b.messages[i].plainText, a.messages[i].plainText);
      expect(b.messages[i].status, a.messages[i].status);
    }
    expect(b.lastSeq, a.lastSeq);
  });
}
