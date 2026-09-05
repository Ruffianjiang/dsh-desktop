import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:launch_at_startup/launch_at_startup.dart';

import '../../core/providers.dart';
import '../../core/settings_store.dart';
import '../chat/chat_controllers.dart';

/// 设置页（M3-T8）：默认端口 / 数据目录 / 主题 / 自启 / 关闭行为 / 端点与模型只读。
class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key});

  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  final _portCtrl = TextEditingController();
  final _dirCtrl = TextEditingController();

  @override
  void dispose() {
    _portCtrl.dispose();
    _dirCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(appSettingsProvider);
    final endpoint = ref.watch(activeEndpointProvider);
    final selected = ref.watch(selectedSessionProvider);
    final models =
        selected == null ? null : ref.watch(sessionModelsProvider(selected));
    if (_portCtrl.text.isEmpty) _portCtrl.text = s.defaultPort.toString();
    if (_dirCtrl.text.isEmpty) _dirCtrl.text = s.dataDir ?? '';

    final modelsAsync = models;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('设置', style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 12),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(children: [
              TextField(
                controller: _portCtrl,
                decoration: const InputDecoration(
                    labelText: '新建实例默认端口（0 = 自动分配）'),
                keyboardType: TextInputType.number,
                onSubmitted: (v) => _save(s),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _dirCtrl,
                decoration:
                    const InputDecoration(labelText: '新建实例数据目录（可空）'),
                onSubmitted: (v) => _save(s),
              ),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: FilledButton.tonal(
                    onPressed: () => _save(s), child: const Text('保存')),
              ),
            ]),
          ),
        ),
        const SizedBox(height: 12),
        Card(
          child: Column(children: [
            SwitchListTile(
              title: const Text('主题：跟随系统'),
              value: s.themeMode == AppThemeMode.system,
              onChanged: (v) => _save(s.copyWith(
                  themeMode:
                      v ? AppThemeMode.system : AppThemeMode.light)),
            ),
            const Divider(height: 1),
            ListTile(
              title: const Text('主题'),
              trailing: SegmentedButton<AppThemeMode>(
                segments: const [
                  ButtonSegment(
                      value: AppThemeMode.light, label: Text('亮')),
                  ButtonSegment(value: AppThemeMode.dark, label: Text('暗')),
                  ButtonSegment(
                      value: AppThemeMode.system, label: Text('跟随')),
                ],
                selected: {s.themeMode},
                onSelectionChanged: (v) =>
                    _save(s.copyWith(themeMode: v.first)),
              ),
            ),
            const Divider(height: 1),
            SwitchListTile(
              title: const Text('开机自启'),
              value: s.autoStart,
              onChanged: (v) async {
                try {
                  if (v) {
                    await launchAtStartup.enable();
                  } else {
                    await launchAtStartup.disable();
                  }
                } catch (_) {/* 注册失败仍记录偏好 */}
                _save(s.copyWith(autoStart: v));
              },
            ),
            const Divider(height: 1),
            SwitchListTile(
              title: const Text('关闭窗口时最小化到托盘'),
              value: s.minimizeToTray,
              onChanged: (v) => _save(s.copyWith(minimizeToTray: v)),
            ),
          ]),
        ),
        const SizedBox(height: 12),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('活动端点：$endpoint'),
                const SizedBox(height: 4),
                Text('当前会话：${selected ?? '（未选择）'}',
                    style: Theme.of(context).textTheme.bodySmall),
                const SizedBox(height: 8),
                Row(
                  children: [
                    FilledButton.tonal(
                      onPressed: selected == null || endpoint == null
                          ? null
                          : () => ref.invalidate(sessionModelsProvider(
                              selected)),
                      child: const Text('查询模型'),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: modelsAsync == null
                          ? const Text('模型：连接并选择会话后可查询')
                          : modelsAsync.when(
                              loading: () => const Text('模型：查询中…'),
                              error: (e, _) => Text('模型查询失败：$e'),
                              data: (m) {
                                final cur = (m?['current'] as Map?) ?? const {};
                                final groups = (m?['groups'] as List?) ?? const [];
                                return Text(
                                    '模型：${cur['model'] ?? '未知'}（${cur['provider'] ?? '-'}）· 可选组 ${groups.length}');
                              },
                            ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  void _save(AppSettings s) {
    ref.read(appSettingsProvider.notifier).update(s.copyWith(
          defaultPort: int.tryParse(_portCtrl.text.trim()) ?? 0,
          dataDir: _dirCtrl.text.trim().isEmpty ? null : _dirCtrl.text.trim(),
        ));
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('设置已保存')));
  }
}
