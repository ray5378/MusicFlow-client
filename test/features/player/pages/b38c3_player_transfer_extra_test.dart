// b38c3 —— Route C 补测：`lib/features/player/pages/player_transfer_page.dart`
// 剩余缺口（在既有 player_transfer_page_cov_test(.dart/2) 全绿基础上再补）。
//
// 覆盖点：
//   * 139：drop 到「本机」圆 → backToLocal(resumeLocal: true)。
//   * 198-200：单击远端但 switchTo 失败 → 弹 cast_failed 错误提示、不关页。
//   * 214-217：再点一次已选中的群组 → 退出成员管理模式（清空选中态）。
//   * 229 / 282：群组 peerId **不带** `group:` 前缀时，gid 直接取 peerId。
//   * 320：拖远端（非本机）到回收站 → 额外 invalidate 该端在播 provider。
//   * 326：destroyPeer 返回 false → 弹 destroy_failed 错误提示。
//   * 365：点空白处 → 关页（maybePop）。
//   * 571：拖拽被取消（onDraggableCanceled）→ 清空拖拽态。
//   * 653-659 / 771-776：本机在播且有「曲名 - 歌手」→ 圆右侧渲染曲目文案。
//   * 666/667：远端在播（PeerNowPlaying.isActive）→ 取封面与曲目文案。
//   * 708-715：有封面时圆内渲染 CoverArtImage（含 semanticLabel）。
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:musicflow_client/core/offline/offline_cache_manager.dart';
import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/data/models/music_library.dart';
import 'package:musicflow_client/data/models/peer.dart';
import 'package:musicflow_client/data/models/server_address.dart';
import 'package:musicflow_client/data/models/song.dart';
import 'package:musicflow_client/data/sources/subsonic_api_client.dart';
import 'package:musicflow_client/features/player/pages/player_transfer_page.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:musicflow_client/providers/api/api_provider.dart';
import 'package:musicflow_client/providers/cast/cast_peer_provider.dart';
import 'package:musicflow_client/providers/library/library_provider.dart';
import 'package:musicflow_client/providers/offline/offline_provider.dart';
import 'package:musicflow_client/providers/player/player_provider.dart';
import 'package:musicflow_client/providers/ui/palette_provider.dart';
import 'package:musicflow_client/widgets/cover_art_image.dart';

import '../test_player_notifier.dart';

const String kSelfName = '本机';
const String kDlnaName = '主卧';
const String kGroupName = '客厅组';

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
/// 不带 `group:` 前缀的群组 id —— 走 `gid = peerId` 那条分支。
const PeerInfo kGroupPlain = PeerInfo(
  peerId: 'g1',
  name: kGroupName,
  kind: 'group',
  available: true,
);

class FakeCastPeer extends CastPeerController {
  FakeCastPeer(super.ref);

  final List<String> calls = <String>[];

  List<PeerInfo> loaded = const <PeerInfo>[];
  bool switchToOk = true;
  bool destroyOk = true;
  List<dynamic>? groups;

  @override
  Future<List<PeerInfo>> loadPeers() async {
    calls.add('loadPeers');
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
    return destroyOk;
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

  @override
  Future<PeerNowPlaying?> fetchPeerNowPlaying(String peerId) async => null;
}

class _StubOfflineCache extends OfflineCacheManager {
  _StubOfflineCache() : super(rootForTest: null);
}

/// 能吐真实 PNG 字节的 HttpClient：让 CoverArtImage 成功出帧，
/// 避免真网络请求失败抛异常污染 `takeException()`。
const String _kTestPngBase64 =
    'iVBORw0KGgoAAAANSUhEUgAAAAgAAAAICAYAAADED76LAAAAEklEQVR42mM4YRP1Hx9mGBkKAOorl0GM4cQIAAAAAElFTkSuQmCC';
final Uint8List _kTestPngBytes =
    Uint8List.fromList(base64Decode(_kTestPngBase64));

class _BytesHttpClient implements HttpClient {
  @override
  Future<HttpClientRequest> getUrl(Uri url) async => _BytesRequest();
  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async =>
      _BytesRequest();
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _BytesRequest implements HttpClientRequest {
  @override
  Future<HttpClientResponse> close() async => _BytesResponse();
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _BytesResponse extends StreamView<List<int>>
    implements HttpClientResponse {
  _BytesResponse()
      : super(Stream<List<int>>.fromIterable(<List<int>>[_kTestPngBytes]));
  @override
  int get statusCode => 200;
  @override
  int get contentLength => _kTestPngBytes.length;
  @override
  HttpClientResponseCompressionState get compressionState =>
      HttpClientResponseCompressionState.notCompressed;
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

Future<void> settle(WidgetTester tester, {int frames = 6}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}

FakeCastPeer? ctrl;
final List<String> transfers = <String>[];
final List<String> npRequests = <String>[];

Finder hintFinder(String needle) => find.byWidgetPredicate(
      (Widget w) => w is Text && (w.data ?? '').contains(needle),
    );

Finder coverDragHandle(String peerId) => find.byWidgetPredicate(
      (Widget w) => w is Draggable<PeerInfo> && w.data?.peerId == peerId,
    );

Finder ringGesture(String name) => find
    .ancestor(of: find.text(name), matching: find.byType(GestureDetector))
    .at(0);

Future<void> pumpPage(
  WidgetTester tester, {
  List<PeerInfo> loaded = const <PeerInfo>[],
  PeerInfo? activePeer,
  List<dynamic>? groups,
  PlayerState? playerState,
  PeerNowPlaying? nowPlaying,
}) async {
  ctrl = null;
  transfers.clear();
  npRequests.clear();
  final library = MusicLibrary(
    id: 'lib-b38c3',
    name: '补测库',
    createdAt: DateTime(2026, 10, 1),
    updatedAt: DateTime(2026, 10, 1),
  );
  final client = SubsonicApiClient(
    dio: Dio(BaseOptions(baseUrl: 'https://music.example.test')),
  )..setLibrary(library);
  await tester.pumpWidget(ProviderScope(
    overrides: <Override>[
      castPeerControllerProvider.overrideWith((Ref ref) {
        final c = FakeCastPeer(ref)
          ..loaded = loaded
          ..groups = groups;
        if (activePeer != null) {
          c.state = CastPeerState(activePeer: activePeer);
        }
        ctrl = c;
        return c;
      }),
      peerNowPlayingProvider.overrideWith((Ref ref, String peerId) {
        npRequests.add(peerId);
        return nowPlaying == null
            ? const Stream<PeerNowPlaying?>.empty()
            : Stream<PeerNowPlaying?>.value(nowPlaying);
      }),
      // 屏蔽取色链上的 PaletteGenerator（会留 15s pending Timer）。
      currentSongMediaVisualsProvider.overrideWith((ref) async => null),
      if (playerState != null)
        playerProvider
            .overrideWith((Ref ref) => TestPlayerNotifier(playerState)),
      // CoverArtImage 依赖链：给全桩，避免 provider 未实现异常与 pending Timer。
      subsonicApiClientProvider.overrideWithValue(client),
      activeLibraryProvider.overrideWithValue(library),
      activeAddressProvider.overrideWith(
        (ref) => ServerAddress(
          id: 'addr-ok',
          libraryId: library.id,
          label: '测试地址',
          url: 'https://music.example.test',
          priority: 0,
          status: ServerAddressStatus.ok,
        ),
      ),
      isOfflineProvider.overrideWithValue(false),
      offlineCacheManagerProvider.overrideWithValue(_StubOfflineCache()),
      offlineCacheReadyProvider.overrideWith((ref) async {}),
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

Future<void> dragGesture(
  WidgetTester tester, {
  required Finder src,
  required Offset dstCenter,
}) async {
  final start = tester.getCenter(src);
  final g = await tester.startGesture(start);
  await g.moveBy(const Offset(50, 18));
  await tester.pump(const Duration(milliseconds: 30));
  await g.moveTo(dstCenter);
  await tester.pump(const Duration(milliseconds: 30));
  await g.up();
  await tester.pump(const Duration(milliseconds: 120));
  await settle(tester);
}

void main() {
  testWidgets('拖远端圆到本机 = backToLocal 续播（139）', (tester) async {
    await pumpPage(
      tester,
      loaded: <PeerInfo>[kSelf, kDlna],
      activePeer: kSelf,
    );
    await settle(tester);

    await dragGesture(
      tester,
      src: coverDragHandle(kDlna.peerId),
      dstCenter: tester.getCenter(ringGesture(kSelfName)),
    );

    expect(ctrl!.calls, contains('backToLocal:true'),
        reason: 'drop 到本机要走 backToLocal(resumeLocal: true)');
    expect(transfers, contains('dlna:30->local:u1'));

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('单击远端但 switchTo 失败：弹错误提示、留在页内（198-200）',
      (tester) async {
    await pumpPage(
      tester,
      loaded: <PeerInfo>[kSelf, kDlna],
      activePeer: kSelf,
    );
    await settle(tester);
    ctrl!.switchToOk = false;

    await tester.tap(find.text(kDlnaName));
    await settle(tester);

    expect(ctrl!.calls, contains('switchTo:dlna:30'));
    // 失败不关页：两个圆的名字仍在（home 路由 maybePop 无副作用的对照）。
    expect(find.text(kSelfName), findsOneWidget);
    expect(find.text(kDlnaName), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('再点一次已选中的群组 = 退出管理模式（214-217）', (tester) async {
    await pumpPage(
      tester,
      loaded: <PeerInfo>[kSelf, kGroupPlain, kDlna],
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
    expect(hintFinder('已选中群组'), findsOneWidget);

    // 第二次点：命中「同一群组」→ 清空选中态（214-217）。
    await tester.tap(find.text(kGroupName));
    await settle(tester);
    expect(hintFinder('已选中群组'), findsNothing,
        reason: '再点一次应退出成员管理模式');
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('群组 peerId 不带 group: 前缀：gid 直接取 peerId（229/282）',
      (tester) async {
    await pumpPage(
      tester,
      loaded: <PeerInfo>[kSelf, kGroupPlain, kDlna],
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
    expect(ctrl!.calls, contains('fetchGroups'));
    expect(hintFinder('已选中群组'), findsOneWidget);

    // 主卧不在组里 → 加入圈；点击 → _toggleMembership，gid 取非前缀 peerId。
    expect(find.bySemanticsLabel('加入该群组'), findsWidgets);
    await tester.tap(find.bySemanticsLabel('加入该群组').first);
    await settle(tester);
    expect(ctrl!.calls, contains('setGroupMembership:g1:30:true'),
        reason: '非前缀群组 id 也要正确拼出 setGroupMembership');

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('拖远端到回收站成功：销毁远端并 invalidate 其在播（320）',
      (tester) async {
    await pumpPage(
      tester,
      loaded: <PeerInfo>[kSelf, kDlna],
      activePeer: kSelf,
    );
    await settle(tester);
    final before = npRequests.where((p) => p == 'dlna:30').length;

    await dragGesture(
      tester,
      src: coverDragHandle(kDlna.peerId),
      dstCenter: tester.getCenter(find.byIcon(Icons.delete_outline)),
    );

    expect(ctrl!.calls, contains('destroyPeer:dlna:30'));
    final after = npRequests.where((p) => p == 'dlna:30').length;
    expect(after, greaterThan(before),
        reason: '非本机的销毁成功要连带 invalidate 其在播 provider（重读一次）');

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('拖远端到回收站但销毁失败：弹失败提示、仍不关页（326）',
      (tester) async {
    await pumpPage(
      tester,
      loaded: <PeerInfo>[kSelf, kDlna],
      activePeer: kSelf,
    );
    await settle(tester);
    ctrl!.destroyOk = false;

    await dragGesture(
      tester,
      src: coverDragHandle(kDlna.peerId),
      dstCenter: tester.getCenter(find.byIcon(Icons.delete_outline)),
    );

    expect(ctrl!.calls, contains('destroyPeer:dlna:30'));
    // 失败分支：仍留在页内，两个圆都在。
    expect(find.text(kDlnaName), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('点空白区域 = 关页（365，hitTest opaque 层）', (tester) async {
    await pumpPage(
      tester,
      loaded: <PeerInfo>[kSelf, kDlna],
      activePeer: kSelf,
    );
    await settle(tester);

    // 左上角在 SafeArea 内容层里、圆与文案之外 —— 落到整块 GestureDetector。
    await tester.tapAt(const Offset(6, 6));
    await settle(tester);
    expect(tester.takeException(), isNull);
    expect(find.text(kDlnaName), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('拖拽被取消：onDraggableCanceled 清空拖拽态（571）', (tester) async {
    await pumpPage(
      tester,
      loaded: <PeerInfo>[kSelf, kDlna],
      activePeer: kSelf,
    );
    await settle(tester);

    final g = await tester.startGesture(
      tester.getCenter(coverDragHandle(kDlna.peerId)),
    );
    await g.moveBy(const Offset(60, 20));
    await tester.pump(const Duration(milliseconds: 30));
    await g.cancel();
    await tester.pump(const Duration(milliseconds: 120));
    await settle(tester);

    // 取消后页面仍在，圆未消失、未误触发流转。
    expect(find.text(kDlnaName), findsOneWidget);
    expect(transfers, isEmpty, reason: '取消拖拽不应触发流转');
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('本机在播（有曲名/歌手）：圆右侧渲染「曲名 - 歌手」（653-659/771-776）',
      (tester) async {
    await pumpPage(
      tester,
      loaded: <PeerInfo>[kSelf, kDlna],
      playerState: PlayerState(
        currentSong: Song(id: 's1', title: '夜曲', artist: '周杰伦'),
        isPlaying: true,
      ),
    );
    await settle(tester);

    expect(find.text('夜曲 - 周杰伦'), findsOneWidget,
        reason: '本机在播时圆右侧要显示完整曲目文案');

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('本机在播但只有曲名无歌手：只显示曲名（657）', (tester) async {
    await pumpPage(
      tester,
      loaded: <PeerInfo>[kSelf],
      playerState: PlayerState(
        currentSong: Song(id: 's2', title: '纯音乐'),
        isPlaying: true,
      ),
    );
    await settle(tester);

    expect(find.text('纯音乐'), findsOneWidget);
    expect(find.textContaining(' - '), findsNothing,
        reason: '无歌手时不拼「曲名 - 歌手」');

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('本机在播且有封面：圆内渲染 CoverArtImage（708-715）',
      (tester) async {
    debugNetworkImageHttpClientProvider = _BytesHttpClient.new;
    addTearDown(() => debugNetworkImageHttpClientProvider = null);
    await pumpPage(
      tester,
      loaded: <PeerInfo>[kSelf, kDlna],
      playerState: PlayerState(
        currentSong: Song(id: 's3', title: '有封面', coverArt: 'al-9'),
        isPlaying: true,
      ),
    );
    await settle(tester);

    expect(find.byType(CoverArtImage), findsWidgets,
        reason: '本机在播且有封面 → 圆内走 CoverArtImage 分支');
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox());
    debugNetworkImageHttpClientProvider = null;
  });

  testWidgets('远端在播：取 PeerNowPlaying 的封面与曲目文案（666/667）',
      (tester) async {
    debugNetworkImageHttpClientProvider = _BytesHttpClient.new;
    addTearDown(() => debugNetworkImageHttpClientProvider = null);
    await pumpPage(
      tester,
      loaded: <PeerInfo>[kSelf, kDlna],
      nowPlaying: const PeerNowPlaying(
        isActive: true,
        currentIndex: 0,
        total: 3,
        title: '远方曲',
        artist: '远方人',
        coverArt: 'al-remote',
      ),
    );
    await settle(tester);

    expect(find.text('远方曲 - 远方人'), findsWidgets,
        reason: '远端在播时圆右侧显示其 trackLabel');
    expect(find.byType(CoverArtImage), findsWidgets,
        reason: '远端在播且有封面 → 圆内走 CoverArtImage 分支');
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox());
    debugNetworkImageHttpClientProvider = null;
  });
}
