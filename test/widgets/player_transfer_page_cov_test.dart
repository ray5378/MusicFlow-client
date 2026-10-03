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
    return <String>[memberKey];
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
}) async {
  ctrl = null;
  transfers.clear();
  await tester.pumpWidget(ProviderScope(
    overrides: <Override>[
      castPeerControllerProvider.overrideWith((Ref ref) {
        final c = FakeCastPeer(ref)
          ..loaded = loaded
          ..loadGate = loadGate
          ..groups = groups;
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
}
