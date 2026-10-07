// batch44 —— 发现页视口优先加载（按首页排版顺序安排加载优先级）。
//
// 被钉行为（discover_page.dart 的 _scheduleSectionPrefetch / _homeSectionPrefetch）：
//   1. 冷启动首帧：首屏分区（SliverList 视口 + cacheExtent 内）在 build 中
//      watch provider 即时拉取；屏外分区不在首帧发起。
//   2. 首帧后：屏外分区按首页排版顺序 × 100ms 步长错开补触发（ref.read 幂等），
//      滑到时数据已在加载/就绪。
//   3. 幂等（缓存命中不延迟/不重复）：同一 provider 的 builder 只跑一次 ——
//      首帧已 watch 的分区再被预取 read 不会重复请求。
//   4. 「随机歌曲」不被预取触发（该区块按需拉取，缓存秒出语义保持）。
//
// 姿势与 discover_page_test.dart 的 _pumpDiscover 一致：ProviderScope 全桩，
// 但**不 pumpAndSettle**，用带时长的 pump 观察帧序与错开触发时序。
import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:musicflow_client/core/network/address_pool.dart';
import 'package:musicflow_client/core/network/connectivity_monitor.dart';
import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/data/models/home_section_layout.dart';
import 'package:musicflow_client/data/models/playlist.dart';
import 'package:musicflow_client/data/models/recommend.dart';
import 'package:musicflow_client/data/models/song.dart';
import 'package:musicflow_client/data/models/server_address.dart';
import 'package:musicflow_client/features/discover/pages/discover_page.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:musicflow_client/providers/api/api_provider.dart';
import 'package:musicflow_client/providers/api/music_provider.dart';
import 'package:musicflow_client/providers/library/playlist_provider.dart';
import 'package:musicflow_client/providers/library/recommend_provider.dart';
import 'package:musicflow_client/providers/player/player_provider.dart';

import '../player/test_player_notifier.dart';

/// 记录各分区数据 provider 的拉取发起顺序与次数。
class _FetchRecorder {
  final List<String> order = <String>[];
  final Map<String, int> counts = <String, int>{};

  void record(String key) {
    order.add(key);
    counts[key] = (counts[key] ?? 0) + 1;
  }

  int countOf(String key) => counts[key] ?? 0;
}

Playlist _playlist([String name = '默认歌单']) => Playlist(
      id: 'pl-' + name.hashCode.toString(),
      name: name,
      songCount: 8,
      duration: 1800,
    );

List<Song> _songs() => List<Song>.generate(
      3,
      (index) => Song(
        id: 'song-$index',
        title: '歌曲 ${index + 1}',
        artist: '歌手',
        duration: 180,
      ),
    );

Future<void> _pumpDiscover(
  WidgetTester tester, {
  required _FetchRecorder rec,
  Size size = const Size(390, 400),
}) async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);

  final connectivity = ConnectivityMonitor(AddressPool(Dio()));
  addTearDown(connectivity.stop);

  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        connectivityMonitorProvider.overrideWithValue(connectivity),
        ensureActiveAddressProvider.overrideWith(
          (ref) async => ServerAddress(
            id: 'server-1',
            libraryId: 'library-1',
            label: 'Test server',
            url: 'https://example.test',
            priority: 0,
          ),
        ),
        playerProvider.overrideWith((ref) => TestPlayerNotifier(PlayerState())),
        // 分区清单为空 → 回落默认顺序:
        // [remote-control, random-songs, recent-playlists, home-recommend,
        //  local-recommend, platform-recommend]
        homeSectionsProvider.overrideWith((ref) async => const <HomeSection>[]),
        // 各分区数据 provider:记录拉取发起(异步 builder 第一行同步执行,
        // 顺序即真实发起顺序)。
        randomSongsProvider.overrideWith((ref) async {
          rec.record('random-songs');
          return _songs();
        }),
        recentPlaylistsProvider.overrideWith((ref) async {
          rec.record('recent-playlists');
          return <Playlist>[_playlist()];
        }),
        homeRecommendSectionProvider.overrideWith((ref) async {
          rec.record('home-recommend');
          return const HomeRecommendSection(
            fixed: <HomeCard>[],
            random: <Playlist>[],
          );
        }),
        localRecommendChannelsProvider.overrideWith((ref) async {
          rec.record('local-recommend');
          return const <LocalRecommendChannel>[];
        }),
        recommendChannelsProvider.overrideWith((ref) async {
          rec.record('platform-recommend');
          return RecommendResult(providerId: '', channels: const []);
        }),
      ],
      child: MaterialApp(
        theme: AppTheme.light(),
        locale: const Locale('zh', 'CN'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        home: const DiscoverPage(),
      ),
    ),
  );
  // pumpWidget 已完成首帧(含 addPostFrameCallback),预取 Timer 已排上。
}

void main() {
  testWidgets('窄视口冷启动:首屏分区首帧拉取,屏外分区按排版顺序错开补齐', (
    tester,
  ) async {
    final rec = _FetchRecorder();
    await _pumpDiscover(tester, rec: rec, size: const Size(390, 400));

    final firstFrame = List<String>.of(rec.order);
    // 屏外分区(local-recommend / platform-recommend 位于排版尾部)不得在首帧发起。
    expect(
      firstFrame,
      isNot(contains('local-recommend')),
      reason: '排版尾部的分区不应在首帧(视口+cacheExtent 外)发起拉取',
    );
    expect(firstFrame, isNot(contains('platform-recommend')));

    // 推进 600ms:错开步长 100ms × 排版序(最大 500ms)全部到期,屏外分区补齐。
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump();

    expect(rec.countOf('local-recommend'), 1, reason: '延迟后仍会加载');
    expect(rec.countOf('platform-recommend'), 1, reason: '延迟后仍会加载');

    // 补齐顺序遵循首页排版顺序:local-recommend 先于 platform-recommend,
    // 且都晚于首帧已发起的分区。
    final deferred = rec.order
        .where((k) => !firstFrame.contains(k))
        .toList(growable: false);
    expect(
      deferred.indexOf('local-recommend'),
      lessThan(deferred.indexOf('platform-recommend')),
      reason: '屏外分区按排版顺序错开触发(排版序 = 加载优先级)',
    );
    expect(deferred, isNotEmpty);
  });

  testWidgets('高视口冷启动:首屏分区首帧即拉取且整体顺序跟随排版', (tester) async {
    final rec = _FetchRecorder();
    await _pumpDiscover(tester, rec: rec, size: const Size(390, 1400));

    // 视口 1400 + cacheExtent 400 覆盖前几个分区:近期更新的歌单(排版第 3)
    // 必然在首屏内,首帧由 build watch 触发,不等错开步长。
    expect(
      rec.order.first,
      'recent-playlists',
      reason: '首屏分区立即拉取,不等首帧后的预取错开',
    );

    // 推进后四个可预取分区全部就绪,发起顺序 = 首页排版顺序
    // (首帧 SliverList 按序构建 + 屏外预取按序错开,两者都遵循排版)。
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump();
    final sectionOrder = rec.order
        .where((k) => k != 'random-songs')
        .toList(growable: false);
    final expectedIdx = <String, int>{
      'recent-playlists': 0,
      'home-recommend': 1,
      'local-recommend': 2,
      'platform-recommend': 3,
    };
    for (final key in expectedIdx.keys) {
      expect(sectionOrder, contains(key), reason: '$key 应已被触发拉取');
    }
    final observed = sectionOrder
        .map((k) => expectedIdx[k]!)
        .toList(growable: false);
    final sorted = List<int>.of(observed)..sort();
    expect(
      observed,
      sorted,
      reason: '发起顺序应跟随首页排版顺序(排版序 = 加载优先级)',
    );
  });

  testWidgets('幂等(缓存命中不延迟/不重复):预取 read 不会让任何分区重复拉取', (
    tester,
  ) async {
    final rec = _FetchRecorder();
    await _pumpDiscover(tester, rec: rec, size: const Size(390, 1400));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump();

    final countsAfterFirstPass = Map<String, int>.of(rec.counts);

    // 再推进两轮(覆盖所有错开 Timer 到期 + 重建),不应有任何 provider 重拉。
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump();

    for (final key in <String>[
      'recent-playlists',
      'home-recommend',
      'local-recommend',
      'platform-recommend',
    ]) {
      expect(
        rec.countOf(key),
        countsAfterFirstPass[key] ?? 0,
        reason: '$key 只应拉取一次:首屏 watch 触发后,预取 read 幂等(不重复请求)',
      );
      expect(rec.countOf(key), 1);
    }
  });

  testWidgets('随机歌曲不被预取触发(按需拉取语义保持)', (tester) async {
    final rec = _FetchRecorder();
    await _pumpDiscover(tester, rec: rec, size: const Size(390, 400));

    final randomAfterFirstFrame = rec.countOf('random-songs');
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump();

    expect(
      rec.countOf('random-songs'),
      randomAfterFirstFrame,
      reason: '预取错开触发不得波及随机歌曲:该区块按需拉取(缓存秒出 + 广播信号)',
    );
  });
}
