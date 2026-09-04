/// dsh L3 协议信封类型（契约 v0.1，见 packages/contract/schema/api-v0.1.md）。
///
/// 请求信封（client → server）：
///   `{ "type":"client-request", "rpcId":"<uuid>", "method":"session.list", "payload":{} }`
/// 响应信封（server → client）：
///   `{ "type":"server-response", "rpcId":"<uuid>", "result":{ "ok":true, "value":{...} } }`
///   ok=false 时：`result = { "ok":false, "error":{ "code","message","details"? } }`
/// SSE 帧信封（server → client）：`{ "type":"server-request", "rpcId":"<uuid>", "method":"…", "payload":{…} }`
library;

/// RPC 错误（`result.ok == false` 时存在）。
class RpcError {
  const RpcError({required this.code, required this.message, this.details});

  factory RpcError.parse(Object? json) {
    final m = (json is Map) ? json.cast<String, dynamic>() : const <String, dynamic>{};
    return RpcError(
      code: (m['code'] ?? '').toString(),
      message: (m['message'] ?? '').toString(),
      details: m['details'],
    );
  }

  final String code;
  final String message;
  final Object? details;

  @override
  String toString() => 'RpcError($code: $message)';
}

/// `server-response` 信封解析结果。
class ServerResponse {
  const ServerResponse({
    required this.type,
    required this.rpcId,
    required this.ok,
    this.value,
    this.error,
  });

  factory ServerResponse.parse(Object? json) {
    final m = (json is Map) ? json.cast<String, dynamic>() : const <String, dynamic>{};
    final result = (m['result'] is Map) ? (m['result'] as Map).cast<String, dynamic>() : const <String, dynamic>{};
    final ok = result['ok'] == true;
    return ServerResponse(
      type: (m['type'] ?? '').toString(),
      rpcId: (m['rpcId'] ?? '').toString(),
      ok: ok,
      value: ok ? _mapOrNull(result['value']) : null,
      error: ok ? null : RpcError.parse(result['error']),
    );
  }

  final String type;
  final String rpcId;
  final bool ok;
  final Map<String, dynamic>? value;
  final RpcError? error;

  static Map<String, dynamic>? _mapOrNull(Object? v) =>
      (v is Map) ? v.cast<String, dynamic>() : null;
}

/// `server-request` 信封（SSE 下行帧的传输层）。
class ServerRequestFrame {
  const ServerRequestFrame({
    required this.type,
    required this.rpcId,
    required this.method,
    required this.payload,
  });

  factory ServerRequestFrame.parse(Object? json) {
    final m = (json is Map) ? json.cast<String, dynamic>() : const <String, dynamic>{};
    return ServerRequestFrame(
      type: (m['type'] ?? '').toString(),
      rpcId: (m['rpcId'] ?? '').toString(),
      method: (m['method'] ?? '').toString(),
      payload: (m['payload'] is Map) ? (m['payload'] as Map).cast<String, dynamic>() : const <String, dynamic>{},
    );
  }

  final String type;
  final String rpcId;
  final String method;
  final Map<String, dynamic> payload;
}
