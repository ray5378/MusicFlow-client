import 'package:musicflow_client/core/design/music_flow_design.dart';
import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/core/utils/cover_ref_security.dart';
import 'package:musicflow_client/data/models/song.dart';
import 'package:musicflow_client/features/player/widgets/play_queue_sheet.dart';
import 'package:musicflow_client/providers/player_provider.dart';
import 'package:musicflow_client/widgets/cover_art_image.dart';
import 'package:musicflow_client/widgets/now_playing_bars.dart';
import 'package:musicflow_client/widgets/song_list_item.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final songs = <Song>[
    Song(id: 'a', title: 'Current song', artist: 'First artist'),
    Song(
      id: 'b',
      title: 'A long queued song title that may wrap at large text sizes',
      artist: 'Second artist with a long display name',
      isPreview: true,
      previewCoverUrl: 'https://images.example.test/preview.jpg',
    ),
  ];

  Widget buildSubject({
    required PlayerState state,
    required Future<void> Function(int) onSelect,
    required Future<void> Function() onClear,
    required QueueSongAction onOpenSongActions,
    double textScale = 1,
    MusicFlowMediaVisuals? mediaVisuals,
    Color? albumColor,
  }) {
    return ProviderScope(
      child: MaterialApp(
        theme: AppTheme.dark(),
        builder: (context, child) {
          final media = MediaQuery.of(context);
          return MediaQuery(
            data: media.copyWith(
              textScaler: TextScaler.linear(textScale),
              disableAnimations: true,
            ),
            child: child!,
          );
        },
        home: Scaffold(
          body: SizedBox.expand(
            child: PlayQueueSheetView(
              playerState: state,
              mediaVisuals: mediaVisuals,
              albumColor: albumColor,
              onSelect: onSelect,
              onClear: onClear,
              onOpenSongActions: onOpenSongActions,
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('queue rows remain operable at 200% text', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 800);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    final selected = <int>[];
    var cleared = 0;
    final opened = <int>[];
    await tester.pumpWidget(
      buildSubject(
        state: PlayerState(
          currentSong: songs.first,
          queue: songs,
          currentIndex: 0,
        ),
        textScale: 2,
        onSelect: (index) async => selected.add(index),
        onClear: () async => cleared += 1,
        onOpenSongActions: (context, index, song) async => opened.add(index),
      ),
    );
    await tester.pump();

    expect(find.bySemanticsLabel('关闭播放队列'), findsOneWidget);
    expect(find.byType(MusicFlowSongRow), findsNWidgets(2));
    expect(find.byType(CoverArtImage), findsNWidgets(2));
    expect(find.bySemanticsLabel(RegExp('正在播放')), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp('试听')), findsOneWidget);
    // 当前行封面内展示「跳动竖条」播放指示器（替代旧的角标 equalizer）。
    expect(find.byType(NowPlayingCoverOverlay), findsOneWidget);
    expect(find.text('2'), findsNothing);
    final covers = tester.widgetList<CoverArtImage>(find.byType(CoverArtImage));
    expect(isTrustedCoverUrlRef(covers.last.coverArtId), isTrue);
    expect(
      extractTrustedCoverUrl(covers.last.coverArtId),
      'https://images.example.test/preview.jpg',
    );
    expect(find.bySemanticsLabel(RegExp('更多操作')), findsNothing);
    expect(
      find.descendant(
        of: find.byType(ListView),
        matching: find.byType(MusicFlowDivider),
      ),
      findsNothing,
    );
    expect(tester.takeException(), isNull);

    // 队列行的“更多操作”走长按(showMoreButton:false),点按仅切歌不弹菜单。
    await tester.ensureVisible(find.text(songs[1].title));
    await tester.pump();
    await tester.tap(find.text(songs[1].title));
    await tester.pump();
    expect(selected, <int>[1]);
    expect(opened, isEmpty);

    await tester.ensureVisible(find.text(songs[1].title));
    await tester.pump();
    await tester.longPress(find.text(songs[1].title));
    await tester.pump();
    expect(selected, <int>[1]);
    expect(opened, <int>[1]);

    await tester.drag(find.byType(ListView), const Offset(0, 600));
    // 当前行封面含无限循环的跳动竖条动画，pumpAndSettle 永不稳定，改用固定时长 pump。
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.longPress(find.text(songs.first.title));
    await tester.pump();
    expect(selected, <int>[1]);
    expect(opened, <int>[1, 0]);

    final clearQueue = find.bySemanticsLabel(RegExp('清空后续播放队列'));
    await tester.tap(clearQueue);
    await tester.pump();
    expect(cleared, 1);
  });

  testWidgets('queue content consumes the panel media color scope', (
    tester,
  ) async {
    final visuals = MusicFlowMediaVisuals.fallback(seed: const Color(0xFFBFD7EA));
    await tester.pumpWidget(
      buildSubject(
        state: PlayerState(
          currentSong: songs.first,
          queue: songs,
          currentIndex: 0,
        ),
        mediaVisuals: visuals,
        albumColor: const Color(0xFF7B1E3A),
        onSelect: (_) async {},
        onClear: () async {},
        onOpenSongActions: (context, index, song) async {},
      ),
    );
    await tester.pump();

    final surface = tester.widget<MusicFlowSurface>(find.byType(MusicFlowSurface).first);
    final currentTitle = tester.widget<Text>(find.text(songs.first.title));
    expect(surface.color, visuals.panelSurface);
    // 当前曲目标题走 media scope 内的 colors.accent(相对 panelSurface 做对比保底),
    // 并非原始 controlAccent。按同样逻辑算期望值。
    final accent = MusicFlowColors.ensureColorContrast(
      visuals.controlAccent,
      background: visuals.panelSurface,
    );
    expect(currentTitle.style?.color, accent);
  });

  testWidgets('empty queue explains the state and disables clear', (
    tester,
  ) async {
    await tester.pumpWidget(
      buildSubject(
        state: PlayerState(),
        onSelect: (_) async {},
        onClear: () async {},
        onOpenSongActions: (context, index, song) async {},
      ),
    );
    await tester.pump();

    expect(find.text('队列为空'), findsOneWidget);
    expect(find.text('清空后续队列'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'long queue auto-centers the current row into the viewport middle',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(320, 800);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);

      // 随机/长队列:当前播放位于深位置(模拟 shuffle 后 index=100/120),
      // 打开队列时必须自动滚动到视口中间,而不是停在顶部。
      final longQueue = List<Song>.generate(
        120,
        (i) => Song(id: 's$i', title: 'Song $i', artist: 'Artist $i'),
      );
      const currentIndex = 100;

      await tester.pumpWidget(
        buildSubject(
          state: PlayerState(
            currentSong: longQueue[currentIndex],
            queue: longQueue,
            currentIndex: currentIndex,
          ),
          onSelect: (_) async {},
          onClear: () async {},
          onOpenSongActions: (context, index, song) async {},
        ),
      );
      // 居中链:initState postFrame → 比例法粗估 jumpTo → refine → ensureVisible
      // (disableAnimations 下动画归零但仍需多帧调度)。
      // 当前行封面含无限循环跳动竖条动画,pumpAndSettle 永不稳定,用固定时长 pump。
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump(const Duration(milliseconds: 320));
      await tester.pump(const Duration(milliseconds: 320));

      // 当前行必须已实例化(滚动到可视区)。
      final currentFinder = find.text('Song $currentIndex');
      expect(currentFinder, findsOneWidget);

      // 且位于列表视口中间附近(上、下方都还有内容)。
      final listRect = tester.getRect(find.byType(ListView));
      final rowTop = tester.getTopLeft(currentFinder).dy;
      expect(
        rowTop,
        greaterThan(listRect.top + listRect.height * 0.2),
        reason: '当前行应位于视口中间附近,而不是顶部',
      );
      expect(
        rowTop,
        lessThan(listRect.top + listRect.height * 0.8),
        reason: '当前行应位于视口中间附近,而不是底部',
      );
    },
  );
}
