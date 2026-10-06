// b39c —— Route C 补测：`lib/features/player/pages/full_player_page.dart` 剩余缺口。
//
// 覆盖点：
//   * 694：`_WideDragBanner` 的 `onTap: () {}`（Windows 桌面端宽屏布局里的
//     拖拽条真实构建）。需要宽视口 + `Theme.platform == windows`（走宽屏布局）
//     且 `isWindowsDesktop`（走 native 标题栏拖拽条）。
//
// 报告为**不可达 / 死代码**（见文末）：
//   * 624：`_buildSongIdentity` 的 SingleChildScrollView 分支 —— 两处调用
//     （476/530）都传 `scrollable: false`，`if (!scrollable) return identity;` 恒命中。
//   * 809/811/812：`_PlayerLyricsPane` 的 `bestLyrics == null` 分支 ——
//     `Lyrics.getBest()` 仅在 `entries.isEmpty` 时返回 null，而 800 行
//     `lyrics.isEmpty` 已先拦截 ⇒ 死代码。
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/data/models/song.dart';
import 'package:musicflow_client/features/player/pages/full_player_page.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:musicflow_client/providers/media/lyrics_cover_provider.dart';
import 'package:musicflow_client/providers/player/player_provider.dart';
import 'package:musicflow_client/providers/ui/palette_provider.dart';

import '../test_player_notifier.dart';

Song _song() => Song(
      id: 'current',
      title: 'Who are you',
      artist: 'Cesária Évora',
      album: 'Café Atlantico',
      duration: 240,
      bitRate: 320,
    );

Widget _app(PlayerState state) {
  return ProviderScope(
    overrides: <Override>[
      playerProvider.overrideWith((ref) => TestPlayerNotifier(state)),
      currentSongPaletteProvider.overrideWith((ref) async => null),
      resolvedCurrentSongMediaVisualsProvider.overrideWithValue(
        MusicFlowMediaVisuals.fallback(),
      ),
      currentLyricsProvider.overrideWith((ref) async => null),
    ],
    child: MaterialApp(
      theme: AppTheme.dark(),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      locale: const Locale('zh'),
      home: const FullPlayerPage(),
    ),
  );
}

void main() {
  testWidgets('Windows 宽屏 → 拖拽条真实构建（694）', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1440, 900);
    addTearDown(tester.view.reset);
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;

    await tester.pumpWidget(_app(PlayerState(currentSong: _song())));
    await tester.pumpAndSettle();

    // 宽屏（非触屏）布局被选中 ⇒ _WideDragBanner 在 Windows 下被构建。
    expect(
      find.byKey(const ValueKey<String>('full_player_wide_layout')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);

    debugDefaultTargetPlatformOverride = null;
  });
}
