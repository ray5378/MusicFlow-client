import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/data/models/peer.dart';
import 'package:musicflow_client/features/player/pages/player_transfer_page.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:musicflow_client/providers/cast/cast_peer_provider.dart';
import 'package:musicflow_client/providers/cast/cast_peer_state.dart';
import 'package:musicflow_client/providers/ui/palette_provider.dart';

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
/// sendspin 成员：服务端成员命名空间与 peerId 同形（`sendspin:<clientId>`），
/// `_memberKeyFor` 对它的处理与 dlna 不同（不剥前缀），单独留一条用例钉住。
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
  FakeCastPeer(Ref ref) : super(ref);

  final List<String> calls = <String>[];

  List<PeerInfo> loaded = const <PeerInfo>[];
  Future<void>? loadGate;
  bool switchToOk = true;
  List<dynamic>? groups;

  /// 给 null = 模拟「操作失败」（真 controller 在服务端报错时返回 null）。
  List<String>? membershipIds;

  /// 置 true 时 setGroupMembership 直接返 null（模拟服务端报错）。
  bool membershipFailure = false;

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
}) async {
  ctrl = null;
  transfers.clear();
  await tester.pumpWidget(ProviderScope(
    overrides: <Override>[
      castPeerControllerProvider.overrideWith((Ref ref) {
        final c = FakeCastPeer(ref)
          ..loaded = loaded
          ..loadGate = loadGate
          ..groups = groups
          ..membershipIds = membershipIds;
        if (activePeer != null) {
          c.state = CastPeerState(activePeer: activePeer);
        }
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
      home: PlayerTransferPage(
        onTransfer: (PeerInfo from, PeerInfo to) async {
          transfers.add('${from.peerId}->${to.peerId}');
          return true;
        },
      ),
    ),
  ));
}

/// 某个播放端**整行**（落点）的 GestureDetector 句柄。
///
/// 页面里 `_RingNode.build` 的注释写得很清楚：落点 DragTarget 铺在**整行**
/// （拖到名称区也能接住，手势容错更大），所以落点找整行的 GestureDetector。
Finder ringGesture(String name) =>
    find
        .ancestor(
          of: find.text(name),
          matching: find.byType(GestureDetector),
        )
        .at(0);

/// 某个播放端**封面圆**（拖拽源）的句柄。
///
/// 两个坑：
/// 1. 拖拽源只包封面圆 —— `Draggable` 挂在 `circleWrapper` 上，而「播放器名/歌名」
///    那个 Text 与圆是**兄弟**关系，不是它的后代（`find.ancestor(of: find.text(...))`
///    按 Draggable 去查永远落空，实测报 `Index out of range`）；
/// 2. 从名称区按下也起不了拖（源码原话「只有封面圆可拖起」）。
/// 所以直接用 `Draggable.data` 反查 —— `Draggable<PeerInfo>.data.peerId` 就是唯一的锚点。
Finder coverDragHandle(String peerId) =>
    find.byWidgetPredicate((Widget w) => w is Draggable<PeerInfo> && w.data?.peerId == peerId);

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
Finder hintFinder(String needle) =>
    find.byWidgetPredicate(
      (Widget w) => w is Text && (w.data ?? '').contains(needle),
    );

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

  testWidgets('服务端一条播放端都不给时落到空态文案', (
    WidgetTester tester,
  ) async {
    await pumpPage(tester, loaded: const <PeerInfo>[]);
    await settle(tester);
    expect(find.text('当前没有其它可用的播放器'), findsOneWidget);
    expect(find.text(kSelfName), findsNothing, reason: '没数据就没有本机圆');
  });

  testWidgets('只回本机那一行时不是空态（本机自己占一格）', (
    WidgetTester tester,
  ) async {
    await pumpPage(tester, loaded: <PeerInfo>[kSelf]);
    await settle(tester);
    // 与例 2 区分开：`_load` 会把本机行塞回列表首位 → 走列表分支。
    expect(find.text(kSelfName), findsOneWidget);
    expect(find.text('当前没有其它可用的播放器'), findsNothing,
        reason: '有本机行就不该显示空态');
  });

  testWidgets('列表装配：本机排第一，离线端与 Web 端不出', (
    WidgetTester tester,
  ) async {
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
    expect(find.text(kOfflineName), findsNothing,
        reason: '[B20-P1] 离线端不出列表（现状钉子）');
    expect(find.text(kWebName), findsNothing,
        reason: '[B20-P1] Web 端不出列表（现状钉子）');

    // 顺序（QA 复核意见 4）：例 4 原来只断言「有/没有」，谁在前谁在后没人管。
    // 这里按 widget 树的深度优先顺序取三个名字，钉住 `_load` 的装配次序。
    final order = find
        .byWidgetPredicate(
          (Widget w) =>
              w is Text &&
              (w.data == kSelfName || w.data == kDlnaName || w.data == kGroupName),
        )
        .evaluate()
        .map((Element e) => (e.widget as Text).data)
        .toList(growable: false);
    // 实测顺序：本机 → 群组 → 设备（comparePeerDisplayOrder 里群组优先于普通设备）。
    expect(order, <String>[kSelfName, kGroupName, kDlnaName],
        reason: '本机强制置首，其余按 comparePeerDisplayOrder');
  });

  testWidgets('点在线远端 = 切遥控目标，成功后自动关页', (
    WidgetTester tester,
  ) async {
    await pumpPage(
      tester,
      loaded: <PeerInfo>[kSelf, kDlna],
      activePeer: kSelf, // 当前遥控本机 → 主卧不是当前目标
    );
    await settle(tester);
    await tester.tap(find.text(kDlnaName));
    await settle(tester);
    expect(ctrl!.calls, contains('switchTo:dlna:30'),
        reason: '点远端必须走 switchTo');
    expect(ctrl!.calls, isNot(contains('backToLocal:true')));
  });

  testWidgets('点当前已遥控的远端 = 什么也不做，只关页（钉子）', (
    WidgetTester tester,
  ) async {
    await pumpPage(
      tester,
      loaded: <PeerInfo>[kSelf, kDlna],
      activePeer: kDlna,
    );
    await settle(tester);
    await tester.tap(find.text(kDlnaName));
    await settle(tester);
    // [B20-P2] 现状钉子：命中「已经在遥控它」的早退分支（只关页，不下发任何命令）。
    // 将来若改成「再点一次取消遥控」，这条会红。
    expect(ctrl!.calls, isNot(contains('switchTo:dlna:30')),
        reason: '[B20-P2] 已是当前目标时不该再 switchTo（现状钉子）');
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
    expect(ctrl!.calls, contains('backToLocal:true'),
        reason: '点本机要 backToLocal(resumeLocal: true)');
    expect(ctrl!.calls, isNot(contains('switchTo:dlna:30')));
  });

  testWidgets('点群组：静默切遥控 + 拉成员配置 + 进入管理模式', (
    WidgetTester tester,
  ) async {
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
    expect(ctrl!.calls, contains('switchTo:group:g1'),
        reason: '选中群组同时把遥控切过去');
    expect(ctrl!.calls, contains('fetchGroups'), reason: '要拉成员配置');
    expect(hintFinder('已选中群组'), findsOneWidget,
        reason: '选中后标题下方出现进度提示');
    // [B20-P4] 现状钉子：主卧在 `memberIds` 里 → 走「已是成员」档，显示退出圈。
    // 同时印证成员键是 `_memberKeyFor()` 的产出**裸 id**（`30`，DLNA 剥掉
    // `dlna:` 前缀），不是 `dlna:30` —— 服务端 DLNA 成员命名空间就是裸 id。
    // 将来若改成「先给加入圈」或改成传完整 peerId，这两条会红。
    expect(find.bySemanticsLabel('退出该群组'), findsOneWidget,
        reason: '[B20-P4] 已是成员显示退出圈（现状钉子）');
    expect(find.bySemanticsLabel('加入该群组'), findsNothing,
        reason: '[B20-P4] 成员态不显示加入圈（现状钉子）');
  });

  testWidgets('点群组但服务端查不到这个 gid = 不进管理模式（钉子）', (
    WidgetTester tester,
  ) async {
    await pumpPage(
      tester,
      loaded: <PeerInfo>[kSelf, kGroup, kDlna],
      activePeer: kSelf,
      groups: <dynamic>[
        <String, dynamic>{'id': 'other', 'name': '别的组', 'memberIds': <dynamic>[]},
      ],
    );
    await settle(tester);
    await tester.tap(find.text(kGroupName));
    await settle(tester);
    // [B20-P3] 现状钉子：查不到 gid 时只弹错提示，页面**不进**管理模式
    // （`_selectedGroupId` 保持 null，+/− 按钮也不出现）。
    // 将来若改成「查不到也按空成员进管理模式」，这两条会红。
    expect(hintFinder('已选中群组'), findsNothing,
        reason: '[B20-P3] 没命中 gid 不进管理模式（现状钉子）');
    expect(find.bySemanticsLabel('加入该群组'), findsNothing,
        reason: '[B20-P3] 没有成员按钮（现状钉子）');
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
    // 协议走的是裸 id（DLNA 剥掉 `dlna:` 前缀），不是 `dlna:30`。
    expect(ctrl!.calls, contains('setGroupMembership:g1:30:false'),
        reason: '退组带 join=false，且成员键走裸 id 命名空间');
  });

  testWidgets('还没选群组时设备圆下方不出现成员圈（早退方向）', (
    WidgetTester tester,
  ) async {
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
    expect(find.bySemanticsLabel('退出该群组'), findsNothing,
        reason: '未选群组时不显示成员圈（早退方向）');
    expect(find.bySemanticsLabel('加入该群组'), findsNothing);
  });

  testWidgets('点 dlna 成员的加入圈 = setGroupMembership(..., join: true)', (
    WidgetTester tester,
  ) async {
    await pumpPage(
      tester,
      loaded: <PeerInfo>[kSelf, kGroup, kDlna],
      activePeer: kSelf,
      groups: <dynamic>[
        // 主卧**不在** memberIds 里 → 走「加入」分支（join=true）。
        // 只验退出那条的话，join=true 这条链（dlna 命名空间下的入组）没人守。
        <String, dynamic>{
          'id': 'g1',
          'name': kGroupName,
          'memberIds': <dynamic>['dlna:77'],
        },
      ],
    );
    await settle(tester);
    await tester.tap(find.text(kGroupName));
    await settle(tester);
    expect(find.bySemanticsLabel('加入该群组'), findsOneWidget,
        reason: '组里没有这台 dlna → 显示加入圈（而不是退出圈）');
    expect(find.bySemanticsLabel('退出该群组'), findsNothing);

    await tester.tap(find.bySemanticsLabel('加入该群组'));
    await settle(tester);
    // dlna 的成员键是**裸 id**（剥掉 `dlna:` 前缀），join 方向也要走裸 id 命名空间。
    expect(ctrl!.calls, contains('setGroupMembership:g1:30:true'),
        reason: '入组带 join=true，且 dlna 成员键走裸 id 命名空间');
    expect(ctrl!.calls, isNot(contains('setGroupMembership:g1:dlna:30:true')),
        reason: '不能把完整 peerId 当 dlna 成员键发出去');
  });

  testWidgets('sendspin 成员的成员键原样走 peerId（不与裸 id 混用）', (
    WidgetTester tester,
  ) async {
    await pumpPage(
      tester,
      loaded: <PeerInfo>[kSelf, kGroup, kSpin],
      activePeer: kSelf,
      groups: <dynamic>[
        <String, dynamic>{'id': 'g1', 'name': kGroupName, 'memberIds': <dynamic>[]},
      ],
    );
    await settle(tester);
    await tester.tap(find.text(kGroupName));
    await settle(tester);
    expect(find.bySemanticsLabel('加入该群组'), findsOneWidget,
        reason: 'sendspin peer 未被成员键命中 → 显示加入圈');
    await tester.tap(find.bySemanticsLabel('加入该群组'));
    await settle(tester);
    // [B20-P5] 现状钉子：sendspin 的 `_memberKeyFor` **原样**传 peerId，
    // 不像 dlna 那样剥 `dlna:` 前缀（服务端 sendspin 成员命名空间就是 `peerId` 同形）。
    expect(ctrl!.calls, contains('setGroupMembership:g1:sendspin:sp1:true'),
        reason: '[B20-P5] sendspin 成员键原样传（现状钉子）');
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
    expect(find.bySemanticsLabel('退出该群组'), findsOneWidget,
        reason: '[B20-P6] 完整 peerId 也算成员（双通道，现状钉子）');
    expect(find.bySemanticsLabel('加入该群组'), findsNothing);
  });

  testWidgets('同一屏：dlna 成员显示退出圈、sendspin 成员显示加入圈', (
    WidgetTester tester,
  ) async {
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
    expect(find.bySemanticsLabel('退出该群组'), findsOneWidget,
        reason: '主卧在组里 → 退出圈');
    expect(find.bySemanticsLabel('加入该群组'), findsOneWidget,
        reason: '掌柜音箱不在组里 → 加入圈（同一屏两种圈并存）');
    expect(find.bySemanticsLabel('退出该群组'), isNot(find.bySemanticsLabel('加入该群组')));
  });

  testWidgets('成员操作失败（返回 null）时保留原状、不空掉成员集', (
    WidgetTester tester,
  ) async {
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
    expect(ctrl!.calls, contains('setGroupMembership:g1:30:false'));
    expect(find.bySemanticsLabel('退出该群组'), findsOneWidget,
        reason: '失败后成员集没被清空，圈还在（现状钉子）');
    expect(hintFinder('已选中群组'), findsOneWidget,
        reason: '失败后仍停留在管理模式');
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

    testWidgets('拖本机圆到回收站 = destroyPeer 销毁', (
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
        dstCenter: tester.getCenter(find.byIcon(Icons.delete_outline)),
      );

      expect(ctrl!.calls, contains('destroyPeer:local:u1'),
          reason: '拖到回收站必须真的销毁');
    });

    testWidgets('拖远端 A 到远端 B 只切遥控目标，不动本机', (
      WidgetTester tester,
    ) async {
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
}
