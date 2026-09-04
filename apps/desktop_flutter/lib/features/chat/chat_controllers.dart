import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';

/// 会话元数据（session.list + WS `session/projection` 增量维护）。
class SessionMeta {
  SessionMeta({required this.sessionId, this.title = '（未命名）'});

  final String sessionId;
  String title;
  bool running = false;

  /// 投影快照（title/sessionStats/contextPressure…，key→value）。
  final Map<String, dynamic> projections = {};
}

/// 会话列表控制器：跟随 L3 连接拉取 + 增量维护（M3 Gate-B §5.3 会话列表）。
class SessionsController extends Notifier<List<SessionMeta>> {
  final Map<String, SessionMeta> _byId = {};

  @override
  List<SessionMeta> build() {
    ref.listen(connectionEventsProvider, (_, next) {
      next.whenData(_onFrame);
    });
    ref.listen(connPhaseStreamProvider, (_, next) {
      next.whenData((phase) {
        if (phase == ConnPhase.streaming) Future.microtask(refresh);
      });
    });
    return const [];
  }

  /// 拉取会话列表（保留已知的投影/标题）。
  Future<void> refresh() async {
    final conn = ref.read(connectionProvider);
    if (conn == null) return;
    try {
      final r = await conn.sessionApi.list();
      final items = (r?['items'] as List?) ?? const [];
      final result = <SessionMeta>[];
      for (final it in items) {
        if (it is! Map) continue;
        final sid = it['sessionId']?.toString() ?? '';
        if (sid.isEmpty) continue;
        final meta =
            _byId.putIfAbsent(sid, () => SessionMeta(sessionId: sid));
        meta.running = it['running'] == true;
        final pj = it['projections'];
        if (pj is Map) {
          for (final e in pj.entries) {
            meta.projections[e.key.toString()] = e.value;
            if (e.key == 'title' && e.value != null) {
              meta.title = e.value.toString();
            }
          }
        }
        result.add(meta);
      }
      state = List.unmodifiable(result);
      _ensureSelection(result);
    } catch (_) {
      // 刷新失败静默（事件流会再次触发）；list 为只读操作无副作用
    }
  }

  void _ensureSelection(List<SessionMeta> items) {
    final sel = ref.read(selectedSessionProvider);
    if ((sel == null || !items.any((m) => m.sessionId == sel)) &&
        items.isNotEmpty) {
      ref.read(selectedSessionProvider.notifier).select(items.first.sessionId);
    }
  }

  void _onFrame(ServerRequestFrame frame) {
    final payload = frame.payload;
    switch (payload['type']) {
      case 'session/subscribed':
        Future.microtask(refresh);
      case 'session/projection':
        final sid = payload['sessionId']?.toString() ?? '';
        final key = payload['key']?.toString() ?? '';
        final value = payload['value'];
        final meta = _byId[sid];
        if (meta == null) {
          Future.microtask(refresh);
          return;
        }
        meta.projections[key] = value;
        if (key == 'title' && value != null) meta.title = value.toString();
        if (key == 'running') meta.running = value == true;
        state = List.unmodifiable(state);
      case 'session/event':
        final event = payload['event'];
        if (event is Map && event['type'] == 'session/title') {
          final sid = payload['sessionId']?.toString() ?? '';
          final data = event['data'];
          final title =
              data is Map ? data['title']?.toString() : null;
          final meta = _byId[sid];
          if (meta != null && title != null && title.isNotEmpty) {
            meta.title = title;
            state = List.unmodifiable(state);
          }
        }
    }
  }

  /// 新建会话并选中。
  Future<String?> createSession() async {
    final conn = ref.read(connectionProvider);
    if (conn == null) return null;
    final r = await conn.sessionApi.create();
    final sid = r?['sessionId']?.toString();
    if (sid != null && sid.isNotEmpty) {
      _byId[sid] = SessionMeta(sessionId: sid);
      await refresh();
      ref.read(selectedSessionProvider.notifier).select(sid);
    }
    return sid;
  }
}

/// 当前选中的会话（对话工作台右侧消息流展示目标）。
class SelectedSession extends Notifier<String?> {
  @override
  String? build() => null;

  void select(String id) => state = id;
}

final selectedSessionProvider =
    NotifierProvider<SelectedSession, String?>(SelectedSession.new);

final sessionsProvider =
    NotifierProvider<SessionsController, List<SessionMeta>>(
        SessionsController.new);

/// 对话视图控制器（family per sessionId）：
/// history 装载 + WS 直播增量（经 ChatAssembler）+ send/steer/cancel。
///
/// Riverpod 3.4 family 写法：类继承 `Notifier<State>`，arg 经构造函数传入，
/// provider 用 ChatController.new tear-off（匹配 NotifierT Function(ArgT)）。
class ChatController extends Notifier<List<ChatMessage>> {
  ChatController(this.sessionId);

  /// 目标会话 id（family arg）。
  final String sessionId;

  late ChatState _internal = ChatState();
  bool _historyLoaded = false;

  @override
  List<ChatMessage> build() {
    _internal = ChatState();
    _historyLoaded = false;
    ref.listen(connectionEventsProvider, (_, next) {
      next.whenData(_onFrame);
    });
    ref.listen(connPhaseStreamProvider, (_, next) {
      next.whenData((phase) {
        if (phase == ConnPhase.streaming && !_historyLoaded) {
          Future.microtask(() => _loadHistory());
        }
      });
    });
    // 晚进入会话（连接已 streaming）时立即装载。
    if (ref.read(connPhaseStreamProvider).value == ConnPhase.streaming &&
        !_historyLoaded) {
      Future.microtask(() => _loadHistory());
    }
    return const [];
  }

  /// 当前是否还有流式中的消息（控制 cancel 按钮与发送节流）。
  bool get isStreaming => state.any((m) => m.status == MessageStatus.streaming);

  Future<void> _loadHistory() async {
    if (_historyLoaded) return;
    _historyLoaded = true;
    final conn = ref.read(connectionProvider);
    if (conn == null) return;
    try {
      final r = await conn.sessionApi.history(sessionId, maxMessages: 500);
      final events = ((r?['events'] as List?) ?? const [])
          .map<Map<String, dynamic>>(
              (e) => (e['event'] as Map).cast<String, dynamic>())
          .toList();
      _internal = ChatAssembler().applyAll(events);
      state = List.unmodifiable(_internal.messages);
    } catch (_) {
      // history 失败不阻塞直播（live 帧仍会增量应用）
    }
  }

  void _onFrame(ServerRequestFrame frame) {
    final payload = frame.payload;
    if (payload['type'] == 'session/subscribed') {
      // 重连后基线比对：服务端 lastSeq 超前 → 重新拉 history 补缺口。
      final items = payload['items'];
      if (items is List && _historyLoaded) {
        for (final it in items) {
          if (it is Map && it['sessionId']?.toString() == sessionId) {
            final serverSeq = (it['lastSeq'] as num?)?.toInt() ?? 0;
            if (serverSeq > (_internal.lastSeq ?? 0)) {
              _historyLoaded = false;
              Future.microtask(() => _loadHistory());
            }
          }
        }
      }
      return;
    }
    if (payload['type'] != 'session/event') return;
    if (payload['sessionId']?.toString() != sessionId) return;
    final event = payload['event'];
    if (event is! Map) return;
    ChatAssembler().applyEvent(_internal, event.cast<String, dynamic>());
    state = List.unmodifiable(_internal.messages);
  }

  /// 发送消息（mode: queue 常规 / steer 插话）。
  Future<void> send(String text, {bool steer = false}) async {
    final body = text.trim();
    if (body.isEmpty) return;
    final conn = ref.read(connectionProvider);
    if (conn == null) return;
    await conn.sessionApi.prompt(sessionId, body, mode: steer ? 'steer' : 'queue');
  }

  /// 取消当前 run。
  Future<void> cancel() async {
    final conn = ref.read(connectionProvider);
    if (conn == null) return;
    await conn.sessionApi.cancel(sessionId);
  }
}

final chatControllerProvider = NotifierProvider.family<ChatController,
    List<ChatMessage>, String>(ChatController.new);
