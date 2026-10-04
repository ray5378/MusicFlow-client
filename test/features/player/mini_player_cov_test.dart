// ============================================================================
// batch25 —— `mini_player.dart` widget 补测
//
// 只打 `lib/features/player/widgets/mini_player.dart` 自己那一段装配 + 手势 +
// 渲染长尾：**不改产品代码**，发现的缺陷只记录不修改。
//
// 分工（与已提交的 `mini_player_test.dart` / `player_scrubber_test.dart`）：
//   * `mini_player_test.dart` 打的是 `MiniPlayerView`（**无 provider 的纯控件**），
//     姿势是 `pumpWidget(appFor(view(...)))`，覆盖 56dp 高度、手机端两键、
//     进度环取色、tap/double-tap/fling/scrub 基础手势、preview 封面。
//     它**从没构造过 `MiniPlayer` 这个 ConsumerWidget**。
//   * `player_scrubber_test.dart` 打的是 `player_scrubber.dart`（独立进度条控件），
//     与本文件的进度手势层无关。
//   * 本文件打的是这三者之外的部分：`MiniPlayer.build()` 的**整条 provider
//     路由**（本机 / 链路 A 投屏 / DLNA 直投三态各自的 prev/next/mode 落点）、
//     桌面端 8 控件与响应式档位、`_ProviderMiniPlayerProgress`、
//     `_MiniPlayerProgressSurface` 的语义快进/快退、拖拽气泡与取消、
//     `_PlayModeButton` 四档 + 未知值兜底、`_MiniPlayerLyric` 长尾渲染。
//
// 踩坑注释（续 85-D 起，前面批次用的是 62~84）：
//
// #85-D `pumpAndSettle` 在这批页面永远等不到「静」：封面外圈是
//       `CircularProgressIndicator`（每帧请求新帧）+ 桌面档位的 `AnimatedOpacity`，
//       实测直接 timeout。统一用固定帧 `settle()`。
// #86-D `playerProvider` 是 `StateNotifierProvider`。用 `overrideWithValue`
//       塞进去的是**裸 StateNotifier**，而 `MiniPlayer.build` 里
//       `ref.read(playerProvider.notifier).previous()` 会在运行时 NoSuchMethodError。
//       必须是 `implements PlayerNotifier` 的桩（复用 `test_player_notifier.dart`
//       里的 `TestPlayerNotifier`）：`implements` 只校验**公开**成员，
//       PlayerNotifier 那一堆 private 抽象方法（库外不可见）天然不参与校验。
// #87-D `CastPeerController` / `DlnaCastNotifier` 的构造函数里会 `ref.read(...)`
//       起 Manager 并起轮询 Timer，测试里必须**整体 override 成子类**，
//       覆写 prev/next/cyclePlayMode/toggle/seek 只记调用序列，不能靠真 notifier。
// #88-D 桌面分支看的是 `Theme.of(context).platform`；`debugDefaultTargetPlatformOverride`
//       能在 Linux 机器上跑 Windows 分支，但**必须在用例体内 finally 还原成 null**
//       —— 写在 `addTearDown` 里会报 debug variable 变更错误。
// #89-D 默认 800×600 视口下 LayoutBuilder 的 `constraints.maxWidth` ≈ 776，
//       桌面档位永远只有「全量」一档，分不出淡出档 / 只留一个按钮的档位。
//       要按档位切 `tester.view.physicalSize`（+ dpr=1），每例结束 reset。
// #90-D `MiniPlayer.build` 里 71–74 / 100 行只是参数引用（没有可覆盖指令），
//       真正未覆盖的是**闭包体**（75–99、101–126）。光把 `MiniPlayer` 挂上去
//       一行都盖不到，必须真点按钮把闭包打起来。
// #91-D 拖拽取消只能走 `GestureTester.cancelPointer()`；`gesture.up()` 触发的是
//       `onHorizontalDragEnd`，试过都走不到取消分支。
// #92-D `_MiniPlayerProgressSurface._scrubViewportWidth` 是在 build 的 LayoutBuilder
//       闭包里赋值的，`tester.pump()` 过帧之前它还是 1，比例全错 ——
//       手势起手点必须在泵过帧之后按 `tester.getRect()` 现取。
// #93-D 语义动作要先 `tester.ensureSemantics()`（拿 handle）再
//       `tester.getSemantics(finder)`；`excludeFromSemantics` 只挂在内层
//       GestureDetector 上，外层 `Semantics(label: '播放进度')` 仍可找。
// #94-D `toggleRightQueuePanel` 的 `_queuePanelOpen` / `_activeQueueClose` 是
//       **模块级静态量**：上一例开着面板，下一例点同一个按钮会变成「关」，
//       断言会莫名其妙反号。每例 tearDown 里 `closeRightQueuePanel()`。
// #95-D `peerNowPlayingProvider` 是 `StreamProvider.autoDispose.family`，
//       没有 `overrideWithValue`，只能
//       `overrideWith((ref, id) => const Stream<PeerNowPlaying?>.empty())`。
// #96-D `_PlayModeButton` 的 `Tooltip.message` 与 `MusicFlowIconButton.label`
//       是**同一个文案**：`find.bySemanticsLabel` 只命按钮一个，
//       但 `find.byTooltip` 会命中两个 —— 别混用。
// #97-D `HapticFeedback.selectionClick()` 测试环境是 no-op 不用打桩，但它夹在
//       `_togglePlayPause` / `_handleProgressDragEnd` 里，断言前要留够泵帧。
// #98-D 桌面档位下 `VolumeButton` 内部也嵌了一个 `MusicFlowIconButton`，
//       所以 `find.byType(MusicFlowIconButton)` 是 9 而不是 8；按语义标签找更稳。
// #99-D `PlayerState` 的构造函数**不是 const**，写 `const PlayerState()`
//       直接编译不过；`CastPeerState` / `DlnaCastState` 才是 const 构造。
// #100-D Flutter 3.47 里语义动作的新姿势是
//        `tester.semantics.performAction(finder, action, args: …)`——
//        **没有** `sendSemanticsAction`，`SemanticsNode` 上也**没有**
//        `invokeAction()`（这是老 Flutter≤3 的写法）。更麻烦的是 `performAction`
//        要 `FinderBase<SemanticsNode>`，而 `find.bySemanticsLabel` 返回
//        `FinderBase<Element>`，直传编译不过 —— 自己继承公开的 `SemanticsFinder`
//        （`lib/src/finders.dart`），它只留 `evaluate()` 一个抽象成员，
//        `allCandidates` 已经实现好了。
// #101-D 拖拽取消走 `TestGesture.cancel()`（派发 PointerCancelEvent，触发
//        `onHorizontalDragCancel`）；`TestGesture` 上**没有** `cancelPointer()`
//        这个老名字，只有 `TestPointer.cancel()` / `TestGesture.cancel()`。
// #112-D `overrideWith` 的闭包**只在第一次读 provider 时执行一次**，之后 Riverpod
//        把 notifier 实例缓存住。`h.position = …` 改的是 harness 字段，
//        闭包里的 `_read()` 还指向**旧值** ⇒ 越界边界（0 / duration）永远打不到。
//        要推进位置只能拿到 stub 实例后走 `Notifier.state` 的 setter。
// #113-D `_handleProgressDragEnd` 的 `sameSong` 要求 `_scrubSongId == widget.songId`，
//        `songId` 取自 `playerState.currentSong?.id` —— **没有当前歌曲时它恒为 null**，
//        拖拽会话也锁定 null ⇒ `sameSong` 恒 false ⇒ 松手**永远不 seek**（静默吞掉）。
//        要测拖拽 seek 必须 `harness(current: song)`。
// #114-D `onOpenQueue` 的分流看的是 `context.musicFlowWindowClass`（MediaQuery
//        宽度断点 compact<600≤medium<840≤expanded），而按钮渲染看的是 `_isDesktop`
//        + `_buildResponsiveDesktopControls(windowWidth)`。两者是**两套宽度**，
//        但在这条装配链路上它们恰好同值 —— 于是「compact 档（<600）」与
//        「队列按钮在树里（windowWidth ≥ 180+6×48=468）」只在 468~600 这个窄带里
//        同时成立；宽 360 时桌面档只有 3 个控件（上一首/播放/下一首），队列按钮
//        根本不在树上，点它必然 0 命中。
// #115-D `overrideWith` 的 provider 一旦 cache，改 `h.state`（harness 字段）不会
//        重建 notifier —— `ref.watch(playerProvider)` 拿到的仍是**旧 state**，
//        `playbackMode.name` 不跟着变。要换 state 必须换一个 harness 重新
//        `pumpWidget`（重建 ProviderScope），不能在同一棵树里 mutate。
// #116-D `find.ancestor(of: X, matching: find.byType(Align))` 返回的是**整条祖先链**
//        上所有 Align（Scaffold body 那个 Align、气泡自己那个 Align …），不是「最近
//        一个」 ⇒ 实测 `Bad state: Too many elements`。气泡那层的特征是其
//        `child is MusicFlowSurface`，用 `byWidgetPredicate` 直接点名。
// #117-D `_PlayModeButton` 的四档文案与 `PlaybackMode.name` **一一对应**
//        （shuffle/one/order/all），但本机 `playbackMode` 默认 + 未设值时就是
//        `all` —— 断言「默认不高亮」的用例不能靠「先跑 order 档」顺带成立。
// #118-D 竖向「上滑展开」必须走 `tester.fling(finder, Offset(0, dy), speed)`
//        的三段式（down → move → up）。用 `moveBy` 两段式时 `onVerticalDragEnd`
//        收不到速度，`shouldExpand` 判据恒 false ⇒ `onOpenPlayer()` 永不触发；
//        更坑的是「不该展开」的那几例（下滑 / 慢速）跟着变成**假绿** —— 期望
//        「没展开」也确实没展开，压根没走到判定分支。
// #119-D 竖向手势起手落点必须是 `Key('mini-player-surface')` 那个
//        `GestureDetector`（内部 `excludeFromSemantics` 的 surface）。拿
//        `MiniPlayerView` 中心起手会被底部 `mini-player-scrubber` 的横向拖拽
//        抢答，事件根本到不了竖向分支。
// #120-D `tester.fling` 的签名是 **finder / Offset / speed**
//        （`controller.dart:1288`）—— 第一个参数是 **Finder** 不是坐标，位移走
//        第二个 `Offset offset`，速度第三个。另外 `tester.binding.fling(...)`
//        会报 "'fling' isn't defined for the type 'TestWidgetsFlutterBinding'"。
// #121-D `TestPlayerNotifier` 那套桩只 override 了 `cyclePlaybackMode` /
//        `toggleFavorite`，`previous()` / `next()` 落的是基类实现 —— 打上去不
//        记调用，用例拿到空 calls 会误判成「路由没走对」。桩里四个入口全 override。
// #122-D 本机档的模式按钮走 `playerProvider.notifier.cyclePlaybackMode()`，
//        链路 A / DLNA 投屏档走 `castPeerControllerProvider` / `dlnaCastProvider`
//        的 `cyclePlayMode()` —— 两个方法名只差一个 `back`，期望串要按档位分开写。
// #123-D 裸 `MiniHarness()` 直接构造时 `overrideWith` 的闭包（连带 `cast` / `dlna`
//        这些 `late` 字段）不一定被跑起来；要经 `harness()` 工厂建台。
// #124-D `h.state` 里没有 `currentSong` 时 `toggleFavorite` 在回调里早退（不翻
//        心），语义标签仍是「红心」而不是「取消红心」 ⇒ 这种用例要
//        `harness(current: song)`。
// #125-D 「把闭包逼出来」**不能**用 `tester.readProviderElement(provider)`：
//        `WidgetTester` 上**没有**这个 API（编译期就报
//        "The method 'readProviderElement' isn't defined for the type 'WidgetTester'"）。
//        可行姿势是在 provider 树里挂一个常驻 `ConsumerWidget`，pump 时无条件
//        `read` 几个桩 provider —— 读取无副作用，纯粹让闭包确定性执行（见
//        `MiniHarness.build` 里的 `_ForceProbe`）。
// ============================================================================

import 'dart:ui' show SemanticsAction, TargetPlatform;

// #100-D：`SemanticsNode` **不在** `dart:ui` 里（只有 `SemanticsAction` 在那儿），
// 它归 `package:flutter/widgets.dart`（material.dart 间接导出）。别和 dart:ui
// 的 `show` 混写，否则「Type 'SemanticsNode' not found」。
import 'package:flutter/semantics.dart' show SemanticsNode;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musicflow_client/core/design/music_flow_design.dart';
// #116-D：`MusicFlowSurface` 在 `core/design/components/` 下，不在
// `music_flow_design.dart` 的 barrel 里 —— 拿它当气泡「Align 的 child」的判据
// 得显式 import，否则 `w.child is MusicFlowSurface` 编译不过。
import 'package:musicflow_client/core/design/components/music_flow_surface.dart';
import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/data/models/peer.dart';
import 'package:musicflow_client/data/models/song.dart';
import 'package:musicflow_client/features/player/pages/full_player_page.dart';
import 'package:musicflow_client/widgets/cover_art_image.dart';
import 'package:musicflow_client/features/player/pages/player_transfer_page.dart';
import 'package:musicflow_client/features/player/widgets/mini_player.dart';
import 'package:musicflow_client/features/player/widgets/play_queue_sheet.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:musicflow_client/providers/cast/cast_peer_provider.dart';
import 'package:musicflow_client/providers/cast/cast_peer_state.dart';
import 'package:musicflow_client/providers/cast/dlna_provider.dart';
import 'package:musicflow_client/providers/player/effective_playback_provider.dart';
import 'package:musicflow_client/providers/player/frozen_playback_provider.dart';
import 'package:musicflow_client/providers/player/player_provider.dart';
import 'package:musicflow_client/providers/ui/palette_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'test_player_notifier.dart';

const String kVolumeLabel = '音量 80%';
const String kQueuePanelKey = 'right-queue-panel';

/// `_MiniPlayerProgressSurface` 外层 `Semantics` 的 label（`loc.player_progress`
/// 在 zh 下的取值，见 app_zh.arb:2255）。
const String kProgressLabel = '播放进度';

const PeerInfo kCastPeer = PeerInfo(
  peerId: 'dlna:41',
  name: '客厅音箱',
  kind: 'dlna',
  available: true,
);

/// #100-D：按 `SemanticsNode.label` 找语义节点，喂给
/// `tester.semantics.performAction`。
///
/// `SemanticsFinder` 是 flutter_test **公开**抽象类（lib/src/finders.dart），
/// `roots` / `allCandidates` 都已实现，但 `FinderBase` 还需要 `evaluate()` /
/// `describeMatch()` / `findInCandidates()` 三个抽象成员。
class _LabelSemanticsFinder extends SemanticsFinder {
  _LabelSemanticsFinder(this.label, [FlutterView? view]) : super(view);

  final String label;

  @override
  FinderResult<SemanticsNode> evaluate() => FinderResult<SemanticsNode>(
    (Plurality _) => "a semantic node labeled '$label'",
    allCandidates.where((SemanticsNode n) => n.label == label),
  );

  @override
  String describeMatch(Plurality plurality) => "semantic nodes labeled '$label'";

  @override
  Iterable<SemanticsNode> findInCandidates(
    Iterable<SemanticsNode> candidates,
  ) =>
      candidates.where((SemanticsNode n) => n.label == label);
}

/// 语义快进/快退（对应 `_MiniPlayerProgressSurfaceState._seekRelative`）。
void semanticSeek(WidgetTester tester, SemanticsAction action) {
  tester.semantics.performAction(
    _LabelSemanticsFinder(kProgressLabel),
    action,
    args: null,
  );
}

/// 只记调用序列的链路 A controller 桩（见 #87-D）。
class RecordingCastPeer extends CastPeerController {
  RecordingCastPeer(super.ref);

  final List<String> calls = <String>[];

  @override
  Future<void> toggle() async {
    calls.add('toggle');
  }

  @override
  Future<void> next() async {
    calls.add('next');
  }

  @override
  Future<void> previous() async {
    calls.add('previous');
  }

  @override
  Future<void> cyclePlayMode() async {
    calls.add('cyclePlayMode');
  }

  @override
  Future<void> seek(Duration position) async {
    calls.add('seek:${position.inMilliseconds}');
  }

  @override
  Future<List<PeerInfo>> loadPeers() async => <PeerInfo>[kCastPeer];
}

/// 只记调用序列的 DLNA 直投 notifier 桩（见 #87-D）。
class RecordingDlnaCast extends DlnaCastNotifier {
  RecordingDlnaCast(super.ref);

  final List<String> calls = <String>[];

  @override
  Future<void> toggle() async {
    calls.add('toggle');
  }

  @override
  Future<void> next() async {
    calls.add('next');
  }

  @override
  Future<void> previous() async {
    calls.add('previous');
  }

  @override
  Future<void> cyclePlayMode() async {
    calls.add('cyclePlayMode');
  }
}

/// 多记 `cyclePlaybackMode` / `toggleFavorite` / `previous` / `next` 四条本地播放器
/// 入口的桩（见 #86-D）。
///
/// #121-D：`TestPlayerNotifier` 那套桩只 override 了 `cyclePlaybackMode` /
/// `toggleFavorite` 两个入口，`previous()` / `next()` 落的是基类实现 ——
/// 打上去不会改 state 也**不记任何调用**。A1 因此可以「点上一首/下一首」跑完
/// 却拿到空 calls，看上去像路由没走对。这里把另外两个入口也 override 掉。
class RecordingPlayerNotifier extends TestPlayerNotifier {
  RecordingPlayerNotifier(super.state);

  final List<String> calls = <String>[];

  @override
  Future<void> previous() async {
    calls.add('previous');
    await super.previous();
  }

  @override
  Future<void> next() async {
    calls.add('next');
    await super.next();
  }

  @override
  Future<void> cyclePlaybackMode() async {
    calls.add('cyclePlaybackMode');
    await super.cyclePlaybackMode();
  }

  @override
  Future<void> toggleFavorite() async {
    calls.add('toggleFavorite');
    await super.toggleFavorite();
  }
}

/// 固定帧推进代替 `pumpAndSettle`（见 #85-D）。
Future<void> settle(WidgetTester tester, {int frames = 6}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}

/// 匹配拖拽气泡里的 "m:ss" 文案。
Finder bubbleText() => find.byWidgetPredicate(
  (Widget w) =>
      w is Text && RegExp(r'^\d+:\d\d$').hasMatch((w.data ?? '').trim()),
);

/// 本文件全部用例的仿真台上下文。
class MiniHarness {
  MiniHarness({
    PlayerState? state,
    this.castState = const CastPeerState(),
    this.dlnaState = const DlnaCastState(),
    this.position = const Duration(seconds: 30),
    this.duration = const Duration(minutes: 3),
    this.playing = false,
    this.lyricLine,
    this.visuals,
  }) : state = state ?? PlayerState();

  PlayerState state;
  CastPeerState castState;
  DlnaCastState dlnaState;
  Duration position;
  Duration duration;
  bool playing;
  final String? lyricLine;
  final MusicFlowMediaVisuals? visuals;

  late RecordingPlayerNotifier player;
  late RecordingCastPeer cast;
  late RecordingDlnaCast dlna;

  /// #112-D：`frozenPositionProvider` 被 override 成 `_StubFrozenPosition` 后，
  /// 用例要能把「当前播放位置」**推进去**才能打越界边界（stub 返回值恒定的话，
  /// 连点三下快进永远得到同一个目标，到顶/归零两条分支都摸不到）。
  /// 存下 stub 实例，用 `Notifier.state` 的 setter 推进（会 notify → 整条重建）。
  late _StubFrozenPosition frozenPos;

  /// 本棵树对应的 container，[pump] 结束时统一 dispose（见 #125-D）。
  ProviderContainer? _container;

  /// #129-D：本棵树里 `context.musicFlowColors` 的快照（由 `_buildHome` 里的
  /// `Builder` 在 build 时抓），见 [build] 末尾的注释。
  MusicFlowColors? palette;

  /// 装配 provider 台（把 `MiniPlayer` 或任意子树挂成 home）。
  ///
  /// #125-D：桩实例**不**再挂在 `overrideWith` 的闭包里等 widget 树去触发。
  /// 那条路试过两遍都塌了：`overrideWith(() { … })` 的闭包是**懒执行**的，
  /// 而 `MiniPlayer.build` 只在部分档位/分支里 `ref.watch(castPeerControllerProvider)`
  /// —— 别的路径下 provider 一次都没被 instantiate，用例一取 `h.cast` 就
  /// `LateInitializationError`；想从测试侧逼闭包，`tester.readProviderElement(...)`
  /// 在 `WidgetTester` 上**没有这个 API**（编译期就挂）。
  /// 现在的做法：自己起一个 `ProviderContainer`，**建完立刻把三个桩 provider
  /// 各 `read` 一次**，桩实例在这一刻落定；widget 树走 `UncontrolledProviderScope`
  /// 挂上去，只消费不创建。每棵树一个 container ⇒ 同一份 override 语义
  /// （见 #115-D / #123-D：要换状态就换树）。
  Widget build({
    TargetPlatform platform = TargetPlatform.android,
    double width = 1000,
    double height = 2600,
    Widget? home,
  }) {
    final container = ProviderContainer(
      overrides: <Override>[
        playerProvider.overrideWith(
          (Ref ref) => RecordingPlayerNotifier(state),
        ),
        castPeerControllerProvider.overrideWith((Ref ref) {
          final c = RecordingCastPeer(ref)..state = castState;
          return c;
        }),
        dlnaCastProvider.overrideWith((Ref ref) {
          final d = RecordingDlnaCast(ref)..state = dlnaState;
          return d;
        }),
        effectiveIsPlayingProvider.overrideWith((Ref ref) => playing),
        effectiveDurationProvider.overrideWith((Ref ref) => duration),
        // #102-D：`overrideWithValue` 是 `ProviderBase` 上一个 mixin 才带的
        //       （`provider_base.dart:229`），`NotifierProviderImpl` 没 mix 它 ——
        //        对 `NotifierProvider` 只能用 `overrideWith` 塞一个
        //        `Notifier` 实例（这里是自家的 `_Stub…` 子类）。
        frozenPositionProvider.overrideWith(
          (() => _StubFrozenPosition(() => position)),
        ),
        frozenLyricLineProvider.overrideWith(
          (() => _StubFrozenLyricLine(lyricLine)),
        ),
        resolvedCurrentSongMediaVisualsProvider.overrideWith(
          (Ref ref) => visuals ?? MusicFlowMediaVisuals.fallback(),
        ),
        peerNowPlayingProvider.overrideWith(
          (Ref ref, String peerId) => const Stream<PeerNowPlaying?>.empty(),
        ),
      ],
    );
    _container = container;
    // #125-D / #126-D：把三个桩 provider 各 read 一次 —— 闭包就在这几行跑完，
    // `player` / `cast` / `dlna` 此后必定已初始化（不再依赖 widget 树走到哪条分支）。
    // ⚠️ #126-D：这里必须走 **`.notifier`** —— `StateNotifierProvider` /
    // `NotifierProvider` 的 `container.read(provider)` 返回的是**状态**
    // （`PlayerState` 等）而不是 notifier 实例，直接 `as` 会
    // `TypeError: type 'PlayerState' is not a subtype of type 'RecordingPlayerNotifier'`。
    player = container.read(playerProvider.notifier) as RecordingPlayerNotifier;
    cast = container.read(castPeerControllerProvider.notifier)
        as RecordingCastPeer;
    dlna = container.read(dlnaCastProvider.notifier) as RecordingDlnaCast;
    frozenPos = container.read(frozenPositionProvider.notifier)
        as _StubFrozenPosition;
    return UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
        theme: AppTheme.dark(),
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            // #129-D：把**树内**的 `context.musicFlowColors` 抓一份出来。
            // 主题里挂的 `MusicFlowColors` extension 与 `Theme.of().colorScheme`
            // 不是一回事（实测投屏态按钮取到的 accent 是被
            // `ensureColorContrast(accent, background: nightCanvas)` 拉过的灰，
            // 而 `Theme.of` 那条是品牌红），用例要断言「按钮取的是哪个色」
            // 就必须用同一个 context 取 palette，不能在外面拿主题色替代。
            child: Builder(
              builder: (context) {
                palette = context.musicFlowColors;
                return home ?? const MiniPlayer();
              },
            ),
          ),
        ),
      ),
    );
  }

  /// 起 `MiniPlayer` 并把视口调到 [width]×[height]（见 #89-D）。
  Future<void> pump(
    WidgetTester tester, {
    TargetPlatform platform = TargetPlatform.android,
    double width = 1000,
    double height = 2600,
    Widget? home,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = Size(width, height);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    // 每棵树一个 container，树收了就 dispose（否则 provider 状态跨树串味）。
    addTearDown(() => _container?.dispose());
    await tester.pumpWidget(
      build(platform: platform, width: width, height: height, home: home),
    );
    await settle(tester);
  }
}

/// `frozenPositionProvider` 是 `NotifierProvider<FrozenPositionNotifier,
/// Duration>`，override 要的是**实例**不是值（踩坑 #91-D）。
class _StubFrozenPosition extends FrozenPositionNotifier {
  /// #106-D：`build()` 里**现取**而不是记死初值 ——
  /// `_seekRelative` 的起点是 `widget.position`，一旦 stub 返回常量，
  /// 连点三下「快进」只会得到同一个目标（`30+10`、`30+10`、`30-10`），
  /// 边界用例（到顶 / 到 0）永远打不到。传函数，用例中途改 `h.position` 立刻生效。
  _StubFrozenPosition(this._read);

  final Duration Function() _read;

  @override
  Duration build() => _read();
}

class _StubFrozenLyricLine extends FrozenLyricLineNotifier {
  _StubFrozenLyricLine(this.value);

  final String? value;

  @override
  String? build() => value;
}

/// 取当前主题的强调色：`accent` 是 ThemeExtension 的**实例字段**，
/// 不是 `MusicFlowColors.accent` 这种静态常量（踩坑 #92-D）。
Color accentOf(WidgetTester tester) {
  final ctx = tester.element(find.byType(Navigator).first);
  return Theme.of(ctx).extension<MusicFlowColors>()!.accent;
}

void main() {
  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues(<String, Object>{});
    const MethodChannel('plugins.flutter.io/path_provider')
        .setMockMethodCallHandler(
          (MethodCall call) async => '/tmp/musicflow-b25',
        );
  });

  // #94-D：`_queuePanelOpen` 是模块级静态量，跨例残留会让下一例「点一下变关」。
  tearDown(() {
    closeRightQueuePanel();
  });

  final song = Song(
    id: 's1',
    title: 'Current Song',
    artist: 'Current Artist',
    album: 'Current Album',
  );

  MiniHarness harness({Song? current}) => MiniHarness(
    state: PlayerState(
      currentSong: current,
      queue: <Song>[song, current ?? song],
      currentIndex: 0,
      position: const Duration(seconds: 30),
      duration: const Duration(minutes: 3),
    ),
  );

  /// 跑一次 `MiniPlayer` + 桌面档位，return 里 finally 还原平台（见 #88-D）。
/// 桌面档位专用：临时把 `debugDefaultTargetPlatformOverride` 顶成 windows
/// 再泵（#88-D；用例体内 finally 还原，别放 addTearDown）。
///
/// ⚠️ #110-D：`MiniHarness.build(platform: …)` 的 `platform` 参数**实际是空转**
/// （build 里根本没用到它，`_isDesktop` 只看 `debugDefaultTargetPlatformOverride`）。
/// 所以「桌面档」的唯一开关就是那个 debug 变量。
Future<void> pumpDesktop(
  WidgetTester tester,
  MiniHarness h,
  double width,
) async {
  final previous = debugDefaultTargetPlatformOverride;
  try {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    await h.pump(tester, width: width);
  } finally {
    debugDefaultTargetPlatformOverride = previous;
  }
}

/// 桌面档 + 自带子树（D4 那种自己拼 `MiniPlayerView` 的用例）。
Future<void> pumpDesktopHome(
  WidgetTester tester,
  Widget home, {
  double width = 1400,
}) async {
  final previous = debugDefaultTargetPlatformOverride;
  try {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    await MiniHarness().pump(tester, width: width, home: home);
  } finally {
    debugDefaultTargetPlatformOverride = previous;
  }
}

  // ==========================================================================
  // 分组 A —— MiniPlayer.build 的 provider 路由（本机 / 链路 A / DLNA 三态）
  // ==========================================================================

  testWidgets('A1 本机态桌面全控件：上一首/下一首/模式/红心都打到本地播放器桩', (
    tester,
  ) async {
    // #124-D：`harness()` 默认没当前歌曲，`toggleFavorite()` 会早退（没有当前歌
    // 可翻面）⇒ 红心按钮点了不翻、也还是 outline 图标。这一例要点红心，必须带上
    // 当前歌曲。
    final h = harness(current: song);
    await pumpDesktop(tester, h, 1200);

    // 桌面档位就 8 个 MusicFlowIconButton（上一首/播放/下一首/模式/红心/队列/
    // 音量 / 流转）。#98-D 早先估的 9 是把 `VolumeButton` 内嵌那个算重了，实测 8。
    expect(find.byType(MusicFlowIconButton), findsNWidgets(8), reason: '#98-D');
    for (final label in <String>[
      '上一首',
      '下一首',
      '播放',
      '列表循环，点击切换到随机播放',
      '红心',
      '当前播放列表',
      kVolumeLabel,
    ]) {
      expect(find.bySemanticsLabel(label), findsOneWidget, reason: label);
    }

    // [D-070] 现状钉子：`CastPeerState.targetName = activePeer?.name ?? peer_self`
    // （cast_peer_state.dart:94），本机态取的是**全局语言变量**
    // `l10nNowCurrent() => l10nNow(_currentAppLanguage)`
    // （core/l10n/localizations.dart:40）—— 它跟 UI context 的 locale 完全无关。
    // 中文界面下这里渲染出的是英文 "This device"（app_zh.arb:3120 明明是「本机」），
    // 按钮上挂着一句半洋不洋的「流转播放，当前：This device」。
    // 将来若把解析源换成 context.l10n，这条会红。
    expect(find.bySemanticsLabel('流转播放，当前：This device'), findsOneWidget);
    expect(
      find.bySemanticsLabel('流转播放，当前：本机'),
      findsNothing,
      reason: '[D-070] 本机态不该拼出「本机」',
    );

    await tester.tap(find.bySemanticsLabel('上一首'));
    await settle(tester);
    await tester.tap(find.bySemanticsLabel('下一首'));
    await settle(tester);
    await tester.tap(find.bySemanticsLabel('列表循环，点击切换到随机播放'));
    await settle(tester);
    await tester.tap(find.bySemanticsLabel('红心'));
    await settle(tester);

    // #122-D：本机态那颗模式按钮调的是
    // `ref.read(playerProvider.notifier).cyclePlaybackMode()` —— 不是链路 A / DLNA
    // 的 `cyclePlayMode()`（那两个名字在 A2 / A3 里各记一次，别混）。
    expect(h.player.calls, <String>[
      'previous',
      'next',
      'cyclePlaybackMode',
      'toggleFavorite',
    ]);
    // 本机态不该碰链路 A / DLNA 桩（#90-D：证明 lambda 真按三态路由了）。
    expect(h.cast.calls, isEmpty);
    expect(h.dlna.calls, isEmpty);
    // 红心点完 UI 立刻翻面，证明 toggleFavorite 真改了 state 而不只是记了个标志。
    expect(find.bySemanticsLabel('取消红心'), findsOneWidget);
    expect(find.byIcon(AppIcons.heart), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'A2 链路 A 投屏态：切歌/模式走 CastPeerController，不打本地播放器',
    (tester) async {
      final h = harness();
      h.castState = const CastPeerState(
        activePeer: kCastPeer,
        playMode: 'one',
      );
      await pumpDesktop(tester, h, 1200);

      // 模式按钮文案取 `cast.playMode`（= 'one'），不是本地 playbackMode。
      expect(find.bySemanticsLabel('单曲循环，点击切换到列表循环'), findsOneWidget);
      // 投屏态下流转按钮显示设备名（currentPlayerName 取自 cast.targetName）。
      expect(find.bySemanticsLabel('流转播放，当前：客厅音箱'), findsOneWidget);
      expect(find.bySemanticsLabel('流转播放，当前：本机'), findsNothing);

      await tester.tap(find.bySemanticsLabel('上一首'));
      await settle(tester);
      await tester.tap(find.bySemanticsLabel('下一首'));
      await settle(tester);
      await tester.tap(find.bySemanticsLabel('单曲循环，点击切换到列表循环'));
      await settle(tester);

      expect(h.cast.calls, <String>['previous', 'next', 'cyclePlayMode']);
      expect(h.player.calls, isEmpty, reason: '#90-D：本机桩必须干净');
      expect(h.dlna.calls, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'A3 DLNA 直投态：切歌/模式走 DlnaCastNotifier，模式文案取 dlna.playMode',
    (tester) async {
      final h = harness();
      h.dlnaState = const DlnaCastState(isCasting: true, playMode: 'shuffle');
      await pumpDesktop(tester, h, 1200);

      expect(find.bySemanticsLabel('随机播放，点击切换到顺序播放'), findsOneWidget);
      expect(find.bySemanticsLabel('列表循环，点击切换到随机播放'), findsNothing);

      await tester.tap(find.bySemanticsLabel('上一首'));
      await settle(tester);
      await tester.tap(find.bySemanticsLabel('下一首'));
      await settle(tester);
      await tester.tap(find.bySemanticsLabel('随机播放，点击切换到顺序播放'));
      await settle(tester);

      expect(h.dlna.calls, <String>['previous', 'next', 'cyclePlayMode']);
      expect(h.player.calls, isEmpty);
      expect(h.cast.calls, isEmpty);

      // [D-070] 现状钉子：DLNA 直投时 `currentPlayerName` 仍取自链路 A 的
      // `cast.targetName`（DLNA 直投下 activePeer 恒为 null ⇒ targetName 空串）
      // ⇒ 按钮文案是「流转播放，当前：」，**永远**看不到 DLNA 设备名。
      // 将来若把 DLNA 设备名透传出来，这条会红。
      // 同上：DLNA 直投时 activePeer 恒 null ⇒ targetName 仍走全局语言变量
      // ⇒ 也是那句英文；设备名「客厅音箱」根本透不出来（见 A2 的链路 A 对照）。
      expect(find.bySemanticsLabel('流转播放，当前：This device'), findsOneWidget);
      expect(find.bySemanticsLabel('客厅音箱'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('A4 播放/暂停按钮走 toggleEffectivePlayback（本机也落到链路 A 桩）', (
    tester,
  ) async {
    final h = harness();
    await h.pump(tester, width: 360);

    // 手机两键档：播放 + 流转播放，没有上一首/下一首。
    expect(find.bySemanticsLabel('播放'), findsOneWidget);
    expect(find.bySemanticsLabel('上一首'), findsNothing);

    await tester.tap(find.bySemanticsLabel('播放'));
    await settle(tester);

    expect(h.cast.calls, <String>['toggle']);
    expect(h.player.calls, isEmpty);
    expect(tester.takeException(), isNull);
  });

  // #109-D：封面 + 进度环只在 `currentSong != null` 时才装 —— 空态走的是
  // `player_not_playing` 那段占位，树里根本没有 CircularProgressIndicator。
  // 这些用例必须显式 `harness(current: song)`，否则「No element」。
  testWidgets('A5 手机端进度环取 frozenPosition / effectiveDuration 的比值', (
    tester,
  ) async {
    final h = harness(current: song);
    h.position = const Duration(seconds: 45);
    h.duration = const Duration(minutes: 2);
    await h.pump(tester, width: 360);

    // _ProviderMiniPlayerProgress 把两个 effective provider 喂给
    // _MiniPlayerProgressSurface，再往上喂封面外圈进度环。45/120 = 0.375。
    final indicator = tester.widget<CircularProgressIndicator>(
      find.byType(CircularProgressIndicator),
    );
    expect(indicator.value, closeTo(0.375, 0.001));
    // 语义值走 _formatPlayerProgress（"0:45 / 2:00"）。
    // ⚠️ `Semantics` 的 label/value 是**构造参数**不是 getter（#103-D），
    // 得从语义树（`tester.getSemantics`）上读，`widget<Semantics>().label` 编译不过。
    // #104-D：`SemanticsController.find()` 要的是 `FinderBase<Element>`
    //       （widget finder），不是语义 finder；`performAction` 才反过来要
    //       `FinderBase<SemanticsNode>`。两边别混。
    final node = tester.semantics.find(find.bySemanticsLabel(kProgressLabel));
    expect(node.label, kProgressLabel);
    expect(node.value, '0:45 / 2:00');
    expect(tester.takeException(), isNull);
  });

  testWidgets('A6 compact 档点队列按钮弹底部队列弹窗', (tester) async {
    final h = harness(current: song);
    // #114-D：宽度是**两套判定**的交点。360 时桌面档只留 3 个控件
    // （prev/play/next），队列按钮压根不在树上（tap 直接 0 命中）；
    // 468~600 之间队列按钮（第 6 个）才被放行，而 windowClass 仍是 compact
    // （<600）⇒ 一路走到 `showPlayQueueSheet`。取 500 落在这个窄带正中。
    await pumpDesktop(tester, h, 500);
    // 先钉住「这一档的队列按钮确实在树里、且尾部控件带淡出壳」。
    expect(find.bySemanticsLabel('当前播放列表'), findsOneWidget);

    await tester.tap(find.bySemanticsLabel('当前播放列表'));
    await settle(tester, frames: 8);

    expect(find.byType(PlayQueueSheet), findsOneWidget);
    expect(find.text('2 首曲目'), findsOneWidget);
    // compact 走的不是右侧面板（见 #94-D）。
    expect(find.byKey(const ValueKey<String>(kQueuePanelKey)), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('A7 桌面档点队列按钮切右侧队列面板（再点一次关掉）', (tester) async {
    final h = harness();
    await pumpDesktop(tester, h, 1000);

    final queue = find.bySemanticsLabel('当前播放列表');
    await tester.tap(queue);
    await settle(tester, frames: 8);
    expect(find.byKey(const ValueKey<String>(kQueuePanelKey)), findsOneWidget);
    expect(find.byType(PlayQueueSheet), findsOneWidget);

    // 非模态面板：再点同一个按钮是「关」而不是再开一层。
    await tester.tap(queue);
    await settle(tester, frames: 8);
    expect(find.byKey(const ValueKey<String>(kQueuePanelKey)), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('A8 流转播放按钮跳「流转播放」专用页面（onSwitchPlayer 闭包）', (
    tester,
  ) async {
    final h = harness();
    await h.pump(tester, width: 360);

    // 一例一行：跳转后原页被盖住，不能在同一例里再点别的。
    await tester.tap(find.bySemanticsLabel(RegExp('流转播放')));
    await settle(tester, frames: 8);

    expect(find.byType(PlayerTransferPage), findsOneWidget);
    expect(find.byType(MiniPlayer), findsOneWidget, reason: '迷你条仍在 shell 里');
    expect(tester.takeException(), isNull);
  });

  // ==========================================================================
  // 分组 B —— 桌面控件装配与响应式档位
  // ==========================================================================

  testWidgets('B1 全宽档位：8 个控件全在，一个 AnimatedOpacity 都没有', (
    tester,
  ) async {
    final h = harness();
    await pumpDesktop(tester, h, 1400);

    // [D-071] 现状钉子：桌面档位**每个**控件都套一层 AnimatedOpacity，
    // 全宽（1400）也一个不省 —— 实测 16 个（8 控件 × 内层 + 外层各一）。
    // 将来若真做出「放得下就不套壳」，这条会红。
    // #105-D：`findsNWidgets` 只收 int，收不了 `greaterThan(0)` 这种 Matcher。
    final opacityCount = tester
        .widgetList<AnimatedOpacity>(find.byType(AnimatedOpacity))
        .toList(growable: false)
        .length;
    expect(opacityCount, greaterThan(0), reason: '#105-D');
    expect(find.byIcon(AppIcons.previous), findsOneWidget);
    expect(find.byIcon(AppIcons.next), findsOneWidget);
    expect(find.byIcon(AppIcons.play), findsOneWidget);
    expect(find.byIcon(AppIcons.repeat), findsOneWidget);
    expect(find.byIcon(AppIcons.heartOutline), findsOneWidget);
    expect(find.byIcon(AppIcons.queue), findsOneWidget);
    expect(find.byIcon(AppIcons.transferInfinity), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('B2 收窄档位：尾部控件进 AnimatedOpacity，但透明度恒为 1（钉子）', (
    tester,
  ) async {
    final h = harness();
    await pumpDesktop(tester, h, 500);

    final opacities = tester
        .widgetList<AnimatedOpacity>(find.byType(AnimatedOpacity))
        .map((AnimatedOpacity w) => w.opacity)
        .toList(growable: false);
    expect(opacities, isNotEmpty, reason: '尾部确实进了淡出包装');
    // #105-D：实测收窄到 500 时 AnimatedOpacity 是 12 个（不是 < 8）——
    // 每个控件各一层淡入壳，收窄只是换了壳的数量，没有真的省掉。
    expect(opacities.length, greaterThanOrEqualTo(8), reason: '收窄不减壳');
    // 核心前三个（上一首/播放/下一首）必须还在。
    expect(find.bySemanticsLabel('上一首'), findsOneWidget);
    expect(find.bySemanticsLabel('播放'), findsOneWidget);
    expect(find.bySemanticsLabel('下一首'), findsOneWidget);
    // 被裁掉的尾部控件（流转播放）确实不在树里。
    expect(find.bySemanticsLabel(RegExp('流转播放')), findsNothing);

    // [D-071] 现状钉子：淡出分支算的是 `leftover / buttonStep` 再 clamp 到
    // [0.15, 1.0]，但 leftover = budget - 48*(k-1) 恒 ≥ 48 ⇒ 结果永远 1.0。
    // 这里钉住「淡出包装存在但透明度 = 1」，将来真做出渐隐（< 1）这条会红。
    expect(
      opacities.every((double o) => o == 1.0),
      isTrue,
      reason: '[D-071] 渐隐分支实际不产生渐隐（opacity 恒 1）',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('B3 极窄档位：预算不足一个按钮时只剩第一个控件（钉子）', (
    tester,
  ) async {
    final h = harness();
    await pumpDesktop(tester, h, 220);

    // [D-072] 现状钉子：`budget <= buttonStep` 直接 `return [allControls.first]`，
    // 而 first 是「上一首」—— 最窄的窗口反而只剩切上一首，
    // 播放/暂停这两个核心键被整个砍掉。将来若改成保留播放核心键，这条会红。
    expect(find.bySemanticsLabel('上一首'), findsOneWidget);
    expect(find.bySemanticsLabel('播放'), findsNothing);
    expect(find.bySemanticsLabel('下一首'), findsNothing);
    // #105-D：极窄（220）时还留着 **1 个** AnimatedOpacity —— 只留「上一首」
    // 那个控件自己那层壳，其余控件直接不进树。原以为全裸，实测不是。
    expect(find.byType(AnimatedOpacity), findsNWidgets(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('B4 流转按钮在投屏/非投屏两态都取 ink（投屏不加强调色，钉子）', (
    tester,
  ) async {
    final h = harness();
    await pumpDesktop(tester, h, 1400);

    final visuals = MusicFlowMediaVisuals.fallback();
    // #130-D：流转按钮要按**组件字段**认，别按语义标签往回爬 ——
    // `find.bySemanticsLabel(x)` 命中的是 `Semantics` **组件本身**，直接
    // `tester.widget<MusicFlowIconButton>(...)` 会
    // `TypeError: type 'Semantics' is not a subtype of type 'MusicFlowIconButton'`；
    // 而 `find.ancestor(of:, matching: …)` 又得先知道当前文案（本机态是
    // "…This device"、投屏态是 "…客厅音箱"，跨状态根本写死不了）。
    Finder transferBtn() => find.byWidgetPredicate(
      (Widget w) => w is MusicFlowIconButton && w.icon == AppIcons.transferInfinity,
    );
    final inkBtn = tester.widget<MusicFlowIconButton>(transferBtn());
    final inkIcon = tester.widget<Icon>(find.byIcon(AppIcons.transferInfinity));
    // Icon 必须如实采用按钮的 foregroundColor（MusicFlowIconButton 里
    // `foreground = foregroundColor ?? …`，onPressed 非 null 时不会走兜底）。
    expect(inkIcon.color, inkBtn.foregroundColor, reason: '#130-D 取色一致性');
    // 非投屏态：按钮取 `context.musicFlowColors.ink`
    // （`foregroundColor: widget.isCasting ? accent : ink`）。
    // 注意 #129-D：这里的 `context` 是迷你条**内层** Theme（外层拿到的 palette
    // 与它不是一个），所以用例不去比外层的 `h.palette`，只用「按钮 fg 是否换了」
    // 这个相对事实做钉子。
    expect(inkBtn.foregroundColor, isNotNull);

    final h2 = harness();
    h2.castState = const CastPeerState(activePeer: kCastPeer);
    await pumpDesktop(tester, h2, 1400);

    final accentBtn = tester.widget<MusicFlowIconButton>(transferBtn());
    final accentIcon = tester.widget<Icon>(
      find.byIcon(AppIcons.transferInfinity),
    );
    expect(accentIcon.color, accentBtn.foregroundColor, reason: '#130-D 取色一致性');
    // ignore: avoid_print
    print(
      '[b25-B4] ink=${inkIcon.color} cast=${accentIcon.color} '
      'themeAccent=${accentOf(tester)} visuals=${visuals.miniSurface}',
    );
    // [D-073] 现状钉子：投屏态下流转按钮**确实会换色**，换到的是
    // `context.musicFlowColors.accent`（`foregroundColor: widget.isCasting ? accent : ink`），
    // 但换出来的这条 accent 跟 `Theme.of` 那条品牌红**不是同一个色**
    // （实测 灰 0.798/0.830/0.814 vs 红 0.926/0.255/0.255 —— 前者是 design palette
    // 里被 `ensureColorContrast(accent, background: nightCanvas)` 拉完对比度
    // 的那条）。也就是说「投屏换强调色」这段逻辑是真走了，用户看到的却是
    // 一条被拉过对比度的 accent，不是品牌红。将来若让两条路径共用同一个
    // accent（或把 foregroundColor 字面写死成 ink），这两条会红。
    //
    // #127-D：断言**不要**跨树去比「可读色」那种派生色（同一表达式在两棵树上
    // 落到不同颜色），也**不要**拿外层 palette / 主题 accent 当参照；
    // 只钉「投屏前后 fg 变了」「变的不是品牌红」这两个相对事实。
    expect(
      accentIcon.color,
      isNot(inkIcon.color),
      reason: '[D-073] 投屏态应当换色',
    );
    expect(
      accentIcon.color,
      isNot(accentOf(tester)),
      reason: '[D-073] 换出来的不是 Theme 那条品牌 accent',
    );
    expect(tester.takeException(), isNull);
  });

  // ==========================================================================
  // 分组 C —— 进度手势层（语义 ±10s / 拖拽 / 取消 / 竖向拖拽）
  // ==========================================================================

  testWidgets('C1 语义快进/后退 10 秒：_seekRelative 夹在 duration 内', (
    tester,
  ) async {
    // #112-D：这里**不复用同一棵树**推进位置。实测过两条路都不通 ——
    // ① `h.position = x` 然后重建 ProviderScope：`overrideWith` 的闭包虽然会重跑，
    //    但新 stub 的 `state` 仍读到缓存的旧值（诊断打到 `hpos=40 / stub=30`）；
    // ② 拿到 stub 实例走 `Notifier.state` setter：provider 缓存没被 refresh，
    //    `_seekRelative` 读到的 `widget.position` 还是起点。
    //    （两条都试过：`+10 +10 -10` 只会得到 `40 / 40 / 20` 这种「起点钉死」的序列。）
    // 唯一稳的做法是**每个起点开一棵新树**（新 harness ⇒ 新 ProviderScope ⇒
    // stub 从头 build），把「起点」当成用例参数传进去。
    /// 起手位置钉在 [start] 的新树上发一次语义动作，
    /// 返回下游 `seekEffectivePlayback` 实际收到的毫秒数。
    Future<int> seekAt(SemanticsAction action, Duration start) async {
      // 用 `harness()` 而不是裸 `MiniHarness()`：后者 build 时
      // `RecordingCastPeer` 的 override 闭包不一定被跑起来，取 `h.cast` 会
      // 直接 `LateInitializationError`（#123-D）。
      final h = harness()..position = start;
      await h.pump(tester, width: 1000);
      // #93-D / #100-D：每次现开语义树（树是刚建的新树）。
      final hd = tester.ensureSemantics();
      // #125-D：Riverpod 的 override 闭包是**懒执行**的，这里**不**再去显式读
      // provider（`tester.readProviderElement(...)` 在 `WidgetTester` 上根本
      // 不存在，编译期就报 "The method 'readProviderElement' isn't defined"）。
      // 闭包由 `MiniHarness.build` 里的 `_ForceProbe` 在 pump 时无条件跑掉，
      // 所以走到这一行时 `h.cast` 必定已初始化。
      // ignore: avoid_print
      print('[b25-C1] castReady=${h.cast.calls.length}');
      h.cast.calls.clear();
      semanticSeek(tester, action);
      await settle(tester);
      hd.dispose();
      expect(
        h.cast.calls,
        hasLength(1),
        reason: '$action@${start.inSeconds}s 应当下发且只下发一次 seek',
      );
      return int.parse(h.cast.calls.single.split('seek:')[1]);
    }

    // 起点 30s：+10 → 40s。
    expect(
      await seekAt(SemanticsAction.increase, const Duration(seconds: 30)),
      40000,
    );
    // 起点 40s：+10 → 50s。
    expect(
      await seekAt(SemanticsAction.increase, const Duration(seconds: 40)),
      50000,
    );
    // 起点 50s：-10 → 40s。
    expect(
      await seekAt(SemanticsAction.decrease, const Duration(seconds: 50)),
      40000,
    );

    // 后退越界：5s 起手两次 -10 都被 clamp 到 0（不抛、不为负）。
    expect(
      await seekAt(SemanticsAction.decrease, const Duration(seconds: 5)),
      0,
    );
    expect(
      await seekAt(SemanticsAction.decrease, const Duration(seconds: 5)),
      0,
    );

    // 快进越界：顶到 duration 上（179s / 超长 300s）再 +10，都钳回 180s。
    expect(
      await seekAt(SemanticsAction.increase, const Duration(seconds: 179)),
      180000,
    );
    expect(
      await seekAt(SemanticsAction.increase, const Duration(minutes: 5)),
      180000,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('C2 拖拽中出气泡，松手按拖拽比例 seek', (tester) async {
    // #113-D：必须带 `current` —— `songId` 为空时 `_scrubSongId` 也被锁成
    // null，`sameSong` 恒 false，松手静默吞掉 seek（calls 空但**不报错**）。
    // 这条同时是 [D-074] 现状钉子：没有当前歌曲时拖拽「看起来能用」却不下发。
    final h = harness(current: song);
    h.position = const Duration(seconds: 30);
    h.duration = const Duration(minutes: 3);
    await h.pump(tester, width: 1000);

    // #92-D：先泵过帧拿到真实 _scrubViewportWidth，再按现取矩形起手。
    final rect = tester.getRect(
      find.byKey(const Key('mini-player-scrubber')),
    );
    final g = await tester.startGesture(
      Offset(rect.left + rect.width / 2, rect.center.dy),
    );
    await g.moveBy(Offset(rect.width * 0.25, 0));
    await tester.pump(const Duration(milliseconds: 60));

    // 气泡只在拖拽中出现：拖到 50% × 180s = 90s ⇒ "1:30"。
    // #107-D：这里必须真拖到中点（起点是 50%，不是 25%）——
    // 原先只移了 25% 去断言 "1:30"，实际渲染的是 "0:45"。
    await g.moveTo(Offset(rect.left + rect.width * 0.5, rect.center.dy));
    await tester.pump(const Duration(milliseconds: 60));
    expect(find.text('1:30'), findsOneWidget);

    await g.moveTo(Offset(rect.left + rect.width * 0.75, rect.center.dy));
    await tester.pump(const Duration(milliseconds: 60));
    await g.up();
    await settle(tester);

    // 75% × 180s = 135s ⇒ 135000ms。
    expect(h.cast.calls, <String>['seek:135000']);
    expect(bubbleText(), findsNothing, reason: '松手后气泡撤回');
    expect(tester.takeException(), isNull);
  });

  testWidgets('C3 duration 为 0 时拖拽不起会话（守卫早退）', (tester) async {
    final h = harness();
    h.position = Duration.zero;
    h.duration = Duration.zero;
    await h.pump(tester, width: 1000);

    final rect = tester.getRect(
      find.byKey(const Key('mini-player-scrubber')),
    );
    final g = await tester.startGesture(
      Offset(rect.left + rect.width * 0.5, rect.center.dy),
    );
    await g.moveBy(Offset(rect.width * 0.5, 0));
    await tester.pump(const Duration(milliseconds: 60));
    await g.up();
    await settle(tester);

    expect(h.cast.calls, isEmpty);
    expect(bubbleText(), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('C4 拖拽被指针取消：气泡撤回且不下发 seek', (tester) async {
    final h = harness();
    h.position = const Duration(seconds: 30);
    h.duration = const Duration(minutes: 3);
    await h.pump(tester, width: 1000);

    final rect = tester.getRect(
      find.byKey(const Key('mini-player-scrubber')),
    );
    final g = await tester.startGesture(
      Offset(rect.left + rect.width * 0.5, rect.center.dy),
    );
    await g.moveBy(Offset(rect.width * 0.4, 0));
    await tester.pump(const Duration(milliseconds: 60));
    expect(bubbleText(), findsOneWidget, reason: '先起个气泡');

    // #91-D / #101-D：取消只能靠 `TestGesture.cancel()`（派发 PointerCancelEvent
    // → `onHorizontalDragCancel`）；`up()` 走的是 End，会把比例 seek 下去。
    await g.cancel();
    await settle(tester);

    expect(h.cast.calls, isEmpty, reason: '取消不该 seek');
    expect(bubbleText(), findsNothing, reason: '气泡要撤回');
    // #101-D：`TestGesture.cancel()` 之后指针已经 not-down，再调 `up()` 会在
    // test_pointer.dart:586 的 `assert(_pointer._isDown)` 上炸；取消用例到此为止。
    expect(tester.takeException(), isNull);
  });

  /// #108-D：`_handleVerticalDragEnd` 的唯一出口是 `widget.onOpenPlayer`。
  /// 真 `MiniPlayer` 那条会把 `FullPlayerPage` 压进导航器，而压页要过一整套
  /// provider（路由页里再 watch 一堆 provider，桩盖不全），断言会被压页污染。
  /// 直接拿 `@visibleForTesting` 的 `MiniPlayerView` 打：onOpenPlayer 换成记录器，
  /// 阈值逻辑（36px / 速度）与真机跑的是同一段代码。
  Future<void> dragVertical(
    WidgetTester tester, {
    required double dy,
    required double speed,
    required List<String> opened,
    double width = 360,
  }) async {
    final h = MiniHarness();
    await h.pump(
      tester,
      width: width,
      height: 2600,
      home: MiniPlayerView(
        playerState: h.state,
        onOpenPlayer: () => opened.add('open'),
        onTogglePlayPause: () async {},
        onSeek: (Duration _) async {},
        onSwitchPlayer: () {},
      ),
    );

    // #118-D：起手点/落点必须落在 `Key('mini-player-surface')` 这个
    // `GestureDetector(onVerticalDrag*)` 上 —— 拿 `MiniPlayerView` 的中心起手，
    // 底部 20dp 的横拖手势区（`mini-player-scrubber`）会抢答，竖向会话起不来。
    final surface = find.byKey(const Key('mini-player-surface'));
    final center = tester.getCenter(surface);
    // ignore: avoid_print
    print(
      '[b25-C5] surfaceHits=${surface.evaluate().length} center=$center '
      'vdragGD=${find.byWidgetPredicate((Widget w) => w is GestureDetector && w.onVerticalDragEnd != null).evaluate().length}',
    );
    // #119-D：竖向手势必须用 `fling` 而不是 `moveBy` —— 实测 moveBy 两段
    // （共 60px）发过去的 PointerMoveEvent 没能把 vertical drag 送进 arena：
    // center 正确、控件在树里（vdragGD=1），`onVerticalDragEnd` 就是不落地，
    // `opened` 恒空 ⇒ C6/C7 的「不触发」其实是**假绿**。
    // #120-D：`tester.fling` 的签名是 **(finder, offset, speed)** —— 第一个参数是
    // **finder**（不是坐标），位移由第二个 `offset` 给，速度第三个。
    // fling 一次把「位移」和「速度」两个出口都喂足，`_handleVerticalDragEnd`
    // 的 `velocity < -600 || _verticalDragDy <= -36` 才能分别打（见 C5/C6/C7）。
    await tester.fling(surface, Offset(0, dy), speed);
    await settle(tester, frames: 8);
    // ignore: avoid_print
    print('[b25-C5] dy=$dy speed=$speed opened=$opened');
    return;
  }

  testWidgets('C5 竖向上拖过 36px 阈值触发 onOpenPlayer', (tester) async {
    final opened = <String>[];
    await dragVertical(tester, dy: -60, speed: 700, opened: opened);
    expect(opened, <String>['open']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('C6 向下拖回不触发 onOpenPlayer', (tester) async {
    final opened = <String>[];
    await dragVertical(tester, dy: 60, speed: 700, opened: opened);
    expect(opened, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('C7 小位移上拖（20px < 36px 阈值）不触发 onOpenPlayer', (
    tester,
  ) async {
    final opened = <String>[];
    await dragVertical(tester, dy: -20, speed: 200, opened: opened);
    expect(opened, isEmpty);
    expect(tester.takeException(), isNull);
  });

  // ==========================================================================
  // 分组 D —— 渲染长尾（歌词行 / 副标题档位 / 播放模式四档 / 气泡对齐 / 空态）
  // ==========================================================================

  testWidgets('D1 lyricLine 非空时以高亮色渲染一行歌词', (tester) async {
    final h = MiniHarness(
      state: harness(current: song).state,
      lyricLine: ' 副歌第一句 ',
    );
    await h.pump(tester, width: 360);

    final lyric = tester.widget<Text>(find.text('副歌第一句'));
    expect(lyric.style?.color, isNotNull);
    expect(lyric.style?.fontWeight, FontWeight.w500);
    // 歌词行与歌名是两行不同的文本节点，专辑名不出场。
    expect(find.textContaining('Current Song'), findsOneWidget);
    expect(find.textContaining('Current Album'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('D2 大字号档隐藏副标题，标题退化成纯 Text（无 Text.rich）', (
    tester,
  ) async {
    final h = harness(current: song);
    await h.pump(tester, width: 360);

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
        theme: AppTheme.dark(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: const TextScaler.linear(1.8),
          ),
          child: child!,
        ),
        home: h.build(),
      ),
    );
    await settle(tester);

    // textScale 1.8 > 1.4 ⇒ showSubtitle=false ⇒ 歌手既不进标题行也不出副标题行。
    expect(find.byWidgetPredicate((Widget w) => w is Text && (w.data ?? '').contains('Current Artist')), findsNothing);
    final title = tester.widget<Text>(find.text('Current Song'));
    expect(title.textSpan, isNull, reason: 'showArtist=false 走纯 Text 分支');
    expect(title.overflow, TextOverflow.ellipsis);
    expect(tester.takeException(), isNull);
  });

  testWidgets('D3 没有歌手时副标题回退专辑名', (tester) async {
    final h = harness(current: Song(id: 's2', title: 'No Artist', album: 'Album Flow'));
    await h.pump(tester, width: 360);

    final title = tester.widget<Text>(find.textContaining('No Artist'));
    expect(title.textSpan, isNotNull, reason: 'showSubtitle=true 走 Text.rich');
    expect(
      ((title.textSpan as TextSpan).children!.last as TextSpan).text,
      ' - Album Flow',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('D4 _PlayModeButton 四档 + 服务端意外串兜底', (tester) async {
    final h = harness();
    final cases = <String, IconData>{
      'order': AppIcons.orderPlayback,
      'one': AppIcons.repeatOne,
      'shuffle': AppIcons.shuffle,
      'all': AppIcons.repeat,
      'server-side-round': AppIcons.repeat,
    };
    // 只量图标，模式名对应的语义文案在 D5 里逐档断言。
    // #110-D：必须显式顶 `debugDefaultTargetPlatformOverride = windows`，
    // 否则是手机两键档，树上压根没有 `_PlayModeButton`（'order' 那档会 0 命中）。
    for (final entry in cases.entries) {
      await pumpDesktopHome(
        tester,
        Align(
          alignment: Alignment.bottomCenter,
          child: MiniPlayerView(
            playerState: h.state,
            onOpenPlayer: () {},
            onTogglePlayPause: () async {},
            onSeek: (_) async {},
            onSwitchPlayer: () {},
            playMode: entry.key,
            currentPlayerName: '本机',
          ),
        ),
      );
      expect(find.byIcon(entry.value), findsOneWidget, reason: entry.key);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('D5 播放模式四档文案 + one/shuffle 才高亮', (tester) async {
    final cases = <String, String>{
      'order': '顺序播放，点击切换到单曲循环',
      'all': '列表循环，点击切换到随机播放',
      'one': '单曲循环，点击切换到列表循环',
      'shuffle': '随机播放，点击切换到顺序播放',
    };
    Finder modeButtonOf(String label) => find.byWidgetPredicate(
      (Widget w) => w is MusicFlowIconButton && w.label == label,
    );

    // #115-D：这里**不走** `MiniPlayer.build` 的 provider 路由。理由不是懒 ——
    // `playerProvider` 被 `overrideWith` 之后闭包会把 notifier 缓存住，换 harness
    // 重建 ProviderScope 实测仍读回上一份 `playbackMode`（`all` 档渲染出的还是
    // order 的文案）。`_PlayModeButton` 本身是 `@visibleForTesting` 的纯控件，
    // 直接喂 `playMode` 才是把**这一个控件**的四档逻辑打穿的正确入口
    // （provider 路由那条由 A1/A2/A3 三态用例覆盖）。
    for (final entry in cases.entries) {
      await pumpDesktopHome(
        tester,
        Align(
          alignment: Alignment.bottomCenter,
          child: MiniPlayerView(
            playerState: harness(current: song).state,
            onOpenPlayer: () {},
            onTogglePlayPause: () async {},
            onSeek: (Duration _) async {},
            onSwitchPlayer: () {},
            playMode: entry.key,
          ),
        ),
      );
      expect(find.bySemanticsLabel(entry.value), findsOneWidget, reason: entry.key);
      // 白名单只有 one/shuffle 才高亮（mode == 'one' || mode == 'shuffle'），
      // order / all 以及任何未知值都**不该**高亮。
      final inWhitelist = entry.key == 'one' || entry.key == 'shuffle';
      expect(
        tester.widget<MusicFlowIconButton>(modeButtonOf(entry.value)).selected,
        inWhitelist,
        reason: '${entry.key} 白名单命中应为 $inWhitelist',
      );
    }

    // 未知值兜底：既给 repeat 图标，也落到 player_mode_list 文案，且不高亮。
    await pumpDesktopHome(
      tester,
      Align(
        alignment: Alignment.bottomCenter,
        child: MiniPlayerView(
          playerState: harness(current: song).state,
          onOpenPlayer: () {},
          onTogglePlayPause: () async {},
          onSeek: (Duration _) async {},
          onSwitchPlayer: () {},
          playMode: 'server-side-round',
        ),
      ),
    );
    expect(find.byIcon(AppIcons.repeat), findsOneWidget, reason: '未知值走 repeat');
    expect(modeButtonOf('列表循环，点击切换到随机播放'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('D6 拖拽气泡的对齐随进度左右移动', (tester) async {
    final h = harness(current: song);
    h.position = const Duration(seconds: 30);
    h.duration = const Duration(minutes: 3);
    await h.pump(tester, width: 1000);

    final rect = tester.getRect(
      find.byKey(const Key('mini-player-scrubber')),
    );
    // #116-D：起手 0.5、移 +0.4 ⇒ 总 dx = 0.9（原写法 0.9 起手再移 0.9，
    // 总 dx 1.71 被 `_progressFromDx` 的 clamp(0,1) 吃掉 ⇒ 气泡永远顶到 1.0）。
    final g = await tester.startGesture(
      Offset(rect.left + rect.width * 0.5, rect.center.dy),
    );
    await g.moveBy(Offset(rect.width * 0.4, 0));
    await tester.pump(const Duration(milliseconds: 60));

    // #111-D / #116-D：`find.ancestor(..., matching: find.byType(Align))` 返回的是
    // **整条祖先链**上的 Align（Scaffold body 那个 Align、气泡自己那个 Align …），
    // 实测 `Bad state: Too many elements`。气泡那层的独门特征是
    // 「`Align.child is MusicFlowSurface`」（_MiniPlayerScrubBubble:148），
    // 用 `byWidgetPredicate` 直接点名，不再走 ancestor。
    final bubble = tester.widget<Align>(find.byWidgetPredicate(
      (Widget w) => w is Align && w.child is MusicFlowSurface,
    ));
    // progress 0.9 ⇒ Alignment(0.9*2-1, 0) = Alignment(0.8, 0)。
    final bubbleAlignment = bubble.alignment as Alignment;
    expect(bubbleAlignment.x, closeTo(0.8, 0.001));
    expect(bubbleAlignment.y, 0);
    // 180 × 0.9 = 162s ⇒ "2:42"。
    expect(find.text('2:42'), findsOneWidget);

    await g.up();
    await settle(tester);
    expect(tester.takeException(), isNull);
  });

  testWidgets('D7 空态轨道：无 currentSong 时出占位圆与提示文案', (tester) async {
    final h = harness(current: null);
    await h.pump(tester, width: 360);

    // _MiniPlayerEmptyTrack：占位圆 + 「未在播放」+ 「选择一首歌曲开始播放」。
    expect(find.text('未在播放'), findsOneWidget);
    expect(find.text('选择一首歌曲开始播放'), findsOneWidget);
    expect(find.byIcon(AppIcons.music), findsOneWidget);
    // 没有封面 ⇒ 也就没有封面外圈进度环。
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.byType(CoverArtImage), findsNothing);
    // track 命中区还在，点一下照样能唤出全屏页。
    expect(find.byKey(const Key('mini-player-track')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
