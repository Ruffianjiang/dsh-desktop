/// F1 安装/升级流真机自检（不破坏现有 dsh；临时 prefix 用完即删）。
///
/// 覆盖：registry 查版、resolveTarget 纯逻辑、detectInstalled（现有 dsh，
/// 非破坏）、临时 prefix 真实 install/upgrade/rollback 闭环。
///
/// 说明：为控制时长，临时 prefix 仅安装**已进 npm 缓存**的 0.1.2-rc.1
/// （此前手动探针已完整验证 0.1.2-rc.1 全量安装可用）；跨版本差异仅是 npm
/// install 的目标版本字符串不同，机制一致。
library;

import 'dart:io';

import 'package:dsh_manager/dsh_manager.dart';

Future<String> _resolveNode() async {
  final env = Platform.environment['DSH_NODE'];
  if (env != null && File(env).existsSync()) return env;
  if (Platform.isWindows) {
    final r = await Process.run('cmd', ['/c', 'where node']);
    if (r.exitCode == 0) {
      final p = (r.stdout as String).trim().split('\n').first.trim();
      if (p.isNotEmpty && File(p).existsSync()) return p;
    }
  }
  throw StateError('未找到 node（设 DSH_NODE）');
}

String _resolveNpm(String nodePath) {
  final dir = File(nodePath).parent.path;
  final cand = Platform.isWindows ? '$dir\\npm.cmd' : '$dir/npm';
  if (File(cand).existsSync()) return cand;
  throw StateError('未找到 npm（node 同目录: $cand）');
}

/// 从 dsh bin.js 路径推导 npm prefix（取 `node_modules` 之前的部分）。
String _prefixOf(String cliJs) {
  final norm = cliJs.replaceAll('/', '\\');
  final idx = norm.indexOf('\\node_modules\\');
  return idx < 0 ? cliJs : norm.substring(0, idx);
}

void main() async {
  final results = <String, bool>{};
  void check(String name, bool ok, [String? detail]) {
    results[name] = ok;
    print('${ok ? 'PASS' : 'FAIL'}  $name${detail != null ? '  ($detail)' : ''}');
  }

  final node = await _resolveNode();
  final npm = _resolveNpm(node);
  final proxy = Platform.environment['HTTPS_PROXY'] ??
      Platform.environment['HTTP_PROXY'];
  print('node=$node\nnpm=$npm\nproxy=$proxy');

  final env = await NodeEnv.probe();
  final existingPrefix = _prefixOf(env.dshCliJs);
  print('现有 dsh: ${env.dshCliJs}  v${env.dshVersion}  prefix=$existingPrefix');

  // 1) registry 查版（走代理；Dart HttpClient 不读 HTTPS_PROXY，须显式注入）
  VersionCatalog cat;
  try {
    cat = await VersionCatalog.fetchHttp('@deepseek-ai/dsh', proxy: proxy);
    check('registry 查版(latest=${cat.latest}, next=${cat.tag("next")})',
        cat.all.isNotEmpty && cat.latest.isNotEmpty, '共 ${cat.all.length} 版');
  } catch (e) {
    check('registry 查版', false, e.toString());
    return;
  }

  // 2) resolveTarget 纯逻辑
  check('resolve latest', cat.resolveTarget('latest') == cat.latest);
  check('resolve next', cat.resolveTarget('next') == cat.tag('next'));
  final upPre = cat.resolveTarget('upgrade',
      current: env.dshVersion, includePrerelease: true);
  check('resolve upgrade(含pre) > 当前',
      upPre != null && upPre != env.dshVersion, 'target=$upPre');
  final upStable = cat.resolveTarget('upgrade',
      current: env.dshVersion, includePrerelease: false);
  check('resolve upgrade(仅stable) 不越预发布',
      upStable == null || !VersionCatalog.isPrerelease(upStable),
      'target=$upStable');
  check('resolve 精确版本存在', cat.resolveTarget('0.1.1-rc.2') == '0.1.1-rc.2');
  check('resolve 不存在版本→null', cat.resolveTarget('9.9.9') == null);

  // 3) detectInstalled 现有 prefix（非破坏，读 package.json）
  final detected = await InstallService(
    nodeExecutable: node,
    npmExecutable: npm,
    proxy: proxy,
  ).detectInstalled(existingPrefix);
  check('detectInstalled(现有prefix) 一致',
      detected == env.dshVersion, 'detected=$detected');

  // 4) 临时 prefix 真实 install/upgrade/rollback（仅用缓存版本 0.1.2-rc.1）
  final tmp = await Directory.systemTemp.createTemp('dsh-f1-');
  final svc = InstallService(
    nodeExecutable: node,
    npmExecutable: npm,
    proxy: proxy,
    engineHome: tmp.path,
  );
  try {
    print('\n--- 临时 prefix 真实安装: ${tmp.path} ---');
    final base = await svc.install('0.1.2-rc.1', prefix: tmp.path, onLog: print);
    check('install 0.1.2-rc.1（缓存）', base.version == '0.1.2-rc.1',
        'prefix=${base.prefix}');

    final up = await svc.upgrade(
        spec: 'next', prefix: tmp.path, current: base, onLog: print);
    check('upgrade→next（已最新则 no-op）',
        up.version == '0.1.2-rc.1' && up.previousVersion == null,
        'got=${up.version}');

    // 构造带 previousVersion 的 current，验证 rollback 调 install(prev) 并互换
    final withPrev = base.copyWith(previousVersion: '0.1.2-rc.1');
    final rb = await svc.rollback(withPrev);
    check('rollback 调 install(previousVersion)', rb.version == '0.1.2-rc.1',
        'got=${rb.version}');
    check('rollback 互换 previousVersion', rb.previousVersion == withPrev.version,
        'prev=${rb.previousVersion}');
  } catch (e) {
    check('临时 prefix install/upgrade/rollback', false, e.toString());
  } finally {
    await tmp.delete(recursive: true).catchError((_) => tmp);
    print('已清理临时 prefix: ${tmp.path}');
  }

  final allPass = results.values.every((v) => v);
  print(
      '\n=== ${allPass ? 'ALL PASS' : 'FAIL'}  (${results.entries.where((e) => e.value).length}/${results.length}) ===');
  if (!allPass) exit(1);
}
