import 'dart:async';
import 'dart:convert';

/// SSE 流解析：把字节流按 `\n\n` 分帧，取每帧 `data: ` 前缀行拼接后 JSON 解码。
///
/// 对齐 dsh 下行（streaming fetch，非 EventSource）：帧之间空行分隔；
/// 单帧允许多个 `data:` 行（拼接）。畸形帧跳过不中断（与参考客户端一致）。
Stream<Map<String, dynamic>> parseSse(Stream<List<int>> bytes) async* {
  final decoder = utf8.decoder;
  var buffer = '';
  await for (final chunk in bytes) {
    buffer += decoder.convert(chunk);
    var boundary = buffer.indexOf('\n\n');
    while (boundary != -1) {
      final block = buffer.substring(0, boundary);
      buffer = buffer.substring(boundary + 2);
      final data = block
          .split('\n')
          .where((line) => line.startsWith('data: '))
          .map((line) => line.substring('data: '.length))
          .join();
      if (data.isEmpty) {
        boundary = buffer.indexOf('\n\n');
        continue;
      }
      try {
        final decoded = jsonDecode(data);
        if (decoded is Map) {
          yield decoded.cast<String, dynamic>();
        }
      } catch (_) {
        // 丢弃畸形帧，不中断流。
      }
      boundary = buffer.indexOf('\n\n');
    }
  }
  // 尾部残余无空行分隔者丢弃（等待更多数据或流结束）。
}
