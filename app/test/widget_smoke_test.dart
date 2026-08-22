import 'package:flutter_test/flutter_test.dart';
import 'package:musicflow_app/app.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('未登录时展示登录页', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await tester.pumpWidget(const MusicFlowApp());
    // 初始化是异步的：先加载指示器，再落到登录页。
    await tester.pumpAndSettle();

    expect(find.text('MusicFlow'), findsWidgets);
    expect(find.text('连接你的音乐库'), findsOneWidget);
    expect(find.text('服务器地址'), findsOneWidget);
    expect(find.text('连接'), findsOneWidget);
  });

  testWidgets('空表单提交给出校验提示', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await tester.pumpWidget(const MusicFlowApp());
    await tester.pumpAndSettle();

    await tester.tap(find.text('连接'));
    await tester.pump();

    expect(find.text('请填写服务器地址和用户名'), findsOneWidget);
  });
}
