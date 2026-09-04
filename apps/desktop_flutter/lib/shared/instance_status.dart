import 'package:dsh_manager/dsh_manager.dart';
import 'package:flutter/material.dart';

/// 实例状态 → 展示文案 / 颜色（M3 Gate-B §5.3 实例面板）。
String statusLabel(InstanceStatus s) => switch (s) {
      InstanceStatus.created => '已创建',
      InstanceStatus.starting => '启动中',
      InstanceStatus.running => '运行中',
      InstanceStatus.stopping => '停止中',
      InstanceStatus.stopped => '已停止',
      InstanceStatus.crashed => '已崩溃',
    };

Color statusColor(InstanceStatus s) => switch (s) {
      InstanceStatus.created => Colors.blueGrey,
      InstanceStatus.starting => Colors.amber,
      InstanceStatus.running => Colors.green,
      InstanceStatus.stopping => Colors.orange,
      InstanceStatus.stopped => Colors.grey,
      InstanceStatus.crashed => Colors.red,
    };

/// 状态徽标（圆点 + 文案）。
class StatusBadge extends StatelessWidget {
  const StatusBadge({super.key, required this.status});

  final InstanceStatus status;

  @override
  Widget build(BuildContext context) {
    final color = statusColor(status);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        Text(statusLabel(status),
            style: TextStyle(color: color, fontWeight: FontWeight.w600)),
      ],
    );
  }
}
