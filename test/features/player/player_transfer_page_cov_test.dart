import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/data/models/peer.dart';
import 'package:musicflow_client/features/player/pages/player_transfer_page.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:musicflow_client/providers/cast/cast_peer_provider.dart';

/// 流转页 widget 补测（批处理补测）：只打「页面层」逻辑 ——
/// 列表装配/过滤、单击切遥控、群组管理模式、回收站销毁。
///
/// 铁律：本文件只测 `player_transfer_page.dart`，不碰产品代码；
/// 真 controller（`CastPeerController`）整条网络/轮询/心跳链路都被换成桩，
/// 页面里所有 `ref.read(...)....` 调用都落到这个桩上，调用序列可断言。

const String kSelfName = '本机';
const String kDlnaName = '主卧';
const String kGroupName = '客厅组';
const String kOfflineName = '离线音箱';
const String kWebName = 'Web播放器';

const PeerInfo kSelf = PeerInfo(
  peerId: 'local:u1',
  name: kSelfName,
  kind: 'local',
  available: true,
  self: true,
  platform: 'windows',
);
const PeerInfo kDlna = PeerInfo(
  peerId: 'dlna:30',
  name: kDlnaName,
  kind: 'dlna',
  available: true,
);
const PeerInfo kGroup = PeerInfo(
  peerId: 'group:g1',
  name: kGroupName,
  kind: 'group',
  available: true,
);

/// AirPlay 成员：服务端成员命名空间与 peerId 同形（`airplay:<deviceId>`）。
/// 群组只收 airplay / sendspin（DLNA 被服务端拒收）⇒ 勾选圈只挂这两种设备。
const PeerInfo kAir = PeerInfo(
  peerId: 'airplay:aa01',
  name: '客厅音响',
  kind: 'airplay',
  available: true,
);

/// sendspin 成员：服务端成员命名空间与 peerId 同形（`sendspin:<clientId>`）。
const PeerInfo kSpin = PeerInfo(
  peerId: 'sendspin:sp1',
  name: '掌柜音箱',
  kind: 'sendspin',
  available: true,
);

const PeerInfo kOffline = PeerInfo(
  peerId: 'dlna:99',
  name: kOfflineName,
  kind: 'dlna',
  available: false,
);
const PeerInfo kWeb = PeerInfo(
  peerId: 'airplay:7',
  name: kWebName,
  kind: 'airplay',
  available: true,
  platform: 'web',
);

/// 所有产品侧 controller 调用的落地桩：记调用序列 + 可预设返回。
class FakeCastPeer extends CastPeerController {
  FakeCastPeer();

  final List<String> calls = <String>[];

  List<PeerInfo> loaded = const <PeerInfo>[];
  Future<void>? loadGate;
  bool switchToOk = true;
  List<dynamic>? groups;

  /// 给 null = 模拟「操作失败」（真 controller 在服务端报错时返回 null）。
  List<String>? membershipIds;

  /// 置 true 时 setGroupMembership 直接返 null（模拟服务端报错）。
  bool membershipFailure = false;

  /// 预置态。**不能**在 `overrideWith` 工厂里写 `c.state = ...`：那一刻元素尚未
  /// attach，`NotifierBase._element` 还是未初始化的 late 字段，赋值会抛
  /// LateInitializationError（`Notifier` 语义，与 `StateNotifier` 不同）。
  /// 种态统一从 `build()` 的返回值出。
  CastPeerState? seed;

  @override
  CastPeerState build() {
    super.build();
    return seed ?? const CastPeerState();
  }

  @override
  Future<List<PeerInfo>> loadPeers() async {
    calls.add('loadPeers');
    final g = loadGate;
    if (g != null) await g;
    return loaded;
  }

  @override
  Future<bool> switchTo(PeerInfo peer) async {
    calls.add('switchTo:${peer.peerId}');
    return switchToOk;
  }

  @override
  Future<void> backToLocal({bool resumeLocal = false}) async {
    calls.add('backToLocal:$resumeLocal');
  }

  @override
  Future<bool> destroyPeer(PeerInfo peer) async {
    calls.add('destroyPeer:${peer.peerId}');
    return true;
  }

  @override
  Future<List<dynamic>?> fetchGroups() async {
    calls.add('fetchGroups');
    return groups;
  }

  @override
  Future<List<String>?> setGroupMembership(
    String groupId,
    String memberKey, {
    required bool join,
  }) async {
    calls.add('setGroupMembership:$groupId:$memberKey:$join');
    if (membershipFailure) return null;
    return membershipIds ?? <String>[memberKey];
  }

  /// 页面只 watch 这个 stream provider 拿「此刻在播」，测试里不需要它出数。
  @override
  Future<PeerNowPlaying?> fetchPeerNowPlaying(String peerId) async => null;
}

/// 页面里当前遥控目标的圆带 `_ActivePulse`（Ticker 呼吸动画），
/// 测试环境下它每帧都请求新帧 —— `pumpAndSettle` 永远等不到「静下来」
/// （实测直接 timeout）。所以本文件统一用**固定帧推进**代替 pumpAndSettle。
Future<void> settle(WidgetTester tester, {int frames = 5}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}

FakeCastPeer? ctrl;
final List<String> transfers = <String>[];

/// 起页面。 fetches 由 [loaded] 控制，[activePeer] 预设当前遥控目标。
Future<void> pumpPage(
  WidgetTester tester, {
  List<PeerInfo> loaded = const <PeerInfo>[],
  Future<void>? loadGate,
  PeerInfo? activePeer,
  List<dynamic>? groups,
  List<String>? membershipIds,
  bool viaOpen = false,
}) async {
  ctrl = null;
  transfers.clear();
  Future<bool> transfer(PeerInfo from, PeerInfo to) async {
    transfers.add('${from.peerId}->${to.peerId}');
    return true;
  }

  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        castPeerControllerProvider.overrideWith(() {
          final c = FakeCastPeer()
            ..loaded = loaded
            ..loadGate = loadGate
            ..groups = groups
            ..membershipIds = membershipIds
            ..seed = activePeer == null
                ? null
                : CastPeerState(activePeer: activePeer);
          ctrl = c;
          return c;
        }),
        // 页面只 watch 这个 stream 拿「在播」，测试里给空流即可。
        peerNowPlayingProvider.overrideWith(
          (Ref ref, String peerId) => const Stream<PeerNowPlaying?>.empty(),
        ),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
        theme: AppTheme.light(),
        // viaOpen = 走产品提供的静态入口 `PlayerTransferPage.open`（根导航器
        // fullscreenDialog 路由），用于覆盖该包装方法本身；其余用例直接把页面
        // 当 home，省掉一次路由跳转。
        home: viaOpen
            ? Builder(
                builder: (BuildContext context) => TextButton(
                  onPressed: () => unawaited(
                    PlayerTransferPage.open(context, onTransfer: transfer),
                  ),
                  child: const Text('打开流转页'),
                ),
              )
            : PlayerTransferPage(onTransfer: transfer),
      ),
    ),
  );
}

/// 某个播放端**整行**（落点）的 GestureDetector 句柄。
///
/// 页面里 `_RingNode.build` 的注释写得很清楚：落点 DragTarget 铺在**整行**
/// （拖到名称区也能接住，手势容错更大），所以落点找整行的 GestureDetector。
Finder ringGesture(String name) => find
    .ancestor(of: find.text(name), matching: find.byType(GestureDetector))
    .at(0);

/// 松手点落在哪个播放端的**整行**上（与页面 `_peerAt` 同一口径：按整行矩形）。
/// 找不到返回 null —— 说明落点落在行间空隙 / 视口外。
String? peerNameAtPoint(
  WidgetTester tester,
  Offset point,
  Iterable<String> names,
) {
  for (final name in names) {
    final finder = ringGesture(name);
    if (finder.evaluate().isEmpty) continue;
    if (tester.getRect(finder).contains(point)) return name;
  }
  return null;
}

/// 某个播放端**封面圆**（拖拽源）的句柄。
///
/// 两个坑：
/// 1. 拖拽源只包封面圆 —— `Draggable` 挂在 `circleWrapper` 上，而「播放器名/歌名」
///    那个 Text 与圆是**兄弟**关系，不是它的后代（`find.ancestor(of: find.text(...))`
///    按 Draggable 去查永远落空，实测报 `Index out of range`）；
/// 2. 从名称区按下也起不了拖（源码原话「只有封面圆可拖起」）。
/// 所以直接用 `Draggable.data` 反查 —— `Draggable<PeerInfo>.data.peerId` 就是唯一的锚点。
Finder coverDragHandle(String peerId) => find.byWidgetPredicate(
  (Widget w) => w is Draggable<PeerInfo> && w.data?.peerId == peerId,
);

/// 拖拽手势：QA 复核 batch20 缺口时验证过的**唯一可行姿势**。
///
/// 只 pump 起止两点时 DragTarget 收不到数据 —— `tester.drag()` /
/// `dragFrom()` 三种姿势实测全部落空（`destroyPeer` 一次都没调），
/// 必须按起手 / 按下 / 经过落点 / 落在落点 分四段 pump，最后再补一段时长。
Future<void> dragGesture(
  WidgetTester tester, {
  required Finder src,
  required Offset dstCenter,
}) async {
  final start = tester.getCenter(src);
  // 四段泵帧缺一不可：起手(startGesture) → 跨过 touch slop(moveBy 50,18) →
  // 扫到落点(moveTo) → up() 提交。直接 moveTo 落点或只 pump 起止两点时，
  // DragTarget 的 onWillAccept 收不到候选，onAccept 永不触发（实测三种姿势全落空）。
  final g = await tester.startGesture(start);
  await g.moveBy(const Offset(50, 18));
  await tester.pump(const Duration(milliseconds: 30));
  await g.moveTo(dstCenter);
  await tester.pump(const Duration(milliseconds: 30));
  await g.up();
  await tester.pump(const Duration(milliseconds: 120));
  await settle(tester);
}

/// 提示文案不进 Findle 字面量（中间可能夹富文本），直接找 Text 节点按内容筛。
Finder hintFinder(String needle) => find.byWidgetPredicate(
  (Widget w) => w is Text && (w.data ?? '').contains(needle),
);

/// 造 N 个远端播放端（全部 DLNA，名称 P01..P12），拼上本机：默认 800×600
/// 测试窗口下 13 个圆排成 7 行 —— 远超滚动视口高度，页面必定可滚动。
List<PeerInfo> manyPeers(int count) => <PeerInfo>[
  kSelf,
  for (var i = 1; i <= count; i++)
    PeerInfo(
      peerId: 'dlna:${i.toString().padLeft(2, '0')}',
      name: 'P${i.toString().padLeft(2, '0')}',
      kind: 'dlna',
      available: true,
    ),
];

/// 页面里唯一的滚动视口控制器（C1 接入的 `ScrollController`）。
ScrollController pageScroll(WidgetTester tester) => tester
    .widget<SingleChildScrollView>(find.byType(SingleChildScrollView))
    .controller!;

/// 把指针移到 [target] 并推进 [ticks] 拍（16ms/拍，与页面自动滚动定时器同频）。
Future<void> holdInHotzone(
  WidgetTester tester,
  TestGesture gesture,
  Offset target, {
  int ticks = 10,
}) async {
  await gesture.moveTo(target);
  for (var i = 0; i < ticks; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

void main() {
  testWidgets('首帧还没拿到播放端列表时显示加载圈', (WidgetTester tester) async {
    await pumpPage(
      tester,
      loadGate: Future<void>.delayed(const Duration(milliseconds: 60)),
    );
    // 加载态：列表为 null，正文区域是转圈。
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    // 过掉迟到窗口，列表落回（这条只为了让 next 例不受影响）。
    await tester.pump(const Duration(milliseconds: 120));
    await settle(tester);
  });

  testWidgets('服务端一条播放端都不给时落到空态文案', (WidgetTester tester) async {
    await pumpPage(tester, loaded: const <PeerInfo>[]);
    await settle(tester);
    expect(find.text('当前没有其它可用的播放器'), findsOneWidget);
    expect(find.text(kSelfName), findsNothing, reason: '没数据就没有本机圆');
  });

  testWidgets('只回本机那一行时不是空态（本机自己占一格）', (WidgetTester tester) async {
    await pumpPage(tester, loaded: <PeerInfo>[kSelf]);
    await settle(tester);
    // 与例 2 区分开：`_load` 会把本机行塞回列表首位 → 走列表分支。
    expect(find.text(kSelfName), findsOneWidget);
    expect(find.text('当前没有其它可用的播放器'), findsNothing, reason: '有本机行就不该显示空态');
  });

  testWidgets('列表装配：本机排第一，离线端与 Web 端不出', (WidgetTester tester) async {
    await pumpPage(
      tester,
      loaded: <PeerInfo>[kOffline, kWeb, kDlna, kSelf, kGroup],
    );
    await settle(tester);
    expect(find.text(kSelfName), findsOneWidget);
    expect(find.text(kDlnaName), findsOneWidget);
    expect(find.text(kGroupName), findsOneWidget);
    // [B20-P1] 现状钉子：离线端和 Web 端被 `available` / `platform != 'web'`
    // 两道过滤挡在页面外（拖到已下线的端上才会失败，所以先不展示）。
    // 将来若放开「离线端也列出来（灰显）」，这两条会红。
    expect(
      find.text(kOfflineName),
      findsNothing,
      reason: '[B20-P1] 离线端不出列表（现状钉子）',
    );
    expect(
      find.text(kWebName),
      findsNothing,
      reason: '[B20-P1] Web 端不出列表（现状钉子）',
    );

    // 顺序（QA 复核意见 4）：例 4 原来只断言「有/没有」，谁在前谁在后没人管。
    // 这里按 widget 树的深度优先顺序取三个名字，钉住 `_load` 的装配次序。
    final order = find
        .byWidgetPredicate(
          (Widget w) =>
              w is Text &&
              (w.data == kSelfName ||
                  w.data == kDlnaName ||
                  w.data == kGroupName),
        )
        .evaluate()
        .map((Element e) => (e.widget as Text).data)
        .toList(growable: false);
    // 实测顺序：本机 → 群组 → 设备（comparePeerDisplayOrder 里群组优先于普通设备）。
    expect(order, <String>[
      kSelfName,
      kGroupName,
      kDlnaName,
    ], reason: '本机强制置首，其余按 comparePeerDisplayOrder');
  });

  testWidgets('点在线远端 = 切遥控目标，成功后自动关页', (WidgetTester tester) async {
    await pumpPage(
      tester,
      loaded: <PeerInfo>[kSelf, kDlna],
      activePeer: kSelf, // 当前遥控本机 → 主卧不是当前目标
    );
    await settle(tester);
    await tester.tap(find.text(kDlnaName));
    await settle(tester);
    expect(
      ctrl!.calls,
      contains('switchTo:dlna:30'),
      reason: '点远端必须走 switchTo',
    );
    expect(ctrl!.calls, isNot(contains('backToLocal:true')));
  });

  testWidgets('点当前已遥控的远端 = 什么也不做，只关页（钉子）', (WidgetTester tester) async {
    await pumpPage(tester, loaded: <PeerInfo>[kSelf, kDlna], activePeer: kDlna);
    await settle(tester);
    await tester.tap(find.text(kDlnaName));
    await settle(tester);
    // [B20-P2] 现状钉子：命中「已经在遥控它」的早退分支（只关页，不下发任何命令）。
    // 将来若改成「再点一次取消遥控」，这条会红。
    expect(
      ctrl!.calls,
      isNot(contains('switchTo:dlna:30')),
      reason: '[B20-P2] 已是当前目标时不该再 switchTo（现状钉子）',
    );
    expect(ctrl!.calls, isNot(contains('backToLocal')));
  });

  testWidgets('点本机 = 切回本机并续播快照', (WidgetTester tester) async {
    await pumpPage(
      tester,
      loaded: <PeerInfo>[kSelf, kDlna],
      activePeer: kDlna, // 正在遥控主卧 → 点本机的「回路」才成立
    );
    await settle(tester);
    await tester.tap(find.text(kSelfName));
    await settle(tester);
    expect(
      ctrl!.calls,
      contains('backToLocal:true'),
      reason: '点本机要 backToLocal(resumeLocal: true)',
    );
    expect(ctrl!.calls, isNot(contains('switchTo:dlna:30')));
  });

  testWidgets('点群组：静默切遥控 + 拉成员配置 + 进入管理模式', (WidgetTester tester) async {
    await pumpPage(
      tester,
      loaded: <PeerInfo>[kSelf, kGroup, kDlna],
      activePeer: kSelf,
      groups: <dynamic>[
        <String, dynamic>{
          'id': 'g1',
          'name': kGroupName,
          'memberIds': <dynamic>['dlna:30'],
        },
      ],
    );
    await settle(tester);
    await tester.tap(find.text(kGroupName));
    await settle(tester);
    expect(ctrl!.calls, contains('switchTo:group:g1'), reason: '选中群组同时把遥控切过去');
    expect(ctrl!.calls, contains('fetchGroups'), reason: '要拉成员配置');
    expect(hintFinder('已选中群组'), findsOneWidget, reason: '选中后标题下方出现进度提示');
    // [B20-P4] 现状钉子：主卧在 `memberIds` 里 → 走「已是成员」档，显示退出圈。
    // 同时印证成员键是 `_memberKeyFor()` 的产出**裸 id**（`30`，DLNA 剥掉
    // `dlna:` 前缀），不是 `dlna:30` —— 服务端 DLNA 成员命名空间就是裸 id。
    // 将来若改成「先给加入圈」或改成传完整 peerId，这两条会红。
    expect(
      find.bySemanticsLabel('退出该群组'),
      findsOneWidget,
      reason: '[B20-P4] 已是成员显示退出圈（现状钉子）',
    );
    expect(
      find.bySemanticsLabel('加入该群组'),
      findsNothing,
      reason: '[B20-P4] 成员态不显示加入圈（现状钉子）',
    );
  });

  testWidgets('点群组但服务端查不到这个 gid = 不进管理模式（钉子）', (WidgetTester tester) async {
    await pumpPage(
      tester,
      loaded: <PeerInfo>[kSelf, kGroup, kDlna],
      activePeer: kSelf,
      groups: <dynamic>[
        <String, dynamic>{
          'id': 'other',
          'name': '别的组',
          'memberIds': <dynamic>[],
        },
      ],
    );
    await settle(tester);
    await tester.tap(find.text(kGroupName));
    await settle(tester);
    // [B20-P3] 现状钉子：查不到 gid 时只弹错提示，页面**不进**管理模式
    // （`_selectedGroupId` 保持 null，+/− 按钮也不出现）。
    // 将来若改成「查不到也按空成员进管理模式」，这两条会红。
    expect(
      hintFinder('已选中群组'),
      findsNothing,
      reason: '[B20-P3] 没命中 gid 不进管理模式（现状钉子）',
    );
    expect(
      find.bySemanticsLabel('加入该群组'),
      findsNothing,
      reason: '[B20-P3] 没有成员按钮（现状钉子）',
    );
  });

  testWidgets('点成员圈 = 加入 / 退出选中的群组', (WidgetTester tester) async {
    await pumpPage(
      tester,
      loaded: <PeerInfo>[kSelf, kGroup, kDlna],
      activePeer: kSelf,
      groups: <dynamic>[
        <String, dynamic>{
          'id': 'g1',
          'name': kGroupName,
          'memberIds': <dynamic>['dlna:30'],
        },
      ],
    );
    await settle(tester);
    await tester.tap(find.text(kGroupName));
    await settle(tester);
    // 主卧已是成员 → 显示「退出该群组」。
    expect(find.bySemanticsLabel('退出该群组'), findsOneWidget);
    await tester.tap(find.bySemanticsLabel('退出该群组'));
    await settle(tester);
    // 成员键 = 服务端口径的**完整 peerId**（`dlna:30`）。旧实现剥掉 `dlna:`
    // 前缀发裸 id `30`，与 memberIds 里存的字符串对不上 ⇒ 服务端 no-op ⇒ 删不掉。
    expect(
      ctrl!.calls,
      contains('setGroupMembership:g1:dlna:30:false'),
      reason: '退组带 join=false，成员键回传组里那条字符串',
    );
  });

  testWidgets('还没选群组时设备圆下方不出现成员圈（早退方向）', (WidgetTester tester) async {
    await pumpPage(
      tester,
      loaded: <PeerInfo>[kSelf, kGroup, kDlna],
      activePeer: kSelf,
      groups: <dynamic>[
        <String, dynamic>{
          'id': 'g1',
          'name': kGroupName,
          'memberIds': <dynamic>['dlna:30'],
        },
      ],
    );
    await settle(tester);
    // 没进管理模式就不要把 +/− 挂出来（点了也没用，`_groupBusy`/`_selectedGroupId` 早退）。
    expect(
      find.bySemanticsLabel('退出该群组'),
      findsNothing,
      reason: '未选群组时不显示成员圈（早退方向）',
    );
    expect(find.bySemanticsLabel('加入该群组'), findsNothing);
  });

  testWidgets('点 airplay 成员的加入圈 = setGroupMembership(..., join: true)', (
    WidgetTester tester,
  ) async {
    await pumpPage(
      tester,
      loaded: <PeerInfo>[kSelf, kGroup, kAir],
      activePeer: kSelf,
      groups: <dynamic>[
        // 客厅音响**不在** memberIds 里 → 走「加入」分支（join=true）。
        <String, dynamic>{
          'id': 'g1',
          'name': kGroupName,
          'memberIds': <dynamic>['airplay:77'],
        },
      ],
    );
    await settle(tester);
    await tester.tap(find.text(kGroupName));
    await settle(tester);
    expect(
      find.bySemanticsLabel('加入该群组'),
      findsOneWidget,
      reason: '组里没有这台 airplay → 显示加入圈（而不是退出圈）',
    );
    expect(find.bySemanticsLabel('退出该群组'), findsNothing);

    await tester.tap(find.bySemanticsLabel('加入该群组'));
    await settle(tester);
    // airplay 的成员键就是完整 peerId（服务端 airplay:<deviceId> 命名空间）。
    expect(
      ctrl!.calls,
      contains('setGroupMembership:g1:airplay:aa01:true'),
      reason: '入组带 join=true，成员键用服务端命名空间',
    );
  });

  testWidgets('DLNA 不能进组：管理模式下列不出现任何勾选圈', (WidgetTester tester) async {
    // 2026-10-24 用户确认的契约：只有 airplay / sendspin 能加入群组。
    // DLNA 即使组是空的也不给加入圈 —— 服务端 splitMemberId 会 400 拒收，
    // 给了圈只会让用户看到一次「群组操作失败」。
    await pumpPage(
      tester,
      loaded: <PeerInfo>[kSelf, kGroup, kDlna],
      activePeer: kSelf,
      groups: <dynamic>[
        <String, dynamic>{
          'id': 'g1',
          'name': kGroupName,
          'memberIds': <dynamic>[],
        },
      ],
    );
    await settle(tester);
    await tester.tap(find.text(kGroupName));
    await settle(tester);
    expect(
      hintFinder('已选中群组'),
      findsOneWidget,
      reason: '确认已进入管理模式（否则「没有圈」是因为没进模式，测不到点子上）',
    );
    expect(
      find.bySemanticsLabel('加入该群组'),
      findsNothing,
      reason: 'DLNA 不渲染加入圈',
    );
    expect(
      find.bySemanticsLabel('退出该群组'),
      findsNothing,
      reason: 'DLNA 不渲染退出圈',
    );
  });

  testWidgets('sendspin 成员的成员键原样走 peerId（不与裸 id 混用）', (
    WidgetTester tester,
  ) async {
    await pumpPage(
      tester,
      loaded: <PeerInfo>[kSelf, kGroup, kSpin],
      activePeer: kSelf,
      groups: <dynamic>[
        <String, dynamic>{
          'id': 'g1',
          'name': kGroupName,
          'memberIds': <dynamic>[],
        },
      ],
    );
    await settle(tester);
    await tester.tap(find.text(kGroupName));
    await settle(tester);
    expect(
      find.bySemanticsLabel('加入该群组'),
      findsOneWidget,
      reason: 'sendspin peer 未被成员键命中 → 显示加入圈',
    );
    await tester.tap(find.bySemanticsLabel('加入该群组'));
    await settle(tester);
    // [B20-P5] 现状钉子：sendspin 的 `_memberKeyFor` **原样**传 peerId，
    // 不像 dlna 那样剥 `dlna:` 前缀（服务端 sendspin 成员命名空间就是 `peerId` 同形）。
    expect(
      ctrl!.calls,
      contains('setGroupMembership:g1:sendspin:sp1:true'),
      reason: '[B20-P5] sendspin 成员键原样传（现状钉子）',
    );
  });

  testWidgets('memberIds 里写完整 peerId 也能判定成员（_isMember 双通道）', (
    WidgetTester tester,
  ) async {
    await pumpPage(
      tester,
      loaded: <PeerInfo>[kSelf, kGroup, kDlna],
      activePeer: kSelf,
      groups: <dynamic>[
        // 故意写**完整 peerId**（而不是 `_memberKeyFor` 的裸 id `30`）
        <String, dynamic>{
          'id': 'g1',
          'name': kGroupName,
          'memberIds': <dynamic>['dlna:30'],
        },
      ],
    );
    await settle(tester);
    await tester.tap(find.text(kGroupName));
    await settle(tester);
    // [B20-P6] 现状钉子：`_isMember` 同时用裸 id 和 peerId 两路去 contains，
    // 所以服务端回完整 peerId 也算命中 —— 显示退出圈而非加入圈。
    expect(
      find.bySemanticsLabel('退出该群组'),
      findsOneWidget,
      reason: '[B20-P6] 完整 peerId 也算成员（双通道，现状钉子）',
    );
    expect(find.bySemanticsLabel('加入该群组'), findsNothing);
  });

  testWidgets('同一屏：dlna 成员显示退出圈、sendspin 成员显示加入圈', (WidgetTester tester) async {
    await pumpPage(
      tester,
      loaded: <PeerInfo>[kSelf, kGroup, kDlna, kSpin],
      activePeer: kSelf,
      groups: <dynamic>[
        <String, dynamic>{
          'id': 'g1',
          'name': kGroupName,
          'memberIds': <dynamic>['dlna:30'],
        },
      ],
    );
    await settle(tester);
    await tester.tap(find.text(kGroupName));
    await settle(tester);
    // 同一屏两种圈并存：组内那台（主卧）是退出圈，组外那台（掌柜音箱）是加入圈。
    // 注意不能写 `findsNothing` —— 组外成员本来就该显示加入圈。
    // 本机与群组自身不参与成员操作，所以没有第三种圈。
    expect(
      find.bySemanticsLabel('退出该群组'),
      findsOneWidget,
      reason: '主卧在组里 → 退出圈',
    );
    expect(
      find.bySemanticsLabel('加入该群组'),
      findsOneWidget,
      reason: '掌柜音箱不在组里 → 加入圈（同一屏两种圈并存）',
    );
    expect(
      find.bySemanticsLabel('退出该群组'),
      isNot(find.bySemanticsLabel('加入该群组')),
    );
  });

  testWidgets('成员操作失败（返回 null）时保留原状、不空掉成员集', (WidgetTester tester) async {
    await pumpPage(
      tester,
      loaded: <PeerInfo>[kSelf, kGroup, kDlna],
      activePeer: kSelf,
      groups: <dynamic>[
        <String, dynamic>{
          'id': 'g1',
          'name': kGroupName,
          'memberIds': <dynamic>['dlna:30'],
        },
      ],
    );
    await settle(tester);
    // 真 controller 在服务端报错时返回 null —— 用失败开关走那条分支。
    // 不能直接传 `membershipIds: []`：空列表是「成功但成员集为空」，会把圈全刷成加入圈。
    ctrl!.membershipFailure = true;
    await tester.tap(find.text(kGroupName));
    await settle(tester);
    await tester.tap(find.bySemanticsLabel('退出该群组'));
    await settle(tester);
    // ids 为 null 分支：不 `_selectedMembers = ids.toSet()`（会把成员集清空），
    // 只弹错提示；界面仍是「已选中」态，退出圈还在。
    expect(ctrl!.calls, contains('setGroupMembership:g1:dlna:30:false'));
    expect(
      find.bySemanticsLabel('退出该群组'),
      findsOneWidget,
      reason: '失败后成员集没被清空，圈还在（现状钉子）',
    );
    expect(hintFinder('已选中群组'), findsOneWidget, reason: '失败后仍停留在管理模式');
  });

  // ───────────────────── 十、拖拽（batch20 缺口，batch21 补齐） ─────────────────────
  // batch20 的 9.6 缺口里「拖播放端到远端点 / 拖到回收站销毁」两条，
  // 本批用 dragGesture 补齐（QA 复核给了可行姿势，见该函数的注释）。
  group('拖拽流转 / 拖到回收站', () {
    testWidgets('拖本机圆到远端圆上 = 切换遥控目标（DragTarget 落点生效）', (
      WidgetTester tester,
    ) async {
      await pumpPage(
        tester,
        loaded: <PeerInfo>[kSelf, kDlna],
        activePeer: kDlna,
      );
      await settle(tester);

      await dragGesture(
        tester,
        src: coverDragHandle(kSelf.peerId),
        dstCenter: tester.getCenter(ringGesture(kDlnaName)),
      );

      // 拖拽这条路径最终也走 switchTo —— 钉的是「DragTarget 真的吃到了 data」。
      expect(ctrl!.calls, contains('switchTo:dlna:30'));
      expect(transfers, isNotEmpty, reason: '拖放成功会回调 onTransfer 关页');
    });

    testWidgets('拖本机圆到回收站 = destroyPeer 销毁', (WidgetTester tester) async {
      await pumpPage(
        tester,
        loaded: <PeerInfo>[kSelf, kDlna],
        activePeer: kDlna,
      );
      await settle(tester);

      await dragGesture(
        tester,
        src: coverDragHandle(kSelf.peerId),
        dstCenter: tester.getCenter(find.byIcon(Icons.delete_outline)),
      );

      expect(
        ctrl!.calls,
        contains('destroyPeer:local:u1'),
        reason: '拖到回收站必须真的销毁',
      );
    });

    testWidgets('拖远端 A 到远端 B 只切遥控目标，不动本机', (WidgetTester tester) async {
      await pumpPage(
        tester,
        loaded: <PeerInfo>[kSelf, kDlna, kGroup],
        activePeer: kSelf,
      );
      await settle(tester);

      await dragGesture(
        tester,
        src: coverDragHandle(kDlna.peerId),
        dstCenter: tester.getCenter(ringGesture(kGroupName)),
      );

      expect(ctrl!.calls, contains('switchTo:group:g1'));
      expect(ctrl!.calls, isNot(contains('backToLocal')));
      expect(ctrl!.calls, isNot(contains('destroyPeer')));
    });

    testWidgets('切遥控失败（switchTo=false）时 drag 路径不被 trap 吞掉', (
      WidgetTester tester,
    ) async {
      await pumpPage(
        tester,
        loaded: <PeerInfo>[kSelf, kDlna],
        activePeer: kSelf,
      );
      await settle(tester);
      ctrl!.switchToOk = false;

      await dragGesture(
        tester,
        src: coverDragHandle(kSelf.peerId),
        dstCenter: tester.getCenter(ringGesture(kDlnaName)),
      );

      // 桩返回 false 时页面不关，但命令已经下发了 ——
      // 这条钉的是「drop 之后仍然把 switchTo 发出去」，而不是「成功才发」。
      expect(ctrl!.calls, contains('switchTo:dlna:30'));
    });
  });

  // ───────────────── 十一、拖拽边缘自动滚动（C1–C5） ─────────────────
  group('拖拽边缘自动滚动', () {
    testWidgets('拖到顶部热区：持续向上滚，越靠边越快', (WidgetTester tester) async {
      await pumpPage(tester, loaded: manyPeers(12));
      await settle(tester);
      final viewport = tester.getRect(find.byType(SingleChildScrollView));
      final controller = pageScroll(tester);
      controller.jumpTo(controller.position.maxScrollExtent);
      await tester.pump();

      final g = await tester.startGesture(
        tester.getCenter(coverDragHandle('dlna:12')),
      );
      await g.moveBy(const Offset(40, 20));
      await tester.pump(const Duration(milliseconds: 20));

      // 先停在顶部热区浅处（离下边界远）→ 滚得慢。
      await holdInHotzone(
        tester,
        g,
        Offset(viewport.center.dx, viewport.top + 40),
        ticks: 6,
      );
      final afterShallow = controller.offset;
      expect(
        afterShallow,
        lessThan(controller.position.maxScrollExtent),
        reason: '顶部热区必须向上滚',
      );

      // 再贴到上边界 → 同样帧数滚得更多。
      await holdInHotzone(
        tester,
        g,
        Offset(viewport.center.dx, viewport.top + 4),
        ticks: 6,
      );
      final afterDeep = controller.offset;
      final shallowDelta = controller.position.maxScrollExtent - afterShallow;
      final deepDelta = afterShallow - afterDeep;
      expect(afterDeep, lessThan(afterShallow), reason: '贴边继续向上滚');
      expect(deepDelta, greaterThan(shallowDelta), reason: '越靠近边缘滚得越快（深度调速）');

      await g.up();
      await tester.pump();
    });

    testWidgets('离开热区立即停止滚动', (WidgetTester tester) async {
      await pumpPage(tester, loaded: manyPeers(12));
      await settle(tester);
      final viewport = tester.getRect(find.byType(SingleChildScrollView));
      final controller = pageScroll(tester);
      controller.jumpTo(controller.position.maxScrollExtent);
      await tester.pump();

      final g = await tester.startGesture(
        tester.getCenter(coverDragHandle('dlna:12')),
      );
      await g.moveBy(const Offset(40, 20));
      await tester.pump(const Duration(milliseconds: 20));
      await holdInHotzone(
        tester,
        g,
        Offset(viewport.center.dx, viewport.top + 4),
        ticks: 5,
      );
      expect(
        controller.offset,
        lessThan(controller.position.maxScrollExtent),
        reason: '热区内已开始滚动',
      );

      // 移到视口正中（不在上下热区）→ 再推进 12 帧也不再滚。
      await g.moveTo(viewport.center);
      await tester.pump(const Duration(milliseconds: 16));
      final stopped = controller.offset;
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(controller.offset, stopped, reason: '离开热区必须立刻停');

      await g.up();
      await tester.pump();
    });

    testWidgets('拖到底部热区：向下滚，到最大边界自然停', (WidgetTester tester) async {
      await pumpPage(tester, loaded: manyPeers(12));
      await settle(tester);
      final viewport = tester.getRect(find.byType(SingleChildScrollView));
      final controller = pageScroll(tester);
      expect(
        controller.position.maxScrollExtent,
        greaterThan(0),
        reason: '13 个圆在 600 高的窗口里必须可滚动',
      );

      final g = await tester.startGesture(
        tester.getCenter(coverDragHandle('dlna:02')),
      );
      await g.moveBy(const Offset(40, 20));
      await tester.pump(const Duration(milliseconds: 20));
      await holdInHotzone(
        tester,
        g,
        Offset(viewport.center.dx, viewport.bottom - 4),
        ticks: 8,
      );
      expect(controller.offset, greaterThan(0), reason: '底部热区必须向下滚');

      // 继续停满 80 帧：滚到边界后不再越界。
      for (var i = 0; i < 80; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(
        controller.offset,
        controller.position.maxScrollExtent,
        reason: '到边界自然停，clamp 不越界',
      );

      await g.up();
      await tester.pump();
    });

    testWidgets('拖到回收站：只销毁不滚动（热区与回收站互斥）', (WidgetTester tester) async {
      await pumpPage(tester, loaded: manyPeers(12));
      await settle(tester);
      final controller = pageScroll(tester);
      expect(controller.position.maxScrollExtent, greaterThan(0));

      final g = await tester.startGesture(
        tester.getCenter(coverDragHandle('dlna:02')),
      );
      await g.moveBy(const Offset(40, 20));
      await tester.pump(const Duration(milliseconds: 20));
      await g.moveTo(tester.getCenter(find.byIcon(Icons.delete_outline)));
      for (var i = 0; i < 15; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(controller.offset, 0, reason: '回收站在滚动视口外，悬停其中不得触发滚动');

      await g.up();
      await tester.pump(const Duration(milliseconds: 120));
      await settle(tester);
      expect(
        ctrl!.calls,
        contains('destroyPeer:dlna:02'),
        reason: '拖入回收站仍然只触发销毁',
      );
    });

    testWidgets('页面没有滚动空间时热区不生效', (WidgetTester tester) async {
      await pumpPage(tester, loaded: <PeerInfo>[kSelf, kDlna]);
      await settle(tester);
      final viewport = tester.getRect(find.byType(SingleChildScrollView));
      final controller = pageScroll(tester);
      expect(controller.position.maxScrollExtent, 0);

      final g = await tester.startGesture(
        tester.getCenter(coverDragHandle(kSelf.peerId)),
      );
      await g.moveBy(const Offset(40, 20));
      await tester.pump(const Duration(milliseconds: 20));
      await holdInHotzone(
        tester,
        g,
        Offset(viewport.center.dx, viewport.top + 4),
        ticks: 10,
      );
      expect(controller.offset, 0, reason: '无可滚空间时热区不激活');

      await g.up();
      await tester.pump();
    });

    testWidgets('自动滚动后松手：按指针实际坐标重判落点（不落旧目标）', (WidgetTester tester) async {
      await pumpPage(tester, loaded: manyPeers(12));
      await settle(tester);
      final viewport = tester.getRect(find.byType(SingleChildScrollView));
      final controller = pageScroll(tester);

      final g = await tester.startGesture(
        tester.getCenter(coverDragHandle('dlna:02')),
      );
      await g.moveBy(const Offset(40, 20));
      await tester.pump(const Duration(milliseconds: 20));
      // 指针停在底部热区右列（不落在两列之间的空隙里）并让列表滚一段。
      // 离下边界 34px：仍在 44px 热区内，且滚动后落点会落在某一行圆格中部。
      final releasePoint = Offset(viewport.right - 120, viewport.bottom - 34);
      await holdInHotzone(tester, g, releasePoint, ticks: 20);
      expect(controller.offset, greaterThan(0));

      // 指针不动直接松手：DragTarget 的旧目标可能已被滚走，
      // 页面必须按松手点的实际位置重新判定。
      await g.up();
      await tester.pump(const Duration(milliseconds: 20));
      await settle(tester);

      // 逐格核对松手点命中谁：按整行矩形（与页面 _peerAt 同一口径）反推
      // 期望目标，避免“只断言有流转”放过落到旧目标的回归。
      final names = <String>[
        kSelfName,
        for (var i = 1; i <= 12; i++) 'P${i.toString().padLeft(2, '0')}',
      ];
      final hitName = peerNameAtPoint(tester, releasePoint, names);
      expect(hitName, isNotNull, reason: '松手点必须落在某个播放端整行上');
      final hitId = hitName == kSelfName
          ? kSelf.peerId
          : 'dlna:${hitName!.substring(1)}';

      expect(transfers, hasLength(1), reason: '一次拖拽只能落地一次');
      expect(
        transfers.single,
        'dlna:02->$hitId',
        reason: '必须落到松手点实际所在的播放端（不是滚动前的旧目标）',
      );
      expect(hitId, isNot('dlna:02'), reason: '不能落回自己');
    });

    testWidgets('多指同时拖两个圆：后起的拖拽被忽略，不得覆盖先起会话', (WidgetTester tester) async {
      await pumpPage(tester, loaded: manyPeers(12));
      await settle(tester);
      final viewport = tester.getRect(find.byType(SingleChildScrollView));

      final first = await tester.startGesture(
        tester.getCenter(coverDragHandle('dlna:02')),
      );
      await first.moveBy(const Offset(40, 20));
      await tester.pump(const Duration(milliseconds: 20));

      // 第二根手指在另一个圆上起拖：页面应忽略它（否则会覆盖源/坐标）。
      final second = await tester.startGesture(
        tester.getCenter(coverDragHandle('dlna:03')),
      );
      await second.moveBy(const Offset(40, 20));
      await tester.pump(const Duration(milliseconds: 20));
      await second.moveTo(Offset(viewport.center.dx, viewport.top + 120));
      await tester.pump(const Duration(milliseconds: 20));
      await second.up();
      await tester.pump(const Duration(milliseconds: 40));

      expect(transfers, isEmpty, reason: '被忽略的第二路拖拽松手不得流转');

      // 第一路仍在会话内：正常落到另一个可见圆上，且只落一次。
      await first.moveTo(tester.getCenter(ringGesture('P01')));
      await tester.pump(const Duration(milliseconds: 20));
      await first.up();
      await tester.pump(const Duration(milliseconds: 20));
      await settle(tester);
      expect(transfers, hasLength(1));
      expect(transfers.single, 'dlna:02->dlna:01');
    });

    // ── C6/C7：自动滚动的两条收尾分支（覆盖率补测，2026-10-22） ──
    // 自动滚动后 DragTarget 的旧落点不可信，回收站也一样：`_handleDestroy` 在
    // `_autoScrolled` 时早退，必须由 `_onDragFinished` 按指针实际坐标销毁。
    testWidgets('自动滚动后松手落在回收站：按实际坐标销毁,且只销毁一次', (WidgetTester tester) async {
      await pumpPage(tester, loaded: manyPeers(12));
      await settle(tester);
      final viewport = tester.getRect(find.byType(SingleChildScrollView));
      final controller = pageScroll(tester);
      expect(controller.position.maxScrollExtent, greaterThan(0));

      final g = await tester.startGesture(
        tester.getCenter(coverDragHandle('dlna:02')),
      );
      await g.moveBy(const Offset(40, 20));
      await tester.pump(const Duration(milliseconds: 20));
      await holdInHotzone(
        tester,
        g,
        Offset(viewport.center.dx, viewport.bottom - 4),
        ticks: 8,
      );
      expect(controller.offset, greaterThan(0), reason: '先发生自动滚动');

      // 指针移到回收站后松手：此时已离开热区，但 `_autoScrolled` 仍为 true，
      // 回收站 DragTarget 的 onAccept 会被 `_handleDestroy` 早退挡掉，
      // 必须由 `_onDragFinished` 按松手坐标补上销毁。
      await g.moveTo(tester.getCenter(find.byIcon(Icons.delete_outline)));
      await tester.pump(const Duration(milliseconds: 20));
      await g.up();
      await tester.pump(const Duration(milliseconds: 120));
      await settle(tester);

      expect(
        ctrl!.calls.where((String c) => c == 'destroyPeer:dlna:02').length,
        1,
        reason: '自动滚动后拖入回收站必须销毁，且不能被两条路径重复销毁',
      );
      expect(transfers, isEmpty, reason: '拖进回收站不是流转');
    });

    // 系统抢占/取消拖拽（来电、手势被外层接管）时，自动滚动定时器必须停、
    // 会话必须清干净，否则下一次拖拽会带着旧坐标/旧源起手。
    testWidgets('拖拽被系统取消：停自动滚动并清空会话，不流转也不关页', (WidgetTester tester) async {
      await pumpPage(tester, loaded: manyPeers(12));
      await settle(tester);
      final viewport = tester.getRect(find.byType(SingleChildScrollView));
      final controller = pageScroll(tester);
      expect(controller.position.maxScrollExtent, greaterThan(0));

      final g = await tester.startGesture(
        tester.getCenter(coverDragHandle('dlna:02')),
      );
      await g.moveBy(const Offset(40, 20));
      await tester.pump(const Duration(milliseconds: 20));
      await holdInHotzone(
        tester,
        g,
        Offset(viewport.center.dx, viewport.bottom - 4),
        ticks: 6,
      );
      final scrolled = controller.offset;
      expect(scrolled, greaterThan(0), reason: '取消前已在自动滚动');

      await g.cancel();
      await tester.pump(const Duration(milliseconds: 20));
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }

      expect(controller.offset, scrolled, reason: '取消后自动滚动必须停住');
      expect(transfers, isEmpty, reason: '取消不得流转');
      expect(find.byType(PlayerTransferPage), findsOneWidget, reason: '取消不得关页');
    });

    // `PlayerTransferPage.open` 是全仓所有入口共用的包装（根导航器 +
    // fullscreenDialog）：漏测时，「从 mini 播放器槽位打开只盖住内容区」
    // 这类回归没有任何线索。
    testWidgets('open(): 经根导航器弹出全屏流转页，点空白可关闭', (WidgetTester tester) async {
      await pumpPage(tester, loaded: <PeerInfo>[kSelf, kDlna], viaOpen: true);
      await settle(tester);
      expect(find.byType(PlayerTransferPage), findsNothing);

      await tester.tap(find.text('打开流转页'));
      await settle(tester);
      expect(find.byType(PlayerTransferPage), findsOneWidget);
      expect(find.text(kDlnaName), findsOneWidget);

      // 点空白处关闭（页面自身 onTap = maybePop），回到宿主按钮。
      // ⚠️ 转场必须彻底落地：Zoom 转场在 300ms 边界时页面仍被缩放/尚未完成，
      // 左上角这点还在屏障区，点击会被 ModalBarrier 吞掉（实测 canPop 一直是 true）。
      await tester.pump(const Duration(seconds: 1));
      await tester.tapAt(const Offset(6, 6));
      // 退场动画 300ms；本机圆带呼吸动画，不能改用 pumpAndSettle。
      await settle(tester, frames: 12);
      expect(find.byType(PlayerTransferPage), findsNothing);
      expect(find.text('打开流转页'), findsOneWidget);
    });

    // 防御路径：`onDragEnd` 未按预期到达时，`onDraggableCanceled` 仍须把会话与
    // 自动滚动定时器收干净。真实时序里 onDragEnd 在前会先清，这条只在例外时序
    // 下走 —— 用直达回调钉住它的清理职责，避免日后被误删导致定时器静默泄漏。
    testWidgets('onDraggableCanceled 直达：停自动滚动并清空会话', (
      WidgetTester tester,
    ) async {
      await pumpPage(tester, loaded: manyPeers(12));
      await settle(tester);
      final viewport = tester.getRect(find.byType(SingleChildScrollView));
      final controller = pageScroll(tester);
      final handle = coverDragHandle('dlna:02');
      final g = await tester.startGesture(tester.getCenter(handle));
      await g.moveBy(const Offset(40, 20));
      await tester.pump(const Duration(milliseconds: 20));
      await holdInHotzone(
        tester,
        g,
        Offset(viewport.center.dx, viewport.bottom - 4),
        ticks: 6,
      );
      final scrolled = controller.offset;
      expect(scrolled, greaterThan(0), reason: '先发生自动滚动');

      final draggable = tester.widget<Draggable<PeerInfo>>(handle);
      draggable.onDraggableCanceled?.call(Velocity.zero, Offset.zero);
      await tester.pump(const Duration(milliseconds: 16));
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(controller.offset, scrolled, reason: '取消回调必须停掉自动滚动');

      await g.cancel();
      await settle(tester);
      expect(transfers, isEmpty, reason: '取消不得流转');
      expect(find.byType(PlayerTransferPage), findsOneWidget);
    });
  });
}
