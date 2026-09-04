import 'dart:async';
import 'dart:io';

import 'package:dsh_manager/dsh_manager.dart';

/// F2 出口自检（Gate-B §9 C1–C8）：守护拉起（N5）、crashed 终态、复位、
/// restart、心跳、Registry CRUD + autoStart、dispose 无泄漏。
/// 真实调用本机 dsh，预计 2–4 分钟。
/// 用法：`dart run tool/selfcheck_lifecycle.dart`
Future<void> main() async {
  var failed = 0;
  void check(String name, bool ok, [String? detail]) {
    stdout.writeln(
        '${ok ? 'PASS' : 'FAIL'}  $name${detail == null ? '' : '  -- $detail'}');
    if (!ok) failed++;
  }

  final env = await NodeEnv.probe();
  check('C0 NodeEnv.probe', env.nodePath.isNotEmpty && env.dshCliJs.isNotEmpty,
      '${env.nodePath} | ${env.dshCliJs}');

  final events = <InstanceEvent>[];
  final supervisor = InstanceSupervisor(env);
  final sub = supervisor.events.listen(events.add);

  // —— C1 正常起停回归（兼容 selfcheck_manager 语义） ——
  final cfg = InstanceConfig(
    id: 'lc-${DateTime.now().millisecondsSinceEpoch}',
    alias: 'f2-selfcheck',
    port: 0, // 自动分配，避免端口冲突
    dataDir: Directory.current.path,
  );
  var st = await supervisor.start(cfg);
  await _pump(); // 广播流异步投递：留出微任务窗口再断言
  check('C1 start→running', st.status == InstanceStatus.running,
      'port=${st.port} pid=${st.pid}');
  check('C1 事件含 starting/running',
      events.any((e) => e is InstanceStatusChanged && e.to == InstanceStatus.starting) &&
          events.any((e) => e is InstanceStatusChanged && e.to == InstanceStatus.running));
  final code1 = await supervisor.stop();
  await _pump();
  check('C1 stop→stopped', st.status == InstanceStatus.stopped, 'exit=$code1');
  check('C1 主动停止 Exited(none)',
      events.any((e) => e is InstanceExited && e.action == GuardianAction.none));

  // —— C2 崩溃自动拉起（N5：≤5s 重新 spawn；达到 running 不受 N5 约束） ——
  events.clear();
  st = await supervisor.start(cfg);
  check('C2 start→running', st.status == InstanceStatus.running);
  final oldPid = st.pid!;
  final killAt = DateTime.now();
  final kr = await Process.run('taskkill', ['/F', '/T', '/PID', '$oldPid']);
  check('C2 taskkill 强杀成功', kr.exitCode == 0, kr.stdout.toString().trim());

  DateTime? respawnAt;
  var respawnDeadline = killAt.add(const Duration(seconds: 15));
  while (DateTime.now().isBefore(respawnDeadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 200));
    final pid = supervisor.state?.pid;
    if (pid != null && pid != oldPid) {
      respawnAt = DateTime.now();
      break;
    }
  }
  check(
      'C2 ≤5s 重新 spawn',
      respawnAt != null &&
          respawnAt.difference(killAt) <= const Duration(seconds: 5),
      respawnAt == null
          ? '未观测到新 pid'
          : '${respawnAt.difference(killAt).inMilliseconds}ms');
  check('C2 事件 Exited(scheduled)',
      events.any((e) => e is InstanceExited && e.action == GuardianAction.scheduled));
  final running2 = await _waitStatus(
      supervisor, InstanceStatus.running, const Duration(seconds: 90));
  check('C2 守护重启后 running', running2);
  st = supervisor.state!;

  // —— C5 restart（事件序列 stopping→starting→running） ——
  events.clear();
  st = await supervisor.restart();
  await _pump();
  check('C5 restart→running', st.status == InstanceStatus.running);
  check('C5 事件序列 stopping→starting→running',
      _containsSequence(events, const [
        InstanceStatus.stopping,
        InstanceStatus.starting,
        InstanceStatus.running,
      ]));

  // —— C6 心跳（运行实例 ok；关闭端口 fail） ——
  final probe = HealthProbe(onHeartbeat: (_, __, ___) {}, onZombie: () {});
  final r1 = await probe.pingOnce(host: st.config.host, port: st.port!);
  check('C6 pingOnce 运行实例 ok', r1.ok, r1.reason);
  final r2 = await probe.pingOnce(host: '127.0.0.1', port: 1); // 保留端口必拒
  check('C6 pingOnce 关闭端口 fail', !r2.ok, r2.reason);
  probe.dispose();

  // —— C3/C4 连续失败 → crashed → 复位（独立 fake supervisor） ——
  final tmp = Directory.systemTemp.createTempSync('dsh_f2_selfcheck');
  final fakeJs = File('${tmp.path}${Platform.pathSeparator}fake_dsh.js');
  fakeJs.writeAsStringSync('process.exit(1);\n');
  final fakeEnv = NodeEnv.forDshCli(env.nodePath, fakeJs.path);
  final fakeSup = InstanceSupervisor(fakeEnv, readyTimeout: const Duration(seconds: 20));
  final fakeEvents = <InstanceEvent>[];
  final fakeSub = fakeSup.events.listen(fakeEvents.add);

  var threw = false;
  final fakeCfg = InstanceConfig(
      id: 'lc-fake', alias: 'fake', port: 0, dataDir: tmp.path);
  try {
    await fakeSup.start(fakeCfg);
  } catch (_) {
    threw = true; // 预期抛出：进程秒退（守护已接手）
  }
  check('C3 初始 start 抛出（进程秒退）', threw);
  final crashed = await _waitStatus(
      fakeSup, InstanceStatus.crashed, const Duration(seconds: 60));
  check('C3 连续失败≥3 → crashed', crashed,
      fakeEvents
          .whereType<InstanceExited>()
          .map((e) => e.action.name)
          .join(','));
  check('C3 事件 Exited(gaveUp)',
      fakeEvents.any((e) => e is InstanceExited && e.action == GuardianAction.gaveUp));

  // C4 复位：crashed 后再次 start → 状态机重燃（T8：crashed→starting 迁移）。
  // 注意：start() 的就绪等待可能比守护 3 连败周期更晚返回（期间守护已重新
  // 拉起又秒退直至 crashed），故用事件断言（crashed→starting 出现过）而非即时状态。
  var hadReset = false;
  try {
    await fakeSup.start(fakeCfg);
  } catch (_) {
    // 预期抛出（fake 秒退且守护可能已再次耗尽），不影响复位语义判定
  }
  await _pump();
  hadReset = fakeEvents.any((e) =>
      e is InstanceStatusChanged &&
      e.from == InstanceStatus.crashed &&
      e.to == InstanceStatus.starting);
  check('C4 crashed 后 start 复位（crashed→starting 迁移）', hadReset);
  await fakeSub.cancel();
  await fakeSup.dispose();

  // —— C7 Registry CRUD + autoStart（InstanceManager） ——
  final regPath = '${Directory.systemTemp.path}${Platform.pathSeparator}'
      'dsh_f2_selfcheck_instances.json';
  final regFile = File(regPath);
  if (regFile.existsSync()) regFile.deleteSync();
  final manager = InstanceManager(env: env, registry: RegistryStore(regPath));
  final autoCfg = InstanceConfig(
    id: 'lc-auto',
    alias: 'autostart',
    port: 0,
    dataDir: Directory.current.path,
    autoStart: true,
  );
  manager.registry.upsert(autoCfg);
  final got = manager.registry.get(autoCfg.id);
  check('C7 upsert+get', got != null && got.id == autoCfg.id);
  final started = await manager.startAutoStart();
  check(
      'C7 autoStart 拉起 running',
      started.any((s) =>
          s.config.id == autoCfg.id && s.status == InstanceStatus.running));
  await manager.remove(autoCfg.id);
  check('C7 remove 后 get 为空', manager.registry.get(autoCfg.id) == null);

  // —— C8 dispose 后操作被拒（无泄漏） ——
  await manager.dispose();
  manager.registry.upsert(autoCfg); // 配置在，但 manager 已关
  var closed = false;
  try {
    await manager.start(autoCfg.id);
  } catch (_) {
    closed = true;
  }
  check('C8 dispose 后操作被拒', closed);
  regFile.deleteSync();

  // —— 清理 ——
  await supervisor.stop();
  await sub.cancel();
  await supervisor.dispose();
  tmp.deleteSync(recursive: true);

  stdout.writeln(failed == 0 ? 'ALL PASS' : '$failed FAILED');
  exit(failed == 0 ? 0 : 1);
}

Future<bool> _waitStatus(
    InstanceSupervisor s, InstanceStatus target, Duration timeout) async {
  final end = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(end)) {
    if (s.state?.status == target) return true;
    await Future<void>.delayed(const Duration(milliseconds: 300));
  }
  return false;
}

/// 泵一遍微任务/事件循环，让广播流完成异步投递后再断言。
Future<void> _pump() =>
    Future<void>.delayed(const Duration(milliseconds: 80));

bool _containsSequence(List<InstanceEvent> events, List<InstanceStatus> seq) {
  var i = 0;
  for (final e in events) {
    if (e is InstanceStatusChanged && e.to == seq[i]) {
      i++;
      if (i == seq.length) return true;
    }
  }
  return false;
}
