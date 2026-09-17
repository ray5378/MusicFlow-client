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

/// 源端「彻底重置」契约 —— 流转播放「拖 A→B」与回收站「销毁 A」的收尾动作。
///
/// 背景(用户实测反馈):原先对源端只做 `POST /stop` + `DELETE /queue`,这两步
/// 都只清**队列实体**,服务端的运行态各留各的 —— A 队列虽空,`GET /status`
/// 仍把它报成「在播某一首」(local 端尤其明显:状态上报是字段级合并,客户端
/// 停止时不发 songId,上一首就永远挂着)。
///
/// 现统一走 `POST /peers/:id/reset`,一次做完「停止 + 清队列 + 清运行态」:
///   - 旧服务端没有该端点 → **降级**回 stop + DELETE /queue,不比现状更差;
///   - 保留 peer 注册与 playMode —— 故这里只断言「重置」,不涉及注销。
void main() {
  late MockSubsonicApiClient client;
  late TestPlayerNotifier playerNotifier;
  late ProviderContainer container;
  late CastPeerController controller;

  /// 所有 postRaw 的 (path) 留痕。
  final posts = <String>[];

  /// 所有 deleteRaw 的 (path) 留痕。
  final deletes = <String>[];

  /// 置 true 模拟「旧服务端」:`/reset` 抛异常(404 无此端点)。
  var resetUnsupported = false;

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
    deletes.clear();
    resetUnsupported = false;
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
          ? <String, dynamic>{
              'state': 'PLAYING',
              'position': 1,
              'duration': 200,
            }
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
      final path = invocation.positionalArguments.first as String;
      posts.add(path);
      // 模拟旧服务端:没有 /reset 这个端点。
      if (path.endsWith('/reset') && resetUnsupported) {
        throw Exception('404 Not Found');
      }
      return <String, dynamic>{'success': true};
    });
    when(
      () => client.deleteRaw(
        any(),
        queryParameters: any(named: 'queryParameters'),
      ),
    ).thenAnswer((invocation) async {
      deletes.add(invocation.positionalArguments.first as String);
      return <String, dynamic>{'success': true};
    });
  });

  tearDown(() {
    controller.stopHeartbeat();
    container.dispose();
  });

  bool posted(String needle) => posts.any((p) => p.contains(needle));
  bool deleted(String needle) => deletes.any((p) => p.contains(needle));
  String srcPath(PeerInfo p) => Uri.encodeComponent(p.peerId);

  test('远端→远端流转:源端走 /reset 彻底重置,不再只 stop', () async {
    final ok = await controller.transferQueue(remoteA, remoteB);
    expect(ok, isTrue);

    expect(
      posts.any((p) => p.contains(srcPath(remoteA)) && p.endsWith('/reset')),
      isTrue,
      reason:
          '搬移语义:搬完源端要彻底重置(停止 + 清队列 + 清服务端运行态)。'
          '只 stop 会留下运行态,源端虽空仍被 GET /status 报成「在播」',
    );
  });

  test('回收站销毁远端:走 /reset,不是只 stop', () async {
    final ok = await controller.destroyPeer(remoteB);
    expect(ok, isTrue);

    expect(
      posts.any((p) => p.contains(srcPath(remoteB)) && p.endsWith('/reset')),
      isTrue,
      reason: '销毁 = 彻底重置该端,与流转的源端收尾同一口径',
    );
  });

  test('旧服务端无 /reset:降级回 stop + DELETE /queue,不静默失败', () async {
    resetUnsupported = true;

    final ok = await controller.transferQueue(remoteA, remoteB);
    expect(ok, isTrue, reason: '降级不应让流转本身失败');

    expect(
      posts.any((p) => p.contains(srcPath(remoteA)) && p.endsWith('/stop')),
      isTrue,
      reason: '旧服务端没有 /reset,必须退回 stop —— 不能什么都不做',
    );
    expect(deleted('/queue'), isTrue, reason: '降级路径仍要清掉源端服务端队列');
  });

  test('旧服务端无 /reset 且 stop 也失败:销毁记失败,但仍尽力清队列', () async {
    resetUnsupported = true;
    when(
      () => client.postRaw(
        any(),
        queryParameters: any(named: 'queryParameters'),
        data: any(named: 'data'),
        receiveTimeout: any(named: 'receiveTimeout'),
      ),
    ).thenAnswer((invocation) async {
      final path = invocation.positionalArguments.first as String;
      posts.add(path);
      if (path.endsWith('/reset') || path.endsWith('/stop')) {
        throw Exception('boom');
      }
      return <String, dynamic>{'success': true};
    });

    final ok = await controller.destroyPeer(remoteB);
    expect(ok, isFalse, reason: '停止失败 = 销毁失败,与原先口径一致');
    expect(
      deleted('/queue'),
      isTrue,
      reason: '清空队列永远 best-effort,不因 stop 失败而跳过',
    );
  });

  test('销毁本机:抛弃内存会话 + 重置服务端,两者都做', () async {
    final ok = await controller.destroyPeer(selfPeer);
    expect(ok, isTrue);

    expect(
      playerNotifier.clearCount,
      greaterThan(0),
      reason: '本机做源端必须停掉音频并清空内存队列(mini 播放器才不留残影)',
    );
    expect(
      playerNotifier.state.queue,
      isEmpty,
      reason: 'keepCurrent: false —— 当前曲一并清掉',
    );
    expect(
      playerNotifier.state.currentSong,
      isNull,
      reason: '当前曲必须真的清掉：只清队列会留下孤儿（迷你条还显示歌名、点播放还能续播）',
    );
    expect(
      posts.any((p) => p.contains(srcPath(selfPeer)) && p.endsWith('/reset')),
      isTrue,
      reason: '服务端那一份权威队列与状态上报同样要清',
    );
  });
}
