import 'dart:convert';
import 'dart:io';

import 'package:dsh_client/dsh_client.dart';

/// 基于 packages/contract/golden 的 fixture 校验（等价契约测试的 Dart 侧骨架）。
/// 用法：`dart run tool/verify_contract.dart`（自动向上查找 repo 内 golden 目录）。
void main() {
  final goldenDir = _findGoldenDir();
  if (goldenDir == null) {
    stderr.writeln('FAIL: 未找到 packages/contract/golden（从 $goldenDir 上溯）');
    exit(1);
  }
  var failed = 0;
  int check(String name, bool ok, [String? detail]) {
    stdout.writeln('${ok ? 'PASS' : 'FAIL'}  $name${detail == null ? '' : '  -- $detail'}');
    if (!ok) failed++;
    return failed;
  }

  // 1) session.create.response：ok + value.sessionId
  final create = ServerResponse.parse(_load(goldenDir, 'session.create.response.json'));
  check('session.create 信封', create.ok && create.type == 'server-response');
  check('session.create value.sessionId 非空',
      (create.value?['sessionId'] as String? ?? '').isNotEmpty);

  // 2) session.prompt.accepted：value.accepted==true
  final accept = ServerResponse.parse(_load(goldenDir, 'session.prompt.accepted.response.json'));
  check('session.prompt accepted', accept.ok && accept.value?['accepted'] == true);

  // 3) session.prompt.badrequest：ok=false + error.code
  final bad = ServerResponse.parse(_load(goldenDir, 'session.prompt.badrequest.response.json'));
  check('session.prompt badrequest ok=false', !bad.ok);
  check('session.prompt badrequest error.code=bad-request', bad.error?.code == 'bad-request');
  check('session.prompt badrequest details.issues 存在', bad.error?.details is Map);

  // 4) session.list：value.items 非空数组且首项有 sessionId/projections
  final list = ServerResponse.parse(_load(goldenDir, 'session.list.response.json'));
  final items = list.value?['items'];
  check('session.list value.items 为数组', items is List && items.isNotEmpty);
  if (items is List && items.isNotEmpty) {
    final first = (items.first as Map).cast<String, dynamic>();
    check('session.list 首项字段', (first['sessionId'] as String? ?? '').isNotEmpty &&
        first.containsKey('projections'));
  }

  // 5) session.history：value.events 为数组且含 event 键
  final hist = ServerResponse.parse(_load(goldenDir, 'session.history.response.json'));
  final events = hist.value?['events'];
  check('session.history value.events 为数组', events is List && events.isNotEmpty);
  if (events is List && events.isNotEmpty) {
    final firstEvent = ((events.first as Map)['event']);
    check('session.history 首事件含 type',
        firstEvent is Map && (firstEvent['type'] as String? ?? '').isNotEmpty);
  }

  // 6) SSE 空样例：占位文件不应产出帧
  final emptyFrames = <Map<String, dynamic>>[];
  parseSse(Stream.value(File('${goldenDir.path}/events.mux.raw.sse').readAsBytesSync()))
      .listen(emptyFrames.add)
      .asFuture<void>()
      .then((_) {
    check('events.mux 空样例 0 帧', emptyFrames.isEmpty);
    stdout.writeln(failed == 0 ? 'ALL PASS' : '$failed FAILED');
    exit(failed == 0 ? 0 : 1);
  });
}

Directory? _findGoldenDir() {
  var dir = Directory(Platform.script.toFilePath());
  for (var i = 0; i < 8 && dir.parent.path != dir.path; i++) {
    final candidate = Directory('${dir.path}${Platform.pathSeparator}packages'
        '${Platform.pathSeparator}contract${Platform.pathSeparator}golden');
    if (candidate.existsSync()) return candidate;
    dir = dir.parent;
  }
  return null;
}

Object? _load(Directory golden, String name) =>
    jsonDecode(File('${golden.path}${Platform.pathSeparator}$name').readAsStringSync());
