// GPU 智能按需渲染 · 门控行为测试（Windows 与 Android 共享同一套 Dart 逻辑）。
//
// 覆盖用户确认的四类门控：
//   1) 窗口完全不可见（最小化/隐藏 paused|hidden、销毁 detached）→
//      TickerMode 全局静音 + appVisibilityProvider 冻结数据驱动 UI；
//      失焦(inactive)≠不可见——窗口仍在屏幕上、内容仍可见，保持渲染（仅隔离）；
//   2) 播放状态门控：暂停不跳（跳动竖条冻结、黑胶停转）；
//   3) 大屏前台门控：黑胶只在 fullPlayerActive 时旋转、大屏歌词非大屏不渲染；
//   4) 冻结进度/歌词：窗口完全不可见时 UI 不再随播放推进重建，恢复可见立即对齐。
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

/// 读取跳动竖条当前高度（3 根白条）。改为读取合帧 CustomPainter 的当前相位高度。
List<double> _barHeights(WidgetTester tester) {
  final painter = tester.widget<CustomPaint>(
    find.descendant(
      of: find.byType(NowPlayingCoverOverlay),
      matching: find.byType(CustomPaint),
    ),
  );
  return (painter.painter! as JumpingBarsPainter).barHeights();
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

      // 失焦(inactive)：窗口仍可见 → ticker 保持运行，动画不静音。
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
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
          child: AppVisibilityScope(child: MaterialApp(home: const SizedBox())),
        ),
      );
      await tester.pump();
      // 直接读 provider 值断言：paused 会禁帧(scheduler _setFramesEnabledState(false)),
      // markNeedsBuild→scheduleFrame 被吞 → tester.pump 不画帧 → 无法用 find.text 验证
      // widget 重建(禁帧正是不可见态预期行为)。provider 值才是门控真源。
      final ctx = tester.element(find.byType(AppVisibilityScope));
      final container = ProviderScope.containerOf(ctx);
      expect(container.read(appVisibilityProvider), isTrue, reason: '初始可见');

      // 失焦(inactive)：窗口仍在屏幕上、内容仍可见 → 保持可见、继续渲染
      //（用户确认：失焦只是不在最前端，不是不可见）。
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      expect(
        container.read(appVisibilityProvider),
        isTrue,
        reason: 'inactive 失焦仍可见',
      );

      // 最小化(paused)：窗口从屏幕消失 → 不可见、冻结。
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      expect(
        container.read(appVisibilityProvider),
        isFalse,
        reason: 'paused 最小化不可见',
      );

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(
        container.read(appVisibilityProvider),
        isTrue,
        reason: 'resumed 恢复可见',
      );
    });
  });

  group('冻结进度/歌词 provider: 窗口不可见时 UI 冻结, 恢复立即对齐', () {
    testWidgets('frozenPositionProvider 冻结与恢复', (tester) async {
      // StateProvider 中转：setState 同步通知，避免裸容器 invalidate 走
      // ProviderScheduler 的 Future(task) 异步调度（pump 不等事件队列）。
      final positionProvider = StateProvider<Duration>(
        (ref) => const Duration(seconds: 1),
      );
      final container = ProviderContainer(
        overrides: [
          effectivePositionProvider.overrideWith(
            (ref) => ref.watch(positionProvider),
          ),
        ],
      );
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: Consumer(
              builder: (context, ref, child) =>
                  Text(ref.watch(frozenPositionProvider).inSeconds.toString()),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('1'), findsOneWidget);

      // 可见：进度推进 → UI 跟随。
      container.read(positionProvider.notifier).state = const Duration(
        seconds: 2,
      );
      await tester.pump();
      expect(find.text('2'), findsOneWidget);

      // 窗口不可见：进度推进 → UI 冻结在 2s。
      container.read(appVisibilityProvider.notifier).state = false;
      await tester.pump();
      container.read(positionProvider.notifier).state = const Duration(
        seconds: 3,
      );
      await tester.pump();
      expect(find.text('2'), findsOneWidget);

      // 恢复可见：立即跳回真实进度 3s。
      container.read(appVisibilityProvider.notifier).state = true;
      await tester.pump();
      expect(find.text('3'), findsOneWidget);
    });

    testWidgets('frozenLyricLineProvider 冻结最后一行', (tester) async {
      final lyricProvider = StateProvider<String?>((ref) => '第一句');
      final container = ProviderContainer(
        overrides: [
          currentLyricLineProvider.overrideWith(
            (ref) => ref.watch(lyricProvider),
          ),
        ],
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
      container.read(lyricProvider.notifier).state = '第二句';
      await tester.pump();
      // 不可见期间歌词行冻结在「第一句」，不随播放推进。
      expect(find.text('第一句'), findsOneWidget);

      container.read(appVisibilityProvider.notifier).state = true;
      await tester.pump();
      expect(find.text('第二句'), findsOneWidget);
    });
  });

  group('封面播放指示: 静态竖条标志(不跳,零动画开销)', () {
    testWidgets('静态三根竖条恒定,无持续动画', (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            theme: AppTheme.dark(),
            home: const Scaffold(
              body: Center(child: NowPlayingCoverOverlay(size: 160)),
            ),
          ),
        ),
      );
      await tester.pump();
      final h1 = _barHeights(tester);
      expect(h1.length, 3);
      expect(h1, everyElement(isNonNegative));

      // 静态标志：时间流逝后高度完全不变,且无任何持续动画(running animation)。
      await tester.pump(const Duration(milliseconds: 300));
      final h2 = _barHeights(tester);
      expect(h1, h2, reason: '静态标志高度恒定,不随时间变化');
      expect(tester.hasRunningAnimations, isFalse, reason: '静态标志零动画开销');
    });
  });

  group('黑胶封面: 静态不旋转(已彻底移除旋转开销)', () {
    // Song 无 const 构造（仅 id/title 必填，其余可选）。
    final song = Song(id: 'x', title: '测试曲');

    testWidgets('无论播放与否均为静态,无持续动画', (tester) async {
      await tester.pumpWidget(
        _wrap(
          VinylRecordCover(song: song, size: 200),
          overrides: [effectiveIsPlayingProvider.overrideWith((ref) => true)],
        ),
      );
      // 静态封面没有持续动画：帧立刻能 settle（无 Ticker/Timer 持续调度）。
      // 若黑胶仍残留持续旋转，这里会因持续动画而 pumpAndSettle 超时失败。
      await tester.pumpAndSettle();
      expect(tester.hasRunningAnimations, isFalse, reason: '静态封面零持续动画');
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
          SyncedLyricsView(lyrics: lyrics(), fullPlayerActive: false),
          overrides: [
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
          SyncedLyricsView(lyrics: lyrics(), fullPlayerActive: true),
          overrides: [
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
              home: const Scaffold(body: MusicFlowSkeleton(height: 20)),
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
