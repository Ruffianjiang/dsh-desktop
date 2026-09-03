import 'dart:convert';
import 'dart:io';

/// 环境探测结果。
class NodeEnv {
  const NodeEnv({
    required this.nodePath,
    required this.dshCliJs,
    required this.dshVersion,
  });

  /// node 可执行文件绝对路径。
  final String nodePath;

  /// dsh 的 JS 入口（`<prefix>/node_modules/@deepseek-ai/dsh/lib/bin.js` 等）。
  final String dshCliJs;

  final String? dshVersion;

  static const _knownSuffixes = [
    r'node_modules\@deepseek-ai\dsh\lib\bin.js',
    r'node_modules\dsh\lib\bin.js',
  ];

  /// 解析 node + dsh CLI 的 JS 入口。
  ///
  /// 优先级：环境变量 `DSH_CLI`（直接给 bin.js 路径）→ Windows `where dsh.cmd`
  /// （取其所在 prefix，探测已知后缀）→ node 同目录前缀的 node_modules。
  static Future<NodeEnv> probe({String? dshCliOverride}) async {
    final explicit = dshCliOverride ?? Platform.environment['DSH_CLI'];
    if (explicit != null && File(explicit).existsSync()) {
      final node = await _node();
      return NodeEnv(
          nodePath: node,
          dshCliJs: explicit,
          dshVersion: await _dshVersion(node, explicit));
    }

    final node = await _node();
    final candidates = <String>[];

    if (Platform.isWindows) {
      try {
        final r = await Process.run('cmd', ['/c', 'where dsh.cmd']);
        if (r.exitCode == 0) {
          final first = (r.stdout as String).trim().split('\n').first.trim();
          if (first.isNotEmpty) {
            final prefix = File(first).parent.path;
            candidates.addAll(_knownSuffixes.map((s) => '$prefix\\$s'));
          }
        }
      } catch (_) {/* 忽略探测失败 */}
    }

    final nodeDir = File(node).parent.path;
    candidates.addAll(_knownSuffixes.map((s) => '$nodeDir\\$s'));

    for (final c in candidates) {
      if (File(c).existsSync()) {
        return NodeEnv(
            nodePath: node,
            dshCliJs: c,
            dshVersion: await _dshVersion(node, c));
      }
    }
    throw StateError('未找到 dsh CLI JS 入口（可设 DSH_CLI 指向 bin.js）');
  }

  static Future<String> _node() async {
    final envNode = Platform.environment['DSH_NODE'];
    if (envNode != null && File(envNode).existsSync()) return envNode;
    if (Platform.isWindows) {
      final r = await Process.run('cmd', ['/c', 'where node']);
      if (r.exitCode == 0) {
        final first = (r.stdout as String).trim().split('\n').first.trim();
        if (first.isNotEmpty && File(first).existsSync()) return first;
      }
    }
    throw StateError('未找到 node（可设 DSH_NODE 指向 node.exe）');
  }

  static Future<String?> _dshVersion(String node, String cli) async {
    try {
      final r = await Process.run(node, [cli, '--version'],
          stdoutEncoding: utf8, stderrEncoding: utf8);
      return r.exitCode == 0 ? (r.stdout as String).trim() : null;
    } catch (_) {
      return null;
    }
  }
}
