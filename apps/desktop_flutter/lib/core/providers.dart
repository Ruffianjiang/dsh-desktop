import 'dart:io';

import 'package:dsh_manager/dsh_manager.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 全局 providers（M3 Gate-B §5.2）。
///
/// 依赖方向：UI → providers → L2(dsh_manager)/L3(dsh_client)；
/// UI ↔ dsh 唯一通道是 L3 客户端（实例面板消费 L2 事件流属进程管理域）。

/// Node + dsh 环境探测（引擎页/实例页共用）。
final nodeEnvProvider = FutureProvider<NodeEnv>((ref) => NodeEnv.probe());

/// L2 实例管理器单例（聚合全部实例事件；keepAlive 常驻）。
final instanceManagerProvider = FutureProvider<InstanceManager>((ref) async {
  final env = await ref.watch(nodeEnvProvider.future);
  return InstanceManager(env: env);
});

/// 实例事件流：状态/心跳/退出事件驱动实例页局部刷新（不轮询）。
final instanceEventsProvider = StreamProvider<InstanceEvent>((ref) async* {
  final manager = await ref.watch(instanceManagerProvider.future);
  yield* manager.events;
});

/// F1 安装服务（npm 可执行文件由 node 同目录推导；代理沿用进程环境）。
final installServiceProvider = FutureProvider<InstallService>((ref) async {
  final env = await ref.watch(nodeEnvProvider.future);
  final npmDir = File(env.nodePath).parent.path;
  final sep = Platform.pathSeparator;
  final npm = Platform.isWindows ? '$npmDir${sep}npm.cmd' : '$npmDir${sep}npm';
  return InstallService(
    nodeExecutable: env.nodePath,
    npmExecutable: npm,
    proxy: Platform.environment['HTTPS_PROXY'],
  );
});

/// 托管 prefix 下的已装 dsh 版本（null = 未安装）。
final installedVersionProvider = FutureProvider<String?>((ref) async {
  final svc = await ref.watch(installServiceProvider.future);
  return svc.detectInstalled(svc.defaultPrefix);
});

/// npm 版本目录（引擎页版本列表；走 registry HTTP，代理注入）。
final versionCatalogProvider = FutureProvider<VersionCatalog>((ref) {
  return VersionCatalog.fetchHttp(
    '@deepseek-ai/dsh',
    registry: 'https://registry.npmjs.org/',
    proxy: Platform.environment['HTTPS_PROXY'],
  );
});
