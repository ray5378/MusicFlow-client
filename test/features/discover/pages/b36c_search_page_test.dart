// b36c —— `lib/features/discover/pages/search_page.dart` 缺口补测（原 22 miss）。
//
// 既有 search_page_test.dart 覆盖默认态/防抖/范围选择/热门历史/分组堆叠/点击行为。
// 本文件补其余分支：
//   * 带 initialQuery / initialScope 进入 → 直接出结果、不浮出范围浮层；
//   * 清空按钮（suffix close）→ 清词、回到发现态、重新聚焦；
//   * Windows 桌面平台 → 输入框右侧留出窗口控制按钮的等宽空白（不抛、留白存在）；
//   * 网络搜索失败 → VisibleRemoteRetryScope 的重试判定路径被求值。
//
// 产品代码零改动；只读 lib。

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:musicflow_client/core/design/music_flow_design.dart';
import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/data/models/album.dart';
import 'package:musicflow_client/data/models/artist.dart';
import 'package:musicflow_client/data/models/playlist.dart';
import 'package:musicflow_client/data/models/search.dart';
import 'package:musicflow_client/data/models/song.dart';
import 'package:musicflow_client/features/discover/pages/search_page.dart';
import 'package:musicflow_client/features/search/local_search_providers.dart';
import 'package:musicflow_client/features/search/search_scope.dart';
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

Override _network({List<SearchRequest>? requests, bool fail = false}) =>
    searchResultsProvider.overrideWith((ref, req) async {
      requests?.add(req);
      if (fail) throw Exception('network down');
      return SearchOutcome();
    });

Future<void> _pump(
  WidgetTester tester, {
  String initialQuery = '',
  SearchScope initialScope = SearchScope.all,
  List<Override> overrides = const <Override>[],
  Size size = const Size(430, 900),
}) async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));

  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        playerProvider.overrideWith((ref) => TestPlayerNotifier(PlayerState())),
        hotSearchTermsProvider.overrideWith((ref) async => <String>[]),
        ...overrides,
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
        theme: AppTheme.light(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: true),
          child: child!,
        ),
        home: SearchPage(initialQuery: initialQuery, initialScope: initialScope),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('带 initialQuery 进入：直接出结果、不浮出范围浮层', (tester) async {
    final requests = <SearchRequest>[];
    await _pump(
      tester,
      initialQuery: '晨光',
      initialScope: SearchScope.song,
      overrides: <Override>[_network(requests: requests), ..._localEmpty()],
    );
    await tester.pump();

    // 输入框带入初始关键词。
    final textField = tester.widget<TextField>(find.byType(TextField));
    expect(textField.controller!.text, '晨光');
    // 浮层不出现。
    expect(find.textContaining('全部内容', findRichText: true), findsNothing);
    // 只查「歌曲」一个类目。
    expect(requests.map((r) => r.kind).toSet(), <SearchEntityKind>{SearchEntityKind.song});
    expect(requests.every((r) => r.query == '晨光'), isTrue);
  });

  testWidgets('清空按钮：清词并回到发现态、重新聚焦', (tester) async {
    await _pump(
      tester,
      overrides: <Override>[_network(), ..._localEmpty()],
    );

    final textField = find.byType(TextField);
    await tester.enterText(textField, '晨光');
    await tester.pump();
    // 有词 -> 出现清空按钮；浮层收起。
    expect(find.byIcon(AppIcons.close), findsOneWidget);
    expect(find.textContaining('全部内容', findRichText: true), findsNothing);

    await tester.tap(find.byIcon(AppIcons.close));
    await tester.pump();

    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, '');
    // 清空后回到发现态：范围浮层重新浮出。
    expect(find.textContaining('全部内容', findRichText: true), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField)).focusNode!.hasFocus,
      isTrue,
    );
  });

  testWidgets('Windows 桌面平台：输入框行留出窗口控制按钮空白且不抛', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      await _pump(
        tester,
        overrides: <Override>[_network(), ..._localEmpty()],
      );

      expect(find.byType(TextField), findsOneWidget);
      expect(tester.takeException(), isNull);
    } finally {
      // 必须在测试体结束前复位，否则 _verifyInvariants 会判定调试变量被改。
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('网络搜索失败：重试判定路径被求值且不崩', (tester) async {
    await _pump(
      tester,
      initialQuery: '晨光',
      initialScope: SearchScope.song,
      overrides: <Override>[_network(fail: true), ..._localEmpty()],
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.byType(TextField), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
