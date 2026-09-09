import 'package:dsh_client/dsh_client.dart';
import 'package:dsh_manager/dsh_manager.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../shared/markdown_view.dart';
import 'chat_controllers.dart';

/// 对话工作台（M3-T6；T9 修正 Gate-A 20260909 v1.3）：
/// 顶部为紧凑连接条（F2-1 端点绑实例 / F2-2 自动连接 / F2-3 错误可见化），
/// 其余面积全部留给会话列表 + 消息流；气泡带 token 统计（F3-7）与
/// Markdown 渲染（F3-5）。
class ChatPage extends ConsumerStatefulWidget {
  const ChatPage({super.key});

  @override
  ConsumerState<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends ConsumerState<ChatPage> {
  final _inputCtrl = TextEditingController();
  final _scroll = ScrollController();
  bool _steer = false;
  String _lastManualUrl = '';

  @override
  void dispose() {
    _inputCtrl.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(appSettingsProvider);
    final target = ref.watch(activeEndpointProvider);
    final url = ref.watch(activeEndpointUrlProvider);
    final phaseAsync = ref.watch(connPhaseStreamProvider);
    final phase = phaseAsync.value ??
        (url == null ? ConnPhase.disconnected : ConnPhase.connecting);
    final streaming = phase == ConnPhase.streaming;

    // 运行中实例（实例事件驱动刷新；自动连接与切换菜单共用）。
    final mgrAsync = ref.watch(instanceManagerProvider);
    ref.watch(instanceEventsProvider);
    final mgr = mgrAsync.value;
    final running = <({String id, String alias, String url})>[];
    if (mgr != null) {
      for (final cfg in mgr.list()) {
        final st = mgr.stateOf(cfg.id);
        if (st?.status == InstanceStatus.running) {
          running.add((
            id: cfg.id,
            alias: cfg.alias,
            url: 'http://${cfg.host}:${st!.port ?? cfg.port}',
          ));
        }
      }
    }

    // F2-2 自动连接：无活动端点且有运行中实例 → 自动选第一个（设置页可关）。
    if (settings.autoConnect && target == null && running.isNotEmpty) {
      final first = running.first.id;
      Future.microtask(() =>
          ref.read(activeEndpointProvider.notifier).selectInstance(first));
    }

    // 布局（F3-6）：无页首大标题，连接条压缩为单行，面积让给消息区。
    return Column(
      children: [
        _connectionBar(context, target, url, phase, running),
        _approvalBanner(context),
        const Divider(height: 1),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(width: 240, child: _sessionList(context)),
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
          padding: const EdgeInsets.fromLTRB(12, 6, 8, 2),
          child: Row(
            children: [
              const Expanded(child: Text('会话')),
              IconButton(
                tooltip: sessions.isEmpty ? '连接后可新建会话' : '新建会话',
                onPressed: sessions.isEmpty
                    ? null
                    : () => ref.read(sessionsProvider.notifier).createSession(),
                icon: const Icon(Icons.add_comment_outlined, size: 20),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: sessions.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.forum_outlined,
                          size: 40,
                          color: Theme.of(context).colorScheme.outlineVariant),
                      const SizedBox(height: 8),
                      Text('暂无会话\n（连接实例后自动加载 / 新建）',
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.bodySmall),
                    ],
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(vertical: 4),
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
    final hasStreaming =
        messages.any((m) => m.status == MessageStatus.streaming);

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
          padding: const EdgeInsets.fromLTRB(12, 6, 12, 4),
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
      child: Column(
        crossAxisAlignment:
            isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: [
          Text(isUser ? '你' : '助手',
              style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: scheme.outline)),
          Container(
            constraints: const BoxConstraints(maxWidth: 860),
            margin: const EdgeInsets.symmetric(vertical: 4),
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
            decoration: BoxDecoration(
              color: isUser
                  ? scheme.primaryContainer
                  : scheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final b in m.blocks) _block(context, b, isUser: isUser),
                if (m.status == MessageStatus.streaming)
                  const Text('▍', style: TextStyle(fontWeight: FontWeight.bold)),
                if (!isUser && m.usage != null) _tokenFooter(context, m),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// token 统计行（F3-7）：↑输入 ↓输出（+思考/缓存读）· 输出速率 · 用时。
  Widget _tokenFooter(BuildContext context, ChatMessage m) {
    final u = m.usage ?? const {};
    int? numOf(List<String> keys) {
      for (final k in keys) {
        final v = u[k];
        if (v is num) return v.toInt();
      }
      return null;
    }

    final input = numOf(['inputTokens', 'promptTokens']);
    final output = numOf(['outputTokens', 'completionTokens']);
    final reasoning = numOf(['reasoningTokens']);
    final cacheRead = numOf(['cacheReadTokens']);
    final parts = <String>[
      if (input != null) '↑$input',
      if (output != null) '↓$output',
      if (reasoning != null && reasoning > 0) '思考$reasoning',
      if (cacheRead != null && cacheRead > 0) '缓存读$cacheRead',
    ];
    var tail = '';
    final start = m.startedAt;
    if (output != null && start != null) {
      final end = m.finishedAt ?? DateTime.now();
      final secs = end.difference(start).inMilliseconds / 1000;
      if (secs >= 0.5) {
        tail = ' · ${(output / secs).toStringAsFixed(1)} tok/s'
            ' · ${secs.toStringAsFixed(1)}s';
      }
    }
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Text(
        '${parts.join(' · ')}${parts.isEmpty ? '' : ' tok'}$tail',
        style: TextStyle(
            fontSize: 10.5,
            color: Theme.of(context).colorScheme.outline,
            fontFamily: 'Consolas, monospace'),
      ),
    );
  }

  Widget _block(BuildContext context, ChatBlock b, {required bool isUser}) {
    if (b.type == ChatBlockType.code) {
      final messenger = ScaffoldMessenger.of(context);
      return Container(
        width: double.infinity,
        margin: const EdgeInsets.symmetric(vertical: 4),
        decoration: BoxDecoration(
          color: const Color(0xFF1E1E2E),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Stack(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 40, 10),
              child: SelectableText(b.text,
                  style: const TextStyle(
                      fontFamily: 'Consolas, monospace',
                      fontSize: 12.5,
                      color: Color(0xFFE6E6E6))),
            ),
            Positioned(
              top: 0,
              right: 0,
              child: IconButton(
                tooltip: '复制代码',
                icon: const Icon(Icons.copy_rounded, size: 15),
                color: Colors.white38,
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: b.text));
                  messenger.showSnackBar(
                      const SnackBar(content: Text('代码已复制')));
                },
              ),
            ),
          ],
        ),
      );
    }
    if (b.type == ChatBlockType.reasoning) {
      return _ReasoningCard(block: b);
    }
    if (b.type == ChatBlockType.toolCall) {
      return _ToolCallCard(block: b);
    }
    if (b.type == ChatBlockType.unknown) {
      return Text('［非文本块］',
          style: TextStyle(
              fontSize: 12, color: Theme.of(context).hintColor, fontStyle: FontStyle.italic));
    }
    // 文本块：助手消息**闭合块**用 Markdown 渲染（F3-5，BQ1 选型 gpt_markdown）；
    // 流式中的块与用户消息保持纯文本（流式性能 + 防用户输入被当作 Markdown 执行）。
    final text = b.text.isEmpty && !b.closed ? '…' : b.text;
    if (isUser || !b.closed) {
      return SelectableText(text);
    }
    return MarkdownView(text);
  }

  Widget _inputArea(
      BuildContext context, ChatController controller, bool streaming, bool hasStreaming) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
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
  // 连接条（紧凑单行版：F3-6；逻辑 = F2-1/2/3）
  // --------------------------------------------------------------------------

  Widget _connectionBar(
      BuildContext context,
      ActiveTarget? target,
      String? url,
      ConnPhase phase,
      List<({String id, String alias, String url})> running) {
    final conn = ref.watch(connectionProvider);
    final manual = target?.isManual == true;

    final label = target == null
        ? '未连接（检测到运行中的实例会自动连接）'
        : manual
            ? '手动端点：$url'
            : '活动端点：$url';

    return Card(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 6),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                _phaseBadge(phase),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(label,
                      style: Theme.of(context).textTheme.bodySmall,
                      overflow: TextOverflow.ellipsis),
                ),
                PopupMenuButton<String>(
                  tooltip: '切换实例 / 手动端点',
                  icon: const Icon(Icons.swap_horiz_rounded, size: 20),
                  onSelected: (v) {
                    if (v == '__manual__') {
                      _showManualDialog(context);
                      return;
                    }
                    ref.read(activeEndpointProvider.notifier).selectInstance(v);
                  },
                  itemBuilder: (_) => [
                    for (final r in running)
                      PopupMenuItem(
                          value: r.id,
                          child: Text('${r.alias} · ${r.url}',
                              style: const TextStyle(fontSize: 13))),
                    if (running.isNotEmpty) const PopupMenuDivider(),
                    const PopupMenuItem(
                        value: '__manual__',
                        child: Text('手动输入端点…',
                            style: TextStyle(fontSize: 13))),
                  ],
                ),
                if (target != null)
                  IconButton(
                    tooltip: '断开',
                    icon: const Icon(Icons.link_off_rounded, size: 18),
                    onPressed: () =>
                        ref.read(activeEndpointProvider.notifier).clear(),
                  ),
              ],
            ),
            if (phase == ConnPhase.error) ..._errorLine(context, conn),
          ],
        ),
      ),
    );
  }

  /// 手动端点输入（F3-6：从连接条常驻输入框改为按需弹窗）。
  Future<void> _showManualDialog(BuildContext context) async {
    final ctrl = TextEditingController(text: _lastManualUrl);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('手动端点'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(
              labelText: '端点 URL', hintText: 'http://127.0.0.1:port'),
          onSubmitted: (_) => Navigator.of(ctx).pop(true),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('连接')),
        ],
      ),
    );
    if (!mounted) return;
    if (ok == true) {
      final v = ctrl.text.trim();
      if (v.isNotEmpty) {
        _lastManualUrl = v;
        ref.read(activeEndpointProvider.notifier).selectManual(v);
      }
    }
    ctrl.dispose();
  }

  /// F2-3：error 相位显示最近失败原因 + 引导文案。
  List<Widget> _errorLine(BuildContext context, DshConnection? conn) {
    final scheme = Theme.of(context).colorScheme;
    final reason = conn?.lastError;
    return [
      const SizedBox(height: 4),
      Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Text(
          '连接失败${reason == null ? '' : '：$reason'}。'
          '实例可能未运行；若实例刚重启过，端口已自动跟随重连。',
          style: TextStyle(fontSize: 12, color: scheme.error),
        ),
      ),
    ];
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
            margin: const EdgeInsets.fromLTRB(12, 4, 12, 4),
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
      ConnPhase.streaming => ('已连接', Colors.green),
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

/// 工具调用卡片（T9 修正 F3-5）：title 行 + kind 图标 + 可展开详情。
/// call/result 已按 callId 在 assembler 聚合为一卡；详情默认折叠。
class _ToolCallCard extends StatefulWidget {
  const _ToolCallCard({required this.block});

  final ChatBlock block;

  @override
  State<_ToolCallCard> createState() => _ToolCallCardState();
}

class _ToolCallCardState extends State<_ToolCallCard> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final b = widget.block;
    final hasDetail = b.toolDetail?.isNotEmpty ?? false;
    final icon = switch (b.toolKind) {
      'search' => Icons.search_rounded,
      'read' => Icons.description_outlined,
      'edit' => Icons.edit_outlined,
      'write' => Icons.edit_note_outlined,
      'bash' || 'terminal' || 'shell' => Icons.terminal_rounded,
      'web' || 'fetch' => Icons.public_rounded,
      _ => Icons.construction_outlined,
    };
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(vertical: 2),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: hasDetail ? () => setState(() => _open = !_open) : null,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              child: Row(
                children: [
                  Icon(icon, size: 14, color: scheme.primary),
                  const SizedBox(width: 6),
                  Expanded(
                    child: SelectableText(
                      b.text.isEmpty ? '工具调用' : b.text,
                      maxLines: 2,
                      style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                          color: scheme.onSurfaceVariant),
                    ),
                  ),
                  if (hasDetail)
                    Icon(
                      _open
                          ? Icons.expand_less_rounded
                          : Icons.expand_more_rounded,
                      size: 16,
                      color: scheme.outline,
                    ),
                ],
              ),
            ),
          ),
          if (_open && hasDetail)
            Container(
              width: double.infinity,
              constraints: const BoxConstraints(maxHeight: 240),
              margin: const EdgeInsets.fromLTRB(8, 0, 8, 8),
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: const Color(0xFF1E1E2E),
                borderRadius: BorderRadius.circular(6),
              ),
              child: SingleChildScrollView(
                child: SelectableText(
                  b.toolDetail!,
                  style: const TextStyle(
                      fontFamily: 'Consolas, monospace',
                      fontSize: 11,
                      color: Color(0xFFD6D6D6)),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 思考过程卡片（F3-5）：默认折叠，展开显示模型 reasoning 全文。
class _ReasoningCard extends StatefulWidget {
  const _ReasoningCard({required this.block});

  final ChatBlock block;

  @override
  State<_ReasoningCard> createState() => _ReasoningCardState();
}

class _ReasoningCardState extends State<_ReasoningCard> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(vertical: 2),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: () => setState(() => _open = !_open),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              child: Row(
                children: [
                  Icon(Icons.psychology_outlined, size: 14, color: scheme.outline),
                  const SizedBox(width: 6),
                  Text('思考过程',
                      style: TextStyle(
                          fontSize: 12,
                          color: scheme.outline,
                          fontStyle: FontStyle.italic)),
                  const Spacer(),
                  Icon(
                    _open
                        ? Icons.expand_less_rounded
                        : Icons.expand_more_rounded,
                    size: 16,
                    color: scheme.outline,
                  ),
                ],
              ),
            ),
          ),
          if (_open)
            Container(
              width: double.infinity,
              constraints: const BoxConstraints(maxHeight: 280),
              margin: const EdgeInsets.fromLTRB(8, 0, 8, 8),
              padding: const EdgeInsets.all(8),
              child: SingleChildScrollView(
                child: SelectableText(
                  widget.block.text,
                  style: TextStyle(
                      fontSize: 12,
                      height: 1.4,
                      color: scheme.onSurfaceVariant,
                      fontStyle: FontStyle.italic),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
