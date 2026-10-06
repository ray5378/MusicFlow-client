// b38c3 —— Route C 补测：`lib/features/discover/pages/search_page.dart` 剩余缺口。
//
// 既有 search_page_test / b36c / b37c2 已覆盖默认态/防抖/范围/热门历史/
// 分组堆叠/清空/initialQuery/键盘提交。
//
// 覆盖点：
//   * 198：返回按钮 onPressed → Navigator.maybePop()。
//   * 160/226-241：网络类型变化触发 shouldRetry → `_hasNetworkError` 遍历范围读结果
//     异步态并判定 hasError。
//   * 161-170：hasError 为真 → onRetry 遍历 stackedScopes 逐个 invalidate 结果 provider。
//
// 只写 test/，只读 lib/（产品代码零改动）。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:musicflow_client/core/network/connectivity_monitor.dart';
import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/data/models/album.dart';
import 'package:musicflow_client/data/models/artist.dart';
import 'package:musicflow_client/data/models/playlist.dart';
import 'package:musicflow_client/data/models/search.dart';
import 'package:musicflow_client/data/models/song.dart';
import 'package:musicflow_client/features/discover/pages/search_page.dart';
import 'package:musicflow_client/features/search/local_search_providers.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:musicflow_client/providers/api/api_provider.dart';
import 'package:musicflow_client/providers/library/search_provider.dart';
import 'package:musicflow_client/providers/player/player_provider.dart';

import '../../player/test_player_notifier.dart';

class FakeConnectivityMonitor implements ConnectivityMonitor {
  FakeConnectivityMonitor({this.currentNetworkType = NetworkType.none});

  final StreamController<NetworkType> _controller =
      StreamController<NetworkType>.broadcast();

  @override
  NetworkType currentNetworkType;

  @override
  Stream<NetworkType> get networkTypeStream => _controller.stream;

  @override
  void start() {}

  @override
  void stop() {}

  void emit(NetworkType type) {
    currentNetworkType = type;
    _controller.add(type);
  }

  Future<void> dispose() => _controller.close();
}

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
  _Harness({required this.page, this.errorResults = false});

  final Widget page;
  final bool errorResults;
  final List<SearchRequest> requests = <SearchRequest>[];
  final FakeConnectivityMonitor monitor = FakeConnectivityMonitor();
  late ProviderContainer container;

  Widget build() {
    container = ProviderContainer(
      overrides: <Override>[
        playerProvider.overrideWith((ref) => TestPlayerNotifier(PlayerState())),
        hotSearchTermsProvider.overrideWith((ref) async => <String>[]),
        searchResultsProvider.overrideWith((ref, req) async {
          requests.add(req);
          if (errorResults) throw StateError('b38c3 模拟搜索结果失败');
          return SearchOutcome();
        }),
        connectivityMonitorProvider.overrideWithValue(monitor),
        ..._localEmpty(),
      ],
    );
    addTearDown(() {
      container.dispose();
      return monitor.dispose();
    });
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
        home: page,
      ),
    );
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  testWidgets('返回按钮 → maybePop（198）', (tester) async {
    final h = _Harness(page: const SearchPage(initialQuery: '晴天'));
    await tester.pumpWidget(h.build());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    final loc = AppLocalizations.of(tester.element(find.byType(SearchPage)));
    // 图标按钮语义标签即 search_back（纯图标控件不靠 text 定位）。
    await tester.tap(find.bySemanticsLabel(loc.search_back));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(tester.takeException(), isNull);
  });

  testWidgets('网络类型变化：结果失败 → shouldRetry/onRetry 遍历范围失效重拉（160/226-241/161-170）',
      (tester) async {
    final h = _Harness(
      page: const SearchPage(initialQuery: '晴天'),
      errorResults: true,
    );
    await tester.pumpWidget(h.build());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    // 首帧已拉过一轮（initialQuery 非空）。
    expect(h.requests.map((r) => r.kind).toSet().length, 4,
        reason: 'SearchScope.all 会分段查询 4 个实体');

    // none → wifi：网络类型变化触发 _retryIfNeeded → shouldRetry(_hasNetworkError)
    // → 结果为 error → onRetry → 四个范围的 provider 全部 invalidate → 重新拉取。
    h.monitor.emit(NetworkType.wifi);
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(h.requests.length, greaterThan(4),
        reason: 'invalidate 后应重新读取各范围结果 provider');
    expect(tester.takeException(), isNull);
  });
}
