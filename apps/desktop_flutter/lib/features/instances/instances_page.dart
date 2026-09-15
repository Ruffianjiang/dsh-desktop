import 'package:dsh_manager/dsh_manager.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/providers.dart';
import '../../shared/instance_status.dart';

/// 实例面板（M3-T4）：列表 / 新建 / 启停 / 重启 / 删除，事件流驱动刷新。
class InstancesPage extends ConsumerWidget {
  const InstancesPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(instanceEventsProvider); // 任何实例事件 → 本页重建
    final mgrAsync = ref.watch(instanceManagerProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Row(
            children: [
              Expanded(
                  child: Text('实例',
                      style: Theme.of(context).textTheme.headlineSmall)),
              FilledButton.icon(
                onPressed: () => _showCreateDialog(context, ref),
                icon: const Icon(Icons.add),
                label: const Text('新建实例'),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: mgrAsync.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, _) => Center(
              child: Text('实例管理器初始化失败：$e\n（需先在引擎页完成环境探测）',
                  textAlign: TextAlign.center),
            ),
            data: (mgr) {
              final configs = mgr.list();
              if (configs.isEmpty) {
                return const Center(child: Text('暂无实例，点击右上角「新建实例」'));
              }
              return ListView.builder(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                itemCount: configs.length,
                itemBuilder: (context, i) {
                  final cfg = configs[i];
                  final state = mgr.stateOf(cfg.id);
                  final status = state?.status ?? InstanceStatus.created;
                  return Card(
                    child: ListTile(
                      leading: Container(
                        width: 12,
                        height: 12,
                        margin: const EdgeInsets.symmetric(vertical: 14),
                        decoration: BoxDecoration(
                            color: statusColor(status), shape: BoxShape.circle),
                      ),
                      title: Text(cfg.alias),
                      subtitle: Text(
                          '${statusLabel(status)} · ${cfg.host}:${state?.port ?? cfg.port}'
                          '${state?.pid != null ? ' · pid=${state!.pid}' : ''}'),
                      onTap: () => context.push('/instances/${cfg.id}'),
                      trailing: PopupMenuButton<String>(
                        onSelected: (v) {
                          if (v == 'detail') {
                            context.push('/instances/${cfg.id}');
                          } else if (v == 'remove') {
                            _confirmRemove(context, ref, cfg);
                          } else {
                            _act(context, ref, cfg.id, v);
                          }
                        },
                        itemBuilder: (_) => [
                          const PopupMenuItem(
                              value: 'start', child: Text('启动')),
                          const PopupMenuItem(
                              value: 'stop', child: Text('停止')),
                          const PopupMenuItem(
                              value: 'restart', child: Text('重启')),
                          const PopupMenuItem(
                              value: 'detail', child: Text('详情')),
                          const PopupMenuDivider(),
                          const PopupMenuItem(
                              value: 'remove', child: Text('删除实例')),
                        ],
                      ),
                    ),
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }

  Future<void> _showCreateDialog(BuildContext context, WidgetRef ref) async {
    final aliasCtrl = TextEditingController();
    final portCtrl = TextEditingController(text: '0');
    final dirCtrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('新建实例'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: aliasCtrl,
              decoration: const InputDecoration(labelText: '别名'),
            ),
            TextField(
              controller: portCtrl,
              decoration:
                  const InputDecoration(labelText: '端口（0 = 自动分配）'),
              keyboardType: TextInputType.number,
            ),
            TextField(
              controller: dirCtrl,
              decoration: const InputDecoration(
                  labelText: '数据目录（工作目录，可空）'),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('创建')),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;

    final alias = aliasCtrl.text.trim();
    if (alias.isEmpty) return;
    final mgr = await ref.read(instanceManagerProvider.future);
    try {
      await mgr.create(InstanceConfig(
        id: 'inst-${DateTime.now().millisecondsSinceEpoch}',
        alias: alias,
        port: int.tryParse(portCtrl.text.trim()) ?? 0,
        dataDir: dirCtrl.text.trim().isEmpty ? null : dirCtrl.text.trim(),
      ));
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('实例「$alias」已创建并启动')));
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('创建/启动失败：$e')));
      }
    }
  }

  Future<void> _confirmRemove(
      BuildContext context, WidgetRef ref, InstanceConfig cfg) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除实例'),
        content: Text('将停止实例（若在运行）并删除配置「${cfg.alias}」，确定？'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('删除')),
        ],
      ),
    );
    if (ok == true && context.mounted) {
      await _act(context, ref, cfg.id, 'remove');
    }
  }

  Future<void> _act(
      BuildContext context, WidgetRef ref, String id, String action) async {
    final messenger = ScaffoldMessenger.of(context);
    final mgr = await ref.read(instanceManagerProvider.future);
    try {
      switch (action) {
        case 'start':
          await mgr.start(id);
        case 'stop':
          await mgr.stop(id);
        case 'restart':
          await mgr.restart(id);
        case 'remove':
          await mgr.remove(id);
      }
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('操作失败：$e')));
    }
  }
}
