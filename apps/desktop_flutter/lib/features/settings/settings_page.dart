import 'package:flutter/material.dart';

import '../../shared/widgets/placeholder_page.dart';

/// 设置页（M3-T8 实建：端口 / 数据目录 / 主题 / autoStart / 模型只读）。
class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return const PlaceholderPage(
      title: '设置',
      note: 'M3-T8 实建：默认端口 / 数据目录 / 主题 / autoStart / 模型只读',
    );
  }
}
