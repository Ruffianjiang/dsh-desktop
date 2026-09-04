import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:dsh_desktop/app.dart';

void main() {
  testWidgets('T1/T4 壳层冒烟：NavigationRail 四页可渲染', (tester) async {
    await tester.pumpWidget(const ProviderScope(child: DshApp()));
    // 异步 provider（NodeEnv.probe 等真实探测）在测试环境后台进行，
    // 不使用 pumpAndSettle（进度条动画永不 settle）。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.byType(NavigationRail), findsOneWidget);
    expect(find.text('引擎'), findsWidgets);
    expect(find.text('对话'), findsWidgets);
    expect(find.text('设置'), findsWidgets);
  });
}
