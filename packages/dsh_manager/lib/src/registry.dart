import 'dart:convert';
import 'dart:io';

import 'models.dart';

/// 实例配置注册表（持久化，Gate-B §4.3 RegistryStore）。
class RegistryStore {
  RegistryStore([String? path])
      : _file = File(path ??
            '${Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'] ?? '.'}'
            '${Platform.pathSeparator}.dsh-desktop${Platform.pathSeparator}instances.json');

  final File _file;

  static const _schemaVersion = 1;

  List<InstanceConfig> load() {
    if (!_file.existsSync()) return [];
    try {
      final j = jsonDecode(_file.readAsStringSync()) as Map<String, dynamic>;
      final items = (j['instances'] as List?) ?? const [];
      return items
          .map((e) => InstanceConfig.fromJson((e as Map).cast<String, dynamic>()))
          .toList();
    } catch (_) {
      return [];
    }
  }

  void save(List<InstanceConfig> instances) {
    _file.parent.createSync(recursive: true);
    _file.writeAsStringSync(jsonEncode({
      'schemaVersion': _schemaVersion,
      'instances': instances.map((c) => c.toJson()).toList(),
    }));
  }

  /// 按 id 查找（F2 Gate-B §7.1）。
  InstanceConfig? get(String id) {
    for (final c in load()) {
      if (c.id == id) return c;
    }
    return null;
  }

  /// 按 id 替换或追加，立即落盘。
  void upsert(InstanceConfig cfg) {
    final items = load();
    final idx = items.indexWhere((c) => c.id == cfg.id);
    if (idx >= 0) {
      items[idx] = cfg;
    } else {
      items.add(cfg);
    }
    save(items);
  }

  /// 按 id 删除（不存在为 no-op），立即落盘。
  void remove(String id) {
    final items = load();
    final idx = items.indexWhere((c) => c.id == id);
    if (idx < 0) return;
    items.removeAt(idx);
    save(items);
  }
}
