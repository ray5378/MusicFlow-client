// GPU 智能按需渲染 · 门控行为测试（Windows 与 Android 共享同一套 Dart 逻辑）。
//
// 覆盖用户确认的四类门控：
//   1) 窗口不可见（最小化/失焦/切走，AppLifecycleState 非 resumed）→
//      TickerMode 全局静音 + appVisibilityProvider 冻结数据驱动 UI；
//   2) 播放状态门控：暂停不跳（跳动竖条冻结、黑胶停转）；
//   3) 大屏前台门控：黑胶只在 fullPlayerActive 时旋转、大屏歌词非大屏不渲染；
//   4) 冻结进度/歌词：窗口不可见时 UI 不再随播放推进重建，恢复可见立即对齐。
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

import 'package:musicflow_client/core/design/components/music_flow_skeleton.dart';
import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/data/models/lyrics_line.dart';
import 'package:musicflow_client/data/models/song.dart';
import 'package:musicflow_client/data/models/structured_lyrics.dart';
import 'package:musicflow_client/features/player/widgets/synced_lyrics_view.dart';
import 'package:musicflow_client/features/player/widgets/vinyl_record_cover.dart';
import 'package:musicflow_client/providers/app_visibility_provider.dart';
import 'package:musicflow_client/providers/effective_playback_provider.dart';
import 'package:musicflow_client/providers/frozen_playback_provider.dart';
import 'package:musicflow_client/providers/full_player_active_provider.dart';
import 'package:musicflow_client/providers/lyrics_cover_provider.dart';
import 'package:musicflow_client/widgets/now_playing_bars.dart';

/// 无限旋转动画的哨兵 widget：验证 TickerMode 全局静音是否生效。
class _InfiniteSpinner extends StatefulWidget {
  const _InfiniteSpinner();

  @override
  State<_InfiniteSpinner> createState() => _InfiniteSpinnerState();
}

class _InfiniteSpinnerState extends State<_InfiniteSpinner>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 500),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) => Opacity(
        opacity: _controller.value,
        child: const SizedBox(width: 10, height: 10),
      ),
    );
  }
}

Widget _wrap(Widget child, {List<Override> overrides = const []}) {
  return ProviderScope(
    overrides: overrides,
    child: MaterialApp(
      theme: AppTheme.dark(),
      home: Scaffold(body: Center(child: child)),
    ),
  );
}

/// 读取跳动竖条当前高度（3 根白条）。
List<double> _barHeights(WidgetTester tester) {
  final bars = find.descendant(
    of: find.byType(NowPlayingCoverOverlay),
    matching: find.byWidgetPredicate(
      (w) =>
          w is Container &&
          w.decoration is BoxDecoration &&
          ((w.decoration as BoxDecoration).color == Colors.white),
    ),
  );
  final heights = <double>[];
  for (var i = 0; i < bars.evaluate().length; i++) {
    heights.add(tester.getSize(bars.at(i)).height);
  }
  return heights;
}

void main() {
  group('AppVisibilityScope: 窗口不可见全局停帧', () {
    testWidgets('lifecycle 非 resumed → TickerMode 静音全部动画，resumed 恢复', (
      tester,
    ) async {
      await tester.pumpWidget(
        ProviderScope(
          child: AppVisibilityScope(
            child: MaterialApp(home: Scaffold(body: _InfiniteSpinner())),
          ),
        ),
      );
      await tester.pump();
      expect(tester.hasRunningAnimations, isTrue);

      // 最小化(paused) → 全部 ticker 静音，不再调度帧。
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(tester.hasRunningAnimations, isFalse);

      // 恢复前台(resumed) → 动画恢复。
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.hasRunningAnimations, isTrue);
    });

    testWidgets('appVisibilityProvider 随生命周期翻转', (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          child: AppVisibilityScope(
            child: MaterialApp(
              home: Consumer(
                builder: (context, ref, child) => Text(
                  ref.watch(appVisibilityProvider) ? 'visible' : 'hidden',
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('visible'), findsOneWidget);

      // 失焦(inactive) → 不可见（用户确认「关闭主窗口=失焦/切走」）。
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      expect(find.text('hidden'), findsOneWidget);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(find.text('visible'), findsOneWidget);
    });
  });

  group('冻结进度/歌词 provider: 窗口不可见时 UI 冻结, 恢复立即对齐', () {
    testWidgets('frozenPositionProvider 冻结与恢复', (tester) async {
      var position = const Duration(seconds: 1);
      final container = ProviderContainer(
        overrides: [
          effectivePositionProvider.overrideWith((ref) => position),
        ],
      );
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: Consumer(
              builder: (context, ref, child) => Text(
                ref.watch(frozenPositionProvider).inSeconds.toString(),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('1'), findsOneWidget);

      // 可见：进度推进 → UI 跟随。
      position = const Duration(seconds: 2);
      container.invalidate(effectivePositionProvider);
      await tester.pump();
      expect(find.text('2'), findsOneWidget);

      // 窗口不可见：进度推进 → UI 冻结在 2s。
      container.read(appVisibilityProvider.notifier).state = false;
      await tester.pump();
      position = const Duration(seconds: 3);
      container.invalidate(effectivePositionProvider);
      await tester.pump();
      expect(find.text('2'), findsOneWidget);

      // 恢复可见：立即跳回真实进度 3s。
      container.read(appVisibilityProvider.notifier).state = true;
      await tester.pump();
      expect(find.text('3'), findsOneWidget);
    });

    testWidgets('frozenLyricLineProvider 冻结最后一行', (tester) async {
      var line = '第一句';
      final container = ProviderContainer(
        overrides: [currentLyricLineProvider.overrideWith((ref) => line)],
      );
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: Consumer(
              builder: (context, ref, child) =>
                  Text(ref.watch(frozenLyricLineProvider) ?? '无歌词'),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('第一句'), findsOneWidget);

      container.read(appVisibilityProvider.notifier).state = false;
      await tester.pump();
      line = '第二句';
      container.invalidate(currentLyricLineProvider);
      await tester.pump();
      // 不可见期间歌词行冻结在「第一句」，不随播放推进。
      expect(find.text('第一句'), findsOneWidget);

      container.read(appVisibilityProvider.notifier).state = true;
      await tester.pump();
      expect(find.text('第二句'), findsOneWidget);
    });
  });

  group('跳动竖条: 播放状态门控（暂停不跳）', () {
    testWidgets('播放中跳、暂停冻结、恢复续跳', (tester) async {
      var playing = true;
      await tester.pumpWidget(
        _wrap(
          const NowPlayingCoverOverlay(size: 160),
          overrides: [effectiveIsPlayingProvider.overrideWith((ref) => playing)],
        ),
      );
      await tester.pump(); // didChangeDependencies → repeat
      await tester.pump(const Duration(milliseconds: 300));
      final heightsPlaying = _barHeights(tester);
      expect(heightsPlaying.length, 3);

      // 暂停 → 冻结在当前高度。
      playing = false;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      final heightsPaused1 = _barHeights(tester);
      await tester.pump(const Duration(milliseconds: 300));
      final heightsPaused2 = _barHeights(tester);
      expect(heightsPaused1, heightsPaused2);

      // 恢复播放 → 重新跳动（高度至少一根变化）。
      playing = true;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      final heightsResumed = _barHeights(tester);
      expect(heightsPaused1, isNot(equals(heightsResumed)));
    });
  });

  group('黑胶旋转: 大屏前台 + 播放中才转', () {
    // Song 无 const 构造（仅 id/title 必填，其余可选）。
    final song = Song(id: 'x', title: '测试曲');

    double rotationOf(WidgetTester tester) {
      final transform = tester.widget<Transform>(
        find.byType(Transform).first,
      );
      final m = transform.transform;
      return math.atan2(m.entry(1, 0), m.entry(0, 0));
    }

    testWidgets('暂停时停转、播放时旋转', (tester) async {
      var playing = true;
      await tester.pumpWidget(
        _wrap(
          VinylRecordCover(song: song, size: 200),
          overrides: [
            effectiveIsPlayingProvider.overrideWith((ref) => playing),
            fullPlayerActiveProvider.overrideWith((ref) => true),
          ],
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      final r1 = rotationOf(tester);

      // 暂停 → 冻结角度。
      playing = false;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      final r2 = rotationOf(tester);
      await tester.pump(const Duration(milliseconds: 500));
      final r3 = rotationOf(tester);
      expect(r2, r3);
      expect(r2, closeTo(r1, 0.001)); // 停转瞬间角度不突变（已冻结）

      // 恢复播放 → 继续旋转。
      playing = true;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(rotationOf(tester), isNot(closeTo(r3, 0.01)));
    });

    testWidgets('非大屏前台(fullPlayerActive=false)不旋转', (tester) async {
      await tester.pumpWidget(
        _wrap(
          VinylRecordCover(song: song, size: 200),
          overrides: [
            effectiveIsPlayingProvider.overrideWith((ref) => true),
            fullPlayerActiveProvider.overrideWith((ref) => false),
          ],
        ),
      );
      await tester.pump();
      final r1 = rotationOf(tester);
      await tester.pump(const Duration(milliseconds: 500));
      final r2 = rotationOf(tester);
      expect(r1, r2);
    });
  });

  group('大屏歌词: 非大屏模式自动关闭渲染', () {
    // StructuredLyrics / LyricsLine 均无 const 构造。
    StructuredLyrics lyrics() => StructuredLyrics(
      synced: true,
      lines: [
        LyricsLine(startMs: 0, value: '第一句'),
        LyricsLine(startMs: 5000, value: '第二句'),
      ],
    );

    testWidgets('fullPlayerActive=false 不渲染歌词列表', (tester) async {
      await tester.pumpWidget(
        _wrap(
          SyncedLyricsView(lyrics: lyrics()),
          overrides: [
            fullPlayerActiveProvider.overrideWith((ref) => false),
            effectivePositionProvider.overrideWith(
              (ref) => const Duration(seconds: 1),
            ),
          ],
        ),
      );
      await tester.pump();
      expect(find.byType(ScrollablePositionedList), findsNothing);
    });

    testWidgets('fullPlayerActive=true 正常渲染', (tester) async {
      await tester.pumpWidget(
        _wrap(
          SyncedLyricsView(lyrics: lyrics()),
          overrides: [
            fullPlayerActiveProvider.overrideWith((ref) => true),
            effectivePositionProvider.overrideWith(
              (ref) => const Duration(seconds: 1),
            ),
          ],
        ),
      );
      await tester.pump();
      expect(find.byType(ScrollablePositionedList), findsOneWidget);
    });
  });

  group('骨架屏 shimmer: 窗口不可见停帧', () {
    testWidgets('paused 停、resumed 恢复', (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          child: AppVisibilityScope(
            child: MaterialApp(
              theme: AppTheme.dark(),
              home: const Scaffold(
                body: MusicFlowSkeleton(height: 20),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(tester.hasRunningAnimations, isTrue);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(tester.hasRunningAnimations, isFalse);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.hasRunningAnimations, isTrue);
    });
  });
}
