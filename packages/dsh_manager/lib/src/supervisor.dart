import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'events.dart';
import 'health_probe.dart';
import 'log_tail.dart';
import 'models.dart';
import 'node_env.dart';

/// 实例守护（平台 Gate-B §4.2/4.3 + F2 Gate-B §4）：
/// spawn、健康就绪、守护拉起（指数退避）、持续心跳、优雅停止、restart。
///
/// 单实例语义：一个 supervisor 对应一个实例配置；多实例用 [InstanceManager]。
/// 状态机六态不扩枚举；「守护重启中」用 starting + guardianAttempts 表达（BQ7）。
class InstanceSupervisor {
  InstanceSupervisor(this.env, {this.readyTimeout = const Duration(seconds: 90)});

  final NodeEnv env;

  /// 启动就绪等待上限（达到 running 的总时长，与 N5 无关）。
  final Duration readyTimeout;

  // —— Guardian 常量（F2 Gate-B §4.1，BQ1：全局常量） ——
  static const _gInitial = Duration(seconds: 1);
  static const _gFactor = 2;
  static const _gMaxDelay = Duration(seconds: 30);
  static const _gMaxFailures = 3;

  // 优雅停止超时（BQ6：对齐平台 Gate-B §4.4 = 10s）。
  static const _stopGrace = Duration(seconds: 10);

  Process? _process;
  InstanceState? _state;
  InstanceConfig? _config;
  Timer? _restartTimer;
  int _failures = 0;
  LogTail? _logTail;
  HealthProbe? _probe;
  final StreamController<InstanceEvent> _events =
      StreamController<InstanceEvent>.broadcast();

  /// 实例状态/心跳/退出事件（broadcast；UI 仅凭此流驱动状态面板）。
  Stream<InstanceEvent> get events => _events.stream;

  bool get isRunning => _process != null;

  InstanceState? get state => _state;

  /// 当前实例的日志（环形缓冲 tail + 文件 export；未启动过为 null）。
  LogTail? get logTail => _logTail;

  // ---------------------------------------------------------------------------
  // 公共 API
  // ---------------------------------------------------------------------------

  /// 启动实例并等待就绪。
  ///
  /// 失败语义（F2 Gate-B §4.2 T1/T3）：
  /// - 进程从未拉起（如 node/dsh 路径错误）→ 抛出，守护不介入；
  /// - 进程拉起后退出/就绪超时 → 抛出，但守护已由退出回调接手
  ///   （连续失败 ≥[_gMaxFailures] 转 crashed；调用方以 [events] 为权威状态源）。
  Future<InstanceState> start(InstanceConfig config) async {
    if (_process != null) {
      throw StateError('实例 ${config.id} 已在运行');
    }
    if (_events.isClosed) {
      throw StateError('supervisor 已 dispose，无法启动');
    }
    _config = config;
    _failures = 0; // 手动 start 复位守护计数（Gate-A §4.2）
    final state = _ensureState(config);
    state.guardianAttempts = 0;
    _restartTimer?.cancel();
    _restartTimer = null;

    final port = await _resolvePort(config);
    state.port = port;
    _logTail ??= LogTail(logFile: File(_logPath(config)));
    _changeStatus(InstanceStatus.starting);

    await _launch(config, port);
    try {
      await _awaitReady(config, port);
    } catch (_) {
      // 进程曾拉起：退出回调负责计数与调度；就绪超时（进程仍活）→ 清残留，
      // 其退出事件同样走回调计数。此处仅向调用方抛出。
      _process?.kill();
      rethrow;
    }
    _onRunning(state, port);
    return state;
  }

  /// 优雅停止：先终止进程（[_stopGrace] 超时转强杀），等待退出。
  Future<int?> stop() async {
    final state = _state;
    final proc = _process;
    _restartTimer?.cancel();
    _restartTimer = null;
    _probe?.detach();
    if (proc == null || state == null) {
      // 守护定时器挂起（starting，无进程）或从未启动：直接落 stopped（T4）。
      if (state != null && state.status == InstanceStatus.starting) {
        _changeStatus(InstanceStatus.stopped);
      }
      return state?.lastExitCode;
    }
    _changeStatus(InstanceStatus.stopping);
    proc.kill();
    final code = await proc.exitCode.timeout(_stopGrace, onTimeout: () {
      proc.kill(ProcessSignal.sigkill);
      return proc.exitCode;
    });
    if (_process == proc) _process = null;
    state.lastExitCode = code;
    // stopped 迁移与 Exited(none) 由退出回调发射（status == stopping 分支）。
    return code;
  }

  /// 重启：等价 stop（抑制守护）→ start（内部清零守护计数）。
  Future<InstanceState> restart() async {
    final config = _config;
    if (config == null) {
      throw StateError('尚未 start 过，无法 restart');
    }
    await stop();
    return start(config);
  }

  /// 释放资源：取消守护定时器、detach 探针、尽力终止进程、关闭日志与事件流。
  /// 多实例场景由 [InstanceManager.remove] 先 stop 后调用。
  Future<void> dispose() async {
    _restartTimer?.cancel();
    _restartTimer = null;
    _probe?.detach();
    _process?.kill(); // 尽力终止，不等退出（调用方应先 stop）
    _process = null;
    await _logTail?.close();
    _logTail = null;
    await _events.close();
  }

  // ---------------------------------------------------------------------------
  // 内部：状态与事件
  // ---------------------------------------------------------------------------

  InstanceState _ensureState(InstanceConfig config) {
    final s = _state;
    if (s != null && s.config.id == config.id) return s;
    return _state = InstanceState(config: config);
  }

  void _emit(InstanceEvent event) {
    if (!_events.isClosed) _events.add(event);
  }

  void _changeStatus(InstanceStatus to) {
    final s = _state;
    if (s == null || s.status == to) return;
    final from = s.status;
    s.status = to;
    _emit(InstanceStatusChanged(
      instanceId: s.config.id,
      from: from,
      to: to,
      pid: s.pid,
      port: s.port,
    ));
  }

  /// 进入 running（启动或守护重启成功共用）：复位计数、挂探针。
  void _onRunning(InstanceState state, int port) {
    state
      ..port = port
      ..guardianAttempts = 0;
    _failures = 0;
    _changeStatus(InstanceStatus.running);
    _probe ??= HealthProbe(
      onHeartbeat: (ok, latencyMs, reason) {
        final s = _state;
        if (s == null) return;
        if (ok) s.lastHeartbeat = DateTime.now();
        _emit(InstanceHeartbeat(
          instanceId: s.config.id,
          ok: ok,
          latencyMs: latencyMs,
          reason: reason,
        ));
      },
      onZombie: () {
        // F2 Gate-B §5：探针判僵死 → 杀进程；退出回调按异常退出计数并走守护。
        _process?.kill();
      },
    );
    _probe!.attach(
      instanceId: state.config.id,
      host: state.config.host,
      port: port,
    );
  }

  // ---------------------------------------------------------------------------
  // 内部：进程生命周期
  // ---------------------------------------------------------------------------

  /// 解析端口：固定端口直用；port==0 每次启动重新分配（守护重启亦然）。
  Future<int> _resolvePort(InstanceConfig config) =>
      config.port > 0 ? Future.value(config.port) : _freeTcpPort();

  /// 拉起 dsh 进程并接线日志/退出监听（start 与守护重启共用）。
  Future<void> _launch(InstanceConfig config, int port) async {
    final state = _state!;
    final args = <String>[
      env.dshCliJs,
      if (config.profile != 'web') '--profile=${config.profile}' else 'web',
      '--no-open',
      '--host', config.host,
      '--port', port.toString(),
    ];
    final proc = await Process.start(
      env.nodePath,
      args,
      workingDirectory: config.dataDir,
      environment: {
        ...Platform.environment,
        ...config.env,
        'NO_COLOR': '1', // Gate-B §4.4.2（host/port 已由 CLI 参数承载）
      },
    );
    _process = proc;
    state
      ..pid = proc.pid
      ..startedAt = DateTime.now()
      ..lastExitCode = null;
    proc.stdout
        .transform(utf8.decoder)
        .listen((chunk) => _logTail?.handleChunk(chunk, stderr: false));
    proc.stderr
        .transform(utf8.decoder)
        .listen((chunk) => _logTail?.handleChunk(chunk, stderr: true));
    unawaited(proc.exitCode.then(_onProcessExit));
  }

  /// 进程退出统一入口（每次退出恰好一次）。
  ///
  /// 事件发射顺序（F2 Gate-B §3）：Exited → StatusChanged。
  Future<void> _onProcessExit(int code) async {
    final state = _state;
    if (state == null) return;
    _process = null;
    _probe?.detach();
    state.lastExitCode = code;

    if (state.status == InstanceStatus.stopping) {
      // 主动 stop（T5）：守护不介入。
      _changeStatus(InstanceStatus.stopped);
      _emit(InstanceExited(
        instanceId: state.config.id,
        exitCode: code,
        action: GuardianAction.none,
      ));
      await _logTail?.flush();
      return;
    }

    // 异常退出 → 守护计数（T2）。
    _failures += 1;
    if (_failures >= _gMaxFailures) {
      _emit(InstanceExited(
        instanceId: state.config.id,
        exitCode: code,
        action: GuardianAction.gaveUp,
      ));
      _changeStatus(InstanceStatus.crashed);
      await _logTail?.flush();
      return;
    }
    _emit(InstanceExited(
      instanceId: state.config.id,
      exitCode: code,
      action: GuardianAction.scheduled,
    ));
    state.guardianAttempts = _failures;
    _changeStatus(InstanceStatus.starting);
    _restartTimer = Timer(_delayFor(_failures), () {
      unawaited(_guardianRestart());
    });
    await _logTail?.flush();
  }

  /// 守护重启单轮（T2/T3）：拉起 → 就绪；失败则继续退避或转 crashed。
  Future<void> _guardianRestart() async {
    final state = _state;
    final config = _config;
    if (state == null || config == null) return;
    if (state.status == InstanceStatus.stopping ||
        state.status == InstanceStatus.stopped) {
      return;
    }
    var port = 0;
    var launched = false;
    try {
      port = await _resolvePort(config);
      state.port = port;
      await _launch(config, port);
      launched = true; // 退出监听已注册：后续消亡由 _onProcessExit 计数
      await _awaitReady(config, port);
    } catch (_) {
      if (launched) {
        // 进程消亡或就绪超时：计数/调度已由退出回调负责；确保残留被清。
        _process?.kill();
        return;
      }
      // Process.start 本身失败（无退出事件）：由此处计数（T3）。
      _failures += 1;
      if (_failures >= _gMaxFailures) {
        _emit(InstanceExited(
          instanceId: state.config.id,
          exitCode: state.lastExitCode,
          action: GuardianAction.gaveUp,
        ));
        _changeStatus(InstanceStatus.crashed);
        return;
      }
      state.guardianAttempts = _failures;
      _emit(InstanceExited(
        instanceId: state.config.id,
        exitCode: state.lastExitCode,
        action: GuardianAction.scheduled,
      ));
      _changeStatus(InstanceStatus.starting);
      _restartTimer = Timer(_delayFor(_failures), () {
        unawaited(_guardianRestart());
      });
      return;
    }
    _onRunning(state, port);
  }

  // 就绪探测（启动与守护共用；200–499 视为就绪）。
  Future<void> _awaitReady(InstanceConfig config, int port) async {
    final deadline = DateTime.now().add(readyTimeout);
    final uri = Uri.parse('http://${config.host}:$port/');
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
      // 就绪超时：进程可能仍存活 → 先终止，其退出事件走回调计数（防孤儿）。
      _process?.kill();
      throw TimeoutException('dsh 就绪超时（${config.host}:$port）');
    } finally {
      http.close(force: true);
    }
  }

  Duration _delayFor(int failures) {
    var d = _gInitial;
    for (var i = 1; i < failures; i++) {
      d *= _gFactor;
      if (d > _gMaxDelay) return _gMaxDelay;
    }
    return d;
  }

  /// 分配一个当前空闲的 TCP 端口：临时 bind 到 0 取系统分配值后释放。
  /// 存在极小 TOCTOU 窗口（释放后、dsh 绑定前可能被抢占）；生产多实例由
  /// 调用方（RegistryStore / 端口分配器）显式指定 [InstanceConfig.port]。
  Future<int> _freeTcpPort() async {
    final sock = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = sock.port;
    await sock.close();
    return port;
  }

  String _logPath(InstanceConfig config) {
    final explicit = config.logFile;
    if (explicit != null) return explicit;
    final home = Platform.environment['USERPROFILE'] ??
        Platform.environment['HOME'] ??
        '.';
    return '$home${Platform.pathSeparator}.dsh-desktop'
        '${Platform.pathSeparator}logs'
        '${Platform.pathSeparator}dsh-${config.id}.log';
  }
}
