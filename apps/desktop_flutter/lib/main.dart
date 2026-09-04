import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import 'app.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (Platform.isWindows) {
    // M3 Gate-B §2：窗口初始化（尺寸/标题/最小尺寸/居中）。
    await windowManager.ensureInitialized();
    const options = WindowOptions(
      title: 'DSH Desktop',
      size: Size(1440, 900),
      minimumSize: Size(1120, 720),
      center: true,
    );
    await windowManager.waitUntilReadyToShow(options, () async {
      await windowManager.show();
      await windowManager.focus();
    });
  }
  runApp(const ProviderScope(child: DshApp()));
}
