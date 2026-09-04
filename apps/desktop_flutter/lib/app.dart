import 'package:flutter/material.dart';

import 'core/router.dart';
import 'core/theme.dart';

/// 应用根：go_router 路由 + 亮/暗主题（跟随系统）。
class DshApp extends StatelessWidget {
  const DshApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'DSH Desktop',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: ThemeMode.system,
      routerConfig: buildRouter(),
    );
  }
}
