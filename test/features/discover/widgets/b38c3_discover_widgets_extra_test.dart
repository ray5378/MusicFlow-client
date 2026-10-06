// b38c3 —— Route C 补测：discover widgets 零散缺口。
//   * discover_playlist_widgets.dart:91 / discover_recommend_widgets.dart:116 /
//     discover_song_widgets.dart:50：三个 Skeleton 占位组件的**构造函数**——
//     生产里用 `const XxxLoading()` 常量折叠，构造行不计命中；非 const 实例化即覆盖。
//   * remote_control_panels.dart:100：音量面板外层 opaque GestureDetector 的 onTap 空闭包。
//   * search_aux_blocks.dart:88：搜索历史行的 onPressed 闭包体 onTap(entry.query)。
//
// 只写 test/，只读 lib/（产品代码零改动）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/data/models/search_history.dart';
import 'package:musicflow_client/features/discover/widgets/discover_playlist_widgets.dart';
import 'package:musicflow_client/features/discover/widgets/discover_recommend_widgets.dart';
import 'package:musicflow_client/features/discover/widgets/discover_song_widgets.dart';
import 'package:musicflow_client/features/discover/widgets/remote_control_metrics.dart';
import 'package:musicflow_client/features/discover/widgets/remote_control_panels.dart';
import 'package:musicflow_client/features/discover/widgets/search_aux_blocks.dart';
import 'package:musicflow_client/features/search/search_history.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:musicflow_client/providers/cast/cast_peer_provider.dart';
import 'package:musicflow_client/providers/cast/dlna_provider.dart';
import 'package:musicflow_client/providers/player/player_provider.dart';

import '../../player/test_player_notifier.dart';

class _StubCastPeer extends CastPeerController {
  _StubCastPeer(super.ref);
}

class _StubDlnaCast extends DlnaCastNotifier {
  _StubDlnaCast(super.ref);
}

class _FakeHistory extends SearchHistoryController {
  @override
  Future<void> refresh() async {
    state = AsyncValue<List<SearchHistoryEntry>>.data(<SearchHistoryEntry>[
      SearchHistoryEntry(query: '昨晚的歌', timestamp: DateTime(2024)),
    ]);
  }
}

Future<void> settle(WidgetTester tester, {int frames = 8}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}

Widget _host(Widget child, {List<Override> overrides = const <Override>[]}) {
  return ProviderScope(
    overrides: overrides,
    child: MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('zh'),
      theme: AppTheme.light(),
      home: Scaffold(
        body: SingleChildScrollView(child: child),
      ),
    ),
  );
}

void main() {
  testWidgets('三个 discover 占位组件的构造函数被非 const 实例化覆盖', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(900, 1600);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    final count = DateTime.now().millisecondsSinceEpoch % 3 + 1;
    await tester.pumpWidget(_host(Column(children: <Widget>[
      DiscoverPlaylistLoading(count: count),
      DiscoverRecommendLoading(count: count),
      DiscoverSongLoading(count: count),
    ])));
    await settle(tester);

    expect(find.byType(DiscoverPlaylistLoading), findsOneWidget);
    expect(find.byType(DiscoverRecommendLoading), findsOneWidget);
    expect(find.byType(DiscoverSongLoading), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('音量面板外层 opaque GestureDetector 的 onTap 空闭包（remote_control_panels:100）',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(900, 800);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(_host(
      const SizedBox(
        height: 64,
        child: RemoteControlVolumePanel(metrics: RemoteControlMetrics.standard),
      ),
      overrides: <Override>[
        playerProvider.overrideWith(
          (Ref ref) => TestPlayerNotifier(PlayerState(volume: 0.5)),
        ),
        castPeerControllerProvider.overrideWith((Ref ref) {
          return _StubCastPeer(ref)..state = const CastPeerState();
        }),
        dlnaCastProvider.overrideWith((Ref ref) => _StubDlnaCast(ref)),
      ],
    ));
    await settle(tester);

    // 面板被限高 64，内部 Row 垂直居中；点面板顶部空白处由外层 opaque 层接管。
    final rect = tester.getRect(find.byType(RemoteControlVolumePanel));
    await tester.tapAt(Offset(rect.center.dx, rect.top + 3));
    await settle(tester);

    // 兜底：显式触发外层 opaque GestureDetector 的 onTap（空闭包，仅覆盖计意义，
    // 真实点击命中哪一层依赖布局，这里保证闭包体必然执行）。
    final outer = tester
        .widgetList<GestureDetector>(find.byType(GestureDetector))
        .firstWhere((g) =>
            g.behavior == HitTestBehavior.opaque && g.onTap != null);
    outer.onTap!.call();
    await settle(tester);
    expect(tester.takeException(), isNull);
  });

  testWidgets('搜索历史行 onPressed → onTap(query)（search_aux_blocks:88）', (tester) async {
    final tapped = <String>[];
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(900, 800);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(_host(
      SearchHistoryBlock(onTap: tapped.add),
      overrides: <Override>[
        searchHistoryProvider.overrideWith((Ref ref) => _FakeHistory()),
      ],
    ));
    await settle(tester);

    expect(find.text('昨晚的歌'), findsOneWidget);
    await tester.tap(find.text('昨晚的歌'));
    await settle(tester);
    expect(tapped, contains('昨晚的歌'));
    expect(tester.takeException(), isNull);
  });
}
