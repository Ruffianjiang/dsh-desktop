import 'package:go_router/go_router.dart';

import '../features/chat/chat_page.dart';
import '../features/engine/engine_page.dart';
import '../features/instances/instance_detail_page.dart';
import '../features/instances/instances_page.dart';
import '../features/settings/settings_page.dart';
import 'app_shell.dart';

/// 路由表（M3 Gate-B §5.1）：NavigationRail 四页 + IndexedStack 分支。
GoRouter buildRouter() {
  return GoRouter(
    initialLocation: '/instances',
    routes: [
      StatefulShellRoute.indexedStack(
        builder: (context, state, shell) => AppShell(shell: shell),
        branches: [
          StatefulShellBranch(routes: [
            GoRoute(path: '/engine', builder: (_, _) => const EnginePage()),
          ]),
          StatefulShellBranch(routes: [
            GoRoute(
              path: '/instances',
              builder: (_, _) => const InstancesPage(),
              routes: [
                GoRoute(
                  path: ':id',
                  builder: (_, state) =>
                      InstanceDetailPage(id: state.pathParameters['id']!),
                ),
              ],
            ),
          ]),
          StatefulShellBranch(routes: [
            GoRoute(path: '/chat', builder: (_, _) => const ChatPage()),
          ]),
          StatefulShellBranch(routes: [
            GoRoute(path: '/settings', builder: (_, _) => const SettingsPage()),
          ]),
        ],
      ),
    ],
  );
}
