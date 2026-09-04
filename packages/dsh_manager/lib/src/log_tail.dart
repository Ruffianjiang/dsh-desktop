/// 实例日志：环形缓冲 + 文件双写（F2 Gate-B v1.0 §6）。
library;

import 'dart:collection';
import 'dart:io';

/// 按实例采集 stdout/stderr：
/// - 进程输出按 chunk 到达可能切断行，内部行缓冲凑整行后再入环/落盘；
/// - 每行带时间戳前缀（Gate-B §4.4.2），stderr 行追加 `[stderr] ` 标记；
/// - 文件为完整日志（追加写，跨重启保留），环形缓冲仅保留最近 [capacity] 行；
/// - 文件写入用同步 `RandomAccessFile`（追加模式）——IOSink.flush 在
///   退出回调/dispose 交错场景会抛 `StreamSink is bound to a stream`（实测）。
class LogTail {
  LogTail({this.capacity = 2000, required File logFile}) : _logFile = logFile {
    logFile.parent.createSync(recursive: true);
    _raf = logFile.openSync(mode: FileMode.append);
  }

  final int capacity;
  final File _logFile;
  RandomAccessFile? _raf;
  final ListQueue<String> _ring = ListQueue<String>();
  String _pending = '';

  /// 完整日志文件路径（[export] 缺省返回值）。
  String get filePath => _logFile.path;

  static String _ts(DateTime t) {
    String two(int v) => v.toString().padLeft(2, '0');
    String three(int v) => v.toString().padLeft(3, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)} '
        '${two(t.hour)}:${two(t.minute)}:${two(t.second)}.${three(t.millisecond)}';
  }

  /// 喂入一个输出 chunk（stdout/stderr 各自调用）。
  void handleChunk(String chunk, {required bool stderr}) {
    final parts = (_pending + chunk).split('\n');
    _pending = parts.removeLast(); // 尾段无换行，留待下一 chunk
    for (final line in parts) {
      _commitLine(line, stderr: stderr);
    }
  }

  void _commitLine(String raw, {required bool stderr}) {
    final line = raw.endsWith('\r') ? raw.substring(0, raw.length - 1) : raw;
    final stamped = '${_ts(DateTime.now())} ${stderr ? '[stderr] ' : ''}$line';
    _ring.addLast(stamped);
    while (_ring.length > capacity) {
      _ring.removeFirst();
    }
    try {
      _raf?.writeStringSync('$stamped\n');
    } catch (_) {
      // 文件句柄异常不阻断守护主流程（环形缓冲仍在）。
    }
  }

  /// 最近 [lines] 行（lines<=0 返回空；超出容量返回现有全部）。
  List<String> tail(int lines) {
    if (lines <= 0 || _ring.isEmpty) return const <String>[];
    final skip = _ring.length - lines;
    if (skip <= 0) return _ring.toList(growable: false);
    return _ring.skip(skip).toList(growable: false);
  }

  /// 导出日志：缺省返回完整文件路径；给 [path] 则复制一份并返回新路径。
  String export([String? path]) {
    if (path == null || path == _logFile.path) return _logFile.path;
    final target = File(path);
    target.parent.createSync(recursive: true);
    flushSync();
    _logFile.copySync(target.path);
    return target.path;
  }

  /// 刷盘（同步；进程退出后调用保证 tail 文件不丢尾）。
  void flushSync() => _raf?.flushSync();

  /// 兼容异步调用点（内部同步刷盘）。
  Future<void> flush() async => flushSync();

  /// 关闭文件句柄（dispose 语义；此后本对象不再可用）。
  Future<void> close() async {
    final r = _raf;
    _raf = null;
    if (r != null) {
      r.flushSync();
      r.closeSync();
    }
  }
}
