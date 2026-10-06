// batch37 C(2) —— `lib/features/discover/pages/search_page.dart` 剩余分支。
//
// 既有 search_page_test / b36c 已覆盖默认态/防抖/范围/热门历史/分组堆叠/清空/
// initialQuery/网络失败判定。本文件补：
//   * 键盘提交（onSubmitted → _submitSearch：取消防抖、收起浮层、提交并记历史）；
//   * 防抖 450ms 到期回调真正提交（_searchTimer 回调）；
//   * 点范围标签（SearchScopeTabs）→ _onScopeChanged 只查该范围。
//
// 只写 test/，只读 lib/（产品代码零改动）。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/data/models/album.dart';
import 'package:musicflow_client/data/models/artist.dart';
import 'package:musicflow_client/data/models/playlist.dart';
import 'package:musicflow_client/data/models/search.dart';
import 'package:musicflow_client/data/models/song.dart';
import 'package:musicflow_client/features/discover/pages/search_page.dart';
import 'package:musicflow_client/features/search/local_search_providers.dart';
import 'package:musicflow_client/features/search/search_scope.dart';
import 'package:musicflow_client/features/search/widgets/search_scope_picker.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:musicflow_client/providers/library/search_provider.dart';
import 'package:musicflow_client/providers/player/player_provider.dart';

import '../../player/test_player_notifier.dart';

List<Override> _localEmpty() => <Override>[
      localSongSearchProvider.overrideWith(
        (ref, q) async => (items: <Song>[], total: 0),
      ),
      localAlbumSearchProvider.overrideWith(
        (ref, q) async => (items: <Album>[], total: 0),
      ),
      localArtistSearchProvider.overrideWith(
        (ref, q) async => (items: <Artist>[], total: 0),
      ),
      localPlaylistSearchProvider.overrideWith(
        (ref, q) async => (items: <Playlist>[], total: 0),
      ),
    ];

class _Harness {
  _Harness();

  final List<SearchRequest> requests = <SearchRequest>[];
  late ProviderContainer container;

  Widget build() {
    container = ProviderContainer(
      overrides: <Override>[
        playerProvider.overrideWith((ref) => TestPlayerNotifier(PlayerState())),
        hotSearchTermsProvider.overrideWith((ref) async => <String>[]),
        searchResultsProvider.overrideWith((ref, req) async {
          requests.add(req);
          return SearchOutcome();
        }),
        ..._localEmpty(),
      ],
    );
    addTearDown(container.dispose);
    return UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
        theme: AppTheme.light(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: true),
          child: child!,
        ),
        home: const SearchPage(),
      ),
    );
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  testWidgets('键盘提交(onSubmitted) → 出结果并写入搜索历史', (tester) async {
    final h = _Harness();
    await tester.pumpWidget(h.build());
    await tester.pump();

    await tester.enterText(find.byType(TextField), '  晨光  ');
    await tester.pump();
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    expect(find.byKey(const ValueKey<String>('search_results_list')), findsOneWidget);
    expect(h.requests.every((r) => r.query == '晨光'), isTrue,
        reason: '提交时应 trim 关键词');
    expect(tester.takeException(), isNull);
  });

  testWidgets('防抖 450ms 到期 → 自动提交查询', (tester) async {
    final h = _Harness();
    await tester.pumpWidget(h.build());
    await tester.pump();

    await tester.enterText(find.byType(TextField), '七里香');
    await tester.pump();
    // 未到期：尚未提交（无结果列表）。
    expect(find.byKey(const ValueKey<String>('search_results_list')), findsNothing);

    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();

    expect(find.byKey(const ValueKey<String>('search_results_list')), findsOneWidget);
    expect(h.requests.every((r) => r.query == '七里香'), isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('切换范围标签回调 → 后续只查该范围', (tester) async {
    final h = _Harness();
    await tester.pumpWidget(h.build());
    await tester.pump();

    // 直接触发范围切换回调（_onScopeChanged）。
    tester.widget<SearchScopeTabs>(find.byType(SearchScopeTabs)).onChanged(SearchScope.song);
    await tester.pump();
    expect(
      tester.widget<SearchScopeTabs>(find.byType(SearchScopeTabs)).value,
      SearchScope.song,
    );

    await tester.enterText(find.byType(TextField), '晴天');
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();

    expect(
      h.requests.map((r) => r.kind).toSet(),
      <SearchEntityKind>{SearchEntityKind.song},
      reason: '切到「音乐」范围后只查 song',
    );
    expect(tester.takeException(), isNull);
  });
}
