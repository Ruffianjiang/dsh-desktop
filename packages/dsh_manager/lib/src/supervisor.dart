import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'models.dart';
import 'node_env.dart';

/// 实例守护（Gate-B v1.0 §4.2/4.3）：spawn dsh、健康就绪探测、优雅停止。
class InstanceSupervisor {
  InstanceSupervisor(this.env, {this.readyTimeout = const Duration(seconds: 90)});

  final NodeEnv env;
  final Duration readyTimeout;

  Process? _process;
  InstanceState? _state;

  /// 同步启动 dsh（`node <bin.js> <profile> --no-open`）并等待就绪。
  Future<InstanceState> start(InstanceConfig config) async {
    if (_process != null) {
      throw StateError('实例 ${config.id} 已在运行');
    }
    final state = InstanceState(config: config, status: InstanceStatus.starting);
    _state = state;

    final logFile = config.logFile ??
        '${_defaultLogDir(config)}${Platform.pathSeparator}dsh-${config.id}.log';
    Directory(File(logFile).parent.path).createSync(recursive: true);
    final sink = File(logFile).openWrite(mode: FileMode.append);

    final args = <String>[
      env.dshCliJs,
      if (config.profile != 'web') '--profile=${config.profile}' else 'web',
      '--no-open',
    ];

    final proc = await Process.start(
      env.nodePath,
      args,
      workingDirectory: config.dataDir,
      environment: {
        ...Platform.environment,
        ...config.env,
      },
    );
    _process = proc;
    state.pid = proc.pid;
    state.startedAt = DateTime.now();
    state.status = InstanceStatus.starting;

    proc.stdout.transform(utf8.decoder).listen(sink.write);
    proc.stderr.transform(utf8.decoder).listen(sink.write);
    unawaited(proc.exitCode.then((code) async {
      state.status = state.status == InstanceStatus.stopping
          ? InstanceStatus.stopped
          : InstanceStatus.crashed;
      state.lastExitCode = code;
      await sink.flush();
      await sink.close();
      _process = null;
    }));

    await _waitReady(config);
    state.status = InstanceStatus.running;
    return state;
  }

  /// 优雅停止：终止进程并等待退出。
  Future<int?> stop() async {
    final proc = _process;
    final state = _state;
    if (proc == null || state == null) return null;
    state.status = InstanceStatus.stopping;
    proc.kill();
    final code = await proc.exitCode.timeout(const Duration(seconds: 15),
        onTimeout: () {
      proc.kill(ProcessSignal.sigkill);
      return proc.exitCode;
    });
    // 同步清引用与状态（exitCode 监听回调为异步，避免竞态）。
    if (_process == proc) _process = null;
    state.lastExitCode = code;
    if (state.status == InstanceStatus.stopping) {
      state.status = InstanceStatus.stopped;
    }
    return code;
  }

  bool get isRunning => _process != null;

  InstanceState? get state => _state;

  Future<void> _waitReady(InstanceConfig config) async {
    final deadline = DateTime.now().add(readyTimeout);
    final uri = Uri.parse('http://${config.host}:${config.port}/');
    final http = HttpClient()..connectionTimeout = const Duration(seconds: 2);
    try {
      while (DateTime.now().isBefore(deadline)) {
        if (_process == null) {
          throw StateError(
              'dsh 启动后即退出（exit=${_state?.lastExitCode}），请查日志');
        }
        try {
          final req = await http.getUrl(uri);
          final res = await req.close();
          await res.drain<void>();
          if (res.statusCode >= 200 && res.statusCode < 500) return;
        } catch (_) {/* 未就绪，继续轮询 */}
        await Future<void>.delayed(const Duration(seconds: 2));
      }
      throw TimeoutException('dsh 就绪超时（${config.host}:${config.port}）');
    } finally {
      http.close(force: true);
    }
  }

  String _defaultLogDir(InstanceConfig config) {
    final home = Platform.environment['USERPROFILE'] ??
        Platform.environment['HOME'] ??
        '.';
    return '$home${Platform.pathSeparator}.dsh-desktop${Platform.pathSeparator}logs';
  }
}
