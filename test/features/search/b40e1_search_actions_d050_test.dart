// b40e1 —— D-050：playRemoteSearchCollection 歌单 kind 未传 playlist 的安全分支。
//
// 修复前：`playlist ?? (item as SearchPlaylist)`——SearchPlaylist 未实现
// SearchSongLike，调用点若不显式传 `playlist:` 则强转必抛 TypeError
// （b33b 只锁了显式传参路径，此处一直靠全部调用点传参掩盖）。
// 修复后：先判型，畸形调用给出「暂无可播放」提示而非 TypeError 崩溃。

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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    registerFallbackValue(<String, dynamic>{});
  });

  testWidgets('[D-050] playlist kind 未传 playlist 且 item 非 SearchPlaylist → '
      '提示暂无可播放,不崩溃', (tester) async {
    final api = MockSubsonicApiClient();
    Object? caught;

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          searchRepositoryProvider.overrideWithValue(
            SearchRepository(api),
          ),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('zh'),
          navigatorKey: rootNavigatorKey,
          home: Scaffold(
            body: Center(
              child: Consumer(
                builder: (context, ref, _) => FilledButton(
                  onPressed: () async {
                    try {
                      await playRemoteSearchCollection(
                        context,
                        ref,
                        SearchEntityKind.playlist,
                        'netease',
                        SearchSongLike(id: 'p1', source: 'netease'),
                      );
                    } catch (e) {
                      caught = e;
                    }
                  },
                  child: const Text('trigger'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('trigger'));
    await tester.pump(const Duration(milliseconds: 200));

    expect(caught, isNull, reason: '[D-050] 未传 playlist 不应再抛 TypeError');
    expect(find.textContaining('暂无可播放'), findsOneWidget,
        reason: '畸形调用应给出可读的不可播放提示');
    expect(find.textContaining('播放失败'), findsNothing);
  });
}
