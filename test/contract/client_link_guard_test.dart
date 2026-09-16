import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:musicflow_client/core/constants/api_constants.dart';
import 'package:musicflow_client/data/models/peer.dart';
import 'package:musicflow_client/data/models/song.dart';
import 'package:musicflow_client/providers/api/api_provider.dart';
import 'package:musicflow_client/providers/cast/cast_peer_provider.dart';
import 'package:musicflow_client/providers/player/favorite_scrobble_handler.dart';
import 'package:musicflow_client/providers/player/player_provider.dart';

import '../features/player/test_player_notifier.dart';
import '../helpers/mocks.dart';

/// 客户端（安卓 / Windows）互控链路守护 —— 2026-09-15 拍板的三条契约。
///
/// 这些不是「实现细节」，而是**跨端互操作契约**：任何一条被改回去，表现都是
/// 「UI 上看不出异常、功能静默失效」（推流无反应 / 别的客户端那行永远显示
/// 未在播放 / 播放历史里查不到记录），本地手测很难复现。故必须在 CI 钉死。
///
///   1. 推流不得按 `kind == local` 一刀切拒绝 —— 只拒绝「本端自己那条」。
///      历史 bug：`if (peer.isLocal) return false;` 把另一台客户端也挡在门外，
///      于是「流转播放」里给别的客户端按推流箭头必然失败，而接回本机正常。
///   2. now-playing 必须有队列兜底 —— 服务端 `GET /peers/:id/queue` 的
///      `currentMedia` **只对 dlna / airplay / sendspin 填充**，`local` 恒为
///      undefined，只读它会让别的客户端那行永远显示「未在播放」。
///   3. 播放记录上报必须用 GET —— Subsonic 规范的 `/rest/scrobble` 是 GET 端点，
///      用 POST 会 404，播放历史静默丢失。
void main() {
  late MockSubsonicApiClient client;
  late TestPlayerNotifier playerNotifier;
  late ProviderContainer container;
  late CastPeerController controller;

  /// 所有 postRaw 的路径留痕（判断「有没有真的发出推送」）。
  final postedPaths = <String>[];

  Song song(String id) => Song(
        id: id,
        title: 't-$id',
        artist: 'a',
        albumId: 'al1',
        duration: 120,
      );

  setUp(() {
    postedPaths.clear();
    client = MockSubsonicApiClient();
    // 带一条非空队列：pushLocalToPeer 对空队列会提前 return false，
    // 那会掩盖「守卫一刀切」与「真的推了」的区别。
    playerNotifier = TestPlayerNotifier(
      PlayerState(queue: <Song>[song('s1'), song('s2')], currentIndex: 0),
    );
    container = ProviderContainer(
      overrides: <Override>[
        subsonicApiClientProvider.overrideWithValue(client),
        playerProvider.overrideWith((ref) => playerNotifier),
      ],
    );
    controller = container.read(castPeerControllerProvider.notifier);

    registerFallbackValue(<String, dynamic>{});
    registerFallbackValue(const Duration(seconds: 10));

    when(
      () => client.postRaw(
        any(),
        queryParameters: any(named: 'queryParameters'),
        data: any(named: 'data'),
        receiveTimeout: any(named: 'receiveTimeout'),
      ),
    ).thenAnswer((invocation) async {
      postedPaths.add(invocation.positionalArguments.first as String);
      return <String, dynamic>{'success': true};
    });
    when(
      () => client.getRaw(
        any(),
        queryParameters: any(named: 'queryParameters'),
        receiveTimeout: any(named: 'receiveTimeout'),
      ),
    ).thenAnswer((_) async => <String, dynamic>{});
    when(
      () => client.get(
        any(),
        queryParameters: any(named: 'queryParameters'),
        allowFallbackRetry: any(named: 'allowFallbackRetry'),
      ),
    ).thenAnswer((_) async => <String, dynamic>{});
    when(
      () => client.post(
        any(),
        queryParameters: any(named: 'queryParameters'),
        data: any(named: 'data'),
        allowFallbackRetry: any(named: 'allowFallbackRetry'),
      ),
    ).thenAnswer((_) async => <String, dynamic>{});
  });

  tearDown(() {
    controller.stopHeartbeat();
    container.dispose();
  });

  group('契约1: 推流不得按 kind 一刀切(客户端 → 客户端)', () {
    PeerInfo peer({
      required String id,
      required String kind,
      required bool self,
    }) =>
        PeerInfo(
          peerId: id,
          name: 'p-$id',
          kind: kind,
          available: true,
          self: self,
        );

    test('另一台客户端实例(local, self=false)必须真的发起推送', () async {
      final ok = await controller.pushLocalToPeer(
        peer(id: 'local:u:abc123', kind: 'local', self: false),
      );

      expect(ok, isTrue,
          reason: '另一台客户端是独立播放端,与 DLNA 同链路,不得被拒绝');
      expect(
        postedPaths.any((p) => p.contains('/queue/play') || p.contains('/v1/play')),
        isTrue,
        reason: '必须真的发出推送请求。若为空说明 pushLocalToPeer 被 '
            '「kind==local 一刀切」守卫短路了(2026-09-15 的历史 bug)',
      );
    });

    test('本端自己那条(local, self=true)应短路,不发出推送', () async {
      final ok = await controller.pushLocalToPeer(
        peer(id: 'local:u', kind: 'local', self: true),
      );

      expect(ok, isFalse, reason: '推给自己没有意义');
      expect(postedPaths, isEmpty, reason: '自己那条不应产生任何推送请求');
    });

    test('DLNA 设备仍照常推送(对照,防止测试本身写歪)', () async {
      final ok = await controller.pushLocalToPeer(
        peer(id: 'dlna:dev1', kind: 'dlna', self: false),
      );

      expect(ok, isTrue);
      expect(postedPaths.any((p) => p.contains('/queue/play')), isTrue);
    });
  });

  group('契约2: now-playing 必须有队列兜底(currentMedia 对 local 恒空)', () {
    Future<PeerNowPlaying?> fetchWith(Map<String, dynamic> body) async {
      when(
        () => client.getRaw(
          any(),
          queryParameters: any(named: 'queryParameters'),
          receiveTimeout: any(named: 'receiveTimeout'),
        ),
      ).thenAnswer((_) async => body);
      return controller.fetchPeerNowPlaying('local:u:abc123');
    }

    Map<String, dynamic> queueBody({
      Map<String, dynamic>? currentMedia,
      bool isActive = true,
    }) =>
        <String, dynamic>{
          'isActive': isActive,
          'currentIndex': 2,
          'total': 3,
          if (currentMedia != null) 'currentMedia': currentMedia,
          'items': <Map<String, dynamic>>[
            <String, dynamic>{'songId': 's0', 'title': 'T0', 'artist': 'A0'},
            <String, dynamic>{'songId': 's1', 'title': 'T1', 'artist': 'A1'},
            <String, dynamic>{'songId': 's2', 'title': 'T2', 'artist': 'A2'},
          ],
        };

    test('无 currentMedia 时按 items[currentIndex] 补全(客户端实例走这条路)',
        () async {
      final np = await fetchWith(queueBody());

      expect(np, isNotNull);
      expect(np!.title, 'T2',
          reason: 'local 的 currentMedia 恒为 undefined,'
              '只读它会让「流转播放」里别的客户端永远显示「未在播放」');
      expect(np.artist, 'A2');
      expect(np.currentIndex, 2);
    });

    test('有 currentMedia 时仍以设备侧实时值为准(设备型行为不变)', () async {
      final np = await fetchWith(
        queueBody(currentMedia: <String, dynamic>{
          'title': 'DEV-TITLE',
          'artist': 'DEV-ARTIST',
        }),
      );

      expect(np!.title, 'DEV-TITLE');
      expect(np.artist, 'DEV-ARTIST');
    });

    test('未起播(isActive=false)不做兜底,标题保持空', () async {
      final np = await fetchWith(queueBody(isActive: false));

      expect(np!.title, isEmpty, reason: '没在播放就不该凭队列项硬凑一个标题');
      expect(np.isActive, isFalse);
    });
  });

  group('契约3: 播放记录上报必须用 GET', () {
    test('scrobble 走 GET /rest/scrobble,不得退回 POST', () async {
      final ref = container.read(_refProbeProvider);
      final handler = FavoriteScrobbleHandler(ref);

      await handler.scrobble('s1', submission: true);

      verify(
        () => client.get(
          ApiConstants.scrobble,
          queryParameters: any(named: 'queryParameters'),
          allowFallbackRetry: any(named: 'allowFallbackRetry'),
        ),
      ).called(1);
      verifyNever(
        () => client.post(
          any(),
          queryParameters: any(named: 'queryParameters'),
          data: any(named: 'data'),
          allowFallbackRetry: any(named: 'allowFallbackRetry'),
        ),
      );
    });
  });
}

/// 只为在测试里拿到一个真实 `Ref`（FavoriteScrobbleHandler 的构造依赖）。
final _refProbeProvider = Provider<Ref>((ref) => ref);
