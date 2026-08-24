import 'package:musicflow_client/core/design/echo_design.dart';
import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/data/models/song.dart';
import 'package:musicflow_client/features/player/widgets/mini_player.dart';
import 'package:musicflow_client/features/player/widgets/player_hero_helpers.dart';
import 'package:musicflow_client/providers/palette_provider.dart';
import 'package:musicflow_client/providers/player_provider.dart';
import 'package:musicflow_client/widgets/cover_art_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final songs = <Song>[
    Song(id: 'a', title: 'Before', artist: 'Artist A'),
    Song(
      id: 'b',
      title: 'A very long current song title that still remains operable',
      artist: 'Artist B',
    ),
    Song(id: 'c', title: 'After', artist: 'Artist C'),
  ];

  PlayerState playerState({bool playing = false}) => PlayerState(
    currentSong: songs[1],
    queue: songs,
    currentIndex: 1,
    isPlaying: playing,
    position: const Duration(seconds: 50),
    duration: const Duration(seconds: 200),
  );

  Widget appFor(
    Widget child, {
    double textScale = 1,
    bool disableAnimations = true,
  }) {
    return ProviderScope(
      child: MaterialApp(
        theme: AppTheme.dark(),
        builder: (context, appChild) {
          final media = MediaQuery.of(context);
          return MediaQuery(
            data: media.copyWith(
              textScaler: TextScaler.linear(textScale),
              disableAnimations: disableAnimations,
            ),
            child: appChild!,
          );
        },
        home: Scaffold(
          body: Align(alignment: Alignment.bottomCenter, child: child),
        ),
      ),
    );
  }

  MiniPlayerView view({
    required PlayerState state,
    Future<void> Function()? onToggle,
    Future<void> Function(Duration)? onSeek,
    VoidCallback? onOpen,
    VoidCallback? onSwitchPlayer,
    String currentPlayerName = '本机',
    EchoMediaVisuals? mediaVisuals,
    Color? albumColor,
  }) {
    return MiniPlayerView(
      playerState: state,
      onOpenPlayer: onOpen ?? () {},
      onTogglePlayPause: onToggle ?? () async {},
      onSeek: onSeek ?? (_) async {},
      onSwitchPlayer: onSwitchPlayer ?? () {},
      currentPlayerName: currentPlayerName,
      mediaVisuals: mediaVisuals,
      albumColor: albumColor,
    );
  }

  testWidgets('stays 72dp, keeps two visible actions, and survives 200% text', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(360, 800);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(appFor(view(state: playerState()), textScale: 2));
    await tester.pump();

    expect(
      tester.getSize(find.byKey(const Key('mini-player-surface'))).height,
      MiniPlayer.height,
    );
    // 产品定版:手机端两键 = 播放暂停 + 投屏控制(切换播放器)。
    expect(find.byType(EchoIconButton), findsNWidgets(2));
    expect(find.bySemanticsLabel('播放'), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp('切换播放器')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('mini bar exposes no prev/next buttons by design', (tester) async {
    await tester.pumpWidget(appFor(view(state: playerState())));
    await tester.pump();

    expect(find.bySemanticsLabel('上一首'), findsNothing);
    expect(find.bySemanticsLabel('下一首'), findsNothing);
  });

  testWidgets('transport buttons drive toggle and switcher', (tester) async {
    var toggles = 0;
    var switches = 0;
    await tester.pumpWidget(
      appFor(
        view(
          state: playerState(),
          onToggle: () async => toggles += 1,
          onSwitchPlayer: () => switches += 1,
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.bySemanticsLabel('播放'));
    await tester.pump();
    await tester.tap(find.bySemanticsLabel(RegExp('切换播放器')));
    await tester.pump();

    expect(toggles, 1);
    expect(switches, 1);
  });

  testWidgets('switcher action carries the current player name feedback', (
    tester,
  ) async {
    await tester.pumpWidget(
      appFor(view(state: playerState(), currentPlayerName: '客厅音箱')),
    );
    await tester.pump();

    // 非投屏时 MiniPlayer 默认名称为「本机」,这里传入设备名验证透传:
    // 语义标签携带当前播放器名称,作为切换播放器的状态反馈。
    // 切换播放器图标统一使用 DLNA(投放)图标。
    expect(find.byIcon(AppIcons.dlna), findsOneWidget);
    final labeled = find.bySemanticsLabel(RegExp('切换播放器，当前：客厅音箱'));
    expect(labeled, findsOneWidget);

    // 投屏态由 MiniPlayer 的 provider 分支注入设备名,这里验证
    // currentPlayerName 会透传到切换按钮的语义标签。
    final widget = tester.widget<MiniPlayerView>(
      find.byType(MiniPlayerView),
    );
    expect(widget.currentPlayerName, '客厅音箱');
  });

  testWidgets(
    'progress spans the surface, sits at the bottom, and shares its clip',
    (tester) async {
      await tester.pumpWidget(appFor(view(state: playerState())));
      await tester.pump();

      final surface = find.byKey(const Key('mini-player-surface'));
      final progress = find.byKey(const Key('mini-player-progress'));
      final surfaceRect = tester.getRect(surface);
      final progressRect = tester.getRect(progress);
      final progressBar = tester.widget<EchoProgressBar>(progress);
      final fraction = tester.widget<AnimatedFractionallySizedBox>(
        find.descendant(
          of: progress,
          matching: find.byType(AnimatedFractionallySizedBox),
        ),
      );
      final surfaceClip = find.ancestor(
        of: progress,
        matching: find.byKey(const Key('mini-player-surface-clip')),
      );
      final clip = tester.widget<ClipRRect>(surfaceClip);

      expect(progressRect.left, surfaceRect.left);
      expect(progressRect.right, surfaceRect.right);
      expect(progressRect.bottom, surfaceRect.bottom);
      expect(surfaceClip, findsOneWidget);
      expect(clip.borderRadius, tester.element(surface).echoRadii.surface);
      expect(clip.clipBehavior, isNot(Clip.none));
      expect(progressBar.trackColor, Colors.transparent);
      expect(fraction.alignment, Alignment.centerLeft);
      expect(fraction.widthFactor, closeTo(0.25, 0.001));
    },
  );

  testWidgets('bright and dark visuals drive local player tokens', (
    tester,
  ) async {
    for (final seed in const <Color>[Color(0xFFFFD54F), Color(0xFF14213D)]) {
      final visuals = EchoMediaVisuals.fallback(seed: seed);
      await tester.pumpWidget(
        appFor(
          view(
            state: playerState(),
            mediaVisuals: visuals,
            albumColor: const Color(0xFF7B1E3A),
          ),
        ),
      );
      await tester.pump();

      // 迷你条标题以「歌名 - 歌手」富文本(Text.rich)展示,用 textContaining 匹配。
      final title = tester.widget<Text>(
        find.textContaining(songs[1].title),
      );
      final playIcon = tester.widget<Icon>(find.byIcon(AppIcons.play));
      final progress = tester.widget<EchoProgressBar>(
        find.byKey(const Key('mini-player-progress')),
      );
      final backdrop = tester.widget<EchoPlayerBackdrop>(
        find.byType(EchoPlayerBackdrop),
      );
      final backgroundHero = tester.widget<Hero>(
        find.ancestor(
          of: find.byType(EchoPlayerBackdrop),
          matching: find.byType(Hero),
        ),
      );
      // 迷你条标题以「歌名 - 歌手」富文本(Text.rich)展示:颜色在首段 TextSpan 的
      // style 上(EchoMediaColorScope 注入 visuals.foreground),而非 Text.style。
      final titleSpan = (title.textSpan as TextSpan).children!.first
          as TextSpan;
      expect(titleSpan.style?.color, visuals.foreground);
      expect(playIcon.color, visuals.foreground);
      expect(progress.color, visuals.controlAccent);
      expect(backdrop.visuals, visuals);
      expect(backdrop.mode, EchoPlayerBackdropMode.mini);
      expect(
        backgroundHero.flightShuttleBuilder,
        playerBackgroundFlightShuttleBuilder,
      );
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('preserves tap, double tap, swipe up, and scrub gestures', (
    tester,
  ) async {
    var opens = 0;
    var toggles = 0;
    final seeks = <Duration>[];
    await tester.pumpWidget(
      appFor(
        view(
          state: playerState(),
          onOpen: () => opens += 1,
          onToggle: () async => toggles += 1,
          onSeek: (target) async => seeks.add(target),
        ),
      ),
    );

    final track = find.byKey(const Key('mini-player-track'));
    await tester.tap(track);
    await tester.pump(const Duration(milliseconds: 350));
    expect(opens, 1);

    await tester.tap(track);
    await tester.pump(const Duration(milliseconds: 40));
    await tester.tap(track);
    await tester.pump(const Duration(milliseconds: 350));
    expect(toggles, 1);

    await tester.fling(track, const Offset(0, -80), 900);
    await tester.pump();
    expect(opens, 2);

    final scrubber = find.byKey(const Key('mini-player-scrubber'));
    final rect = tester.getRect(scrubber);
    final gesture = await tester.startGesture(
      Offset(rect.left + rect.width * 0.1, rect.center.dy),
    );
    await gesture.moveTo(Offset(rect.left + rect.width * 0.75, rect.center.dy));
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 60));

    expect(seeks, hasLength(1));
    expect(seeks.single.inSeconds, closeTo(150, 2));
  });

  testWidgets('shuffle queue never previews guessed adjacent covers', (
    tester,
  ) async {
    final shuffled = PlayerState(
      currentSong: songs[1],
      queue: songs,
      currentIndex: 1,
      shuffleEnabled: true,
      position: const Duration(seconds: 50),
      duration: const Duration(seconds: 200),
    );
    await tester.pumpWidget(appFor(view(state: shuffled)));
    await tester.pump();

    expect(find.text('Before'), findsNothing);
    expect(find.text('After'), findsNothing);
  });

  testWidgets('preview songs use their remote cover in the compact player', (
    tester,
  ) async {
    final preview = Song(
      id: 'preview',
      title: 'Preview',
      isPreview: true,
      previewCoverUrl: 'https://images.example.test/preview.jpg',
    );
    final state = PlayerState(
      currentSong: preview,
      queue: <Song>[preview],
      duration: const Duration(minutes: 3),
    );

    await tester.pumpWidget(appFor(view(state: state)));
    await tester.pump();

    final covers = tester
        .widgetList<CoverArtImage>(find.byType(CoverArtImage))
        .where(
          (candidate) =>
              candidate.coverArtId == 'https://images.example.test/preview.jpg',
        );
    expect(covers, isNotEmpty);
  });
}
