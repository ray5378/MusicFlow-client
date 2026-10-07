// b37a2：`lib/features/player/widgets/mini_player.dart` 手机端「投屏中换强调色」分支
// （源码 418-420 三元表达式的 true 侧，实测 lcov 只命中了 false 侧 ink）。
//
// 既有 `mini_player_cov_test.dart` 渲染手机端时 `isCasting` 一律默认 false，
// 于是 `_buildMobileControls` 里 `widget.isCasting ? accent : ink` 的 accent
// 分支从未被取到（lcov：418:12 / 419:0 / 420:12）。本文件把手机端两态各渲染一次
// 并钉住「确实换色、且投屏色不是纯白」这一相对事实。
//
// [踩坑] 迷你条内层 `MusicFlowMediaColorScope` 会把 `context.musicFlowColors`
// 换成**媒体自适应**的那套（与 MiniPlayerView 外层 `Theme.of` 的 extension 不同，
// 同 mini_player_cov_test 的 #129-D）：所以断言**不能**拿外层语义色板做参照，
// 只能钉「投屏前后取色变了」这种相对事实。
//
// 只报告不修（源码核对后确认无调用方 / 被上层遮蔽）：
//   * 76 ：`MiniPlayerView.onSeek` 参数 —— `MiniPlayer` 永远显式传
//          `progressLayer: _ProviderMiniPlayerProgress()`（77 行），而 `onSeek`
//          只有在 `progressLayer == null` 时才会被 `_MiniPlayerProgressSurface`
//          消费（559-567 行）。真实链路走的是 `_ProviderMiniPlayerProgress`
//          内部自己的 `seekEffectivePlayback` 闭包（602 行）⇒ 76 行是**被遮蔽的
//          死闭包**（参数仍需保留以满足 required 约束）。
//   * 81-92：`showPlayerSwitcher` 的 `onTransfer` 闭包 —— 只有
//          `PlayerTransferPage` 内选中一个目标设备才会回调，属另一页的交互长尾。
//   * 646/672-677：拖动会话中途切歌的取消分支 —— `_MiniPlayerProgressSurface`
//          的 key 恒为 `ValueKey(currentSong?.id)`（560/594 行），切歌即**重建
//          State**、`_scrubbing` 归零，`_scrubSongId != widget.songId` 永远不成立
//          ⇒ 防御性死代码。
//   * 857：`_MiniPlayerTrack(useHero: false)` 的 `else title` 分支 ——
//          已由 batch41 E3 清理：useHero 参数与死分支删除，恒走 Hero 封装。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musicflow_client/core/design/music_flow_design.dart';
import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/data/models/song.dart';
import 'package:musicflow_client/features/player/widgets/mini_player.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:musicflow_client/providers/player/player_state.dart';

Song _song() => Song(
      id: 's1',
      title: '当前曲',
      artist: '歌手',
      album: '专辑',
      duration: 180,
    );

Widget _app({
  required bool isCasting,
  VoidCallback? onSwitchPlayer,
}) {
  return ProviderScope(
    child: MaterialApp(
      theme: AppTheme.dark(),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      locale: const Locale('zh'),
      home: Scaffold(
        body: Align(
          alignment: Alignment.bottomCenter,
          child: MiniPlayerView(
            playerState: PlayerState(
              currentSong: _song(),
              queue: <Song>[_song()],
              currentIndex: 0,
              position: const Duration(seconds: 30),
              duration: const Duration(minutes: 3),
            ),
            currentPlayerName: '客厅音箱',
            isCasting: isCasting,
            onOpenPlayer: () {},
            onTogglePlayPause: () async {},
            onSeek: (Duration _) async {},
            onSwitchPlayer: onSwitchPlayer ?? () {},
          ),
        ),
      ),
    ),
  );
}

Future<void> _pump(WidgetTester tester, Widget app) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(360, 800);
  addTearDown(tester.view.reset);
  await tester.pumpWidget(app);
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}

Color _castIconColor(WidgetTester tester) =>
    tester.widget<Icon>(find.byIcon(AppIcons.transferInfinity)).color!;

void main() {
  testWidgets('手机端流转按钮两态取色：投屏中改走 accent 分支（418-420）', (
    tester,
  ) async {
    // 手机端两键档：只有「播放」+「流转播放」，没有上一首/下一首。
    await _pump(tester, _app(isCasting: false));
    expect(find.bySemanticsLabel('播放'), findsOneWidget);
    expect(find.bySemanticsLabel('上一首'), findsNothing);
    expect(find.byIcon(AppIcons.transferInfinity), findsOneWidget);
    final inkColor = _castIconColor(tester);

    // 同一棵树换成投屏态（重建 ProviderScope 无关，色板只看 MediaColorScope）。
    await _pump(tester, _app(isCasting: true));
    final castColor = _castIconColor(tester);

    // ignore: avoid_print
    print('[b37a2] mini cast ink=$inkColor accent=$castColor');
    expect(
      castColor,
      isNot(inkColor),
      reason: '418-420 的 true 侧（accent）此前 0 命中，两态必须真的换色',
    );
    expect(
      castColor,
      isNot(const Color(0xFFFFFFFF)),
      reason: '投屏色是过对比度后的 accent，不是纯白',
    );
    expect(inkColor.a, 1.0, reason: '非投屏取 ink（实色）');
    expect(tester.takeException(), isNull);
  });

  testWidgets('手机端点流转按钮 → 回调 onSwitchPlayer（按钮接线）', (tester) async {
    var switched = 0;
    await _pump(tester, _app(isCasting: false, onSwitchPlayer: () => switched++));

    await tester.tap(find.byIcon(AppIcons.transferInfinity));
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }

    expect(switched, 1);
    expect(tester.takeException(), isNull);
  });
}
