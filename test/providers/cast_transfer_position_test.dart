import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart' hide PlayerState;
import 'package:mocktail/mocktail.dart';
import 'package:musicflow_client/data/models/peer.dart';
import 'package:musicflow_client/data/models/song.dart';
import 'package:musicflow_client/providers/api/api_provider.dart';
import 'package:musicflow_client/providers/cast/cast_peer_provider.dart';
import 'package:musicflow_client/providers/player/player_provider.dart';
import 'package:musicflow_client/providers/player/queue_origin_provider.dart';

import '../features/player/test_player_notifier.dart';
import '../helpers/mocks.dart';

/// 流转播放的**进度对齐**契约 —— 队列 + 当前曲 + **此刻进度**一起搬。
///
/// 用户口径（2026-09-26）：「流转播放后出声的状态要是秒级对齐流转前的状态」。
/// 三条路径各有各的落点，任何一条漏带进度，用户听到的就是「从头播」：
///
///   1. 本机 → 远端：`/v1/play`（主通道）或 `/queue/play`（兜底）的 body 带
///      `position`（秒），服务端起播后自行 seek；
///   2. 远端 → 本机：先读源端 `/status` 的**实时**进度（必须在停设备之前读），
///      再经 playSong 的 `initialPosition` 落位；读不到就退化为从头播（不得抛）。
///
/// 远端 → 远端不在本文件覆盖：服务端自读源端进度，客户端一个字节都不上传。
void main() {
  late MockSubsonicApiClient client;
  late _RecordingNotifier playerNotifier;
  late ProviderContainer container;
  late CastPeerController controller;

  final posts = <({String path, Object? data})>[];
  double statusPosition = 0;
  bool statusFails = false;

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
  const dlnaPeer = PeerInfo(
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

  void emitLocal({required Duration position, String? playlistId}) {
    playerNotifier.emit(
      PlayerState(
        currentSong: song,
        queue: <Song>[song],
        currentIndex: 0,
        position: position,
        loopMode: LoopMode.all,
      ),
    );
    if (playlistId != null) {
      container.read(queueOriginProvider.notifier).state =
          QueueOrigin(QueueOriginKind.playlist, playlistId);
    }
  }

  setUp(() {
    posts.clear();
    statusPosition = 0;
    statusFails = false;
    client = MockSubsonicApiClient();
    playerNotifier = _RecordingNotifier(
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
      if (path.endsWith('/status')) {
        if (statusFails) throw Exception('device offline');
        return <String, dynamic>{
          'state': 'PLAYING',
          'position': statusPosition,
          'duration': 200,
        };
      }
      return queueSnapshot();
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

  Map<String, dynamic>? bodyOf(String needle) {
    for (final p in posts) {
      if (p.path.contains(needle)) return p.data as Map<String, dynamic>?;
    }
    return null;
  }

  group('本机 → 远端：起播请求必须带上本机此刻的进度', () {
    test('主通道 /v1/play：body 带 position', () async {
      emitLocal(position: const Duration(seconds: 42), playlistId: 'pl-1');

      final ok = await controller.pushLocalToPeer(dlnaPeer);

      expect(ok, isTrue);
      final body = bodyOf('/rest/api/v1/play');
      expect(body, isNotNull, reason: '源自歌单 → 走主通道');
      expect(body!['position'], 42.0,
          reason: '本机此刻 42s —— 目标端必须从 42s 起，而不是 0s');
    });

    test('兜底整队 /queue/play：body 也带 position', () async {
      // 不登记 queueOrigin → 主通道无从解析，回落整队推送。
      emitLocal(position: const Duration(seconds: 42));

      final ok = await controller.pushLocalToPeer(dlnaPeer);

      expect(ok, isTrue);
      final body = bodyOf('/queue/play');
      expect(body, isNotNull, reason: '来源不可解析时必须走整队推送');
      expect(body!['position'], 42.0,
          reason: '兜底通道同样要带进度，否则「有来源」与「没来源」两种歌单手感不一致');
    });

    test('本机在 0 秒：不带 position（不制造无意义的 target=0）', () async {
      emitLocal(position: Duration.zero, playlistId: 'pl-1');

      final ok = await controller.pushLocalToPeer(dlnaPeer);

      expect(ok, isTrue);
      final body = bodyOf('/rest/api/v1/play');
      expect(body, isNotNull);
      expect(body!.containsKey('position'), isFalse,
          reason: '从头播就是既有行为，不必额外下发 position=0');
    });
  });

  group('远端 → 本机：读源端实时进度并落位', () {
    test('源端 37s → 本机 playSong 带 initialPosition=37s', () async {
      statusPosition = 37;

      final ok = await controller.transferQueue(dlnaPeer, selfPeer);

      expect(ok, isTrue);
      expect(playerNotifier.playSongCalls, hasLength(1));
      expect(playerNotifier.playSongCalls.single.songId, 's1');
      expect(playerNotifier.playSongCalls.single.initialPosition,
          const Duration(seconds: 37),
          reason: '必须落到源端此刻的进度上 —— 这是「秒级对齐」的客户端落点');
    });

    test('读不到源端进度（设备掉线 / 旧服务端）→ 退化为从头播，且不抛', () async {
      statusFails = true;

      final ok = await controller.transferQueue(dlnaPeer, selfPeer);

      expect(ok, isTrue, reason: '进度读不到不该让整个流转失败');
      expect(playerNotifier.playSongCalls, hasLength(1));
      expect(playerNotifier.playSongCalls.single.initialPosition, isNull,
          reason: '没有读数就按从头播（与改动前行为一致），不能瞎猜');
    });

    test('源端 0s → initialPosition 为 0（真实读数，不是「读不到」）', () async {
      statusPosition = 0;

      final ok = await controller.transferQueue(dlnaPeer, selfPeer);

      expect(ok, isTrue);
      expect(playerNotifier.playSongCalls.single.initialPosition, Duration.zero,
          reason: '0 是读到的真实位置，与「读失败(null)」语义不同；'
              'playSong 内部对 0 本就不下发 pendingSeek，所以行为等价');
    });
  });
}

/// 记录 `playSong` 的起播入参（流转进度对齐的唯一可观测落点）。
class _RecordingNotifier extends TestPlayerNotifier {
  _RecordingNotifier(super.state);

  final List<({String songId, Duration? initialPosition})> playSongCalls =
      <({String songId, Duration? initialPosition})>[];

  @override
  Future<void> playSong(
    Song song, {
    List<Song>? queue,
    int? index,
    bool recordShuffleHistory = false,
    bool clearShuffleForwardHistory = false,
    bool autoPlay = true,
    Duration? initialPosition,
  }) async {
    playSongCalls.add((songId: song.id, initialPosition: initialPosition));
    state = state.copyWith(
      currentSong: song,
      queue: queue ?? state.queue,
      currentIndex: index ?? state.currentIndex,
      position: initialPosition ?? Duration.zero,
      isPlaying: autoPlay,
    );
  }
}
