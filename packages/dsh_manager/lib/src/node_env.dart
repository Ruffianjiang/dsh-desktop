import 'dart:convert';
import 'dart:io';

/// 环境探测结果。
class NodeEnv {
  const NodeEnv({
    required this.nodePath,
    required this.dshCliJs,
    required this.dshVersion,
    this.source = 'PATH',
  });

  /// node 可执行文件绝对路径。
  final String nodePath;

  /// dsh 的 JS 入口（`<prefix>/node_modules/@deepseek-ai/dsh/lib/bin.js` 等）。
  final String dshCliJs;

  final String? dshVersion;

  /// 引擎来源：`DSH_CLI`（显式覆盖）/ `managed`（托管 prefix）/
  /// `PATH`（where dsh.cmd 全局）/ `node-dir`（node 同目录）。
  final String source;

  static const _knownSuffixes = [
    r'node_modules\@deepseek-ai\dsh\lib\bin.js',
    r'node_modules\dsh\lib\bin.js',
  ];

  /// 由已知 node + dsh bin.js 直接构造（InstallService 安装结果接入用）。
  factory NodeEnv.forDshCli(String nodePath, String dshCliJs,
          {String source = '指定路径'}) =>
      NodeEnv(
          nodePath: nodePath,
          dshCliJs: dshCliJs,
          dshVersion: null,
          source: source);

  /// 解析 node + dsh CLI 的 JS 入口。
  ///
  /// 优先级（T9 修正 F1-1，Gate-A 20260909）：环境变量 `DSH_CLI`（显式覆盖）
  /// → **托管 prefix**（[managedPrefix]，实现"安装即生效"）→ Windows
  /// `where dsh.cmd`（取其所在 prefix，探测已知后缀）→ node 同目录。
  static Future<NodeEnv> probe(
      {String? dshCliOverride, String? managedPrefix}) async {
    final explicit = dshCliOverride ?? Platform.environment['DSH_CLI'];
    if (explicit != null && File(explicit).existsSync()) {
      final node = await _node();
      return NodeEnv(
          nodePath: node,
          dshCliJs: explicit,
          dshVersion: await _dshVersion(node, explicit),
          source: 'DSH_CLI');
    }

    final node = await _node();

    // 托管 prefix 优先于全局 PATH：引擎页安装后新实例即用托管引擎。
    if (managedPrefix != null) {
      for (final s in _knownSuffixes) {
        final p = '$managedPrefix\\$s';
        if (File(p).existsSync()) {
          return NodeEnv(
              nodePath: node,
              dshCliJs: p,
              dshVersion: await _dshVersion(node, p),
              source: 'managed');
        }
      }
    }

    final candidates = <(String, String)>[];

    if (Platform.isWindows) {
      try {
        final r = await Process.run('cmd', ['/c', 'where dsh.cmd']);
        if (r.exitCode == 0) {
          final first = (r.stdout as String).trim().split('\n').first.trim();
          if (first.isNotEmpty) {
            final prefix = File(first).parent.path;
            candidates.addAll(_knownSuffixes.map((s) => ('$prefix\\$s', 'PATH')));
          }
        }
      } catch (_) {/* 忽略探测失败 */}
    }

    final nodeDir = File(node).parent.path;
    candidates.addAll(_knownSuffixes.map((s) => ('$nodeDir\\$s', 'node-dir')));

    for (final (c, src) in candidates) {
      if (File(c).existsSync()) {
        return NodeEnv(
            nodePath: node,
            dshCliJs: c,
            dshVersion: await _dshVersion(node, c),
            source: src);
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
