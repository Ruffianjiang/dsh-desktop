import 'package:flutter/material.dart';

import '../../shared/widgets/placeholder_page.dart';

/// 引擎管理页（M3-T4 实建：NodeEnv 探测 / 版本列表 / 安装 / 升级 / 回滚）。
class EnginePage extends StatelessWidget {
  const EnginePage({super.key});

  @override
  Widget build(BuildContext context) {
    return const PlaceholderPage(
      title: '引擎管理',
      note: 'M3-T4 实建：NodeEnv 探测 / 版本列表 / 安装 / 升级 / 回滚',
    );
  }
}
