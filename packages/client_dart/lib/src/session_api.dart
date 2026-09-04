import 'rpc_client.dart';

/// session.* 方法薄封装（契约 v0.1 实测子集）。
/// value 以 Map 返回，字段随服务端响应宽放；严格类型化在契约定稿后补充。
class SessionApi {
  SessionApi(this._client);

  final DshClient _client;

  /// payload: {} → value: { items: [ SessionMeta ] }
  Future<Map<String, dynamic>?> list() =>
      _client.call('session.list', {});

  /// payload: { agentPreset? } → value: { sessionId, agentPreset }
  Future<Map<String, dynamic>?> create({String? agentPreset}) =>
      _client.call('session.create', {if (agentPreset != null) 'agentPreset': agentPreset});

  /// payload: { sessionId, beforeSeq?, maxMessages? } → value: { events:[{event}] }
  Future<Map<String, dynamic>?> history(String sessionId,
          {int? beforeSeq, int? maxMessages}) =>
      _client.call('session.history', {
        'sessionId': sessionId,
        if (beforeSeq != null) 'beforeSeq': beforeSeq,
        if (maxMessages != null) 'maxMessages': maxMessages,
      });

  /// payload: { sessionId, mode, content:[{type:"text",text}] } → value: { accepted:true }
  Future<Map<String, dynamic>?> prompt(String sessionId, String text,
          {String mode = 'queue'}) =>
      _client.call('session.prompt', {
        'sessionId': sessionId,
        'mode': mode,
        'content': [
          {'type': 'text', 'text': text}
        ],
      });

  /// payload: { sessionId } → 取消当前 run（源码会话方法，契约 v0.1 未实测）
  Future<Map<String, dynamic>?> cancel(String sessionId) =>
      _client.call('session.cancel', {'sessionId': sessionId});

  /// 审批 / ask-user 回写（契约 v0.2：method 名与 payload 以 T2 抓包定型）。
  Future<Map<String, dynamic>?> respond(Map<String, dynamic> payload) =>
      _client.call('respond', payload);

  /// 模型只读列表（settings 页；method 名以 T2 抓包定型）。
  Future<Map<String, dynamic>?> models() => _client.call('llm.models', {});
}
