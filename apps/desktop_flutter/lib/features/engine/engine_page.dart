import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';

/// 引擎管理页（M3-T4）：环境探测 / 已装版本 / 版本目录 / 安装与升级。
class EnginePage extends ConsumerWidget {
  const EnginePage({super.key});

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
            child: ListTile(
              title: const Text('运行环境'),
              subtitle: Text(
                  'node: ${env.nodePath}\n'
                  'dsh bin.js: ${env.dshCliJs}\n'
                  'dsh 版本: ${env.dshVersion ?? '未知'}'),
              isThreeLine: true,
            ),
          ),
        ),
        const SizedBox(height: 12),
        installedAsync.when(
          loading: () => const LinearProgressIndicator(),
          error: (e, _) => Text('已装版本探测失败：$e'),
          data: (installed) => Card(
            child: ListTile(
              title: Text(installed == null
                  ? '托管引擎未安装（安装后实例将以该版本启动）'
                  : '托管引擎已装版本：$installed'),
              trailing: installed == null
                  ? null
                  : FilledButton.tonal(
                      onPressed: () => _upgrade(context, ref),
                      child: const Text('升级到最新'),
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

  Future<void> _install(
      BuildContext context, WidgetRef ref, String version) async {
    final messenger = ScaffoldMessenger.of(context);
    final svc = await ref.read(installServiceProvider.future);
    try {
      final prev = await svc.detectInstalled(svc.defaultPrefix);
      await svc.install(version, previousVersion: prev, onLog: debugPrint);
      ref.invalidate(installedVersionProvider);
      messenger.showSnackBar(SnackBar(content: Text('已安装 $version')));
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
      messenger.showSnackBar(SnackBar(content: Text('升级完成：${result.version}')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('升级失败：$e')));
    }
  }
}
