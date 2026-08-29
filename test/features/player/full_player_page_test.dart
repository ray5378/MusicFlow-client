
import 'package:musicflow_client/core/design/music_flow_design.dart';
import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/data/models/audio_quality.dart';
import 'package:musicflow_client/data/models/song.dart';
import 'package:musicflow_client/features/player/pages/full_player_page.dart';
import 'package:musicflow_client/features/player/widgets/mini_player.dart';
import 'package:musicflow_client/features/player/widgets/player_hero_helpers.dart';
import 'package:musicflow_client/features/player/widgets/player_scrubber.dart';
import 'package:musicflow_client/providers/lyrics_cover_provider.dart';
import 'package:musicflow_client/providers/palette_provider.dart';
import 'package:musicflow_client/providers/player_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart' hide PlayerState;

import 'test_player_notifier.dart';

MusicFlowPressable? _heartPressable(WidgetTester tester, IconData icon) {
  final pressable = find.ancestor(
    of: find.byIcon(icon),
    matching: find.byType(MusicFlowPressable),
  );
  if (pressable.evaluate().isEmpty) return null;
  return tester.widget<MusicFlowPressable>(pressable.first);
}

/// 复现 [MusicFlowMediaColorScope] 针对某个媒体表面(surface)求出的语义令牌。
/// 作用域把 ink 归一为 black/white 可读前景、muted 保底 4.5:1、accent 相对该
/// 表面保底对比,而不是直接沿用 visuals 的裸 foreground/controlAccent。
({Color surface, Color ink, Color muted, Color accent}) _mediaScopeTokens(
  MusicFlowMediaVisuals visuals,
  Color surface,
) {
  final ink = MusicFlowColors.readableOn(surface);
  final muted = MusicFlowColors.ensureColorContrast(
    Color.lerp(ink, surface, 0.30)!,
    background: surface,
    minimumRatio: 4.5,
  );
  final accent = MusicFlowColors.ensureColorContrast(
    visuals.controlAccent,
    background: surface,
  );
  return (surface: surface, ink: ink, muted: muted, accent: accent);
}

void main() {
  final song = Song(
    id: 'current',
    title:
        'A deliberately long player title that must remain usable at large text sizes',
    artist: 'A long artist name',
    album: 'A long album name',
    bitRate: 320,
    bitDepth: 24,
    samplingRate: 96000,
  );

  PlayerState initialState() => PlayerState(
    currentSong: song,
    queue: <Song>[
      song,
      Song(id: 'next', title: 'Next song'),
    ],
    currentIndex: 0,
    isPlaying: true,
    position: const Duration(seconds: 30),
    duration: const Duration(minutes: 4),
    bufferedPosition: const Duration(minutes: 2),
    loopMode: LoopMode.all,
    currentQuality: AudioQualityLevel.original,
    playbackSource: PlaybackSource.stream,
    currentBitRateKbps: 320,
  );

  Widget providerApp({
    required TestPlayerNotifier notifier,
    required Widget home,
    double textScale = 1,
    bool disableAnimations = true,
    MusicFlowMediaVisuals? visuals,
  }) {
    final resolvedVisuals = visuals ?? MusicFlowMediaVisuals.fallback();
    return ProviderScope(
      overrides: [
        playerProvider.overrideWith((ref) => notifier),
        currentSongPaletteProvider.overrideWith((ref) async => null),
        resolvedCurrentSongMediaVisualsProvider.overrideWithValue(
          resolvedVisuals,
        ),
        currentLyricsProvider.overrideWith((ref) async => null),
      ],
      child: MaterialApp(
        theme: AppTheme.dark(),
        builder: (context, child) {
          final media = MediaQuery.of(context);
          return MediaQuery(
            data: media.copyWith(
              textScaler: TextScaler.linear(textScale),
              disableAnimations: disableAnimations,
            ),
            child: child!,
          );
        },
        home: home,
      ),
    );
  }



  void expectControlHierarchy(WidgetTester tester) {
    final transport = find.byKey(
      const ValueKey<String>('full_player_transport_controls'),
    );
    final utility = find.byKey(
      const ValueKey<String>('full_player_utility_bar'),
    );
    expect(transport, findsOneWidget);
    expect(utility, findsOneWidget);
    // 底部音质信息栏已移除：信息迁移到歌曲信息页。
    expect(
      find.byKey(const ValueKey<String>('full_player_quality_metadata')),
      findsNothing,
    );
    // 图标断言(widget 树),语义树在测试环境不可靠。
    expect(
      find.descendant(of: transport, matching: find.byIcon(AppIcons.previous)),
      findsOneWidget,
    );
    // 播放/暂停随状态二选一。
    expect(
      find.descendant(
        of: transport,
        matching: find.byWidgetPredicate((w) =>
            w is Icon &&
            (w.icon == AppIcons.play || w.icon == AppIcons.pause)),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(of: transport, matching: find.byIcon(AppIcons.next)),
      findsOneWidget,
    );
    // 播放模式与队列下沉到播放控制行两侧(参考截图布局)。
    expect(
      find.descendant(
        of: transport,
        matching: find.byWidgetPredicate((w) =>
            w is Icon &&
            (w.icon == AppIcons.shuffle ||
                w.icon == AppIcons.repeat ||
                w.icon == AppIcons.repeatOne)),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(of: transport, matching: find.byIcon(AppIcons.queue)),
      findsOneWidget,
    );
    // 工具栏精简为 4 项:DLNA 直投(最左) / 红心 / 音量 / 切换播放器(最右)。
    expect(
      find.descendant(
          of: utility, matching: find.byIcon(AppIcons.heartOutline)),
      findsOneWidget,
    );
    expect(
      find.descendant(
          of: utility, matching: find.byIcon(AppIcons.dlnaLocal)),
      findsOneWidget,
    );
    expect(
      find.descendant(
          of: utility, matching: find.byIcon(AppIcons.signalTower)),
      findsOneWidget,
    );
    expect(
      find.descendant(of: transport, matching: find.byIcon(AppIcons.heart)),
      findsNothing,
    );
  }

  testWidgets('full player keeps Hero contract and works at 200% text', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 800);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    final notifier = TestPlayerNotifier(initialState());
    await tester.pumpWidget(
      providerApp(
        notifier: notifier,
        textScale: 2,
        home: const FullPlayerPage(),
      ),
    );
    await tester.pump();
    await tester.pump();

    final tags = tester
        .widgetList<Hero>(find.byType(Hero))
        .map((hero) => hero.tag)
        .toSet();
    expect(
      tags,
      containsAll(<Object>[
        playerBackgroundHeroTag,
        playerCoverHeroTag,
        playerTitleHeroTag,
        playerSubtitleHeroTag,
      ]),
    );
    expect(find.byIcon(AppIcons.chevronDown), findsOneWidget);
    expect(find.byIcon(AppIcons.pause), findsOneWidget);
    expect(find.byIcon(AppIcons.queue), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('full_player_portrait_layout')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('full_player_wide_layout')),
      findsNothing,
    );
    final closePressable = find.ancestor(
      of: find.byIcon(AppIcons.chevronDown),
      matching: find.byType(MusicFlowPressable),
    );
    expect(tester.getSize(closePressable.first).height, greaterThanOrEqualTo(48));
    expectControlHierarchy(tester);
    expect(tester.takeException(), isNull);
  });

  testWidgets('play glyph is optically centered inside the primary control', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(360, 800);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    final notifier = TestPlayerNotifier(
      initialState().copyWith(isPlaying: false),
    );
    await tester.pumpWidget(
      providerApp(notifier: notifier, home: const FullPlayerPage()),
    );
    await tester.pump();

    final glyph = find.byKey(
      const ValueKey<String>('full_player_primary_transport_glyph'),
    );
    expect(glyph, findsOneWidget);
    expect(find.byIcon(AppIcons.play), findsOneWidget);

    var transform = tester.widget<Transform>(glyph);
    expect(transform.transform.getTranslation().x, closeTo(2.88, 0.01));
    expect(transform.transform.getTranslation().y, 0);

    await tester.tap(find.byIcon(AppIcons.play));
    await tester.pump();

    expect(find.byIcon(AppIcons.pause), findsOneWidget);
    transform = tester.widget<Transform>(glyph);
    expect(transform.transform.getTranslation().x, 0);
    expect(transform.transform.getTranslation().y, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'landscape player uses two columns and keeps controls reachable at 130%',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(800, 360);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      // 分栏大屏布局只对非触屏(键鼠/指针)平台启用。
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);

      // 暂停态:黑胶旋转为无限动画,会让 pumpAndSettle 无法收敛。
      final notifier = TestPlayerNotifier(
        initialState().copyWith(isPlaying: false),
      );
      await tester.pumpWidget(
        providerApp(
          notifier: notifier,
          textScale: 1.3,
          disableAnimations: false,
          home: const FullPlayerPage(),
        ),
      );
      await tester.pumpAndSettle();

      final wideLayout = find.byKey(
        const ValueKey<String>('full_player_wide_layout'),
      );
      final artworkPane = find.byKey(
        const ValueKey<String>('full_player_artwork_pane'),
      );
      final detailsPane = find.byKey(
        const ValueKey<String>('full_player_details_pane'),
      );
      expect(wideLayout, findsOneWidget);
      expect(
        find.byKey(const ValueKey<String>('full_player_portrait_layout')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey<String>('full_player_cover')),
        findsOneWidget,
      );
      expect(find.byType(MusicFlowPlayerScrubber), findsOneWidget);
      final heroTags = tester
          .widgetList<Hero>(find.byType(Hero))
          .map((hero) => hero.tag)
          .toSet();
      expect(
        heroTags,
        containsAll(<Object>[
          playerBackgroundHeroTag,
          playerCoverHeroTag,
          playerTitleHeroTag,
          playerSubtitleHeroTag,
        ]),
      );

      final artworkRect = tester.getRect(artworkPane);
      final detailsRect = tester.getRect(detailsPane);
      expect(artworkRect.right, lessThan(detailsRect.left));
      expect(artworkRect.height, closeTo(detailsRect.height, 0.1));
      expectControlHierarchy(tester);

      // 主播放按钮(播放/暂停随状态二选一)可达且落在窗口内。
      final primaryGlyph = find.descendant(
        of: find.byKey(
          const ValueKey<String>('full_player_transport_controls'),
        ),
        matching: find.byWidgetPredicate(
          (w) =>
              w is Icon &&
              (w.icon == AppIcons.play || w.icon == AppIcons.pause),
        ),
      );
      final primaryPressable = find.ancestor(
        of: primaryGlyph,
        matching: find.byType(MusicFlowPressable),
      );
      final primaryRect = tester.getRect(primaryPressable.first);
      expect(primaryRect.width, greaterThanOrEqualTo(48));
      expect(primaryRect.height, greaterThanOrEqualTo(48));
      expect(primaryRect.top, greaterThanOrEqualTo(0));
      expect(primaryRect.bottom, lessThanOrEqualTo(360));
      expect(tester.takeException(), isNull);

      // 右侧详情面板常驻歌词。
      expect(
        find.descendant(of: detailsPane, matching: find.text('暂无歌词')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      // 平台 override 须在测试体结束前复位:校验早于任何 addTearDown。
      debugDefaultTargetPlatformOverride = null;
    },
  );

  testWidgets('expanded portrait width also uses the player split layout', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(900, 1200);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    // 分栏大屏布局只对非触屏(键鼠/指针)平台启用。
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);

    final notifier = TestPlayerNotifier(initialState());
    await tester.pumpWidget(
      providerApp(
        notifier: notifier,
        textScale: 1.3,
        home: const FullPlayerPage(),
      ),
    );
    await tester.pump();

    expect(
      find.byKey(const ValueKey<String>('full_player_wide_layout')),
      findsOneWidget,
    );
    expect(
      tester
          .getRect(
            find.byKey(const ValueKey<String>('full_player_artwork_pane')),
          )
          .right,
      lessThan(
        tester
            .getRect(
              find.byKey(const ValueKey<String>('full_player_details_pane')),
            )
            .left,
      ),
    );
    expectControlHierarchy(tester);
    expect(tester.takeException(), isNull);
    // 平台 override 须在测试体结束前复位:校验早于任何 addTearDown。
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('reduced-motion close collapses lyrics before popping', (
    tester,
  ) async {
    final notifier = TestPlayerNotifier(initialState());
    await tester.pumpWidget(
      providerApp(
        notifier: notifier,
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => Navigator.of(context).push<void>(
                MaterialPageRoute<void>(builder: (_) => const FullPlayerPage()),
              ),
              child: const Text('打开播放器'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开播放器'));
    await tester.pumpAndSettle();
    // 三页结构:[歌词(0) / 封面(1) / 信息(2)]。封面左滑进歌曲信息页。
    await tester.drag(
      find.byKey(const ValueKey<String>('full_player_cover')),
      const Offset(-500, 0),
    );
    await tester.pumpAndSettle();
    expect(find.text('歌曲信息'), findsOneWidget);

    // 右滑回封面页，再右滑进入歌词页。
    await tester.drag(
      find.byKey(const ValueKey<String>('full_player_song_info_page')),
      const Offset(500, 0),
    );
    await tester.pumpAndSettle();
    await tester.drag(
      find.byKey(const ValueKey<String>('full_player_cover')),
      const Offset(500, 0),
    );
    await tester.pumpAndSettle();
    expect(find.text('暂无歌词'), findsOneWidget);

    await tester.tap(find.byIcon(AppIcons.chevronDown));
    await tester.pump();
    await tester.pump();
    await tester.pumpAndSettle();

    expect(find.byType(FullPlayerPage), findsNothing);
    expect(find.text('打开播放器'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'route foreground fades progress and controls together on close',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(360, 800);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);

      // 暂停态:黑胶旋转为无限动画,会让 pumpAndSettle 无法收敛。
      final notifier = TestPlayerNotifier(
        initialState().copyWith(isPlaying: false),
      );
      await tester.pumpWidget(
        providerApp(
          notifier: notifier,
          disableAnimations: false,
          home: const Scaffold(
            body: Align(alignment: Alignment.bottomCenter, child: MiniPlayer()),
          ),
        ),
      );
      await tester.pump();

      await tester.tap(find.byKey(const Key('mini-player-track')));
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
      expect(find.byType(FullPlayerPage), findsOneWidget);

      final foreground = find.byKey(
        const ValueKey<String>('full_player_foreground_transition'),
      );
      expect(foreground, findsOneWidget);
      expect(
        find.descendant(of: foreground, matching: find.byType(ProgressBar)),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: foreground,
          matching: find.byKey(
            const ValueKey<String>('full_player_transport_controls'),
          ),
        ),
        findsOneWidget,
      );

      await tester.tap(find.byIcon(AppIcons.chevronDown));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 90));

      final fade = tester.widget<FadeTransition>(foreground);
      expect(fade.opacity.value, greaterThan(0));
      expect(fade.opacity.value, lessThan(1));
      expect(find.byType(ProgressBar), findsOneWidget);

      await tester.pumpAndSettle();
      expect(find.byType(FullPlayerPage), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('playback mode cycles in the established three-state order', (
    tester,
  ) async {
    final notifier = TestPlayerNotifier(initialState());
    await tester.pumpWidget(
      providerApp(notifier: notifier, home: const FullPlayerPage()),
    );
    await tester.pump();

    await tester.tap(find.byIcon(AppIcons.repeat));
    await tester.pump();
    expect(find.byIcon(AppIcons.repeatOne), findsOneWidget);

    await tester.tap(find.byIcon(AppIcons.repeatOne));
    await tester.pump();
    expect(find.byIcon(AppIcons.shuffle), findsOneWidget);

    await tester.tap(find.byIcon(AppIcons.shuffle));
    await tester.pump();
    expect(find.byIcon(AppIcons.repeat), findsOneWidget);

    MusicFlowPressable? unstarredPressable =
        _heartPressable(tester, AppIcons.heartOutline);
    expect(unstarredPressable?.selected ?? false, isFalse);
    await tester.tap(find.byIcon(AppIcons.heartOutline));
    await tester.pump();
    expect(find.byIcon(AppIcons.heart), findsOneWidget);
    final starredPressable = _heartPressable(tester, AppIcons.heart);
    expect(starredPressable?.selected ?? false, isTrue);
  });

  testWidgets('progress remains seekable with buffered state', (tester) async {
    final notifier = TestPlayerNotifier(initialState());
    await tester.pumpWidget(
      providerApp(notifier: notifier, home: const FullPlayerPage()),
    );
    await tester.pump();

    final progressSlider = find.byType(MusicFlowPlayerScrubber);
    expect(progressSlider, findsOneWidget);

    await tester.drag(progressSlider, const Offset(120, 0));
    await tester.pump();

    // 拖动即发起 seek(语义树在测试环境不生成,改为行为断言)。
    expect(notifier.seekTargets, isNotEmpty);
  });

  testWidgets('changing songs cancels an in-flight seek', (tester) async {
    final notifier = TestPlayerNotifier(initialState());
    await tester.pumpWidget(
      providerApp(notifier: notifier, home: const FullPlayerPage()),
    );
    await tester.pump();

    final scrubber = find.byType(MusicFlowPlayerScrubber);
    final gesture = await tester.startGesture(tester.getCenter(scrubber));
    await tester.pumpAndSettle();
    await gesture.moveBy(const Offset(80, 0));
    await tester.pump();
    expect(notifier.seekTargets, isEmpty);

    final nextSong = notifier.state.queue[1];
    notifier.emit(
      initialState().copyWith(
        currentSong: nextSong,
        currentIndex: 1,
        position: const Duration(seconds: 5),
        duration: const Duration(minutes: 3),
        bufferedPosition: const Duration(seconds: 30),
      ),
    );
    await tester.pump();
    await gesture.up();
    await tester.pump();

    expect(notifier.seekTargets, isEmpty);
    expect(
      tester
          .getSemantics(find.byType(MusicFlowPlayerScrubber))
          .getSemanticsData()
          .value,
      '0:05 / 3:00',
    );
  });

  testWidgets('bright artwork installs dark player ink and system chrome', (
    tester,
  ) async {
    final visuals = MusicFlowMediaVisuals.fallback(seed: const Color(0xFFFFE36B));
    expect(visuals.foreground.computeLuminance(), lessThan(0.1));

    await tester.pumpWidget(
      providerApp(
        notifier: TestPlayerNotifier(initialState()),
        home: const FullPlayerPage(),
        visuals: visuals,
      ),
    );
    await tester.pump();

    // 顶栏「正在播放」文字已换成页签圆点：改取收起按钮所在上下文校验
    // 媒体作用域令牌(按钮位于 MusicFlowMediaColorScope 内)。
    final titleContext = tester.element(find.byIcon(AppIcons.chevronDown));
    final stageTokens = _mediaScopeTokens(visuals, visuals.stageBase);
    expect(titleContext.musicFlowColors.ink, stageTokens.ink);
    expect(titleContext.musicFlowColors.muted, stageTokens.muted);
    expect(titleContext.musicFlowColors.canvas, visuals.stageBase);

    final backdrop = tester.widget<MusicFlowPlayerBackdrop>(
      find.byType(MusicFlowPlayerBackdrop),
    );
    expect(backdrop.mode, MusicFlowPlayerBackdropMode.stage);
    expect(backdrop.visuals, visuals);

    final scrubber = tester.widget<MusicFlowPlayerScrubber>(
      find.byType(MusicFlowPlayerScrubber),
    );
    expect(scrubber.activeColor, stageTokens.accent);
    expect(scrubber.thumbColor, stageTokens.ink);

    final overlay = tester
        .widgetList<AnnotatedRegion<SystemUiOverlayStyle>>(
          find.byType(AnnotatedRegion<SystemUiOverlayStyle>),
        )
        .firstWhere(
          (region) =>
              region.value.systemNavigationBarColor == visuals.stageBottom,
        )
        .value;
    expect(overlay.statusBarIconBrightness, Brightness.dark);
    expect(overlay.systemNavigationBarIconBrightness, Brightness.dark);
  });

  testWidgets('full-player song actions use the album-derived panel palette', (
    tester,
  ) async {
    final visuals = MusicFlowMediaVisuals.fallback(seed: const Color(0xFFBFD7EA));

    await tester.pumpWidget(
      providerApp(
        notifier: TestPlayerNotifier(initialState()),
        home: const FullPlayerPage(),
        visuals: visuals,
      ),
    );
    await tester.pump();

    // 「更多」按钮已从顶栏移除：左滑进信息页，从「歌曲操作」入口打开
    // 同一个操作面板（下一曲播放/添加到歌单/跳转歌手与专辑 全部保留）。
    await tester.drag(
      find.byKey(const ValueKey<String>('full_player_cover')),
      const Offset(-500, 0),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('歌曲操作'));
    await tester.pumpAndSettle();

    final sheet = find.byType(MusicFlowBottomSheet);
    expect(sheet, findsOneWidget);
    final sheetTitle = find.descendant(of: sheet, matching: find.text('歌曲操作'));
    final sheetContext = tester.element(sheetTitle);
    final panelTokens = _mediaScopeTokens(visuals, visuals.panelSurface);
    expect(sheetContext.musicFlowColors.surface, visuals.panelSurface);
    expect(sheetContext.musicFlowColors.accent, panelTokens.accent);
    expect(sheetContext.musicFlowColors.ink, panelTokens.ink);
    expect(sheetContext.musicFlowColors.muted, panelTokens.muted);

    final heart = tester.widget<Icon>(
      find.descendant(of: sheet, matching: find.byIcon(AppIcons.heartOutline)),
    );
    expect(heart.color, panelTokens.accent);
    expect(tester.takeException(), isNull);
  });
}
