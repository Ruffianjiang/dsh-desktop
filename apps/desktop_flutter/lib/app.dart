import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import 'core/providers.dart';
import 'core/router.dart';
import 'core/settings_store.dart';
import 'core/theme.dart';
import 'core/tray.dart';

/// 应用根：go_router 路由 + 主题（跟随设置）+ 托盘/关闭行为（M3-T8）。
class DshApp extends ConsumerStatefulWidget {
  const DshApp({super.key, this.enableSystemTray = true});

  /// widget 测试环境无 window/tray 插件，置 false 跳过系统托盘接线。
  final bool enableSystemTray;

  @override
  ConsumerState<DshApp> createState() => _DshAppState();
}

class _DshAppState extends ConsumerState<DshApp>
    with TrayListener, WindowListener {
  bool _quitting = false;

  @override
  void initState() {
    super.initState();
    if (!widget.enableSystemTray) return;
    trayManager.addListener(this);
    windowManager.addListener(this);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await windowManager.setPreventClose(true); // 关闭行为由设置决定
      await initTray();
    });
  }

  @override
  void dispose() {
    if (widget.enableSystemTray) {
      trayManager.removeListener(this);
      windowManager.removeListener(this);
    }
    super.dispose();
  }

  @override
  Future<void> onTrayMenuItemClick(MenuItem menuItem) async {
    switch (menuItem.key) {
      case 'show':
        await windowManager.show();
        await windowManager.focus();
      case 'stopAll':
        await _stopAll();
      case 'quit':
        await _quit();
    }
  }

  @override
  Future<void> onWindowClose() async {
    // 关闭窗口：按设置最小化到托盘；否则停止全部实例后退出。
    if (ref.read(appSettingsProvider).minimizeToTray && !_quitting) {
      await windowManager.hide();
      return;
    }
    await _quit();
  }

  /// 停止全部实例（失败隔离）。
  Future<void> _stopAll() async {
    try {
      final mgr = await ref.read(instanceManagerProvider.future);
      for (final cfg in List.of(mgr.list())) {
        try {
          await mgr.stop(cfg.id);
        } catch (_) {/* 单实例失败不影响其余 */}
      }
    } catch (_) {/* 管理器未就绪 */}
  }

  Future<void> _quit() async {
    _quitting = true;
    await _stopAll();
    await windowManager.setPreventClose(false);
    await windowManager.destroy();
    exit(0);
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(appSettingsProvider);
    return MaterialApp.router(
      title: 'DSH Desktop',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: switch (settings.themeMode) {
        AppThemeMode.light => ThemeMode.light,
        AppThemeMode.dark => ThemeMode.dark,
        AppThemeMode.system => ThemeMode.system,
      },
      routerConfig: buildRouter(),
    );
  }
}
