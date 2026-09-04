/// F1 版本目录与解析（Gate-B v1.0 §4.4 InstallService）。
///
/// 数据来源：`npm registry` 的 packument（`dist-tags` + `versions` 键）。
/// 优先走 HTTP registry（结构化、可解析），失败时回退 `npm view`。
library;

import 'dart:convert';
import 'dart:io';

/// 单个可用版本（含其拥有的 dist-tag）。
class VersionEntry {
  const VersionEntry(this.version, [this.distTags = const []]);

  final String version;

  /// 该版本拥有的 dist-tag 名（如 `latest`/`next`/`alpha`）。
  final List<String> distTags;

  bool get prerelease => VersionCatalog.isPrerelease(version);

  @override
  String toString() => version;
}

/// npm registry 版本目录。
class VersionCatalog {
  VersionCatalog({
    required this.all,
    required this.distTags,
  }) : assert(
          distTags.isEmpty || distTags.values.every(all.contains),
          'dist-tags 必须指向 all 中存在版本',
        );

  /// 全部版本（升序，语义化排序）。
  final List<String> all;

  /// dist-tag → 版本（latest/next/alpha…）。
  final Map<String, String> distTags;

  /// 取某 dist-tag 指向的版本（不存在返回 null）。
  String? tag(String name) => distTags[name];

  String get latest => distTags['latest'] ?? (all.isNotEmpty ? all.last : '');

  /// 仅发布版本（剔除 prerelease），升序；为空时回退 all。
  List<String> stable() =>
      all.where((v) => !isPrerelease(v)).toList()..sort(compare);

  /// 升序排列（语义化比较）。
  List<String> sorted({bool includePrerelease = true}) =>
      (includePrerelease ? List<String>.from(all) : stable())
        ..sort(compare);

  /// 解析目标版本：
  /// - `latest`/`next`/`alpha`：对应 dist-tag；
  /// - `newest`：全部最新（含 prerelease）；
  /// - `upgrade`：比 [current] 更新的最新（受 [includePrerelease] 影响）；
  /// - 具体 semver：必须存在于 all。
  String? resolveTarget(
    String spec, {
    String? current,
    bool includePrerelease = false,
  }) {
    switch (spec) {
      case 'latest':
        return distTags['latest'];
      case 'next':
        return distTags['next'];
      case 'alpha':
        return distTags['alpha'];
      case 'newest':
        final s = sorted(includePrerelease: true);
        return s.isNotEmpty ? s.last : null;
      case 'upgrade':
        return _newerThan(current, includePrerelease: includePrerelease);
      default:
        return all.contains(spec) ? spec : null;
    }
  }

  String? _newerThan(String? current, {required bool includePrerelease}) {
    final candidates = sorted(includePrerelease: includePrerelease);
    if (candidates.isEmpty) return null;
    if (current == null) return candidates.last;
    final base = candidates.indexOf(current);
    if (base < 0) return candidates.last; // current 不在目录中，取最新。
    return base < candidates.length - 1 ? candidates.last : null; // null=已最新。
  }

  /// 语义化版本比较：a<b 返回负数。遵循 semver 优先级（release > prerelease）。
  static int compare(String a, String b) => _parse(a).compareTo(_parse(b));

  /// 是否为预发布版本（含 `-rc`/`-alpha`/`-beta`/`-preview` 等）。
  static bool isPrerelease(String v) {
    final dash = v.split('-');
    return dash.length > 1 && dash[1].isNotEmpty;
  }

  // ---- 解析与获取 ----

  /// 从 npm registry packument JSON 构建。
  factory VersionCatalog.fromPackument(Map<String, dynamic> doc) {
    final tags = (doc['dist-tags'] as Map?)?.cast<String, String>() ?? {};
    final versions = ((doc['versions'] as Map?)?.keys ?? const [])
        .map((e) => e as String)
        .toList();
    versions.sort((a, b) => VersionCatalog.compare(a, b));
    return VersionCatalog(all: versions, distTags: tags);
  }

  /// 通过 HTTP registry 拉取（结构化、首选）。
  ///
  /// [proxy] 为形如 `http://host:port` 的代理（Dart `HttpClient` 不读
  /// `HTTPS_PROXY` 环境变量，须显式注入）。
  static Future<VersionCatalog> fetchHttp(
    String package, {
    String registry = 'https://registry.npmjs.org/',
    String? proxy,
    HttpClient? client,
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final base = registry.endsWith('/') ? registry : '$registry/';
    final uri = Uri.parse('$base${Uri.encodeComponent(package)}');
    final http = client ?? HttpClient()..connectionTimeout = timeout;
    if (proxy != null) {
      final u = Uri.parse(proxy);
      http.findProxy = (_) => 'PROXY ${u.host}:${u.port};';
    }
    try {
      final req = await http.getUrl(uri);
      final res = await req.close().timeout(timeout);
      if (res.statusCode != 200) {
        throw StateError('registry 返回 HTTP ${res.statusCode} for $package');
      }
      final body = await res.transform(utf8.decoder).join().timeout(timeout);
      final doc = jsonDecode(body) as Map<String, dynamic>;
      return VersionCatalog.fromPackument(doc);
    } finally {
      if (client == null) http.close(force: true);
    }
  }

  /// 回退：通过 `npm view <pkg> versions --json`（无结构化网络时）。
  static Future<VersionCatalog> fetchNpm(
    String package, {
    required String npmExecutable,
    Map<String, String>? environment,
    Duration timeout = const Duration(seconds: 60),
  }) async {
    final tags = await _npmView(
      npmExecutable,
      package,
      'dist-tags',
      environment: environment,
      timeout: timeout,
    );
    final vers = await _npmView(
      npmExecutable,
      package,
      'versions',
      environment: environment,
      timeout: timeout,
    );
    final versionList = (jsonDecode(vers) as List).cast<String>();
    versionList.sort(compare);
    final tagMap = (jsonDecode(tags) as Map).cast<String, String>();
    return VersionCatalog(all: versionList, distTags: tagMap);
  }

  static Future<String> _npmView(
    String npm,
    String package,
    String field, {
    required Map<String, String>? environment,
    required Duration timeout,
  }) async {
    final r = await Process.run(
      npm,
      ['view', package, field, '--json'],
      environment: environment,
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
      runInShell: Platform.isWindows,
    ).timeout(timeout);
    if (r.exitCode != 0) {
      throw StateError('npm view $package $field 失败: ${r.stderr}');
    }
    return (r.stdout as String).trim();
  }
}

/// 语义化版本三元（major.minor.patch）+ 预发布标识列表。
class _Sem {
  _Sem(this.core, this.pre);
  final List<int> core; // [major, minor, patch]
  final List<String> pre; // 预发布标识（可能为空）

  static _Sem parse(String v) {
    final preSplit = v.split('-');
    final coreStr = preSplit[0].split('.');
    final core = coreStr.map((e) => int.tryParse(e) ?? 0).toList();
    while (core.length < 3) {
      core.add(0);
    }
    final pre = preSplit.length > 1
        ? preSplit[1].split('.').where((e) => e.isNotEmpty).toList()
        : const <String>[];
    return _Sem(core, pre);
  }

  int compareTo(_Sem o) {
    for (var i = 0; i < 3; i++) {
      if (core[i] != o.core[i]) return core[i].compareTo(o.core[i]);
    }
    // 主版本相同：release(无 pre) 高于 prerelease。
    if (pre.isEmpty && o.pre.isEmpty) return 0;
    if (pre.isEmpty) return 1;
    if (o.pre.isEmpty) return -1;
    final n = pre.length < o.pre.length ? pre.length : o.pre.length;
    for (var i = 0; i < n; i++) {
      final c = _cmpId(pre[i], o.pre[i]);
      if (c != 0) return c;
    }
    return pre.length.compareTo(o.pre.length);
  }

  static int _cmpId(String a, String b) {
    final ai = int.tryParse(a);
    final bi = int.tryParse(b);
    if (ai != null && bi != null) return ai.compareTo(bi);
    if (ai != null) return -1; // 数字标识低于字母标识。
    if (bi != null) return 1;
    return a.compareTo(b);
  }
}

/// 解析语义化版本（私有，避免与类同名构造冲突）。
_Sem _parse(String v) => _Sem.parse(v);
