// b38b3 —— Route B：`lib/app.dart` 剩余缺口补测。
//
// 覆盖 lcov 未命中行：
//   * 30       `App()` 构造函数
//   * 198      认证翻转时 `rootNavigatorKey.currentState.go(...)` 的参数分支
//   * 247-255  `/library/edit/:id` 路由的 pageBuilder
//
// 打法：挂真实 App（真 AppLocalizations / GoRouter），用可操控的 AuthNotifier
// 驱动 `routerProvider` 里的 `ref.listen`，并显式 go 到编辑库路由。
//
// 产品代码零改动；仅新增 test/。

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:musicflow_client/app.dart';
import 'package:musicflow_client/core/utils/toast_notifier.dart';
import 'package:musicflow_client/data/repositories/auth_repository.dart';
import 'package:musicflow_client/data/repositories/library_repository.dart';
import 'package:musicflow_client/features/auth/pages/login_page.dart';
import 'package:musicflow_client/features/library/pages/edit_library_page.dart';
import 'package:musicflow_client/providers/auth/auth_provider.dart';

class _MockAuthRepository extends Mock implements AuthRepository {}

class _MockLibraryRepository extends Mock implements LibraryRepository {}

/// 复用 b38b2 的做法：`_init()` 因 mock 未打桩走进 catch → 落地「未认证、初始化完成」。
class _FlipAuthNotifier extends AuthNotifier {
  _FlipAuthNotifier()
      : super(_MockAuthRepository(), _MockLibraryRepository());
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test('App() 构造函数可实例化', () {
    expect(App(), isA<App>());
  });

  testWidgets('认证翻转 + 跳转 /library/edit/:id 覆盖 routerProvider 监听与编辑库路由',
      (tester) async {
    final auth = _FlipAuthNotifier();
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          authStateProvider.overrideWith((ref) => auth),
        ],
        child: const App(),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.byType(LoginPage), findsOneWidget, reason: '未认证先落在登录页');

    // 登录成功：未认证 → 已认证，触发 routerProvider 里的 ref.listen 分支。
    auth.state = AuthState(isAuthenticated: true, isInitializing: false);
    await tester.pump(const Duration(milliseconds: 100));

    // 直接跳到「编辑媒体库」路由，驱动其 pageBuilder（247-255）。
    rootNavigatorKey.currentState?.context.go('/library/edit/lib-1');
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 300));

    // 只要路由匹配过编辑库页即可（其内部依赖可能受限，不强行断言整页渲染）。
    expect(find.byType(EditLibraryPage), findsWidgets);
  });
}
