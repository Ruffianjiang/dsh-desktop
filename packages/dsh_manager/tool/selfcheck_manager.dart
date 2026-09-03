import 'dart:io';

import 'package:dsh_manager/dsh_manager.dart';

/// M2/T6 出口自检：探测 node+dsh → 启动实例 → 健康就绪 → 停止 → 断言退出。
/// 真实调用本机 dsh（起停一轮，约 1 分钟）。
/// 用法：`dart run tool/selfcheck_manager.dart`
Future<void> main() async {
  var failed = 0;
  void check(String name, bool ok, [String? detail]) {
    stdout.writeln('${ok ? 'PASS' : 'FAIL'}  $name${detail == null ? '' : '  -- $detail'}');
    if (!ok) failed++;
  }

  final env = await NodeEnv.probe();
  check('NodeEnv.probe 找到 node', env.nodePath.isNotEmpty, env.nodePath);
  check('NodeEnv.probe 找到 dsh bin.js', env.dshCliJs.isNotEmpty, env.dshCliJs);
  stdout.writeln('dsh version: ${env.dshVersion}');

  final config = InstanceConfig(
    id: 'selftest-${DateTime.now().millisecondsSinceEpoch}',
    alias: 'm2-selfcheck',
    port: 3080,
    dataDir: Directory.current.path,
  );

  final supervisor = InstanceSupervisor(env);
  final state = await supervisor.start(config);
  check('实例启动并就绪(running)', state.status == InstanceStatus.running,
      'pid=${state.pid}');

  final registry = RegistryStore(
      '${Directory.systemTemp.path}${Platform.pathSeparator}dsh_m2_selfcheck_instances.json');
  registry.save([config]);
  check('RegistryStore 保存+回读', registry.load().isNotEmpty);

  final code = await supervisor.stop();
  check('实例已停止(stopped)', state.status == InstanceStatus.stopped, 'exit=$code');
  check('进程引用已清空', !supervisor.isRunning);

  stdout.writeln(failed == 0 ? 'ALL PASS' : '$failed FAILED');
  exit(failed == 0 ? 0 : 1);
}
