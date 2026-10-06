// b35a —— full_player_page.dart 歌词区补测（Route A 尾部攻坚）。
//
// 打 batch34 主动放弃后剩下的歌词相关分支：
//   * _PlayerLyricsPane：空歌词 → 无歌词文案；仅非同步歌词 → SyncedLyricsView；
//     加载中 → 骨架屏；加载失败 → 错误文案 + 重试按钮（点了真的 invalidate 重拉）；
//   * _CurrentLyricLine（首屏当前行）：同步双语行拆主/副行、纯主行、空行隐藏、
//     未同步歌词整体隐藏；
//   * 死代码 candidate：`bestLyrics == null` 分支在 entries 非空时不可达
//     （getBest 仅在 entries.isEmpty 时返回 null，而 800 行已拦截）——只报告不修。
//
// 布局约定：_PlayerLyricsPane 在宽屏右栏常驻（debugDefaultTargetPlatformOverride
// = windows, 1440x900）；_CurrentLyricLine 在竖屏首页（默认 android 平台，
// PageView 初始页 1）。
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/data/models/lyrics.dart';
import 'package:musicflow_client/data/models/lyrics_line.dart';
import 'package:musicflow_client/data/models/structured_lyrics.dart';
import 'package:musicflow_client/data/models/song.dart';
import 'package:musicflow_client/features/player/pages/full_player_page.dart';
import 'package:musicflow_client/features/player/widgets/synced_lyrics_view.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:musicflow_client/providers/media/lyrics_cover_provider.dart';
import 'package:musicflow_client/providers/player/player_provider.dart';
import 'package:musicflow_client/providers/ui/palette_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'test_player_notifier.dart';

AppLocalizations? loc;

Song _song() => Song(
      id: 'current',
      title: 'Who are you',
      artist: 'Cesária Évora',
      album: 'Café Atlantico',
      duration: 240,
      bitRate: 320,
    );

class _RootScreen extends StatelessWidget {
  const _RootScreen();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: ElevatedButton(
          key: const ValueKey<String>('b35a_open_full_player'),
          onPressed: () {
            Navigator.of(context).push<void>(
              MaterialPageRoute<void>(
                builder: (_) => const FullPlayerPage(),
              ),
            );
          },
          child: const Text('open'),
        ),
      ),
    );
  }
}

Lyrics _lyrics(List<StructuredLyrics> entries) =>
    Lyrics(sourceId: 'current', entries: entries);

StructuredLyrics _synced(List<LyricsLine> lines) => StructuredLyrics(
      lang: 'zh',
      synced: true,
      lines: lines,
    );

Widget providerApp({
  required PlayerState state,
  required double width,
  required double height,
  required Future<Lyrics?> Function() lyricsFn,
}) {
  return ProviderScope(
    overrides: <Override>[
      playerProvider.overrideWith((ref) => TestPlayerNotifier(state)),
      currentSongPaletteProvider.overrideWith((ref) async => null),
      resolvedCurrentSongMediaVisualsProvider.overrideWithValue(
        MusicFlowMediaVisuals.fallback(),
      ),
      currentLyricsProvider.overrideWith((ref) => lyricsFn()),
    ],
    child: MaterialApp(
      theme: AppTheme.dark(),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      locale: const Locale('zh'),
      builder: (context, child) {
        loc = AppLocalizations.of(context);
        return child!;
      },
      home: const _RootScreen(),
    ),
  );
}

Future<void> pumpApp(
  WidgetTester tester, {
  PlayerState? state,
  double width = 1440,
  double height = 900,
  required Future<Lyrics?> Function() lyricsFn,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(width, height);
  addTearDown(tester.view.reset);
  SharedPreferences.setMockInitialValues(<String, Object>{});
  await tester.pumpWidget(
    providerApp(
      state: state ?? PlayerState(currentSong: _song()),
      width: width,
      height: height,
      lyricsFn: lyricsFn,
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> enterFullPlayer(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey<String>('b35a_open_full_player')));
  await tester.pumpAndSettle();
}

/// 宽屏（windows 平台）进全屏播放器：右栏歌词面板常驻可见。
Future<void> pumpWide(WidgetTester tester, Future<Lyrics?> Function() lyricsFn,
    {PlayerState? state}) async {
  debugDefaultTargetPlatformOverride = TargetPlatform.windows;
  try {
    await pumpApp(tester, lyricsFn: lyricsFn, state: state);
    await enterFullPlayer(tester);
  } finally {
    debugDefaultTargetPlatformOverride = null;
  }
}

void main() {
  group('_PlayerLyricsPane 分支', () {
    testWidgets('空歌词 → 渲染「暂无歌词」消息面板', (tester) async {
      await pumpWide(tester, () async => _lyrics(const <StructuredLyrics>[]));

      expect(find.text(loc!.player_no_lyrics_title), findsOneWidget);
      expect(find.text(loc!.player_no_lyrics_desc), findsOneWidget);
      expect(find.byType(SyncedLyricsView), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('仅非同步歌词 → 也渲染 SyncedLyricsView', (tester) async {
      await pumpWide(
        tester,
        () async => _lyrics(<StructuredLyrics>[
          StructuredLyrics(
            lang: 'zh',
            synced: false,
            lines: <LyricsLine>[LyricsLine(value: '普通歌词行')],
          ),
        ]),
      );

      expect(find.byType(SyncedLyricsView), findsOneWidget);
      expect(find.text(loc!.player_no_lyrics_title), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('歌词加载中 → 渲染骨架屏占位', (tester) async {
      await pumpWide(
        tester,
        () => Completer<Lyrics?>().future,
      );

      expect(
        find.byWidgetPredicate(
          (Widget w) => w is Semantics && w.properties.label == loc!.player_lyrics_loading,
        ),
        findsOneWidget,
      );
      expect(find.byType(SyncedLyricsView), findsNothing);
      expect(find.text(loc!.player_no_lyrics_title), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('歌词加载失败 → 错误面板,点重试后重新拉取并渲染同步歌词', (tester) async {
      var calls = 0;
      await pumpWide(
        tester,
        () async {
          calls += 1;
          if (calls == 1) {
            throw StateError('lyrics down');
          }
          return _lyrics(<StructuredLyrics>[
            _synced(<LyricsLine>[
              LyricsLine(startMs: 0, value: '第一行'),
            ]),
          ]);
        },
      );

      expect(find.text(loc!.player_lyrics_load_failed_title), findsOneWidget);
      expect(find.text(loc!.widgets_retry), findsOneWidget);
      expect(find.byType(SyncedLyricsView), findsNothing);

      await tester.tap(find.text(loc!.widgets_retry));
      await tester.pumpAndSettle();

      expect(calls, 2);
      expect(find.byType(SyncedLyricsView), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('_CurrentLyricLine 分支（竖屏首页）', () {
    testWidgets('同步双语行拆出主行与副行', (tester) async {
      await pumpApp(
        tester,
        lyricsFn: () async => _lyrics(<StructuredLyrics>[
          _synced(<LyricsLine>[
            LyricsLine(startMs: 0, value: 'Hello World 你好世界'),
            LyricsLine(startMs: 30000, value: '只有主行'),
          ]),
        ]),
        state: PlayerState(
          currentSong: _song(),
          position: const Duration(seconds: 10),
        ),
      );
      await enterFullPlayer(tester);

      expect(find.text('Hello World'), findsOneWidget);
      expect(find.text('你好世界'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('单语言行只渲染主行', (tester) async {
      await pumpApp(
        tester,
        lyricsFn: () async => _lyrics(<StructuredLyrics>[
          _synced(<LyricsLine>[
            LyricsLine(startMs: 0, value: '第一句'),
            LyricsLine(startMs: 30000, value: '只有主行'),
          ]),
        ]),
        state: PlayerState(
          currentSong: _song(),
          position: const Duration(seconds: 35),
        ),
      );
      await enterFullPlayer(tester);

      expect(find.text('只有主行'), findsOneWidget);
      expect(find.text('第一句'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('当前行为空白 → 当前歌词行整体隐藏', (tester) async {
      await pumpApp(
        tester,
        lyricsFn: () async => _lyrics(<StructuredLyrics>[
          _synced(<LyricsLine>[
            LyricsLine(startMs: 0, value: '第一句'),
            LyricsLine(startMs: 1000, value: '   '),
            LyricsLine(startMs: 60000, value: '第三行'),
          ]),
        ]),
        state: PlayerState(
          currentSong: _song(),
          position: const Duration(seconds: 5),
        ),
      );
      await enterFullPlayer(tester);

      expect(find.text('第一句'), findsNothing);
      expect(find.text('第三行'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('仅有非同步歌词 → 当前歌词行隐藏', (tester) async {
      await pumpApp(
        tester,
        lyricsFn: () async => _lyrics(<StructuredLyrics>[
          StructuredLyrics(
            lang: 'zh',
            synced: false,
            lines: <LyricsLine>[LyricsLine(value: '纯文本歌词')],
          ),
        ]),
        state: PlayerState(currentSong: _song()),
      );
      await enterFullPlayer(tester);

      expect(find.text('纯文本歌词'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });
}
