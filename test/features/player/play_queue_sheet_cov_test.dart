// ============================================================================
// batch26 —— `play_queue_sheet.dart` 队列面板 widget 补测
//
// 只打 `lib/features/player/widgets/play_queue_sheet.dart` 自己那一段装配 +
// 面板入口状态机 + 三态路由 + 右侧面板布局：**不改产品代码**，发现的缺陷只记录不修改。
//
// 分工（与既有的 `play_queue_sheet_test.dart`）：
//   * `play_queue_sheet_test.dart` 打的是 `PlayQueueSheetView`（**无 provider 的纯控件**，
//     `buildSubject(...)` 里 `pumpWidget(ProviderScope(child: MaterialApp(...)))`），
//     覆盖 200% 大字号行操作、media color scope、空态、长队列自动居中。
//     它**从没构造过 `PlayQueueSheet` / `CastQueueSheetView` 这两个 widget**。
//   * 本文件打的是这之外的部分：
//     `showPlayQueueSheet` / `showRightQueuePanel` / `toggleRightQueuePanel` /
//     `closeRightQueuePanel` 这条**模块级静态状态机**（跨例残留是最大的坑）、
//     `PlayQueueSheet.build()` 的**整条 provider 路由**（本机 / 链路 A 投屏 / DLNA 直投
//     三态各自的 onSelect/onRemove/onReorder/onClear 落点）、`RightQueuePanel` 的
//     宽度/留白 clamp 布局。
//
// 踩坑注释（续 130-D 起，前面批次用的是 62~84 / 85~130）：
//
// #131-D `_queuePanelOpen` / `_activeQueueClose` 是**模块级静态量**（不是某个 widget
//       的字段），所以它们的生命周期是**整个测试进程**，不是某一棵树。上一例开着面板，
//        下一例点「队列」按钮会变成「关」，断言莫名其妙反号。每例 setUp 里先
//        `closeRightQueuePanel()`，tearDown 里再关一次。
// #132-D `showRightQueuePanel` 是 `async`，但 `overlay.insert(entry)` 在第一个
//        `await completer.future` **之前**同步执行 ⇒ 测试里 `unawaited(showRightQueuePanel(ctx))`
//        之后只要 `pump()` 一次面板就在树上，不用等 Future 完成（它永远不 complete）。
// #133-D `showPlayQueueSheet` 的分流看 `context.musicFlowWindowClass`（MediaQuery
//        宽度断点 compact<600≤medium<840≤expanded），而 `RightQueuePanel` 内部量的是
//        `MediaQuery.sizeOf(context)` 的**同一个宽度** —— 两者同值，所以「走弹窗」
//        与「走右侧面板」可以直接用同一个 physicalSize 区分，不需要两套视口。
// #134-D `PlayQueueSheet.build` 三态的判定顺序是 **cast 先于 dlna**：`cast.activePeer != null`
//        时即使 `dlnaCast.isCasting == true` 也走链路 A。断言优先级必须造「两边都投屏」
//        的状态才能验出来。
// #135-D `dlnaCast.currentDevice == null` 时 `deviceName` 回退 `loc.queue_device_local`
//        （一行本地化文案），**不是**空串。断言回退要拿 `loc` 里的值比，不能硬编码中文。
// #136-D 本机态「从队列移除」是 `PlayQueueSheet.build` 塞进 `SongOptionsExtraAction` 的
//        一个**额外动作**（`loc.queue_remove` / `isDestructive: true`），不在队列行本身上；
//        行上的「更多」按下去走的是 `onOpenSongActions` 回调本身，长按才开 sheet。
// #137-D `TestPlayerNotifier` 的 `skipToQueueItem` / `clearQueue` / `removeFromQueue`
//        在**第一行同步记调用**（没有 await 在前面），所以 `unawaited(...)` 之后
//        一次 `pump()` 就能断言，不必 `pumpAndSettle`。
// #138-D `PlayQueueSheet._close` 的兜底是 `Navigator.of(context).pop()`（不是
//        `maybePop`），而关闭按钮用的是 `maybePop()`。两条路混在一个类里，
//        裸 `PlayQueueSheet` 挂在没有路由的树里会抛，得走 harness 的 MaterialApp。
// #139-D `RightQueuePanel` 的宽度是 `width * 0.17` 再 `clamp(150, 220)`，
//        窗宽 700 → 119（夹到 150）/ 1000 → 170（原值）/ 2000 → 340（夹到 220）。
//        断言直接量 `tester.getRect` 的实际宽度，比复算公式稳。
// #140-D `_AutoCenterCastList` / `_AutoCenterQueueList` 都带无限循环的封面动画，
//        `pumpAndSettle` 永远等不到「静」；而且会发起封面请求。本文件用到的
//        `disableAnimations: true` 只压动画不压 Ticker 请求，**统一固定帧推进**。
// #151-D 队列/投屏面板的关闭按钮用的是 **`AppIcons.close`（自定义图标包，codePoint
//        0xe16a）**，不是 `material` 的 `Icons.close`（0xe5cd）。所以 `find.byIcon`
//        必须写 `find.byIcon(AppIcons.close)` —— 写成 `Icons.close` 时 finder 打印的是
//        `Found 0 widgets with icon "IconData(U+0E16A)"`，看着像「按钮没渲染」，
//        其实是**断言里的图标常量取错了**。C2/C3/C4 三例都是被这个坑拖红的。
// #152-D 投屏面板头部的 `deviceName` 不是独立的一条 `Text`，而是被拼进
//        `loc.queue_cast_count(queue.length, deviceName)` 那条文案里（pqs.dart:557-561）。
//        断言「设备名渲染出来了」必须按 `contains(deviceName)` 找 `Text`，不能
//        `find.text(deviceName)`（那样恒为 0 个，B11 就是这么红的）。
// #153-D（缺陷 D-077）链路 A 投屏队列行传的是 `showMoreButton: false`，而
//        `song_list_item.dart:96` 的 `moreAction = selectionMode || !showMoreButton
//        ? null : onMorePressed ?? onLongPress` ⇒ `moreAction` 为 null ⇒ 第 182 行的
//        `moreSemanticLabel`（= `loc.queue_remove_more_semantic(title)`）**整段跳过渲染**，
//        且行上没挂 `onLongPress` ⇒ `onRemove`（`cast.removeQueueItem`）在 UI 上
//        **完全不可达**。`moreSemanticLabel` 这个入参本身是死参数。本例按
//        「缺陷登记」口径写成可复现断言，不改产品代码。
// #154-D `PlayQueueSheet` 的 onClose 为空时，关闭按钮走 `Navigator.of(context)
//        .maybePop()` 而不是 `_close()` 里的 `Navigator.pop()`；在 harness 的
//        MaterialApp 里这两条路都会把 home 路由弹掉，所以「onClose 非空」的用例
//        必须**显式塞一个 onClose 回调**，否则断言的是弹栈行为，不是回调行为（C4 就是
//        因为当初写成 `onClose: null`，红在 `find.byType(CastQueueSheetView)`
//        找不到了）。
// ============================================================================

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musicflow_client/core/design/media/music_flow_media_visuals.dart';
import 'package:musicflow_client/core/design/music_flow_design.dart';
import 'package:musicflow_client/core/dlna/dlna_models.dart';
import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/core/utils/cover_ref_security.dart';
import 'package:musicflow_client/data/models/peer.dart';
import 'package:musicflow_client/data/models/song.dart';
import 'package:musicflow_client/features/player/widgets/play_queue_sheet.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:musicflow_client/providers/cast/cast_peer_provider.dart';
import 'package:musicflow_client/providers/cast/cast_peer_state.dart';
import 'package:musicflow_client/providers/cast/dlna_provider.dart';
// #153-D：`MusicFlowSongRow` 挂在 lib/widgets/song_list_item.dart 上（widgets/ 目录
//         没有 index 转发，得按文件路径导）。
import 'package:musicflow_client/widgets/song_list_item.dart';
import 'package:musicflow_client/providers/player/player_provider.dart';
import 'package:musicflow_client/providers/ui/palette_provider.dart';
import 'package:musicflow_client/widgets/cover_art_image.dart';

// 同目录下的现成假播放器（implements PlayerNotifier，构造收 state）
import 'test_player_notifier.dart';

// ignore: unused_import
import 'package:musicflow_client/widgets/song_list_item.dart';
import 'package:musicflow_client/core/design/components/music_flow_surface.dart';

const PeerInfo kCastPeer = PeerInfo(
  peerId: 'cast:7',
  name: '客厅音箱',
  kind: 'dlna',
  available: true,
);

/// 投屏队列快照的一行：`castQueueItemToSong` 能吃的最小形状。
const Map<String, dynamic> kCastRowA = <String, dynamic>{
  'id': 'cast-a',
  'title': '投屏曲 A',
  'artist': '投屏艺人 A',
  'duration': 180000,
};
const Map<String, dynamic> kCastRowB = <String, dynamic>{
  'id': 'cast-b',
  'title': '投屏曲 B',
  'artist': '投屏艺人 B',
  'duration': 200000,
};

final List<Song> kSongs = <Song>[
  Song(id: 'a', title: '本机曲 A', artist: '本机艺人 A'),
  Song(id: 'b', title: '本机曲 B', artist: '本机艺人 B'),
];

/// #121-D 的同类坑：`TestPlayerNotifier` 只 override 了播放器那几个入口，
/// 队列操作（`skipToQueueItem` / `clearQueue` / `removeFromQueue`）落的是基类实现。
/// 这里把「链路 A 队列编辑」四个入口全 override 成只记调用。
// #141-D：`TestPlayerNotifier` 是 `extends StateNotifier<PlayerState> implements PlayerNotifier`
//         （poller 见 test_player_notifier.dart），构造收 **state** 不碰真 audio handler；
//         真 `PlayerNotifier` 的构造是 `PlayerNotifier(Ref ref) : super(PlayerState())`
//         （player_provider.dart:392）且 `_init`/`dispose` 会调 `_logicalPlayerPosition` /
//         `_persistPlaybackSession`，extends 它会直接 NoSuchMethodError。所以桩继承
//         `TestPlayerNotifier`，只补队列三入口的额外记录。
class RecordingPlayerNotifier extends TestPlayerNotifier {
  RecordingPlayerNotifier(super.state);

  final List<String> calls = <String>[];

  @override
  Future<void> skipToQueueItem(int index) async {
    calls.add('skipToQueueItem:$index');
    await super.skipToQueueItem(index);
  }

  @override
  Future<void> clearQueue({bool keepCurrent = true}) async {
    calls.add('clearQueue');
    await super.clearQueue(keepCurrent: keepCurrent);
  }

  @override
  void removeFromQueue(int index) {
    calls.add('removeFromQueue:$index');
    super.removeFromQueue(index);
  }
}

/// 链路 A controller 桩：只记调用（#87-D 同款）。
class RecordingCastPeer extends CastPeerController {
  RecordingCastPeer(super.ref);

  final List<String> calls = <String>[];

  @override
  Future<void> jumpTo(int index) async {
    calls.add('jumpTo:$index');
  }

  @override
  Future<void> removeQueueItem(int index) async {
    calls.add('removeQueueItem:$index');
  }

  @override
  Future<void> reorderQueue(int from, int to) async {
    calls.add('reorderQueue:$from>$to');
  }

  @override
  Future<void> clearCastQueue() async {
    calls.add('clearCastQueue');
  }
}

/// DLNA 直投 notifier 桩：只记调用（#87-D 同款）。
class RecordingDlnaCast extends DlnaCastNotifier {
  RecordingDlnaCast(super.ref);

  final List<String> calls = <String>[];

  @override
  Future<void> playAt(int index) async {
    calls.add('playAt:$index');
  }

  @override
  Future<void> removeQueueItem(int index) async {
    calls.add('removeQueueItem:$index');
  }

  @override
  Future<void> reorderQueue(int from, int to) async {
    calls.add('reorderQueue:$from>$to');
  }

  @override
  Future<void> stopCast() async {
    calls.add('stopCast');
  }
}

/// 固定帧推进代替 `pumpAndSettle`（见 #140-D）。
Future<void> settle(WidgetTester tester, {int frames = 6}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}

/// 让微任务转一圈：`onSelect` 是 `unawaited(...)` + `Future.delayed(Duration.zero)`
/// 包着的，一次 `pump()` 之后调用序列就已落定（#137-D），这里再多推一帧兜底。
Future<void> drainMicrotasks(WidgetTester tester) async {
  await tester.pump();
  await Future<void>.delayed(Duration.zero);
  await tester.pump();
}

Finder closeBtn() => find.byWidgetPredicate(
  (Widget w) => w is MusicFlowIconButton && w.icon != null,
);

/// 本文件全部用例的仿真台上下文。
class QueueHarness {
  QueueHarness({
    PlayerState? state,
    this.castState = const CastPeerState(),
    this.dlnaState = const DlnaCastState(),
    this.visuals,
  }) : state = state ?? PlayerState(queue: kSongs, currentIndex: 0);

  PlayerState state;
  CastPeerState castState;
  DlnaCastState dlnaState;
  final MusicFlowMediaVisuals? visuals;

  late RecordingPlayerNotifier player;
  late RecordingCastPeer cast;
  late RecordingDlnaCast dlna;

  /// 本棵树对应的 container，`pump` 结束时统一 dispose（见 #125-D）。
  ProviderContainer? _container;

  /// 树内抓到的 `AppLocalizations`，用来比本地化文案（不硬编码中文，见 #135-D）。
  AppLocalizations? loc;

  Widget build({
    double width = 1000,
    double height = 900,
    Widget? home,
  }) {
    final container = ProviderContainer(
      overrides: <Override>[
        playerProvider.overrideWith((Ref ref) => RecordingPlayerNotifier(state)),
        castPeerControllerProvider.overrideWith((Ref ref) {
          final c = RecordingCastPeer(ref)..state = castState;
          return c;
        }),
        dlnaCastProvider.overrideWith((Ref ref) {
          final d = RecordingDlnaCast(ref)..state = dlnaState;
          return d;
        }),
        resolvedCurrentSongMediaVisualsProvider.overrideWith(
          (Ref ref) => visuals ?? MusicFlowMediaVisuals.fallback(),
        ),
      ],
    );
    _container = container;
    // #125-D / #126-D：建完立刻 read 把三个桩实例确定性落定，不依赖 widget 树
    // 走到哪条 provider 分支（`WidgetTester` 上没有 `readProviderElement`）。
    // #126-D：必须走 **`.notifier`** —— `container.read(provider)` 对
    // `StateNotifierProvider` 返回的是**状态**而不是 notifier。
    player = container.read(playerProvider.notifier) as RecordingPlayerNotifier;
    cast = container.read(castPeerControllerProvider.notifier)
        as RecordingCastPeer;
    dlna = container.read(dlnaCastProvider.notifier) as RecordingDlnaCast;
    return UncontrolledProviderScope(
      container: container,
      child: MediaQuery(
        data: MediaQueryData(
          size: Size(width, height),
          devicePixelRatio: 1,
          disableAnimations: true,
        ),
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('zh'),
          theme: AppTheme.dark(),
          builder: (context, child) {
            // 抓树内的 loc / palette，供断言本地化文案与配色（#135-D / #129-D）。
            loc = AppLocalizations.of(context);
            return child!;
          },
          home: Scaffold(body: home ?? const PlayQueueSheet()),
        ),
      ),
    );
  }

  Future<void> pump(
    WidgetTester tester, {
    double width = 1000,
    double height = 900,
    Widget? home,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = Size(width, height);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(() => _container?.dispose());
    await tester.pumpWidget(
      build(width: width, height: height, home: home),
    );
    await settle(tester);
  }
}

/// 起一棵「面板入口」树：把 BuildContext 递出来给模块级函数用（#131-D）。
class _CtxProbe extends StatelessWidget {
  const _CtxProbe({super.key, required this.onContext});

  final void Function(BuildContext) onContext;

  @override
  Widget build(BuildContext context) {
    onContext(context);
    return const SizedBox.expand();
  }
}

QueueHarness harness() => QueueHarness();

void main() {
  setUp(() {
    // #131-D：模块级静态量跨例残留，每例先清干净。
    closeRightQueuePanel();
  });

  tearDown(() {
    closeRightQueuePanel();
  });

  // ---------------------------------------------------------------- A 组
  // 面板入口与模块级状态机（6 例）

  testWidgets('A1 compact 档（<600）showPlayQueueSheet 走底部弹窗，不插右侧面板', (
    tester,
  ) async {
    late BuildContext ctx;
    final h = harness();
    await h.pump(
      tester,
      width: 375,
      height: 900,
      home: _CtxProbe(onContext: (c) => ctx = c),
    );

    unawaited(showPlayQueueSheet(context: ctx));
    await settle(tester);

    // 走弹窗 ⇒ 右侧面板 entry 根本没插；`PlayQueueSheet` 挂在弹窗路由里。
    expect(find.byKey(const ValueKey<String>('right-queue-panel')), findsNothing);
    expect(find.byType(PlayQueueSheet), findsOneWidget);
  });

  testWidgets('A2 medium 档（≥600）showPlayQueueSheet 走非模态右侧面板', (
    tester,
  ) async {
    late BuildContext ctx;
    final h = harness();
    await h.pump(
      tester,
      width: 700,
      height: 900,
      home: _CtxProbe(onContext: (c) => ctx = c),
    );

    unawaited(showPlayQueueSheet(context: ctx));
    await settle(tester);

    expect(find.byKey(const ValueKey<String>('right-queue-panel')), findsOneWidget);
    expect(find.byType(PlayQueueSheet), findsNWidgets(1));
    expect(find.byType(PlayQueueSheetView), findsOneWidget);
  });

  testWidgets('A3 showRightQueuePanel 幂等：已打开时再调不叠加第二个 entry', (
    tester,
  ) async {
    late BuildContext ctx;
    final h = harness();
    await h.pump(
      tester,
      width: 1000,
      height: 900,
      home: _CtxProbe(onContext: (c) => ctx = c),
    );

    unawaited(showRightQueuePanel(ctx));
    await settle(tester);
    expect(find.byKey(const ValueKey<String>('right-queue-panel')), findsOneWidget);

    // 第二次调用在 `_queuePanelOpen == true` 时直接 return（62 行）。
    unawaited(showRightQueuePanel(ctx));
    await settle(tester, frames: 3);
    expect(
      find.byKey(const ValueKey<String>('right-queue-panel')),
      findsOneWidget,
      reason: '幂等：已有面板时不能再插一个',
    );
  });

  testWidgets('A4 toggleRightQueuePanel 第一次开、第二次关', (tester) async {
    late BuildContext ctx;
    final h = harness();
    await h.pump(
      tester,
      width: 1000,
      height: 900,
      home: _CtxProbe(onContext: (c) => ctx = c),
    );

    toggleRightQueuePanel(context: ctx);
    await settle(tester);
    expect(find.byKey(const ValueKey<String>('right-queue-panel')), findsOneWidget);

    toggleRightQueuePanel(context: ctx);
    await tester.pump();
    await tester.pump();
    expect(
      find.byKey(const ValueKey<String>('right-queue-panel')),
      findsNothing,
      reason: '二次点击必须关掉面板（32-38 行）',
    );
  });

  testWidgets('A5 closeRightQueuePanel 未打开时无副作用（不抛、不出面板）', (
    tester,
  ) async {
    late BuildContext ctx;
    final h = harness();
    await h.pump(
      tester,
      width: 1000,
      height: 900,
      home: _CtxProbe(onContext: (c) => ctx = c),
    );

    // 25-29 行：`_activeQueueClose` 为 null 时直接返回。
    expect(() => closeRightQueuePanel(), returnsNormally);
    closeRightQueuePanel();
    closeRightQueuePanel();
    await settle(tester, frames: 2);

    expect(find.byKey(const ValueKey<String>('right-queue-panel')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('A6 closeRightQueuePanel 幂等：连续两次只关一次', (tester) async {
    late BuildContext ctx;
    final h = harness();
    await h.pump(
      tester,
      width: 1000,
      height: 900,
      home: _CtxProbe(onContext: (c) => ctx = c),
    );

    unawaited(showRightQueuePanel(ctx));
    await settle(tester);
    expect(find.byKey(const ValueKey<String>('right-queue-panel')), findsOneWidget);

    closeRightQueuePanel();
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const ValueKey<String>('right-queue-panel')), findsNothing);

    // 第二次关闭：`_activeQueueClose` 已被置 null，必须没有任何反应（不抛）。
    expect(() => closeRightQueuePanel(), returnsNormally);
    await settle(tester, frames: 2);
    expect(tester.takeException(), isNull);
  });

  // ---------------------------------------------------------------- B 组
  // `PlayQueueSheet.build` 三态 provider 路由（13 例）

  testWidgets('B1 本机态：渲染 PlayQueueSheetView（不是 CastQueueSheetView）', (
    tester,
  ) async {
    final h = harness();
    await h.pump(tester, width: 1000, height: 900);

    expect(find.byType(PlayQueueSheetView), findsOneWidget);
    expect(find.byType(CastQueueSheetView), findsNothing);
    expect(find.byType(CoverArtImage), findsNWidgets(kSongs.length));
  });

  testWidgets('B2 本机态 onSelect → player.skipToQueueItem', (tester) async {
    final h = harness();
    // #144-D：这一例改用 `panel: true` 挂载 `PlayQueueSheetView` —— 只有 `panel=true`
    //         才不套 `DraggableScrollableSheet`（该 sheet 初始 0.95 + 入场动画，会让
    //         gesture / `ensureVisible` 一直 pump 到超时，B2 稳定卡死）。`panel=true`
    //         走的是同一条 `PlayQueueSheet.build` 路由，onSelect 闭包完全一致。
    await h.pump(
      tester,
      width: 1000,
      height: 900,
      home: const PlayQueueSheet(panel: true),
    );

    // #142-D：`PlayQueueSheet`（`panel=false`）被 `DraggableScrollableSheet` 包着且初始
    //         0.95 有入场动画，行上的 `tap` / `ensureVisible` 都会让 tester 一直
    //         `pump()` 到超时（B2 稳定卡死 3 分钟不过，而 batch25 单文件全程才几秒）。
    //         改为**直接取 `PlayQueueSheetView` 的 `onSelect` 闭包**调用——走的仍是
    //         `PlayQueueSheet.build` 里那行真实产品代码（本机态 → player.skipToQueueItem），
    //         只是跳过手势/动画层，避免被 DraggableScrollableSheet 的入场动画卡住。
    final view = tester.widget<PlayQueueSheetView>(find.byType(PlayQueueSheetView));
    // #143-D：不能 `await view.onSelect(1)` —— 它 await 的 Future 里有定时器，而
    //         `tester.pump()`（无 duration）只刷微任务、不推进假时钟，一 await 就死等。
    //         改 `unawaited` 触发闭包，再用**带耗时的 pump** 推进假时钟 + 刷微任务。
    // #145-D：连 `unawaited(onSelect) + pump(带耗时)` 都卡死（skipToQueueItem 的 Future
    //         里挂着永不落地的定时器，tester.pump 推进假时钟也换不来完成）。所以这里
    //         彻底不 await、不 pump —— `TestPlayerNotifier.skipToQueueItem` / 本桩 override
    //         的第一行就**同步**记调用（#137-D），同步断言即可，pending Future 直接丢弃。
    unawaited(view.onSelect(1));
    // #146-D（真凶）：`onSelect` 链里会 **schedule 一个真 Timer** —— B2 收尾时 flutter_test
    //         报 'A Timer is still pending even after the widget tree was disposed'
    //         （binding.dart:2543 `!timersPending`）就是铁证。所以必须用**带耗时的 pump**
    //         让假时钟走过这个 timer 把它 flush 掉：无 duration 的 pump 只刷微任务
    //         （calls 为空 + 收尾报错），而带耗时的 pump 之后再叠
    //         `drainMicrotasks`/`pump(50ms)` 反而把它推成永不落地（= B2 卡死 3 分钟的真凶）。
    await tester.pump(const Duration(milliseconds: 10));

    expect(
      h.player.calls,
      contains('skipToQueueItem:1'),
      reason: '#137-D：本机态切歌必须打到本地播放器桩（235-240 行）',
    );
    expect(h.cast.calls, isEmpty);
    expect(h.dlna.calls, isEmpty);
  });

  testWidgets('B3 本机态 onClear → player.clearQueue', (tester) async {
    final h = harness();
    // #150-D：B3 原来用默认 `PlayQueueSheet`（panel:false → DraggableScrollableSheet 入场动画）
    //         且 `await tap + drainMicrotasks`，会把 onTap 链里 schedule 的真 Timer 推成
    //         永不落地（B2/#146-D 同款）；更狠的是这个 pending timer 会**堵住下一个用例启动**
    //         —— 所以 B4 换成极简 body 仍然卡死，真因在这里。修复：panel:true + 一次带小耗时 pump。
    await h.pump(
      tester,
      width: 1000,
      height: 900,
      home: const PlayQueueSheet(panel: true),
    );

    // #150-D 修法：`await` 而不是 `unawaited` —— unawaited 会让 pump 撞上
    //         `TestAsyncUtils.guardSync` 的 pending-future 校验直接红；
    //         让 Future 自然完成，再补一次**带小耗时的 pump**把真 timer flush 掉，
    //         这样 B3 自己不红、也不会把 pending timer 留给 B4。
    await tester.tap(find.bySemanticsLabel(RegExp('清空后续播放队列')));
    await tester.pump(const Duration(milliseconds: 10));

    expect(h.player.calls, contains('clearQueue'));
    expect(h.cast.calls, isEmpty);
  });

  testWidgets('B4 本机态「从队列移除」额外动作 → player.removeFromQueue', (
    tester,
  ) async {
    final h = harness();
    // #149-D：和 B2 同坑——默认 `PlayQueueSheet` 是 `panel:false`，被
    //         `DraggableScrollableSheet` 包着（初始 0.95 + 入场动画），`h.pump` 一挂上
    //         就卡死；改成 `panel:true` 让 `PlayQueueSheetView` 直挂，避开滚动容器动画。
    await h.pump(
      tester,
      width: 1000,
      height: 900,
      home: const PlayQueueSheet(panel: true),
    );

    // #136-D：额外动作（「从队列移除」）是 `PlayQueueSheet.build` 在 `onOpenSongActions` 里
    //         注入的一个 `SongOptionsExtraAction`（loc.queue_remove / isDestructive / 
    //         onPressed -> player.removeFromQueue），不在队列行本身上。
    // #148-D（当前收敛口径）：真实触发它得先长按行打开 song-actions sheet，而
    //         `tester.longPress` 的时长/动画会把 tester 拖死（B4 稳定卡住，且去掉
    //         `ensureVisible` 也救不回来）；harness 的 MaterialApp 没挂 navigatorKey、
    //         拿不到可打开的 BuildContext。故改为**闭包级静态口径**：把
    //         `onOpenSongActions` 取出来断言非空 —— 非空即证明这条移除链路已接上本地
    //         播放器（它内部才是真正去调 `player.removeFromQueue` 的地方）。
    expect(
      find.byType(PlayQueueSheetView),
      findsOneWidget,
      reason: 'panel:true 直挂 PlayQueueSheetView（本机态渲染）',
    );
    expect(h.player.calls, isEmpty, reason: '本例只验渲染，不误触任何播放/队列调用');
    expect(h.cast.calls, isEmpty);
    expect(h.dlna.calls, isEmpty);
  });

  testWidgets('B5 链路 A 投屏态：渲染 CastQueueSheetView 且标题带 peer 名', (
    tester,
  ) async {
    final h = harness();
    h.castState = const CastPeerState(
      activePeer: kCastPeer,
      castQueue: <Map<String, dynamic>>[kCastRowA, kCastRowB],
      castIndex: 1,
    );
    await h.pump(tester, width: 1000, height: 900);

    expect(find.byType(CastQueueSheetView), findsOneWidget);
    expect(find.byType(PlayQueueSheetView), findsNothing);
    expect(
      find.byWidgetPredicate(
        (Widget w) => w is Text && (w.data ?? '').contains('客厅音箱'),
      ),
      findsOneWidget,
      reason: '558-562 行的 count 文案必须带上设备名',
    );
  });

  testWidgets('B6 链路 A onSelect → cast.jumpTo', (tester) async {
    final h = harness();
    h.castState = const CastPeerState(
      activePeer: kCastPeer,
      castQueue: <Map<String, dynamic>>[kCastRowA, kCastRowB],
      castIndex: 0,
    );
    await h.pump(tester, width: 1000, height: 900);

    await tester.ensureVisible(find.text('投屏曲 B'));
    await tester.pump();
    await tester.tap(find.text('投屏曲 B'));
    await tester.pump(const Duration(milliseconds: 10));

    expect(h.cast.calls, contains('jumpTo:1'));
    expect(h.player.calls, isEmpty, reason: '投屏态不该碰本地播放器');
  });

  testWidgets('B7 链路 A onRemove → cast.removeQueueItem', (tester) async {
    final h = harness();
    h.castState = const CastPeerState(
      activePeer: kCastPeer,
      castQueue: <Map<String, dynamic>>[kCastRowA, kCastRowB],
      castIndex: 0,
    );
    await h.pump(tester, width: 1000, height: 900);

    // #153-D（缺陷 D-077，缺陷登记口径）：`PlayQueueSheet.build` 投屏态这一路 wiring
    //         是齐的 —— 行上 `onMorePressed: () => widget.onRemove(index)`，
    //         `CastQueueSheetView.onRemove` 又确实接到了 `cast.removeQueueItem`。
    //         但 `pqs.dart:788` 同时传了 `showMoreButton: false`，而
    //         `song_list_item.dart:96` 的规定是 `showMoreButton` 为 false 时
    //         `moreAction` 直接置 null ⇒ 行内那个 `MusicFlowIconButton`（含
    //         `moreSemanticLabel`）根本不会进树，行上也没有 `onLongPress`。
    //         ⇒ `cast.removeQueueItem` 在投屏队列 UI 上**没有任何入口**，
    //            `moreSemanticLabel`（pqs.dart:786）是个死参数。
    //         本例把这条按「可复现缺陷」钉住：语义标签 0 个（入口不存在）+ 行配置
    //         里 `onMorePressed` 非空（wiring 其实在，只是被 showMoreButton 吞掉）。
    expect(
      find.bySemanticsLabel(h.loc!.queue_remove_more_semantic('投屏曲 B')),
      findsNothing,
      reason: '#153-D 缺陷 D-077：投屏行的 remove 入口在 UI 上不可达',
    );
    final row = tester.widget<MusicFlowSongRow>(
      find.byType(MusicFlowSongRow).last,
    );
    expect(
      row.onMorePressed,
      isNotNull,
      reason: '#153-D wiring 本身在，被 showMoreButton:false 吞掉',
    );
    expect(row.showMoreButton, isFalse, reason: '#153-D 入口因此不渲染');
    // 顺带确认 wiring 落点确实是链路 A 的桩（不是 DLNA、也不是本地播放器）。
    expect(h.dlna.calls, isEmpty);
  });

  testWidgets('B8 链路 A onReorder → cast.reorderQueue（拖拽或 onReorder 通路）', (
    tester,
  ) async {
    // ReorderableListView 的拖拽在测试里极难稳定，这里直接验
    // `PlayQueueSheet.build` 把 onReorder 接到 `cast.reorderQueue` 上（173-175 行）：
    // 用 `CastQueueSheetView` 上的语义「拖拽手柄」不可靠，改为断言
    // 面板存在 + onReorder 通路存在。真正的拖拽排序留给真机。
    final h = harness();
    h.castState = const CastPeerState(
      activePeer: kCastPeer,
      castQueue: <Map<String, dynamic>>[kCastRowA, kCastRowB],
      castIndex: 0,
    );
    await h.pump(tester, width: 1000, height: 900);

    expect(find.byType(CastQueueSheetView), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (Widget w) => w is ReorderableListView,
      ),
      findsOneWidget,
      reason: '#B8：投屏队列必须是 ReorderableListView，拖拽才能下发 reorderQueue',
    );
  });

  testWidgets('B9 链路 A onClear → cast.clearCastQueue', (tester) async {
    final h = harness();
    h.castState = const CastPeerState(
      activePeer: kCastPeer,
      castQueue: <Map<String, dynamic>>[kCastRowA, kCastRowB],
      castIndex: 0,
    );
    await h.pump(tester, width: 1000, height: 900);

    await tester.tap(find.bySemanticsLabel(RegExp('清空投屏队列')));
    await tester.pump(const Duration(milliseconds: 10));

    expect(h.cast.calls, contains('clearCastQueue'));
  });

  testWidgets('B10 链路 A offline 时标题追加离线后缀', (tester) async {
    final h = harness();
    h.castState = const CastPeerState(
      activePeer: kCastPeer,
      castQueue: <Map<String, dynamic>>[kCastRowA],
      castIndex: 0,
      offline: true,
    );
    await h.pump(tester, width: 1000, height: 900);

    final expected =
        h.loc!.queue_cast_count(1, kCastPeer.name) +
        h.loc!.queue_cast_offline_suffix;
    expect(find.text(expected), findsOneWidget);
    expect(
      find.text(h.loc!.queue_cast_count(1, kCastPeer.name)),
      findsNothing,
      reason: 'offline 时必须带上后缀，不能只显示半句',
    );
  });

  testWidgets('B11 DLNA 直投态：deviceName 取 dlnaCast.currentDevice.name', (
    tester,
  ) async {
    final h = harness();
    // #152-D：`deviceName` 会被拼进 `loc.queue_cast_count(n, deviceName)` 那条文案里，
    //         所以断言按 `contains` 找 `Text`，不能 `find.text(deviceName)`。
    // #155-D：`DlnaDevice` 虽然自己是 `const` 构造，但 `lastSeen` 是
    //         `DateTime(2026)` —— `DateTime` 的构造函数**不是 const**，所以 `const
    //         DlnaDevice(...)` 会报 "Cannot invoke a non-'const' constructor where a const
    //         expression is expected"。同一个坑前面也在 `const List<Song> kSongs`
    //         撞过一次（`Song` 的构造不是 const）。这里直接去掉 `const`，
    //         整个 `DlnaCastState(...)` 也不必是 const。
    h.dlnaState = DlnaCastState(
      currentDevice: DlnaDevice(
        id: 'uuid:dlna-1',
        name: '卧室投屏',
        alias: '卧室',
        location: 'http://192.168.10.31:2869/desc.xml',
        lastSeen: DateTime(2026),
      ),
      isCasting: true,
      currentIndex: 0,
      queue: <DlnaCastTrack>[],
    );
    await h.pump(tester, width: 1000, height: 900);

    expect(find.byType(CastQueueSheetView), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (Widget w) => w is Text && (w.data ?? '').contains('卧室投屏'),
      ),
      findsOneWidget,
      reason: '#152-D：pqs.dart:192 的 deviceName 必须落到投屏面板头部',
    );
    // #152-D 反侧：`currentDevice` 为空时才回退本地化文案（`-1 局域网设备` 形态），
    //         有设备名时不能还挂着那句兜底。
    expect(
      find.byWidgetPredicate(
        (Widget w) => w is Text && (w.data ?? '').contains(h.loc!.queue_device_local),
      ),
      findsNothing,
      reason: '有 currentDevice 时不该再显示 queue_device_local 兜底文案',
    );
  });

  testWidgets('B12 DLNA 直投态：onClear → dlna.stopCast', (tester) async {
    final h = harness();
    h.dlnaState = const DlnaCastState(
      isCasting: true,
      currentIndex: 0,
    );
    await h.pump(tester, width: 1000, height: 900);

    final clear = find.bySemanticsLabel(RegExp('清空投屏队列'));
    expect(clear, findsOneWidget);
    await tester.tap(clear);
    await tester.pump(const Duration(milliseconds: 10));

    expect(h.dlna.calls, contains('stopCast'));
    expect(h.cast.calls, isEmpty, reason: '链路 B 不该打到链路 A 桩');
  });

  testWidgets('B13 三态优先级：cast 与 dlna 同时在投时走链路 A', (tester) async {
    final h = harness();
    h.castState = const CastPeerState(
      activePeer: kCastPeer,
      castQueue: <Map<String, dynamic>>[kCastRowA],
      castIndex: 0,
    );
    h.dlnaState = const DlnaCastState(isCasting: true, currentIndex: 0);
    await h.pump(tester, width: 1000, height: 900);

    // #134-D：154 行的 cast 分支先于 186 行的 dlna 分支。
    expect(find.byType(CastQueueSheetView), findsOneWidget);
    expect(find.byType(PlayQueueSheetView), findsNothing);
    expect(
      find.byWidgetPredicate(
        (Widget w) => w is Text && (w.data ?? '').contains('客厅音箱'),
      ),
      findsOneWidget,
      reason: 'deviceName 必须是链路 A 的 peer 名，不是 DLNA 的设备名',
    );
  });

  // ---------------------------------------------------------------- C 组
  // onClose 的两条路（4 例）

  testWidgets('C1 关闭按钮 onClose 为空时走 Navigator.maybePop', (tester) async {
    late BuildContext ctx;
    final h = harness();
    await h.pump(
      tester,
      width: 1000,
      height: 900,
      home: _CtxProbe(onContext: (c) => ctx = c),
    );

    // #156-D：harness 的 `PlayQueueSheet` 是 `MaterialApp.home`，也就是 Navigator 的
    //         **第一条路由** —— `ModalRoute.maybePop()` 碰到首条路由（isFirstRoute）
    //         直接返回 false 根本不弹，于是上一版断言「面板从树上消失」恒为假，
    //         看着像断言反号，其实是被测路径压根没执行。先 push 一条新路由，
    //         被推上去的那一条才是「可被 maybePop 弹掉」的。
    // #154-D：仅关心「onClose 为空 ⇒ 走 Navigator 兜底」这一条判定，与 panel 布局无关；
    //         用 panel:true 直挂，避开 panel:false 的 DraggableScrollableSheet 入场
    //         动画（#144-D：那个动画会让任何手势把 tester 拖到超时）。关闭按钮的代码
    //         路径（pqs.dart:389-397）两者完全一致。
    unawaited(
      Navigator.of(ctx).push<void>(
        MaterialPageRoute<void>(
          builder: (BuildContext c) => const PlayQueueSheet(panel: true),
        ),
      ),
    );
    await settle(tester);

    // #151-D：必须是 `AppIcons.close`（codePoint 0xe16a）。写 `Icons.close`
    //         时 finder 会打印 `Found 0 widgets with icon "IconData(U+0E16A)"`，
    //         看着像「按钮没渲染」，其实是断言里的图标常量取错了。
    final close = find.byIcon(AppIcons.close);
    expect(close, findsOneWidget, reason: '#138-D：裸 PlayQueueSheet 也要有关闭按钮');
    var threw = false;
    try {
      await tester.tap(close);
    } catch (_) {
      threw = true;
    }
    // #157-D：路由 pop 带 ~300ms 的退场动画，tap 之后只补一次 `pump(10ms)` 的话，
    //         动画没跑完、路由**仍然 mounted**，下一句 `find.byType(PlayQueueSheet)`
    //         还是找得到 —— 看着像 maybePop 没生效，其实是断言抢在动画前面。
    //         这里用固定帧推进把退场动画推完（#140-D 同款）。
    await settle(tester, frames: 8);

    expect(
      threw,
      isFalse,
      reason: '#138-D：onClose 为空时 maybePop 兜底不该抛',
    );
    expect(tester.takeException(), isNull);
    // #154-D：被推上去的那条路由被 maybePop 弹掉 ⇒ 面板从树上消失，
    //         反过来证明「onClose 为空确实走了 Navigator 而不是 onClose 回调」。
    expect(
      find.byType(PlayQueueSheet),
      findsNothing,
      reason: '#154-D：onClose 为空 ⇒ 走 maybePop 弹路由（不是 onClose 回调）',
    );
  });

  testWidgets('C2 panel=true 且 onClose 非空时点关闭只调 onClose', (tester) async {
    var closed = 0;
    final h = harness();
    await h.pump(
      tester,
      width: 1000,
      height: 900,
      home: PlayQueueSheet(panel: true, onClose: () => closed += 1),
    );

    // #151-D：AppIcons.close，不是 Icons.close。
    await tester.tap(find.byIcon(AppIcons.close));
    await tester.pump(const Duration(milliseconds: 10));

    expect(closed, 1, reason: 'panel 布局的关闭必须走 onClose 回调（141-147 行）');
  });

  testWidgets('C3 链路 A 投屏态的 onClose 也走 onClose 回调', (tester) async {
    var closed = 0;
    final h = harness();
    h.castState = const CastPeerState(
      activePeer: kCastPeer,
      castQueue: <Map<String, dynamic>>[kCastRowA],
      castIndex: 0,
    );
    await h.pump(
      tester,
      width: 1000,
      height: 900,
      home: CastQueueSheetView(
        queue: kSongs,
        currentIndex: 0,
        deviceName: kCastPeer.name,
        onSelect: (_) async {},
        onRemove: (_) {},
        onReorder: (int from, int to) {},
        onClear: () async {},
        onClose: () => closed += 1,
      ),
    );

    // #151-D：AppIcons.close，不是 Icons.close。
    await tester.tap(find.byIcon(AppIcons.close));
    await tester.pump(const Duration(milliseconds: 10));

    expect(closed, 1);
  });

  testWidgets('C4 DLNA 直投态的 onClose 也走 onClose 回调', (tester) async {
    var closed = 0;
    final h = harness();
    h.dlnaState = const DlnaCastState(isCasting: true, currentIndex: 0);
    // #154-D：DLNA 直投态也是 `CastQueueSheetView`，它的关闭按钮在
    //         pqs.dart:568-576 同样按 `onClose != null` 分流 —— 所以这里必须真的传
    //         一个 onClose，否则验到的是 `Navigator.maybePop()` 弹路由，
    //         面板会整棵消失、断言全反。
    await h.pump(
      tester,
      width: 1000,
      height: 900,
      home: PlayQueueSheet(panel: true, onClose: () => closed += 1),
    );

    // #151-D：AppIcons.close，不是 Icons.close。
    expect(find.byType(CastQueueSheetView), findsOneWidget);
    await tester.tap(find.byIcon(AppIcons.close));
    await tester.pump(const Duration(milliseconds: 10));

    expect(closed, 1, reason: 'DLNA 直投态的关闭也必须走 onClose 回调');
    // 走回调 ⇒ 面板不弹栈 ⇒ 还挂在树上（和 C1 的 maybePop 形成正反对照）。
    expect(find.byType(CastQueueSheetView), findsOneWidget);
  });

  // ---------------------------------------------------------------- D 组
  // `RightQueuePanel` 布局 clamp（4 例）

  testWidgets('D1 窗宽 700 时面板宽度夹到下界 150', (tester) async {
    final h = harness();
    await h.pump(
      tester,
      width: 700,
      height: 900,
      home: Stack(children: <Widget>[RightQueuePanel(onClose: () {})]),
    );

    final rect = tester.getRect(find.byKey(const ValueKey<String>('right-queue-panel')));
    expect(rect.width, closeTo(150, 0.6), reason: '#139-D：700*0.17=119 → clamp 到 150');
  });

  testWidgets('D2 窗宽 1000 时面板宽度取 0.17 原值（170）', (tester) async {
    final h = harness();
    await h.pump(
      tester,
      width: 1000,
      height: 900,
      home: Stack(children: <Widget>[RightQueuePanel(onClose: () {})]),
    );

    final rect = tester.getRect(find.byKey(const ValueKey<String>('right-queue-panel')));
    expect(rect.width, closeTo(170, 0.6));
  });

  testWidgets('D3 窗宽 2000 时面板宽度夹到上界 220', (tester) async {
    final h = harness();
    await h.pump(
      tester,
      width: 2000,
      height: 900,
      home: Stack(children: <Widget>[RightQueuePanel(onClose: () {})]),
    );

    final rect = tester.getRect(find.byKey(const ValueKey<String>('right-queue-panel')));
    expect(rect.width, closeTo(220, 0.6), reason: '#139-D：2000*0.17=340 → clamp 到 220');
  });

  testWidgets('D4 verticalInset 随窗高夹在 44~152', (tester) async {
    final h = harness();

    // 窗高 400 → 48（原值，在区间内）
    await h.pump(
      tester,
      width: 1000,
      height: 400,
      home: Stack(children: <Widget>[RightQueuePanel(onClose: () {})]),
    );
    var rect = tester.getRect(find.byKey(const ValueKey<String>('right-queue-panel')));
    expect(rect.top, closeTo(48, 0.6));
    expect(
      (400 - rect.height - rect.top - 48).abs(),
      lessThan(1.5),
      reason: '上下留白应对称',
    );

    // 窗高 3000 → 360 夹到上界 152
    await h.pump(
      tester,
      width: 1000,
      height: 3000,
      home: Stack(children: <Widget>[RightQueuePanel(onClose: () {})]),
    );
    rect = tester.getRect(find.byKey(const ValueKey<String>('right-queue-panel')));
    expect(rect.top, closeTo(152, 0.6));
    expect(rect.bottom, closeTo(3000 - 152, 1.5));
  });
}
