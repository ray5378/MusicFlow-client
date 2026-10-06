// b38c3 —— full_player_page.dart 剩余可达分支补测（Route C）。
//
// 单点缺口：line 1545 `_PlayerIconButton.build` 的 `!enabled → colors.onDisabled`
// —— 即「队列入口按钮 onPressed == null 时用禁用前景色」。
//
// 该分支在生产里不可达：唯一可为空的入口是公开的 PlaybackControls.onOpenQueue，
// 而全屏播放器总传 `_openQueue`（非空）。因此这里直接挂一个 onOpenQueue: null
// 的 PlaybackControls（公开类）把该分支走通。
//
// 同文件其余缺口经核对为不可达/已由他处钉住，仅报告不测：
//   * 624  `_buildSongIdentity` 的 `if (!scrollable) return identity;` 之后
//         SingleChildScrollView 分支 —— 两处调用（476/530）都传 scrollable:false；
//   * 694  `_WideDragBanner` 的 `onTap: () {}` —— [D-045] 已由 b30c 守卫用例钉住现状；
//   * 809/811/812 `_PlayerLyricsPane` 的 `bestLyrics == null` 分支 —— getBest 仅在
//         entries.isEmpty 时返回 null，而 800 行已拦截，属死代码。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musicflow_client/core/design/music_flow_design.dart';
import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/data/models/song.dart';
import 'package:musicflow_client/features/player/pages/full_player_page.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:musicflow_client/providers/cast/cast_peer_provider.dart';
import 'package:musicflow_client/providers/cast/dlna_provider.dart';
import 'package:musicflow_client/providers/player/player_provider.dart';

import '../test_player_notifier.dart';

Song _song() => Song(
      id: 'current',
      title: 'Who are you',
      artist: 'Cesária Évora',
      album: 'Café Atlantico',
      duration: 240,
    );

void main() {
  testWidgets('onOpenQueue == null → 队列入口按钮走禁用前景色', (tester) async {
    late AppLocalizations loc;
    late MusicFlowColors colors;

    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          playerProvider.overrideWith(
            (ref) => TestPlayerNotifier(PlayerState(currentSong: _song())),
          ),
          castPeerControllerProvider.overrideWith(
            (Ref ref) => CastPeerController(ref),
          ),
          dlnaCastProvider.overrideWith((Ref ref) => DlnaCastNotifier(ref)),
        ],
        child: MaterialApp(
          theme: AppTheme.dark(),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          locale: const Locale('zh'),
          builder: (context, child) {
            loc = AppLocalizations.of(context);
            colors = context.musicFlowColors;
            return child!;
          },
          home: const Scaffold(
            body: Center(
              child: SizedBox(
                width: 600,
                height: 200,
                child: PlaybackControls(onOpenQueue: null),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 队列图标仍在（按钮照样渲染），但其前景色必须是禁用色。
    final queueIcon = tester.widget<Icon>(
      find.byIcon(AppIcons.queue),
    );
    expect(queueIcon.color, colors.onDisabled);

    // 队列入口确实是「禁用态」：语义标签仍是「队列」，但 onPressed 为 null。
    final queueButton = tester.widget<MusicFlowPressable>(
      find.byWidgetPredicate(
        (Widget w) =>
            w is MusicFlowPressable && w.semanticLabel == loc.player_queue,
      ),
    );
    expect(queueButton.onPressed, isNull);

    // 其余四个按钮（模式/上一首/播放/下一首）仍是可用态，取非禁用前景色。
    expect(
      tester
          .widget<Icon>(find.byIcon(AppIcons.previous))
          .color,
      isNot(colors.onDisabled),
    );
    expect(tester.takeException(), isNull);
  });
}
