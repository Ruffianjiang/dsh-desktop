/// 多实例门面（F2 Gate-B v1.0 §7.2）：
/// 组合单实例 [InstanceSupervisor] 与 [RegistryStore]，聚合事件，
/// 提供 F2.1 的实例配置增删改查与 autoStart 批量拉起。
library;

import 'dart:async';

import 'events.dart';
import 'log_tail.dart';
import 'models.dart';
import 'node_env.dart';
import 'registry.dart';
import 'supervisor.dart';

class InstanceManager {
  InstanceManager({required this.env, RegistryStore? registry})
      : registry = registry ?? RegistryStore();

  final NodeEnv env;
  final RegistryStore registry;

  final Map<String, InstanceSupervisor> _byId = {};
  final Map<String, StreamSubscription<InstanceEvent>> _subs = {};
  final StreamController<InstanceEvent> _events =
      StreamController<InstanceEvent>.broadcast();
  bool _closed = false;

  /// 全部实例事件的聚合流（broadcast）。
  Stream<InstanceEvent> get events => _events.stream;

  /// 实例配置清单（注册表快照）。
  List<InstanceConfig> list() => registry.load();

  InstanceState? stateOf(String id) => _byId[id]?.state;

  LogTail? logTailOf(String id) => _byId[id]?.logTail;

  InstanceSupervisor _supervisorFor(InstanceConfig cfg) {
    final existing = _byId[cfg.id];
    if (existing != null) return existing;
    final s = InstanceSupervisor(env);
    _byId[cfg.id] = s;
    _subs[cfg.id] = s.events.listen(_events.add);
    return s;
  }

  void _ensureOpen() {
    if (_closed) throw StateError('InstanceManager 已关闭');
  }

  /// 写入配置并启动（F2.1）。
  Future<InstanceState> create(InstanceConfig cfg) async {
    _ensureOpen();
    registry.upsert(cfg);
    return start(cfg.id);
  }

  Future<InstanceState> start(String id) async {
    _ensureOpen();
    final cfg = registry.get(id);
    if (cfg == null) throw StateError('实例 $id 不存在');
    return _supervisorFor(cfg).start(cfg);
  }

  Future<int?> stop(String id) async {
    _ensureOpen();
    final s = _byId[id];
    return s?.stop();
  }

  Future<InstanceState> restart(String id) async {
    _ensureOpen();
    final cfg = registry.get(id);
    if (cfg == null) throw StateError('实例 $id 不存在');
    return _supervisorFor(cfg).restart();
  }

  /// 删除实例：先停止（若在跑），释放 supervisor，再删配置。
  Future<void> remove(String id) async {
    _ensureOpen();
    final s = _byId[id];
    if (s != null) {
      if (s.isRunning) await s.stop();
      await s.dispose();
      _subs.remove(id)?.cancel();
      _byId.remove(id);
    }
    registry.remove(id);
  }

  /// 拉起全部 autoStart 实例（BQ5：宿主启动时由上层调用）。
  /// 失败隔离：单个实例失败不阻断其余，异常经事件流对外。
  Future<List<InstanceState>> startAutoStart() async {
    _ensureOpen();
    final started = <InstanceState>[];
    for (final cfg in registry.load()) {
      if (!cfg.autoStart) continue;
      try {
        started.add(await _supervisorFor(cfg).start(cfg));
      } catch (_) {
        // 失败隔离（Gate-B §7.2）
      }
    }
    return started;
  }

  /// 释放全部资源（停止在跑实例、取消订阅、关闭事件流）。
  Future<void> dispose() async {
    _closed = true;
    for (final s in _byId.values) {
      await s.dispose();
    }
    _byId.clear();
    for (final sub in _subs.values) {
      await sub.cancel();
    }
    _subs.clear();
    await _events.close();
  }
}
