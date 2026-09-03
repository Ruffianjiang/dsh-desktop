/// L2 引擎管理层领域模型（Gate-B v1.0 §4.1）。
library;

/// 实例状态机：created → starting ⇄ running → stopping → stopped；
/// running → crashed（守护拉起失败达上限后置 crashed）。
enum InstanceStatus {
  created,
  starting,
  running,
  stopping,
  crashed,
  stopped,
}

/// 实例配置（持久化于 RegistryStore）。
class InstanceConfig {
  const InstanceConfig({
    required this.id,
    required this.alias,
    this.profile = 'web',
    this.host = '127.0.0.1',
    this.port = 3080,
    this.dataDir,
    this.logFile,
    this.env = const {},
    this.autoStart = false,
  });

  final String id;
  final String alias;

  /// dsh profile（默认 web；纯 API profile 于 M2 实测后可选）。
  final String profile;

  /// 期望监听地址/端口（dsh 启动参数映射待 M2 收口，health 探测用之）。
  final String host;
  final int port;

  /// 会话工作目录（dsh web 的 cwd；缺省为当前进程 cwd）。
  final String? dataDir;
  final String? logFile;
  final Map<String, String> env;
  final bool autoStart;

  Map<String, dynamic> toJson() => {
        'id': id,
        'alias': alias,
        'profile': profile,
        'host': host,
        'port': port,
        'dataDir': dataDir,
        'logFile': logFile,
        'env': env,
        'autoStart': autoStart,
      };

  factory InstanceConfig.fromJson(Map<String, dynamic> j) => InstanceConfig(
        id: (j['id'] ?? '').toString(),
        alias: (j['alias'] ?? '').toString(),
        profile: (j['profile'] ?? 'web').toString(),
        host: (j['host'] ?? '127.0.0.1').toString(),
        port: (j['port'] ?? 3080) as int,
        dataDir: j['dataDir'] as String?,
        logFile: j['logFile'] as String?,
        env: (j['env'] as Map?)?.cast<String, String>() ?? const {},
        autoStart: j['autoStart'] == true,
      );
}

/// 实例运行时状态。
class InstanceState {
  InstanceState({
    required this.config,
    this.status = InstanceStatus.created,
    this.pid,
    this.lastExitCode,
    this.startedAt,
  });

  final InstanceConfig config;
  InstanceStatus status;
  int? pid;
  int? lastExitCode;
  DateTime? startedAt;
}
