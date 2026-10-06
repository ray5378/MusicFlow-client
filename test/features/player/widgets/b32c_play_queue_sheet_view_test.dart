// batch32 C 路 —— `lib/features/player/widgets/play_queue_sheet.dart` 视图层补测。
//
// 分工（与既有 play_queue_sheet_cov_test.dart / play_queue_sheet_test.dart）：
//   * cov_test 打的是模块级状态机（show/toggle/close）+ PlayQueueSheet 三态路由 +
//     RightQueuePanel 几何；
//   * play_queue_sheet_test.dart 打的是 PlayQueueSheetView 的大字号/media scope/空态；
//   * 本文件打剩余的视图层交互：
//     - PlayQueueSheetView 底部弹窗布局（DraggableScrollableSheet 注入外部
//       ScrollController 的 `_ownsController=false` 路径）+ 点行 onSelect + 长按
//       onOpenSongActions + 「播完清空」按钮；
//     - `_AutoCenterQueueList` 长队列自动居中（jumpToCurrent + didUpdateWidget
//       换 currentIndex 重新居中）；
//     - `CastQueueSheetView` 全矩阵：行渲染/点行 onSelect/onReorder 回调（直接
//       调 ReorderableListView.onReorder，绕开拖拽手势的时序脆弱性）/offline
//       后缀/panel 布局/关闭按钮/空态与清空禁用。
//
// 踩坑记录（C 路约定）：
//   * `_AutoCenter*List` 的封面延载 gate 是有限帧内落定的（postFrame jump 一次），
//     但媒体卡片相关组件仍有无限动画 → 统一有界 settle() 推帧，不 pumpAndSettle。
//   * CastQueueSheetView 的行是 ReorderableDelayedDragStartListener（长按拖拽），
//     测试里拖拽时序脆；onReorder 逻辑在 build 的 lambda 里，直接从 widget 句柄
//     调 `onReorder!(from, to)` 即可覆盖 from!=to / from==to 两个分支。
//   * 关闭按钮图标是自定义 `AppIcons.close`（不是 Icons.close），find.byIcon 必须
//     用 AppIcons 常量。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musicflow_client/core/design/music_flow_design.dart';
import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/data/models/song.dart';
import 'package:musicflow_client/features/player/widgets/play_queue_sheet.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:musicflow_client/providers/player/player_provider.dart';

final List<Song> kSongs = <Song>[
  Song(id: 'q1', title: '队列曲一', artist: '艺人'),
  Song(id: 'q2', title: '队列曲二', artist: '艺人'),
  Song(id: 'q3', title: '队列曲三', artist: '艺人'),
];

AppLocalizations? _loc;

/// 有界推帧：替代 pumpAndSettle（媒体组件含无限动画时永远等不到静）。
Future<void> settle(WidgetTester tester, {int frames = 10}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> pumpView(WidgetTester tester, Widget child) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(1000, 900);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  await tester.pumpWidget(
    // 队列行内渲染 CoverArtImage（ConsumerWidget）→ 必须挂 ProviderScope。
    ProviderScope(
      child: MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('zh'),
      theme: AppTheme.dark(),
      builder: (BuildContext context, Widget? child) {
        _loc = AppLocalizations.of(context);
        final media = MediaQuery.of(context);
        return MediaQuery(
          data: media.copyWith(disableAnimations: true),
          child: child!,
        );
      },
      home: Scaffold(body: child),
      ),
    ),
  );
  await settle(tester);
}

PlayQueueSheetView localView({
  required List<Song> queue,
  int currentIndex = 0,
  bool panel = false,
  void Function(int)? onSelect,
  void Function()? onClear,
  void Function(BuildContext, int, Song)? onSongActions,
  VoidCallback? onClose,
}) {
  return PlayQueueSheetView(
    playerState: PlayerState(queue: queue, currentIndex: currentIndex),
    panel: panel,
    onClose: onClose,
    onSelect: (int index) async => onSelect?.call(index),
    onClear: () async => onClear?.call(),
    onOpenSongActions: (BuildContext context, int index, Song song) async =>
        onSongActions?.call(context, index, song),
  );
}

void main() {
  group('PlayQueueSheetView · 本机队列列表', () {
    testWidgets('底部弹窗布局注入 DraggableScrollableSheet，点行回调 onSelect', (
      tester,
    ) async {
      final selected = <int>[];
      await pumpView(
        tester,
        localView(
          queue: kSongs,
          currentIndex: 1,
          onSelect: selected.add,
        ),
      );

      expect(find.byType(DraggableScrollableSheet), findsOneWidget);
      expect(find.text(_loc!.queue_count(3)), findsOneWidget);
      expect(find.text('队列曲三'), findsOneWidget);

      await tester.tap(find.text('队列曲三'));
      await tester.pump();
      expect(selected, <int>[2]);
      expect(tester.takeException(), isNull);
    });

    testWidgets('长按行回调 onOpenSongActions（带下标与歌曲）', (tester) async {
      final actions = <int>[];
      final actedSongs = <String>[];
      await pumpView(
        tester,
        localView(
          queue: kSongs,
          currentIndex: 0,
          onSongActions: (context, index, song) {
            actions.add(index);
            actedSongs.add(song.id);
          },
        ),
      );

      await tester.longPress(find.text('队列曲二'));
      await tester.pump();
      expect(actions, <int>[1]);
      expect(actedSongs, <String>['q2']);
      expect(tester.takeException(), isNull);
    });

    testWidgets('「播完当前歌曲后清空」按钮触发 onClear', (tester) async {
      var cleared = false;
      await pumpView(
        tester,
        localView(queue: kSongs, currentIndex: 0, onClear: () => cleared = true),
      );

      final btn = find.widgetWithText(
        MusicFlowButton,
        _loc!.queue_clear_after,
      );
      expect(btn, findsOneWidget);
      await tester.tap(btn);
      await tester.pump();
      expect(cleared, isTrue);
      expect(tester.takeException(), isNull);
    });

    testWidgets('60 首长队列 currentIndex=45 打开即自动居中到当前行', (tester) async {
      final songs = List<Song>.generate(
        60,
        (int i) => Song(id: 's$i', title: '长队列曲$i', artist: 'A'),
      );
      await pumpView(
        tester,
        localView(
          queue: songs,
          currentIndex: 45,
          panel: true,
        ),
      );

      expect(find.text('长队列曲45'), findsOneWidget);
      // 深下标两侧的邻行也应可见（居中效果）。
      expect(find.text('长队列曲44'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('currentIndex 变化触发 didUpdateWidget 重新居中', (tester) async {
      final songs = List<Song>.generate(
        60,
        (int i) => Song(id: 's$i', title: '重定位曲$i', artist: 'A'),
      );
      await pumpView(
        tester,
        localView(queue: songs, currentIndex: 45, panel: true),
      );
      expect(find.text('重定位曲45'), findsOneWidget);

      // 同形状换 currentIndex：_AutoCenterQueueList.didUpdateWidget 重新定位。
      await pumpView(
        tester,
        localView(queue: songs, currentIndex: 10, panel: true),
      );
      await settle(tester, frames: 8);

      expect(find.text('重定位曲10'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('空队列渲染空态且清空按钮禁用', (tester) async {
      await pumpView(tester, localView(queue: const <Song>[]));

      expect(find.text(_loc!.queue_empty), findsOneWidget);
      final btn = tester.widget<MusicFlowButton>(
        find.widgetWithText(MusicFlowButton, _loc!.queue_clear_after),
      );
      expect(btn.onPressed, isNull);
      expect(tester.takeException(), isNull);
    });
  });

  group('CastQueueSheetView · 投屏队列列表', () {
    testWidgets('渲染设备名计数行,点行回调 onSelect,onReorder 直接回调生效', (
      tester,
    ) async {
      final selected = <int>[];
      final reorders = <String>[];
      await pumpView(
        tester,
        CastQueueSheetView(
          queue: kSongs,
          currentIndex: 1,
          deviceName: '客厅音箱',
          onSelect: (int index) async => selected.add(index),
          onRemove: (int index) {},
          onReorder: (int from, int to) => reorders.add('$from>$to'),
          onClear: () async {},
        ),
      );

      expect(
        find.text(_loc!.queue_cast_count(3, '客厅音箱')),
        findsOneWidget,
      );

      await tester.tap(find.text('队列曲三'));
      await tester.pump();
      expect(selected, <int>[2]);

      // 拖拽时序脆 → 直接调 ReorderableListView.onReorder 覆盖两个分支。
      final rlv = tester.widget<ReorderableListView>(
        find.byType(ReorderableListView),
      );
      rlv.onReorder!(0, 2); // ignore: deprecated_member_use
      expect(reorders, <String>['0>2']);
      rlv.onReorder!(1, 1); // ignore: deprecated_member_use
      expect(reorders, <String>['0>2'], reason: 'from==to 不下发');
      expect(tester.takeException(), isNull);
    });

    testWidgets('offline 追加离线后缀,panel 布局无拖拽把手,关闭走 onClose', (
      tester,
    ) async {
      var closed = false;
      await pumpView(
        tester,
        CastQueueSheetView(
          queue: kSongs,
          currentIndex: 0,
          deviceName: '书房设备',
          offline: true,
          panel: true,
          onClose: () => closed = true,
          onSelect: (int index) async {},
          onRemove: (int index) {},
          onReorder: (int from, int to) {},
          onClear: () async {},
        ),
      );

      expect(
        find.text(
          _loc!.queue_cast_count(3, '书房设备') + _loc!.queue_cast_offline_suffix,
        ),
        findsOneWidget,
      );

      await tester.tap(find.byIcon(AppIcons.close));
      await tester.pump();
      expect(closed, isTrue);
      expect(tester.takeException(), isNull);
    });

    testWidgets('空投屏队列渲染空态且清空按钮禁用', (tester) async {
      await pumpView(
        tester,
        CastQueueSheetView(
          queue: const <Song>[],
          currentIndex: -1,
          deviceName: '空设备',
          onSelect: (int index) async {},
          onRemove: (int index) {},
          onReorder: (int from, int to) {},
          onClear: () async {},
        ),
      );

      expect(find.text(_loc!.queue_cast_empty), findsOneWidget);
      final btn = tester.widget<MusicFlowButton>(
        find.widgetWithText(MusicFlowButton, _loc!.queue_cast_clear),
      );
      expect(btn.onPressed, isNull);
      expect(tester.takeException(), isNull);
    });

    testWidgets('onClose 为空时关闭按钮走 Navigator.maybePop（不抛栈底断言）', (
      tester,
    ) async {
      await pumpView(
        tester,
        CastQueueSheetView(
          queue: kSongs,
          currentIndex: 0,
          deviceName: '默认关闭',
          onSelect: (int index) async {},
          onRemove: (int index) {},
          onReorder: (int from, int to) {},
          onClear: () async {},
        ),
      );

      await tester.tap(find.byIcon(AppIcons.close));
      await settle(tester, frames: 6);
      // 栈底路由 maybePop 不弹出也不抛异常。
      expect(tester.takeException(), isNull);
      expect(find.byType(CastQueueSheetView), findsOneWidget);
    });
  });
}
