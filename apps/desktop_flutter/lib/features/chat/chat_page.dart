import 'package:flutter/material.dart';

import '../../shared/widgets/placeholder_page.dart';

/// 对话工作台（M3-T6/T7 实建：会话列表 / 流式渲染 / 输入 / 审批浮层）。
class ChatPage extends StatelessWidget {
  const ChatPage({super.key});

  @override
  Widget build(BuildContext context) {
    return const PlaceholderPage(
      title: '对话工作台',
      note: 'M3-T6/T7 实建：会话列表 / 流式渲染 / 输入队列 / 工具轨迹 / 审批',
    );
  }
}
