import 'dart:async';

import 'package:dsh_manager/dsh_manager.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../shared/instance_status.dart';

/// 实例详情（M3-T4）：状态卡 / 启停重启 / 日志 tail（定时刷新）/ 导出。
class InstanceDetailPage extends ConsumerStatefulWidget {
  const InstanceDetailPage({super.key, required this.id});

  final String id;

  @override
  ConsumerState<InstanceDetailPage> createState() => _InstanceDetailPageState();
}

class _InstanceDetailPageState extends ConsumerState<InstanceDetailPage> {
  Timer? _tailTimer;
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    // 日志 tail 随事件流之外持续刷新（日志行不进事件流，Gate-B §6）。
    _tailTimer = Timer.periodic(const Duration(milliseconds: 600), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tailTimer?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(instanceEventsProvider); // 事件驱动状态区刷新
    final mgrAsync = ref.watch(instanceManagerProvider);

    return mgrAsync.when(
      loading: () => const Scaffold(body: Center(child: CircularProgressIndicator())),
      error: (e, _) => Scaffold(body: Center(child: Text('加载失败：$e'))),
      data: (mgr) {
        final cfg = mgr.registry.get(widget.id);
        if (cfg == null) {
          return const Scaffold(body: Center(child: Text('实例不存在')));
        }
        final st = mgr.stateOf(widget.id);
        final tailLines = mgr.logTailOf(widget.id)?.tail(200) ?? const [];
        _scrollToBottom();

        return Scaffold(
          appBar: AppBar(title: Text(cfg.alias)),
          body: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: _statusCard(cfg, st),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Wrap(spacing: 8, children: [
                  FilledButton(
                    onPressed: st?.status == InstanceStatus.running
                        ? null
                        : () => _act(() => mgr.start(widget.id)),
                    child: const Text('启动'),
                  ),
                  FilledButton.tonal(
                    onPressed: st?.status == InstanceStatus.running
                        ? () => _act(() => mgr.stop(widget.id))
                        : null,
                    child: const Text('停止'),
                  ),
                  FilledButton.tonal(
                    onPressed: st?.status == InstanceStatus.running
                        ? () => _act(() => mgr.restart(widget.id))
                        : null,
                    child: const Text('重启'),
                  ),
                  OutlinedButton(
                    onPressed: st?.status == InstanceStatus.running
                        ? () => _setActiveEndpoint(cfg, st)
                        : null,
                    child: const Text('设为活动端点'),
                  ),
                  OutlinedButton(
                    onPressed: () => _export(mgr),
                    child: const Text('导出日志'),
                  ),
                ]),
              ),
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
                child: Text('日志（最近 200 行）'),
              ),
              Expanded(
                child: Container(
                  width: double.infinity,
                  color: Colors.black87,
                  margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  padding: const EdgeInsets.all(8),
                  child: SingleChildScrollView(
                    controller: _scroll,
                    child: SelectableText(
                      tailLines.isEmpty ? '（暂无日志输出）' : tailLines.join('\n'),
                      style: const TextStyle(
                          fontFamily: 'Consolas, monospace',
                          fontSize: 12,
                          color: Colors.white70),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _statusCard(InstanceConfig cfg, InstanceState? st) {
    final status = st?.status ?? InstanceStatus.created;
    final startedAt = st?.startedAt;
    final uptime = startedAt == null
        ? null
        : DateTime.now().difference(startedAt);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [StatusBadge(status: status)]),
            const SizedBox(height: 10),
            _kv(context, '实例 ID', cfg.id),
            _kv(context, 'Profile', cfg.profile),
            _kv(context, '端点', '${cfg.host}:${st?.port ?? cfg.port}'),
            _kv(context, '进程',
                st?.pid != null ? 'pid=${st!.pid}' : '未运行'),
            _kv(context, '启动时长', uptime == null ? '-' : _fmt(uptime)),
            _kv(context, '最近心跳',
                st?.lastHeartbeat == null ? '-' : _time(st!.lastHeartbeat)),
            _kv(context, '守护重试', '${st?.guardianAttempts ?? 0}'),
            if (st?.lastExitCode != null)
              _kv(context, '上次退出码', '${st!.lastExitCode}'),
          ],
        ),
      ),
    );
  }

  /// label-value 两列对齐信息行（F3-4）。
  Widget _kv(BuildContext context, String k, String v) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 92,
            child: Text(k,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.outline)),
          ),
          Expanded(child: SelectableText(v)),
        ],
      ),
    );
  }

  Future<void> _act(Future<void> Function() fn) async {
    try {
      await fn();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('操作失败：$e')));
      }
    }
  }

  /// 设为活动端点（M3-T5；T9 修正 F2-1）：绑定实例 ID，端口变化自动跟随。
  void _setActiveEndpoint(InstanceConfig cfg, InstanceState? st) {
    ref.read(activeEndpointProvider.notifier).selectInstance(cfg.id);
    final url = 'http://${cfg.host}:${st?.port ?? cfg.port}';
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('活动端点已绑定实例「${cfg.alias}」（$url）；'
            '实例重启换端口后对话将自动跟随')));
  }

  Future<void> _export(InstanceManager mgr) async {
    final tail = mgr.logTailOf(widget.id);
    if (tail == null) return;
    final path = tail.export();
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('日志文件：$path')));
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  String _fmt(Duration d) {
    final m = d.inMinutes, s = d.inSeconds % 60;
    return '${m}m ${s}s';
  }

  String _time(DateTime? t) =>
      t == null ? '-' : '${t.hour}:${t.minute.toString().padLeft(2, '0')}:'
          '${t.second.toString().padLeft(2, '0')}';
}
