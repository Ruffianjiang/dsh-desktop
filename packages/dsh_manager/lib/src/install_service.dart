/// F1 安装/升级服务（Gate-B v1.0 §4.4 InstallService）。
///
/// 职责：查询可装版本、解析目标、将 `@deepseek-ai/dsh` 安装到**托管 prefix**
/// （默认 `~/.dsh-desktop/engine`），探测已装版本，支持升级与回滚。
///
/// 设计要点：
/// - 配置与运行解耦：node/npm 路径显式传入，便于测试与多运行时并存。
/// - 幂等：目标 prefix 已为该版本则跳过安装直接返回。
/// - 回滚：升级时记录 `previousVersion`，`rollback()` 重装旧版并互换。
library;

import 'dart:convert';
import 'dart:io';

import 'node_env.dart';
import 'version_catalog.dart';

/// 引擎安装结果（指向一个可用 dsh 实例）。
class EngineInstall {
  const EngineInstall({
    required this.prefix,
    required this.dshCliJs,
    required this.version,
    this.previousVersion,
    this.installedAt,
  });

  /// npm prefix（含 `node_modules/`）。
  final String prefix;

  /// dsh JS 入口 `<prefix>/node_modules/@deepseek-ai/dsh/lib/bin.js`。
  final String dshCliJs;

  final String version;

  /// 升级前的版本（供 rollback）；初始安装为 null。
  final String? previousVersion;

  final DateTime? installedAt;

  EngineInstall copyWith({
    String? prefix,
    String? dshCliJs,
    String? version,
    String? previousVersion,
    DateTime? installedAt,
  }) =>
      EngineInstall(
        prefix: prefix ?? this.prefix,
        dshCliJs: dshCliJs ?? this.dshCliJs,
        version: version ?? this.version,
        previousVersion: previousVersion ?? this.previousVersion,
        installedAt: installedAt ?? this.installedAt,
      );

  NodeEnv toNodeEnv(String nodePath) => NodeEnv.forDshCli(nodePath, dshCliJs);

  Map<String, dynamic> toJson() => {
        'prefix': prefix,
        'dshCliJs': dshCliJs,
        'version': version,
        'previousVersion': previousVersion,
        'installedAt': installedAt?.toIso8601String(),
      };

  factory EngineInstall.fromJson(Map<String, dynamic> j) => EngineInstall(
        prefix: j['prefix'] as String,
        dshCliJs: j['dshCliJs'] as String,
        version: j['version'] as String,
        previousVersion: j['previousVersion'] as String?,
        installedAt: j['installedAt'] == null
            ? null
            : DateTime.tryParse(j['installedAt'] as String),
      );
}

/// 安装失败异常（含 npm 退出码与 stderr 摘要）。
class InstallException implements Exception {
  InstallException(this.message);
  final String message;
  @override
  String toString() => 'InstallException: $message';
}

/// F1 安装/升级服务。
class InstallService {
  InstallService({
    required this.nodeExecutable,
    required this.npmExecutable,
    this.packageName = '@deepseek-ai/dsh',
    this.registry,
    this.proxy,
    this.engineHome,
  });

  /// node 可执行文件（用于 `--version` 探测与 spawn）。
  final String nodeExecutable;

  /// npm 可执行文件（Windows 为 `npm.cmd`）。
  final String npmExecutable;

  /// 目标 npm 包名（默认 `@deepseek-ai/dsh`）。
  final String packageName;

  /// npm registry（默认官方）。
  final String? registry;

  /// 网络代理（注入到 npm 进程环境）。null 表示沿用系统/进程环境。
  final String? proxy;

  /// 托管引擎根目录（默认 `~/.dsh-desktop/engine`）。
  final String? engineHome;

  String get defaultPrefix {
    final home = Platform.environment['USERPROFILE'] ??
        Platform.environment['HOME'] ??
        '.';
    return engineHome ??
        '$home${Platform.pathSeparator}.dsh-desktop${Platform.pathSeparator}engine';
  }

  /// 探测某 prefix 下的已装版本。
  ///
  /// 优先读取 `package.json` 的 `version` 字段（可靠，不依赖 `bin.js` 的
  /// `--version` 调用约定——不同 dsh 版本该约定可能变化）；失败时回退到
  /// 解析 `node <bin.js> --version` 输出。
  Future<String?> detectInstalled(String prefix, {String? dshCliJs}) async {
    final cli = dshCliJs ?? _locateBin(prefix);
    if (cli == null || !File(cli).existsSync()) return null;

    final pkgDir = File(cli).parent.parent.path; // .../@deepseek-ai/dsh
    final pj =
        File('$pkgDir${Platform.pathSeparator}package.json');
    if (pj.existsSync()) {
      try {
        final j = jsonDecode(pj.readAsStringSync()) as Map<String, dynamic>;
        final v = j['version'];
        if (v is String && v.isNotEmpty) return v;
      } catch (_) {/* 回退到 --version */}
    }

    try {
      final r = await Process.run(
        nodeExecutable,
        [cli, '--version'],
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      );
      return r.exitCode == 0 ? (r.stdout as String).trim() : null;
    } catch (_) {
      return null;
    }
  }

  /// 安装指定版本到 [prefix]（默认 [defaultPrefix]）。
  /// 已为该版本则幂等跳过。返回 [EngineInstall]。
  Future<EngineInstall> install(
    String version, {
    String? prefix,
    String? previousVersion,
    void Function(String)? onLog,
  }) async {
    final dir = prefix ?? defaultPrefix;
    Directory(dir).createSync(recursive: true);

    final existing = await detectInstalled(dir);
    if (existing == version) {
      onLog?.call('[install] $dir 已为 $version，跳过安装');
      return EngineInstall(
        prefix: dir,
        dshCliJs: _locateBin(dir)!,
        version: version,
        previousVersion: previousVersion,
        installedAt: DateTime.now(),
      );
    }

    onLog?.call('[install] npm install $packageName@$version --prefix $dir');
    final args = <String>[
      'install',
      '$packageName@$version',
      '--prefix', dir,
      '--no-audit', '--no-fund', '--loglevel', 'error',
      if (registry != null) '--registry=$registry',
    ];
    final r = await Process.run(
      npmExecutable,
      args,
      environment: _npmEnv(),
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
      runInShell: Platform.isWindows,
    );
    if (r.exitCode != 0) {
      throw InstallException(
          'npm install 失败 (exit=${r.exitCode}): ${(r.stderr as String).trim()}');
    }
    final cli = _locateBin(dir);
    if (cli == null || !File(cli).existsSync()) {
      throw InstallException('安装后未找到 $packageName bin.js，prefix=$dir');
    }
    final verified = await detectInstalled(dir, dshCliJs: cli);
    if (verified != version) {
      throw InstallException(
          '版本校验不符：期望 $version，实际 ${verified ?? "未知"}');
    }
    return EngineInstall(
      prefix: dir,
      dshCliJs: cli,
      version: version,
      previousVersion: previousVersion,
      installedAt: DateTime.now(),
    );
  }

  /// 升级到 [spec]（默认 `latest`）。记录 previousVersion 供回滚。
  Future<EngineInstall> upgrade({
    String spec = 'latest',
    String? prefix,
    EngineInstall? current,
    bool includePrerelease = false,
    void Function(String)? onLog,
  }) async {
    final dir = prefix ?? current?.prefix ?? defaultPrefix;
    final catalog = await VersionCatalog.fetchHttp(
      packageName,
      registry: registry ?? 'https://registry.npmjs.org/',
      proxy: proxy,
    );
    final target = catalog.resolveTarget(spec,
        current: current?.version, includePrerelease: includePrerelease);
    if (target == null) {
      throw InstallException('无可用升级目标（spec=$spec）');
    }
    if (target == current?.version) {
      onLog?.call('[upgrade] 已是最新 $target');
      return current!;
    }
    return install(target,
        prefix: dir, previousVersion: current?.version, onLog: onLog);
  }

  /// 回滚到 [current.previousVersion]；无则抛错。
  Future<EngineInstall> rollback(EngineInstall current) async {
    final prev = current.previousVersion;
    if (prev == null) {
      throw InstallException('无回滚点（previousVersion 为空）');
    }
    final installed = await install(prev, prefix: current.prefix);
    return installed.copyWith(previousVersion: current.version);
  }

  Map<String, String> _npmEnv() {
    final env = <String, String>{...Platform.environment};
    if (proxy != null) {
      env['HTTPS_PROXY'] = proxy!;
      env['HTTP_PROXY'] = proxy!;
    }
    return env;
  }

  /// 在 prefix 下定位 dsh bin.js（兼容 @deepseek-ai/dsh 与 dsh 两种包名）。
  static String? locateBin(String prefix) => _locateBin(prefix);

  static String? _locateBin(String prefix) {
    const suffixes = [
      r'node_modules\@deepseek-ai\dsh\lib\bin.js',
      r'node_modules\dsh\lib\bin.js',
    ];
    for (final s in suffixes) {
      final p = '$prefix${Platform.pathSeparator}$s';
      if (File(p).existsSync()) return p;
    }
    return null;
  }
}
