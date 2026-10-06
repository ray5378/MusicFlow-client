// b39c2 —— Route C 清尾：search_actions.dart 剩余缺口。
//   * 132：importSearchAlbum 的 catch 分支 —— repo.importAlbum 抛异常 →
//     `_toast(context, loc.search_import_failed('$e'), error: true)`。
//     既有 b33b 只打了 importSearchSong 的提交失败（105）与 importSearchAlbum
//     的成功路径，本文件补专辑入库提交失败。
//
// 手法沿用 b33b_search_actions_test：MockSubsonicApiClient.postRaw 一律抛错。
//
// 只写 test/，只读 lib/（产品代码零改动）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:musicflow_client/core/utils/toast_notifier.dart';
import 'package:musicflow_client/data/models/search.dart';
import 'package:musicflow_client/data/repositories/search_repository.dart';
import 'package:musicflow_client/features/search/search_actions.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:musicflow_client/providers/library/search_provider.dart';

import '../../helpers/mocks.dart';

void _stubPostThrows(MockSubsonicApiClient api) {
  when(() => api.postRaw(any(),
      data: any(named: 'data'),
      queryParameters: any(named: 'queryParameters'))).thenThrow(
    Exception('post failed'),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    registerFallbackValue(<String, dynamic>{});
  });

  testWidgets('importSearchAlbum：提交抛异常 → 入库失败错误 Toast（132）',
      (tester) async {
    final api = MockSubsonicApiClient();
    _stubPostThrows(api);

    late final BuildContext capturedContext;
    late final WidgetRef capturedRef;

    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          searchRepositoryProvider.overrideWithValue(SearchRepository(api)),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('zh'),
          navigatorKey: rootNavigatorKey,
          home: Scaffold(
            body: Center(
              child: Consumer(
                builder: (context, ref, _) {
                  capturedContext = context;
                  capturedRef = ref;
                  return FilledButton(
                    onPressed: () => importSearchAlbum(
                      capturedContext,
                      capturedRef,
                      SearchAlbum(
                        id: 'al-1',
                        source: 'netease',
                        name: 'Great Album',
                        providerId: 'netease',
                      ),
                    ),
                    child: const Text('trigger'),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('trigger'));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.textContaining('失败'), findsOneWidget,
        reason: 'importAlbum 抛异常 → 展示 search_import_failed');
    expect(find.textContaining('已提交入库任务'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
