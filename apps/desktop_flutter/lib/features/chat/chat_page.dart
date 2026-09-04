import 'package:dsh_client/dsh_client.dart';
import 'package:dsh_manager/dsh_manager.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import 'chat_controllers.dart';

/// 对话工作台（M3-T6）：左会话列表 260px + 右消息流/输入；顶部为 T5 连接条。
///
/// 渲染当前为纯文本保底（Gate-A BQ1：渲染库 bench 后替换 Markdown 组件）。
class ChatPage extends ConsumerStatefulWidget {
  const ChatPage({super.key});

  @override
  ConsumerState<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends ConsumerState<ChatPage> {
  final _inputCtrl = TextEditingController();
  final _manualCtrl = TextEditingController();
  final _scroll = ScrollController();
  bool _steer = false;

  @override
  void dispose() {
    _inputCtrl.dispose();
    _manualCtrl.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final endpoint = ref.watch(activeEndpointProvider);
    final phaseAsync = ref.watch(connPhaseStreamProvider);
    final phase = phaseAsync.value ??
        (endpoint == null ? ConnPhase.disconnected : ConnPhase.connecting);
    final streaming = phase == ConnPhase.streaming;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Text('对话工作台',
              style: Theme.of(context).textTheme.headlineSmall),
        ),
        _connectionBar(context, endpoint, phase),
        _approvalBanner(context),
        const Divider(height: 1),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(width: 260, child: _sessionList(context)),
              const VerticalDivider(width: 1),
              Expanded(child: _messagesColumn(context, streaming)),
            ],
          ),
        ),
      ],
    );
  }

  // --------------------------------------------------------------------------
  // 会话列表
  // --------------------------------------------------------------------------

  Widget _sessionList(BuildContext context) {
    final sessions = ref.watch(sessionsProvider);
    final selected = ref.watch(selectedSessionProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: Row(
            children: [
              const Expanded(child: Text('会话')),
              IconButton(
                tooltip: sessions.isEmpty ? '连接后可新建会话' : '新建会话',
                onPressed: sessions.isEmpty
                    ? null
                    : () => ref.read(sessionsProvider.notifier).createSession(),
                icon: const Icon(Icons.add_comment_outlined),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: sessions.isEmpty
              ? const Center(
                  child: Text('暂无会话\n（连接实例后自动加载 / 新建）',
                      textAlign: TextAlign.center))
              : ListView.builder(
                  itemCount: sessions.length,
                  itemBuilder: (context, i) {
                    final s = sessions[i];
                    return ListTile(
                      dense: true,
                      selected: s.sessionId == selected,
                      leading: Icon(
                        Icons.chat_bubble_outline,
                        size: 18,
                        color: s.running ? Colors.green : Colors.grey,
                      ),
                      title: Text(s.title,
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                      onTap: () => ref
                          .read(selectedSessionProvider.notifier)
                          .select(s.sessionId),
                    );
                  },
                ),
        ),
      ],
    );
  }

  // --------------------------------------------------------------------------
  // 消息流 + 输入
  // --------------------------------------------------------------------------

  Widget _messagesColumn(BuildContext context, bool streaming) {
    final selected = ref.watch(selectedSessionProvider);

    if (selected == null) {
      return const Center(child: Text('选择或新建一个会话开始对话'));
    }

    final messages = ref.watch(chatControllerProvider(selected));
    final controller = ref.read(chatControllerProvider(selected).notifier);
    final hasStreaming = messages.any((m) => m.status == MessageStatus.streaming);

    final list = ListView.builder(
      controller: _scroll,
      reverse: true, // 新消息在底部；滚动锚定天然成立
      padding: const EdgeInsets.all(12),
      itemCount: messages.length,
      itemBuilder: (context, i) {
        final m = messages[messages.length - 1 - i];
        return _bubble(context, m);
      },
    );

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: [
              Expanded(
                child: Text('会话：$selected',
                    style: Theme.of(context).textTheme.bodySmall,
                    overflow: TextOverflow.ellipsis),
              ),
              if (hasStreaming)
                TextButton.icon(
                  onPressed: () => controller.cancel(),
                  icon: const Icon(Icons.stop_circle_outlined, size: 18),
                  label: const Text('取消当前 run'),
                ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(child: list),
        const Divider(height: 1),
        _inputArea(context, controller, streaming, hasStreaming),
      ],
    );
  }

  Widget _bubble(BuildContext context, ChatMessage m) {
    final isUser = m.role == ChatRole.user;
    final scheme = Theme.of(context).colorScheme;
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 720),
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        decoration: BoxDecoration(
          color: isUser ? scheme.primaryContainer : scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final b in m.blocks) _block(context, b),
            if (m.status == MessageStatus.streaming)
              const Text('▍', style: TextStyle(fontWeight: FontWeight.bold)),
          ],
        ),
      ),
    );
  }

  Widget _block(BuildContext context, ChatBlock b) {
    final scheme = Theme.of(context).colorScheme;
    if (b.type == ChatBlockType.code) {
      return Container(
        width: double.infinity,
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.all(8),
        color: Colors.black87,
        child: SelectableText(b.text,
            style: const TextStyle(fontFamily: 'Consolas, monospace', fontSize: 12.5, color: Colors.white)),
      );
    }
    if (b.type == ChatBlockType.toolCall) {
      // 工具轨迹（M3-T7）：host 附带的 view.card 文本，折叠态展示
      return Container(
        width: double.infinity,
        margin: const EdgeInsets.symmetric(vertical: 2),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          children: [
            Icon(Icons.construction_outlined, size: 14, color: scheme.outline),
            const SizedBox(width: 6),
            Expanded(
              child: SelectableText(b.text,
                  style: TextStyle(
                      fontSize: 12, color: scheme.onSurfaceVariant)),
            ),
          ],
        ),
      );
    }
    if (b.type == ChatBlockType.unknown) {
      return Text('［非文本块］',
          style: TextStyle(
              fontSize: 12, color: Theme.of(context).hintColor, fontStyle: FontStyle.italic));
    }
    return SelectableText(b.text.isEmpty && !b.closed ? '…' : b.text);
  }

  Widget _inputArea(
      BuildContext context, ChatController controller, bool streaming, bool hasStreaming) {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Tooltip(
            message: '开启后消息作为插话（steer）立即注入，而非排队',
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Switch(value: _steer, onChanged: (v) => setState(() => _steer = v)),
                const Text('steer'),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: CallbackShortcuts(
              bindings: {
                const SingleActivator(LogicalKeyboardKey.enter): () =>
                    _send(controller),
              },
              child: Focus(
                autofocus: true,
                child: TextField(
                  controller: _inputCtrl,
                  maxLines: 5,
                  minLines: 1,
                  textInputAction: TextInputAction.newline,
                  decoration: const InputDecoration(
                    hintText: '输入消息，Enter 发送（Shift+Enter 换行）',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          FilledButton.icon(
            onPressed: hasStreaming && !_steer ? null : () => _send(controller),
            icon: const Icon(Icons.send_outlined),
            label: const Text('发送'),
          ),
        ],
      ),
    );
  }

  void _send(ChatController controller) {
    final text = _inputCtrl.text;
    if (text.trim().isEmpty) return;
    if (HardwareKeyboard.instance.isShiftPressed) {
      // Shift+Enter：插入换行
      final sel = _inputCtrl.selection;
      final t = _inputCtrl.text;
      final pos = sel.baseOffset.clamp(0, t.length);
      _inputCtrl.text = '${t.substring(0, pos)}\n${t.substring(pos)}';
      _inputCtrl.selection =
          TextSelection.collapsed(offset: pos + 1);
      return;
    }
    _inputCtrl.clear();
    controller.send(text, steer: _steer);
  }

  // --------------------------------------------------------------------------
  // 连接条（M3-T5 迁入；逻辑不变）
  // --------------------------------------------------------------------------

  Widget _connectionBar(
      BuildContext context, String? endpoint, ConnPhase phase) {
    final mgrAsync = ref.watch(instanceManagerProvider);
    ref.watch(instanceEventsProvider);

    final running = <(String, String)>[];
    mgrAsync.maybeWhen(
      data: (mgr) {
        for (final cfg in mgr.list()) {
          final st = mgr.stateOf(cfg.id);
          if (st?.status == InstanceStatus.running) {
            final url = 'http://${cfg.host}:${st!.port ?? cfg.port}';
            running.add((url, '${cfg.alias} · $url'));
          }
        }
      },
      orElse: () {},
    );

    return Card(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                _phaseBadge(phase),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    endpoint == null
                        ? '未选择活动端点（从运行中的实例选择，或手动输入）'
                        : '活动端点：$endpoint',
                    style: Theme.of(context).textTheme.bodySmall,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (endpoint != null)
                  TextButton.icon(
                    onPressed: () =>
                        ref.read(activeEndpointProvider.notifier).clear(),
                    icon: const Icon(Icons.link_off, size: 18),
                    label: const Text('断开'),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<String>(
                    initialValue:
                        endpoint != null && running.any((r) => r.$1 == endpoint)
                            ? endpoint
                            : null,
                    isDense: true,
                    decoration: InputDecoration(
                      labelText: '运行中的实例端点',
                      border: const OutlineInputBorder(),
                      isDense: true,
                      helperText: running.isEmpty ? '暂无运行中的实例' : null,
                    ),
                    items: [
                      for (final (url, label) in running)
                        DropdownMenuItem(value: url, child: Text(label)),
                    ],
                    onChanged: (v) {
                      if (v != null) {
                        ref.read(activeEndpointProvider.notifier).select(v);
                      }
                    },
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: _manualCtrl,
                    decoration: const InputDecoration(
                      labelText: '手动端点（http://127.0.0.1:port）',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton.tonal(
                  onPressed: () {
                    final v = _manualCtrl.text.trim();
                    if (v.isNotEmpty) {
                      ref.read(activeEndpointProvider.notifier).select(v);
                    }
                  },
                  child: const Text('连接'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// 审批浮层（M3-T7）：approval/requested 队列 → 允许/拒绝 → /api/respond。
  Widget _approvalBanner(BuildContext context) {
    final approvals = ref.watch(pendingApprovalsProvider);
    if (approvals.isEmpty) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return Column(
      children: [
        for (final a in approvals)
          Card(
            color: scheme.errorContainer,
            margin: const EdgeInsets.fromLTRB(16, 4, 16, 4),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
              child: Row(
                children: [
                  Icon(Icons.gpp_maybe_outlined, color: scheme.onErrorContainer),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('工具审批：${a.toolName}',
                            style: const TextStyle(fontWeight: FontWeight.w600)),
                        if (a.reason != null && a.reason!.isNotEmpty)
                          Text(a.reason!,
                              style: Theme.of(context).textTheme.bodySmall),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: () => _respond(context, ref, a, allow: true),
                    child: const Text('允许'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.tonal(
                    onPressed: () => _respond(context, ref, a, allow: false),
                    child: const Text('拒绝'),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  Future<void> _respond(BuildContext context, WidgetRef ref,
      ApprovalRequest a, {required bool allow}) async {
    final conn = ref.read(connectionProvider);
    if (conn == null) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      final r = await conn.client.respondClientResponse(
        rpcId: a.frameRpcId,
        value: {
          'sessionId': a.sessionId,
          'approvalId': a.approvalId,
          'outcome': allow ? 'allowed-once' : 'rejected',
        },
      );
      if (r?['accepted'] != true) {
        // not-pending / bad-response 等：移出队列避免横幅卡死
        ref.read(pendingApprovalsProvider.notifier).dismiss(a.approvalId);
        messenger.showSnackBar(SnackBar(
            content: Text('审批未受理：${r?['reason'] ?? '未知原因'}')));
      }
      // accepted=true 时 approval/resolved 帧会到达并自动出队
    } catch (e) {
      ref.read(pendingApprovalsProvider.notifier).dismiss(a.approvalId);
      messenger.showSnackBar(SnackBar(content: Text('审批回写失败：$e')));
    }
  }

  Widget _phaseBadge(ConnPhase phase) {
    final (label, color) = switch (phase) {
      ConnPhase.streaming => ('已连接（streaming）', Colors.green),
      ConnPhase.connected => ('已连接', Colors.blue),
      ConnPhase.connecting => ('连接中', Colors.amber),
      ConnPhase.error => ('连接异常（自动重连中）', Colors.red),
      ConnPhase.disconnected => ('未连接', Colors.grey),
    };
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Container(
        width: 10,
        height: 10,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      ),
      const SizedBox(width: 6),
      Text(label, style: TextStyle(color: color, fontWeight: FontWeight.w600)),
    ]);
  }
}
