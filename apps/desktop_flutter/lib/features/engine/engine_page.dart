import 'package:dsh_manager/dsh_manager.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';

/// 引擎管理页（M3-T4；T9 修正 F1-1/2/3，Gate-A 20260909）：
/// 「实例引擎（当前生效）」+「托管引擎」双卡片；安装/升级后热替换
/// 管理器引擎（新实例即用托管引擎，在跑实例不受影响）。
class EnginePage extends ConsumerWidget {
  const EnginePage({super.key});

  static const _sourceLabels = {
    'DSH_CLI': '环境变量 DSH_CLI',
    'managed': '托管引擎（安装即生效）',
    'PATH': 'PATH 全局（where dsh.cmd）',
    'node-dir': 'node 同目录',
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final envAsync = ref.watch(nodeEnvProvider);
    final catalogAsync = ref.watch(versionCatalogProvider);
    final installedAsync = ref.watch(installedVersionProvider);

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('引擎管理', style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 12),
        envAsync.when(
          loading: () => const LinearProgressIndicator(),
          error: (e, _) => Card(
            color: Theme.of(context).colorScheme.errorContainer,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Text('环境探测失败：$e\n提示：设置 DSH_NODE 指向 node.exe、'
                  'DSH_CLI 指向 dsh bin.js'),
            ),
          ),
          data: (env) => Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text('实例引擎（当前生效）',
                          style: Theme.of(context).textTheme.titleMedium),
                      const Spacer(),
                      Text(_sourceLabels[env.source] ?? env.source,
                          style: Theme.of(context).textTheme.labelSmall
                              ?.copyWith(
                                  color: Theme.of(context)
                                      .colorScheme
                                      .primary)),
                    ],
                  ),
                  const SizedBox(height: 8),
                  _kv(context, 'dsh 版本', env.dshVersion ?? '未知'),
                  _kv(context, 'bin.js', env.dshCliJs),
                  _kv(context, 'node', env.nodePath),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 12),
        installedAsync.when(
          loading: () => const LinearProgressIndicator(),
          error: (e, _) => Text('托管引擎探测失败：$e'),
          data: (installed) => Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text('托管引擎',
                          style: Theme.of(context).textTheme.titleMedium),
                      const Spacer(),
                      if (installed != null)
                        FilledButton.tonal(
                          onPressed: () => _upgrade(context, ref),
                          child: const Text('升级到最新'),
                        ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    installed == null
                        ? '未安装。安装后新实例将以托管引擎启动（优先于 PATH 全局）；'
                            '在跑实例不受影响。'
                        : '已装版本：$installed（新实例优先使用）',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 12),
        Text('可用版本', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        catalogAsync.when(
          loading: () => const LinearProgressIndicator(),
          error: (e, _) => Text('版本目录获取失败：$e（检查网络/代理）'),
          data: (catalog) => Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: 8,
                children: [
                  for (final entry in catalog.distTags.entries)
                    ActionChip(
                      label: Text('${entry.key}: ${entry.value}'),
                      tooltip: '安装 ${entry.value}',
                      onPressed: () => _install(context, ref, entry.value),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              for (final v in catalog.stable().reversed.take(10))
                ListTile(
                  dense: true,
                  title: Text(v),
                  trailing: FilledButton.tonal(
                    onPressed: () => _install(context, ref, v),
                    child: const Text('安装'),
                  ),
                ),
            ],
          ),
        ),
      ],
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

  Future<void> _install(
      BuildContext context, WidgetRef ref, String version) async {
    final messenger = ScaffoldMessenger.of(context);
    final svc = await ref.read(installServiceProvider.future);
    try {
      final prev = await svc.detectInstalled(svc.defaultPrefix);
      await svc.install(version, previousVersion: prev, onLog: debugPrint);
      ref.invalidate(installedVersionProvider);
      ref.invalidate(nodeEnvProvider); // F1-3：引擎页显示随装随变
      await _syncManagerEnv(ref, svc.defaultPrefix); // F1-3：管理器热替换引擎
      messenger.showSnackBar(const SnackBar(
          content: Text('安装完成：新实例将以托管引擎启动（在跑实例不受影响）')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('安装失败：$e')));
    }
  }

  Future<void> _upgrade(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    final svc = await ref.read(installServiceProvider.future);
    try {
      final result = await svc.upgrade(
        spec: 'latest',
        prefix: svc.defaultPrefix,
        includePrerelease: false,
        onLog: debugPrint,
      );
      ref.invalidate(installedVersionProvider);
      ref.invalidate(nodeEnvProvider);
      await _syncManagerEnv(ref, svc.defaultPrefix);
      messenger.showSnackBar(
          SnackBar(content: Text('升级完成：${result.version}（新实例生效）')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('升级失败：$e')));
    }
  }

  /// F1-3：以最新探测结果热替换 InstanceManager 的引擎（仅影响新实例；
  /// 管理器不重建，在跑实例与注册表状态无损）。
  Future<void> _syncManagerEnv(WidgetRef ref, String managedPrefix) async {
    try {
      final mgr = await ref.read(instanceManagerProvider.future);
      final env = await NodeEnv.probe(managedPrefix: managedPrefix);
      mgr.updateEnv(env);
    } catch (_) {
      // 探测失败保持原引擎；下次安装/重启应用再应用。
    }
  }
}
