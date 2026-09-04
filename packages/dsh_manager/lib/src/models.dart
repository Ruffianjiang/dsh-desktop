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

  /// dsh profile（固定 web：M2 实测确认纯 API profile 不可行——
  /// dsh 的 /api carrier 与 web-runtime 耦合，禁用前端会同时撤掉 API）。
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
  /// 实际监听端口（config.port==0 时由分配器填入，用于多实例 / OS 分配场景）。
  int? port;
  DateTime? startedAt;

  /// 最近一次心跳时间（HealthProbe 更新；F2 Gate-B §4.7）。
  DateTime? lastHeartbeat;

  /// 守护连续失败次数（0 = 非守护中；F2 Gate-B §4.1，BQ7 不新增 restarting 态）。
  int guardianAttempts = 0;
}
