import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:musicflow_client/app.dart';
import 'package:musicflow_client/data/models/server_address.dart';
import 'package:musicflow_client/providers/api_provider.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('App smoke test', (WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        // 避免 ensureActiveAddressProvider 的 200ms 探测轮询定时器在测试结束时挂起。
        overrides: <Override>[
          ensureActiveAddressProvider.overrideWith(
            (ref) async => ServerAddress(
              id: 'server-1',
              libraryId: 'library-1',
              label: 'Test server',
              url: 'https://example.test',
              priority: 0,
            ),
          ),
        ],
        child: const App(),
      ),
    );

    expect(find.byType(App), findsOneWidget);
    expect(find.byType(ProviderScope), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 600));
  });
}
