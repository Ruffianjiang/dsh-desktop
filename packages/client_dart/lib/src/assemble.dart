/// 会话事件 → UI 消息模型聚合器（M3 Gate-B v1.0 §4）。
///
/// 纯 Dart、无 UI 依赖：history 装载与 WS 直播增量共用同一规则（T3）。
/// 事件形态以契约 v0.1 golden（session.history.response.json 实测）为准：
/// 每个事件 `{type, seq, time, data}`。
library;

enum ChatRole { user, assistant }

enum MessageStatus { streaming, done }

enum ChatBlockType { text, code, toolCall, unknown }

/// 消息内容块（与 assistant/chunk 的 index 对应）。
class ChatBlock {
  ChatBlock({
    required this.index,
    this.type = ChatBlockType.text,
    this.text = '',
    this.closed = false,
  });

  final int index;
  final ChatBlockType type;
  String text;
  bool closed;
}

/// UI 消息模型。
class ChatMessage {
  ChatMessage({
    required this.id,
    required this.role,
    required this.status,
    this.turn,
    this.step,
    this.seq,
  });

  final String id;
  final ChatRole role;
  final List<ChatBlock> blocks = [];
  MessageStatus status;
  final int? turn;
  final int? step;
  final int? seq;
  Map<String, dynamic>? usage;

  /// 全部文本块拼接（渲染层按 block 细分，此处用于断言/降级展示）。
  String get plainText =>
      blocks.where((b) => b.type == ChatBlockType.text).map((b) => b.text).join();
}

/// 聚合状态（消息列表 + 游标 + 开放中的 assistant 占位）。
class ChatState {
  final List<ChatMessage> messages = [];
  int? lastSeq;

  /// turn/step → 当前流式中的 assistant 消息。
  final Map<String, ChatMessage> _open = <String, ChatMessage>{};
}

/// 聚合器：无状态入口 + 可复用的增量应用。
class ChatAssembler {
  /// history 装载：按序应用全部条目。
  /// 条目为 `session.history` 的 `{event, view?}` 原始形态（也兼容裸 event）。
  ChatState applyAll(List<Map<String, dynamic>> entries) {
    final state = ChatState();
    for (final e in entries) {
      final event = (e['event'] as Map?)?.cast<String, dynamic>() ?? e;
      final view = (e['view'] as Map?)?.cast<String, dynamic>();
      applyEvent(state, event, view: view);
    }
    return state;
  }

  /// 单事件应用（history 事件与 WS `session/event` 的 `event` 同构）。
  /// [view] 为 host 附带的工具轨迹视图（history 条目 `view` /
  /// mux 帧 `view`，`{for:'call'|'result', view:{card}}`——契约 v0.2 实证）。
  ChatState applyEvent(
      ChatState state, Map<String, dynamic> event,
      {Map<String, dynamic>? view}) {
    final type = _s(event, 'type');
    final seq = _i(event, 'seq');
    if (seq != null && (state.lastSeq == null || seq > state.lastSeq!)) {
      state.lastSeq = seq;
    }

    final data = (event['data'] as Map?)?.cast<String, dynamic>();
    switch (type) {
      case 'user/message':
        _applyUserMessage(state, data, seq);
      case 'step/start':
        _openAssistant(state, _i(data, 'turn'), _i(data, 'step'), seq);
      case 'assistant/chunk':
        _applyChunk(state, data);
      case 'assistant/message':
        _applyAssistantMessage(state, data, seq);
      case 'step/end':
        _closeStep(state, _i(data, 'turn'), _i(data, 'step'));
      case 'tool/call':
      case 'tool/result':
        _applyToolEvent(state, data, type == 'tool/call' ? 'call' : 'result',
            view);
      case 'turn/start':
      case 'turn/end':
      case 'session/title':
      case 'session/title-llm-request':
      case 'permission/preset':
      case 'sandbox/mode':
      case 'approval/policy':
      case 'agent/inbox/spliced':
      case 'request/header':
      case 'request/context':
        break; // 非消息事件：不进消息流（审批经 approvalProvider 单独处理）
      default:
        break; // 未知类型静默跳过（dsh rc 版可能新增）
    }
    return state;
  }

  /// 工具轨迹：host 附带 `view.card` 字符串为展示主体（M3 Gate-B §4.5）。
  void _applyToolEvent(ChatState state, Map<String, dynamic>? data,
      String kind, Map<String, dynamic>? view) {
    if (data == null) return;
    final turn = _i(data, 'turn');
    final step = _i(data, 'step');
    var msg = state._open['$turn/$step'];
    // 工具事件可能先于任何 step/start（或 step 已收尾）：落到最近一条 assistant
    if (msg == null && state.messages.isNotEmpty) {
      final last = state.messages.last;
      if (last.role == ChatRole.assistant) msg = last;
    }
    if (msg == null) return;
    final card = ((view?['view'] as Map?)?['card'] ?? '').toString();
    final label = kind == 'call' ? '调用' : '结果';
    msg.blocks.add(ChatBlock(
      // 负索引：与 chunk 的非负 index 空间隔离，防 text-delta 查块串扰
      index: -(msg.blocks.length + 1),
      type: ChatBlockType.toolCall,
      text: card.isEmpty ? '［工具$label］' : '[$label] $card',
      closed: true,
    ));
  }

  void _applyUserMessage(
      ChatState state, Map<String, dynamic>? data, int? seq) {
    if (data == null) return;
    final id = _s(data, 'id') ?? 'user-$seq';
    final text = _contentText(data['content']);
    final msg = ChatMessage(
      id: id,
      role: ChatRole.user,
      status: MessageStatus.done,
      seq: seq,
    )..blocks.add(ChatBlock(
        index: 0,
        text: text,
        closed: true,
      ));
    final existing = state.messages.indexWhere((m) => m.id == id);
    if (existing >= 0) {
      // 同 id 重复投递（如 agent/inbox/spliced）：原位替换
      state.messages[existing] = msg;
    } else {
      state.messages.add(msg);
    }
  }

  void _openAssistant(ChatState state, int? turn, int? step, int? seq) {
    if (turn == null || step == null) return;
    final key = '$turn/$step';
    if (state._open.containsKey(key)) return;
    final m = ChatMessage(
      id: 'assistant-$key',
      role: ChatRole.assistant,
      status: MessageStatus.streaming,
      turn: turn,
      step: step,
      seq: seq,
    );
    state._open[key] = m;
    state.messages.add(m);
  }

  void _applyChunk(ChatState state, Map<String, dynamic>? data) {
    if (data == null) return;
    final turn = _i(data, 'turn');
    final step = _i(data, 'step');
    final msg = state._open['$turn/$step'];
    if (msg == null) return;
    final chunk = (data['chunk'] as Map?)?.cast<String, dynamic>();
    if (chunk == null) return;
    switch (_s(chunk, 'type')) {
      case 'block-start':
        final index = _i(chunk, 'index') ?? msg.blocks.length;
        if (msg.blocks.indexWhere((b) => b.index == index) >= 0) return;
        final bt = _s(chunk, 'blockType');
        msg.blocks.add(ChatBlock(
          index: index,
          type: bt == 'text'
              ? ChatBlockType.text
              : bt == 'code'
                  ? ChatBlockType.code
                  : ChatBlockType.unknown,
        ));
      case 'text-delta':
        final index = _i(chunk, 'index') ?? 0;
        final b = _block(msg, index);
        b.text += _s(chunk, 'text') ?? '';
      case 'block-end':
        final index = _i(chunk, 'index') ?? 0;
        final b = _block(msg, index);
        final full = (chunk['block'] as Map?)?['text'];
        if (full is String) b.text = full; // 权威全量，防增量漂移
        b.closed = true;
      case 'usage':
        msg.usage = chunk;
      case 'finish':
        msg.status = MessageStatus.done;
    }
  }

  /// `assistant/message` 为权威落定：整条替换该 step 的消息。
  void _applyAssistantMessage(
      ChatState state, Map<String, dynamic>? data, int? seq) {
    if (data == null) return;
    final turn = _i(data, 'turn');
    final step = _i(data, 'step');
    final key = '$turn/$step';
    final message = (data['message'] as Map?)?.cast<String, dynamic>();
    if (message == null) return;
    final id = _s(message, 'id') ?? 'assistant-$key';

    ChatMessage m;
    final open = state._open.remove(key);
    if (open != null) {
      final idx = state.messages.indexOf(open);
      m = ChatMessage(
        id: id,
        role: ChatRole.assistant,
        status: MessageStatus.done,
        turn: turn,
        step: step,
        seq: seq,
      )..usage = open.usage;
      if (idx >= 0) {
        state.messages[idx] = m;
      } else {
        state.messages.add(m);
      }
    } else {
      m = ChatMessage(
        id: id,
        role: ChatRole.assistant,
        status: MessageStatus.done,
        turn: turn,
        step: step,
        seq: seq,
      );
      state.messages.add(m);
    }
    final content = message['content'];
    if (content is List) {
      var i = 0;
      for (final c in content) {
        if (c is Map) {
          final cm = c.cast<String, dynamic>();
          if (_s(cm, 'type') == 'text') {
            m.blocks.add(ChatBlock(
              index: i++,
              text: _s(cm, 'text') ?? '',
              closed: true,
            ));
          }
        }
      }
    }
  }

  void _closeStep(ChatState state, int? turn, int? step) {
    if (turn == null || step == null) return;
    final m = state._open.remove('$turn/$step');
    if (m != null) m.status = MessageStatus.done;
  }

  ChatBlock _block(ChatMessage msg, int index) {
    final found = msg.blocks.indexWhere((b) => b.index == index);
    if (found >= 0) return msg.blocks[found];
    final b = ChatBlock(index: index);
    msg.blocks.add(b);
    return b;
  }

  // ---- 工具 ----
  static String? _s(Map<String, dynamic>? m, String key) =>
      m?[key]?.toString();

  static int? _i(Map<String, dynamic>? m, String key) =>
      (m?[key] as num?)?.toInt();

  static String _contentText(Object? content) {
    if (content is! List) return '';
    final buf = StringBuffer();
    for (final c in content) {
      if (c is Map && _s(c.cast<String, dynamic>(), 'type') == 'text') {
        buf.write(_s(c.cast<String, dynamic>(), 'text') ?? '');
      }
    }
    return buf.toString();
  }
}
