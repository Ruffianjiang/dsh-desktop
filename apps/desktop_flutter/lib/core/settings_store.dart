import 'dart:convert';
import 'dart:io';

/// 主题模式（设置页可切；默认跟随系统）。
enum AppThemeMode { light, dark, system }

/// 应用设置（持久化于 `~/.dsh-desktop/settings.json`，与 RegistryStore 同风格）。
class AppSettings {
  const AppSettings({
    this.defaultPort = 0,
    this.dataDir,
    this.themeMode = AppThemeMode.system,
    this.autoStart = false,
    this.minimizeToTray = true,
  });

  /// 新建实例的端口（0 = 自动分配）。
  final int defaultPort;

  /// 新建实例的数据目录（null = 进程 cwd）。
  final String? dataDir;

  final AppThemeMode themeMode;
  final bool autoStart;
  final bool minimizeToTray;

  AppSettings copyWith({
    int? defaultPort,
    String? dataDir,
    AppThemeMode? themeMode,
    bool? autoStart,
    bool? minimizeToTray,
  }) =>
      AppSettings(
        defaultPort: defaultPort ?? this.defaultPort,
        dataDir: dataDir ?? this.dataDir,
        themeMode: themeMode ?? this.themeMode,
        autoStart: autoStart ?? this.autoStart,
        minimizeToTray: minimizeToTray ?? this.minimizeToTray,
      );

  Map<String, dynamic> toJson() => {
        'schemaVersion': 1,
        'defaultPort': defaultPort,
        'dataDir': dataDir,
        'themeMode': themeMode.name,
        'autoStart': autoStart,
        'minimizeToTray': minimizeToTray,
      };

  factory AppSettings.fromJson(Map<String, dynamic> j) => AppSettings(
        defaultPort: (j['defaultPort'] as num?)?.toInt() ?? 0,
        dataDir: j['dataDir'] as String?,
        themeMode: AppThemeMode.values.firstWhere(
          (m) => m.name == j['themeMode'],
          orElse: () => AppThemeMode.system,
        ),
        autoStart: j['autoStart'] == true,
        minimizeToTray: j['minimizeToTray'] != false,
      );
}

/// 设置持久化（JSON 文件；沿用 RegistryStore 的本地文件方案，避免新增依赖）。
class SettingsStore {
  SettingsStore([String? path]) : _file = File(path ?? defaultPath);

  final File _file;

  static String get defaultPath {
    final home = Platform.environment['USERPROFILE'] ??
        Platform.environment['HOME'] ??
        '.';
    return '$home${Platform.pathSeparator}.dsh-desktop'
        '${Platform.pathSeparator}settings.json';
  }

  AppSettings load() {
    if (!_file.existsSync()) return const AppSettings();
    try {
      final j = jsonDecode(_file.readAsStringSync()) as Map<String, dynamic>;
      return AppSettings.fromJson(j);
    } catch (_) {
      return const AppSettings();
    }
  }

  void save(AppSettings s) {
    _file.parent.createSync(recursive: true);
    _file.writeAsStringSync(jsonEncode(s.toJson()));
  }
}
