import 'package:flutter/material.dart';

import '../../shared/widgets/placeholder_page.dart';

/// 实例面板（M3-T4 实建：列表/详情/启停/日志 tail/健康，事件流驱动）。
class InstancesPage extends StatelessWidget {
  const InstancesPage({super.key});

  @override
  Widget build(BuildContext context) {
    return const PlaceholderPage(
      title: '实例面板',
      note: 'M3-T4 实建：列表 / 详情 / 启停 / 重启 / 日志 tail / 健康',
    );
  }
}
