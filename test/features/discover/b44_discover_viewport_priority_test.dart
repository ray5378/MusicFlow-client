// v5.8.6 —— 发现页视口优先加载：启动带宽全给首屏，屏外分区等首屏
// 数据全部就绪后才按排版顺序错开预取。
//
// 被钉行为（discover_page.dart 的 _scheduleSectionPrefetch /
// _prefetchAfterViewportSettled / _homeSectionPrefetch）：
//   1. 冷启动首帧：首屏分区（SliverList 视口 + cacheExtent 内）在 build 中
//      watch provider 即时拉取；屏外分区不在首帧发起。
//   2. 首屏未就绪前：屏外分区**零发起**——预取等待期只 await 已构建分区
//      的 provider future，不碰任何屏外分区（慢网络下等待更久，首屏永远
//      优先，启动带宽全部让给首屏）。
//   3. 首屏就绪后：屏外分区按首页排版顺序 × 100ms 步长错开补齐。
//   4. 幂等：预取 read 不重复请求（已 watch 的 provider 返回同一 future）。
//   5. 「随机歌曲」不被预取触发（该区块按需拉取，缓存秒出语义保持）。
//
// 姿势与 discover_page_test.dart 的 _pumpDiscover 一致：ProviderScope 全桩，
// 不 pumpAndSettle（骨架动画无限循环），用带时长的 pump 观察帧序与错开
// 触发时序；首屏分区的「就绪时机」用 Future.delayed 精确控制。
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
  Map<String, Duration> firstScreenDelay = const <String, Duration>{},
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
        playerProvider.overrideWith(() => TestPlayerNotifier(PlayerState())),
        // 分区清单为空 → 回落默认顺序:
        // [remote-control, random-songs, recent-playlists, home-recommend,
        //  local-recommend, platform-recommend]
        homeSectionsProvider.overrideWith((ref) async => const <HomeSection>[]),
        // 各分区数据 provider:记录拉取发起(异步 builder 第一行同步执行,
        // 顺序即真实发起顺序)。firstScreenDelay 控制指定分区的「就绪
        // 时机」(值返回前的延迟),用于验证「首屏未就绪 → 屏外零发起」。
        randomSongsProvider.overrideWith((ref) async {
          rec.record('random-songs');
          return _songs();
        }),
        recentPlaylistsProvider.overrideWith((ref) async {
          rec.record('recent-playlists');
          final delay = firstScreenDelay['recent-playlists'];
          if (delay != null) await Future.delayed(delay);
          return <Playlist>[_playlist()];
        }),
        homeRecommendSectionProvider.overrideWith((ref) async {
          rec.record('home-recommend');
          final delay = firstScreenDelay['home-recommend'];
          if (delay != null) await Future.delayed(delay);
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
  // pumpWidget 已完成首帧(含 addPostFrameCallback),预取等待期已排上。
}

void main() {
  testWidgets('窄视口冷启动:首屏分区首帧拉取,屏外分区在首屏就绪前零发起', (
    tester,
  ) async {
    final rec = _FetchRecorder();
    // 首屏分区 recent-playlists 的就绪延迟到 2s 后:模拟慢网络下的首屏
    // loading 阶段(narrow 视口 + cacheExtent 400 的首帧只构建它)。
    // 只给首帧确实构建的分区包 delay:后随数据返回才进入覆盖范围的
    // 分区不包,避免 teardown 时残留未到期 timer。
    await _pumpDiscover(
      tester,
      rec: rec,
      size: const Size(390, 400),
      firstScreenDelay: const <String, Duration>{
        'recent-playlists': Duration(seconds: 2),
      },
    );

    final firstFrame = List<String>.of(rec.order);
    // 首屏分区已发起(视口 + cacheExtent 内)。
    expect(firstFrame, contains('recent-playlists'));
    // 屏外分区(local-recommend / platform-recommend 位于排版尾部)
    // 不在首帧发起。
    expect(firstFrame, isNot(contains('local-recommend')));
    expect(firstFrame, isNot(contains('platform-recommend')));

    // 首屏未就绪(2s 未到):推进 600ms,屏外分区仍零发起 —— 预取等待期
    // 只 await 已构建分区,启动带宽全部让给首屏。
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump();
    expect(
      rec.countOf('local-recommend'),
      0,
      reason: '首屏数据未就绪时,屏外分区不得发起(不等同于旧的立即预取)',
    );
    expect(rec.countOf('platform-recommend'), 0);

    // 推进到 2.1s:首屏分区 future 完成 → 预取启动,错开步长 100ms ×
    // 排版序(local index 4 → 400ms,platform index 5 → 500ms)全部到期。
    await tester.pump(const Duration(milliseconds: 1500));
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pump();

    expect(rec.countOf('local-recommend'), 1, reason: '首屏就绪后补齐');
    expect(rec.countOf('platform-recommend'), 1);
    // 补齐顺序遵循首页排版顺序:local-recommend 先于 platform-recommend。
    final deferred = rec.order
        .where((k) => !firstFrame.contains(k))
        .toList(growable: false);
    expect(
      deferred.indexOf('local-recommend'),
      lessThan(deferred.indexOf('platform-recommend')),
      reason: '屏外分区按排版顺序错开触发(排版序 = 加载优先级)',
    );
  });

  testWidgets('首屏即就绪(缓存秒出):600ms 内屏外分区按排版序错开补齐', (
    tester,
  ) async {
    final rec = _FetchRecorder();
    await _pumpDiscover(tester, rec: rec, size: const Size(390, 400));

    final firstFrame = List<String>.of(rec.order);
    expect(firstFrame, isNot(contains('local-recommend')));
    expect(firstFrame, isNot(contains('platform-recommend')));

    // 首屏分区无延迟 → future 立即完成 → 预取等待期当帧即过 → 错开
    // Timer 排期;推进 600ms(最大 500ms 步长到期)全部补齐。
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump();

    expect(rec.countOf('local-recommend'), 1, reason: '首屏就绪后仍会补齐');
    expect(rec.countOf('platform-recommend'), 1);

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

    // 视口 1400 + cacheExtent 400 覆盖全部分区:每个分区首帧由 build
    // watch 触发,不等任何错开步长。
    expect(
      rec.order.first,
      'recent-playlists',
      reason: '首屏分区立即拉取,不等首帧后的预取错开',
    );

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

  testWidgets('幂等(缓存命中不重复):预取 read 不让任何分区重复拉取', (
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
