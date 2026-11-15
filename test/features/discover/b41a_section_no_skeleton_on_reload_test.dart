// b41a · 首页区块「已上屏后不闪回骨架」的行为钉子
//
// 背景（用户报「连上服务端后首页闪一下」）：
//   `recentPlaylistsProvider` 内部 `ref.watch(activeAddressProvider)`。冷启动时
//   地址从「探测中」翻成「ok」会把它推着重建 —— 那是 **reload**（上游依赖变化），
//   不是 **refresh**（自己 invalidate）。Riverpod 的 `.when()` 默认
//   `skipLoadingOnRefresh: true` 但 `skipLoadingOnReload: false`，所以「连上服务端
//   那一刻」整块会闪回一帧骨架。修复是给 `.when()` 显式 `skipLoadingOnReload: true`。
//
// 两条用例分别守两个向：
//   1. reload 期间**旧内容仍在屏上、没有骨架** —— 直接对应报障现象；
//   2. 首次加载（没有 previous value）**仍然显示骨架** —— 证明改动没有把
//      首屏加载态一起吞掉（那会让冷启动变成一片空白）。
//
// 手法：把 `recentPlaylistsProvider` override 成一个 `ref.watch(某个 StateProvider)`
// 的 provider，bump 那个 StateProvider 就等价于「上游依赖变化」。第二次计算挂在
// 一个未完成的 Completer 上，让「重载中的 loading 态」在屏上稳定停留 —— 否则
// 一帧内就变成 data，跳不跳过 loading 都看不出来（假绿）。

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/data/models/playlist.dart';
import 'package:musicflow_client/features/discover/widgets/discover_playlist_widgets.dart';
import 'package:musicflow_client/features/discover/widgets/recent_playlists_section.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:musicflow_client/providers/library/playlist_provider.dart';

/// 等价于真实 provider 里 `ref.watch(activeAddressProvider)` 的那个上游依赖：
/// bump 它就是「上游依赖变化」⇒ 下游 provider 进入 reload。
final StateProvider<int> _upstreamBumpProvider = StateProvider<int>((ref) => 0);

Playlist _pl(String id, String name) => Playlist(
      id: id,
      name: name,
      songCount: 12,
      duration: 600,
    );

/// 挂载被测区块。用 [UncontrolledProviderScope] 是为了能在测试体里直接 bump
/// 上游 `StateProvider`（`ProviderScope` 拿不到 container）。
Future<void> _pumpSection(
  WidgetTester tester,
  ProviderContainer container,
) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(1200, 900);
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: AppTheme.light(),
        locale: const Locale('zh', 'CN'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        home: const Scaffold(
          body: Padding(
            padding: EdgeInsets.all(16),
            child: RecentPlaylistsSection(),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('上游依赖变化（reload）时不闪骨架：旧内容留在屏上', (tester) async {
    final reloadGate = Completer<List<Playlist>>();
    var loads = 0;

    final container = ProviderContainer(
      overrides: <Override>[
        recentPlaylistsProvider.overrideWith((ref) async {
          // 上游依赖：真实实现里是 `ref.watch(activeAddressProvider)`。
          ref.watch(_upstreamBumpProvider);
          loads += 1;
          if (loads == 1) {
            return <Playlist>[_pl('recent-1', '最近歌单')];
          }
          // 第二次计算挂在未完成的 future 上 → loading 态在屏上稳定停留。
          return reloadGate.future;
        }),
      ],
    );
    addTearDown(container.dispose);
    addTearDown(() {
      if (!reloadGate.isCompleted) reloadGate.complete(const <Playlist>[]);
    });

    await _pumpSection(tester, container);
    expect(find.text('最近歌单'), findsOneWidget, reason: '首次加载完成后应显示真实内容');
    expect(find.byType(DiscoverPlaylistCardLoading), findsNothing);

    // 上游依赖变化 → 下游 provider reload（不是 refresh）。
    container.read(_upstreamBumpProvider.notifier).state += 1;
    await tester.pump(); // 让 reload 的 AsyncLoading 落到这一帧上
    await tester.pump(); // 再一帧：确保 widget 已按最新 AsyncValue 重建

    final reloaded = container.read(recentPlaylistsProvider);
    expect(reloaded.isLoading, isTrue, reason: '上游依赖变化后应进入 loading 态');
    expect(
      reloaded.hasValue,
      isTrue,
      reason: 'reload 时必须保留 previous value，否则 skip 参数无从谈起',
    );
    expect(
      reloaded.isReloading,
      isTrue,
      reason: '「上游依赖变化」必须是 reload 语义（isReloading）而不是 refresh —— '
          'skipLoadingOnRefresh 的默认值管不着它，这正是当初闪一下的根因',
    );

    expect(
      find.text('最近歌单'),
      findsOneWidget,
      reason: 'reload 期间旧内容必须仍在屏上（用户报的「闪一下就空了」）',
    );
    expect(
      find.byType(DiscoverPlaylistCardLoading),
      findsNothing,
      reason: 'skipLoadingOnReload 不为 true 时这里会闪回 4 张骨架卡',
    );

    // 放行第二次计算：新内容正常上屏。
    reloadGate.complete(<Playlist>[_pl('recent-1', '最近歌单（已更新）')]);
    await tester.pump();
    await tester.pump();
    expect(find.text('最近歌单（已更新）'), findsOneWidget);
  });

  testWidgets('首次加载（无 previous value）仍然显示骨架', (tester) async {
    final firstLoad = Completer<List<Playlist>>();

    final container = ProviderContainer(
      overrides: <Override>[
        recentPlaylistsProvider.overrideWith((ref) async => firstLoad.future),
      ],
    );
    addTearDown(container.dispose);
    addTearDown(() {
      if (!firstLoad.isCompleted) firstLoad.complete(const <Playlist>[]);
    });

    await _pumpSection(tester, container);

    expect(
      find.byType(DiscoverPlaylistCardLoading),
      findsNWidgets(4),
      reason: '冷启动无缓存时首帧必须是骨架 —— 证明 skip 参数没有把首屏加载态'
          '一起吞掉（那会让冷启动变成一片空白）',
    );
    expect(find.byType(DiscoverPlaylistCard), findsNothing);

    // 放行后必须正常出内容：骨架是「在等」，不是「永远」。
    firstLoad.complete(<Playlist>[_pl('recent-1', '最近歌单')]);
    await tester.pump();
    await tester.pump();

    expect(find.text('最近歌单'), findsOneWidget);
    expect(find.byType(DiscoverPlaylistCardLoading), findsNothing);
  });
}
