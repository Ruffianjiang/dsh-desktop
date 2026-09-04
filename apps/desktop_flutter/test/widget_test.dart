import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:dsh_desktop/app.dart';

void main() {
  testWidgets('T1 壳层冒烟：应用可构建并渲染 NavigationRail 四页导航',
      (tester) async {
    await tester.pumpWidget(const ProviderScope(child: DshApp()));
    await tester.pumpAndSettle();

    // 初始路由 /instances：占位页标题 + Rail 标签
    expect(find.text('实例面板'), findsOneWidget);
    expect(find.text('引擎'), findsOneWidget);
    expect(find.text('对话'), findsOneWidget);
    expect(find.text('设置'), findsOneWidget);
  });
}
