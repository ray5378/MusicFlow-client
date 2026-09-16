import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:musicflow_client/data/models/peer.dart';
import 'package:musicflow_client/data/models/song.dart';
import 'package:musicflow_client/providers/api/api_provider.dart';
import 'package:musicflow_client/providers/cast/cast_peer_provider.dart';
import 'package:musicflow_client/providers/player/player_provider.dart';

import '../features/player/test_player_notifier.dart';
import '../helpers/mocks.dart';

/// `transferQueue` 的路由守卫 —— 快捷区"拖拽流转队列"的落地动作。
///
/// 用户口径：**音乐可以随时在不同播放端之间流转**（任意两端，不限于本机）。
/// 三条路由各有归属，走错就会静默降级成另一个语义或直接失败：
///   1. 本机 → 远端：复用 pushLocalToPeer（主通道 /v1/play，本机队列来源可解析）；
///   2. 远端 → 本机：复用 pullPeerToLocal（搬回本机 just_audio 播）；
///   3. 远端 → 远端：`POST /peers/:to/queue/transfer-from { from }` ——
///      服务端内部搬队列（**不收 items**），搬完源端停止。
/// 同一端拖到自己身上必须短路（不发任何请求）。
void main() {
  late MockSubsonicApiClient client;
  late TestPlayerNotifier playerNotifier;
  late ProviderContainer container;
  late CastPeerController controller;

  /// 所有 postRaw 的 (path, data) 留痕。
  final posts = <({String path, Object? data})>[];

  final song = Song(
    id: 's1',
    title: '本机曲',
    artist: '歌手',
    albumId: 'al1',
    duration: 200,
  );

  const selfPeer = PeerInfo(
    peerId: 'local:u',
    name: '本机',
    kind: 'local',
    available: true,
    self: true,
  );
  const remoteA = PeerInfo(
    peerId: 'local:u:aaaaaa000001',
    name: 'HomePC',
    kind: 'local',
    available: true,
    platform: 'windows',
  );
  const remoteB = PeerInfo(
    peerId: 'dlna:dev-bbbbbb',
    name: '主卧',
    kind: 'dlna',
    available: true,
  );

  Map<String, dynamic> queueSnapshot() => <String, dynamic>{
        'currentIndex': 0,
        'total': 1,
        'playMode': 'all',
        'shuffleOrder': <int>[],
        'shufflePos': -1,
        'items': <Map<String, dynamic>>[
          <String, dynamic>{
            'songId': 's1',
            'title': '本机曲',
            'artist': '歌手',
            'mime': 'audio/mpeg',
            'duration': 200,
          },
        ],
      };

  setUp(() {
    posts.clear();
    client = MockSubsonicApiClient();
    playerNotifier = TestPlayerNotifier(
      PlayerState(currentSong: song, queue: <Song>[song], currentIndex: 0),
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
      () => client.getRaw(
        any(),
        queryParameters: any(named: 'queryParameters'),
        receiveTimeout: any(named: 'receiveTimeout'),
      ),
    ).thenAnswer((invocation) async {
      final path = invocation.positionalArguments.first as String;
      return path.endsWith('/status')
          ? <String, dynamic>{'state': 'PLAYING', 'position': 1, 'duration': 200}
          : queueSnapshot();
    });
    when(
      () => client.postRaw(
        any(),
        queryParameters: any(named: 'queryParameters'),
        data: any(named: 'data'),
        receiveTimeout: any(named: 'receiveTimeout'),
      ),
    ).thenAnswer((invocation) async {
      posts.add((
        path: invocation.positionalArguments.first as String,
        data: invocation.namedArguments[#data],
      ));
      return <String, dynamic>{'success': true};
    });
  });

  tearDown(() {
    controller.stopHeartbeat();
    container.dispose();
  });

  bool sentAny(String needle) => posts.any((p) => p.path.contains(needle));

  test('本机 → 远端：走既有推送链路，不得误用 transfer-from', () async {
    await controller.transferQueue(selfPeer, remoteA);

    expect(sentAny('transfer-from'), isFalse,
        reason: '本机作为源端的队列来源可解析，应走主通道/整队推送，而不是服务端搬运');
    expect(
      sentAny('/queue/play') || sentAny('/v1/play'),
      isTrue,
      reason: '必须真的把本机队列推给目标端',
    );
  });

  test('远端 → 本机：走既有接回链路，不得误用 transfer-from', () async {
    await controller.transferQueue(remoteA, selfPeer);

    expect(sentAny('transfer-from'), isFalse,
        reason: '搬到本机要由客户端 just_audio 接手，服务端搬运无法让它出声');
  });

  test('远端 → 远端：调用服务端 transfer-from，并让源端彻底重置', () async {
    final ok = await controller.transferQueue(remoteA, remoteB);

    expect(ok, isTrue);
    final transfer = posts.where((p) => p.path.contains('transfer-from')).toList();
    expect(transfer, hasLength(1), reason: '远端→远端必须走服务端搬运端点');
    expect(transfer.first.path, contains(Uri.encodeComponent(remoteB.peerId)));
    expect((transfer.first.data as Map)['from'], remoteA.peerId,
        reason: '必须把源端 id 交给服务端；服务端据此自取队列（客户端不上传 items）');
    expect((transfer.first.data as Map).containsKey('items'), isFalse,
        reason: '队列实体在服务端，客户端**不得**上传 items —— 这是零上传设计的红线');
    expect(
      posts.any((p) =>
          p.path.contains(Uri.encodeComponent(remoteA.peerId)) &&
          p.path.endsWith('/reset')),
      isTrue,
      reason: '搬移语义：搬完源端**彻底重置**（停止 + 清队列 + 清服务端运行态）。'
          '不再只 stop —— 只 stop 会留下运行态，源端队列虽空仍被 GET /status '
          '报成「在播某一首」',
    );
  });

  test('同一端拖到自己身上：短路，不发任何请求', () async {
    final ok = await controller.transferQueue(remoteA, remoteA);

    expect(ok, isFalse);
    expect(posts, isEmpty, reason: '自己搬自己没有意义，也不该产生任何副作用');
  });
}
