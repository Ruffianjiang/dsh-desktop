import 'package:tray_manager/tray_manager.dart';

/// 系统托盘（M3-T8）：打开主窗 / 全部停止 / 退出。
///
/// 图标沿用 windows runner 的 `app_icon.ico`（复制为 `assets/tray.ico`）。
/// 菜单动作由 `app.dart` 的 TrayListener 处理（可访问 Riverpod ref）。
Future<void> initTray() async {
  await trayManager.setIcon('assets/tray.ico');
  await trayManager.setToolTip('DSH Desktop');
  await trayManager.setContextMenu(Menu(items: [
    MenuItem(key: 'show', label: '打开主窗'),
    MenuItem(key: 'stopAll', label: '全部停止'),
    MenuItem.separator(),
    MenuItem(key: 'quit', label: '退出'),
  ]));
}
