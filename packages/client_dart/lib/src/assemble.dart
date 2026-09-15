/// 会话事件 → UI 消息模型聚合器（M3 Gate-B v1.0 §4）。
///
/// 纯 Dart、无 UI 依赖：history 装载与 WS 直播增量共用同一规则（T3）。
/// 事件形态以契约 v0.1 golden（session.history.response.json 实测）为准：
/// 每个事件 `{type, seq, time, data}`。
library;

enum ChatRole { user, assistant }

enum MessageStatus { streaming, done }

enum ChatBlockType { text, code, reasoning, toolCall, unknown }

/// 消息内容块（与 assistant/chunk 的 index 对应）。
class ChatBlock {
  ChatBlock({
    required this.index,
    this.type = ChatBlockType.text,
    this.text = '',
    this.closed = false,
    this.toolCallId,
    this.toolKind,
    this.toolDetail,
  });

  final int index;
  final ChatBlockType type;
  String text;
  bool closed;

  /// 工具块（type == toolCall）扩展字段（T9 修正 F3-5，实机帧结构实证）：
  /// [toolCallId] 关联 call/result；[toolKind] 类别（search/read/edit/…）；
  /// [toolDetail] 可展开正文（调用参数 / 结果文本）。[text] 为标题行。
  String? toolCallId;
  String? toolKind;
  String? toolDetail;
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

  /// 计时（F3-7 token 速率）：startedAt=step/start（权威替换时沿用）；
  /// finishedAt=finish chunk / 权威替换 / step/end。
  DateTime? startedAt;
  DateTime? finishedAt;

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

  /// 工具轨迹（T9 修正 F3-5；帧结构 probe 实证 2026-09-09）：
  /// call 帧 `data={callId,name,arguments}` + `view.view={card,title,kind,rawInput}`；
  /// result 帧 `data.message.source.callId` + `data.message.content[].content[].text`，
  /// `view.view={card,shape,paths[],truncated,total}`。
  /// 聚合规则：按 [ChatBlock.toolCallId] 把 result 归并进 call 块——
  /// text=标题行（view.title 优先），toolDetail=可展开正文。
  void _applyToolEvent(ChatState state, Map<String, dynamic>? data,
      String kind, Map<String, dynamic>? view) {
    if (data == null) return;
    final turn = _i(data, 'turn');
    final step = _i(data, 'step');
    var msg = state._open['$turn/$step'];
    // 工具事件可能先于任何 step/start（或 step 已收尾）：落到**最近一条**
    // assistant（seq74/75 的 tool 事件晚于 assistant/message 的权威替换，
    // 此时 open 已移除、messages 尾部可能是 user——必须反向搜索）。
    if (msg == null) {
      for (final candidate in state.messages.reversed) {
        if (candidate.role == ChatRole.assistant) {
          msg = candidate;
          break;
        }
      }
    }
    if (msg == null) return;
    final v = (view?['view'] as Map?)?.cast<String, dynamic>();

    String? callId;
    String title;
    String? toolKind;
    String? detail;
    if (kind == 'call') {
      callId = _s(data, 'callId');
      final t1 = _s(v, 'title');
      final t2 = _s(data, 'name');
      title = (t1 != null && t1.isNotEmpty) ? t1 : (t2 ?? '工具调用');
      toolKind = _s(v, 'kind');
      detail = _s(v, 'rawInput') ?? _s(data, 'arguments');
    } else {
      final message = (data['message'] as Map?)?.cast<String, dynamic>();
      final source = (message?['source'] as Map?)?.cast<String, dynamic>();
      callId = _s(source, 'callId');
      toolKind = _s(v, 'kind');
      title = '结果';
      detail = _resultText(message, v);
    }

    // 按 callId 归并：result 并入已存在的 call 块
    ChatBlock? block;
    for (final b in msg.blocks) {
      if (b.toolCallId != null && b.toolCallId == callId) {
        block = b;
        break;
      }
    }
    final detailText = (detail == null || detail.isEmpty) ? null : detail;
    if (block == null) {
      msg.blocks.add(ChatBlock(
        // 负索引：与 chunk 的非负 index 空间隔离，防 text-delta 查块串扰
        index: -(msg.blocks.length + 1),
        type: ChatBlockType.toolCall,
        text: title,
        closed: true,
        toolCallId: callId,
        toolKind: toolKind,
        toolDetail: detailText,
      ));
    } else if (kind == 'result') {
      if (detailText != null) block.toolDetail = detailText;
    } else {
      block.text = title;
      block.toolKind = toolKind ?? block.toolKind;
      block.toolDetail ??= detailText;
    }
  }

  /// result 正文：优先 `message.content[].content[].text`；fallback
  /// `view.shape == 'paths'`（路径清单）。超长截断（>12000 字符）。
  String? _resultText(Map<String, dynamic>? message, Map<String, dynamic>? v) {
    final buf = StringBuffer();
    final content = message?['content'];
    if (content is List) {
      for (final c in content) {
        if (c is! Map) continue;
        final inner = c['content'];
        if (inner is List) {
          for (final t in inner) {
            if (t is Map && t['type'] == 'text') {
              buf.writeln(t['text']?.toString() ?? '');
            }
          }
        }
      }
    }
    var text = buf.toString().trim();
    if (text.isEmpty && v != null && v['shape'] == 'paths') {
      final paths = v['paths'];
      if (paths is List) {
        text = paths.take(200).map((p) => p.toString()).join('\n');
        if (v['truncated'] == true) {
          text += '\n…（共 ${v['total'] ?? paths.length} 条，已截断）';
        }
      }
    }
    if (text.length > 12000) {
      text = '${text.substring(0, 12000)}\n…（内容过长已截断）';
    }
    return text.isEmpty ? null : text;
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
    )..startedAt = DateTime.now();
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
          type: switch (bt) {
            'text' => ChatBlockType.text,
            'code' => ChatBlockType.code,
            'reasoning' => ChatBlockType.reasoning,
            'tool-call' => ChatBlockType.toolCall,
            _ => ChatBlockType.unknown,
          },
        ));
      case 'text-delta' || 'reasoning-delta':
        // 正文与思考同为增量文本（reasoning-delta 实机帧结构 2026-09-09）
        final index = _i(chunk, 'index') ?? 0;
        final b = _block(msg, index);
        b.text += _s(chunk, 'text') ?? '';
      case 'tool-call-delta':
        // 流式工具调用：{index,id,name,argumentsDelta}
        final index = _i(chunk, 'index') ?? 0;
        final b = _block(msg, index);
        final id = _s(chunk, 'id');
        if (id != null && b.toolCallId == null) b.toolCallId = id;
        final name = _s(chunk, 'name');
        if (name != null &&
            name.isNotEmpty &&
            (b.text.isEmpty || b.text == '工具调用')) {
          b.text = name;
        }
        final delta = _s(chunk, 'argumentsDelta');
        if (delta != null && delta.isNotEmpty) {
          b.toolDetail = (b.toolDetail ?? '') + delta;
        }
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
        msg.finishedAt ??= DateTime.now();
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
      // F3-7：计时沿用 open（startedAt=step/start 时刻，速率分母才真实）
      m.startedAt = open.startedAt;
      m.finishedAt = DateTime.now();
      // T9 修正 F3-5：权威 content 只含文本块——chunk 阶段累积的工具卡
      // （call/result 聚合）不在其中，必须显式携带，否则最终消息丢工具轨迹。
      for (final b in open.blocks) {
        if (b.type == ChatBlockType.toolCall) m.blocks.add(b);
      }
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
        if (c is! Map) continue;
        final cm = c.cast<String, dynamic>();
        final t = _s(cm, 'type');
        if (t == 'text') {
          m.blocks.add(ChatBlock(
            index: i++,
            text: _s(cm, 'text') ?? '',
            closed: true,
          ));
        } else if (t == 'reasoning') {
          // 思考过程（实机帧结构实证：content 含完整 reasoning 文本）
          final rt = _s(cm, 'text') ?? '';
          if (rt.isNotEmpty) {
            m.blocks.add(ChatBlock(
              index: i++,
              type: ChatBlockType.reasoning,
              text: rt,
              closed: true,
            ));
          }
        } else if (t == 'tool-call') {
          // 权威工具卡（与 tool/call 事件按 callId 去重；title 由 view 补充）
          final cid = _s(cm, 'id');
          final exists =
              m.blocks.any((b) => b.toolCallId != null && b.toolCallId == cid);
          if (!exists) {
            m.blocks.add(ChatBlock(
              index: i++,
              type: ChatBlockType.toolCall,
              text: _s(cm, 'name') ?? '工具调用',
              closed: true,
              toolCallId: cid,
              toolDetail: _s(cm, 'arguments'),
            ));
          }
        }
      }
    }
  }

  void _closeStep(ChatState state, int? turn, int? step) {
    if (turn == null || step == null) return;
    final m = state._open.remove('$turn/$step');
    if (m != null) {
      m.status = MessageStatus.done;
      m.finishedAt ??= DateTime.now();
    }
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
