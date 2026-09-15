import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

/// 全局壳：左侧 NavigationRail（引擎/实例/对话/设置）+ 右侧分支内容。
class AppShell extends StatelessWidget {
  const AppShell({super.key, required this.shell});

  final StatefulNavigationShell shell;

  static const _destinations = [
    (icon: Icons.build_outlined, selectedIcon: Icons.build, label: '引擎'),
    (icon: Icons.dns_outlined, selectedIcon: Icons.dns, label: '实例'),
    (icon: Icons.forum_outlined, selectedIcon: Icons.forum, label: '对话'),
    (icon: Icons.settings_outlined, selectedIcon: Icons.settings, label: '设置'),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Row(
        children: [
          NavigationRail(
            selectedIndex: shell.currentIndex,
            onDestinationSelected: (i) => shell.goBranch(
              i,
              initialLocation: i == shell.currentIndex,
            ),
            labelType: NavigationRailLabelType.all,
            destinations: [
              for (final d in _destinations)
                NavigationRailDestination(
                  icon: Icon(d.icon),
                  selectedIcon: Icon(d.selectedIcon),
                  label: Text(d.label),
                ),
            ],
          ),
          const VerticalDivider(width: 1),
          Expanded(child: shell),
        ],
      ),
    );
  }
}
