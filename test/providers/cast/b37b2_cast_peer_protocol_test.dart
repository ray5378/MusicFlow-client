// b37b2 —— `lib/providers/cast/cast_peer_provider.dart` 协议细节补测。
//
// b35b / cast_peer_cov / reset 已覆盖大量分支；本文件补：
//   * pullPeerToLocal：源端 /status 进度可读 → 本机按同进度接续（playSong 带
//     initialPosition）；源端进度非法（负数）→ initialPosition 为 null 仍成功；
//   * 传输命令影子（_applyTransportShadow）：投屏态 pause 后，滞后的 PLAYING 采样
//     不得把播放态顶回去；
//   * pushLocalToPeer：「另一台客户端」（kind=local 但 self=false）不再被一刀切挡下。
// 产品代码零改动；仅新增 test/。

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:musicflow_client/data/models/peer.dart';
import 'package:musicflow_client/data/models/song.dart';
import 'package:musicflow_client/providers/api/api_provider.dart';
import 'package:musicflow_client/providers/cast/cast_peer_provider.dart';
import 'package:musicflow_client/providers/player/player_provider.dart';

import '../../helpers/mocks.dart';
import '../../features/player/test_player_notifier.dart';

class _RecPlayer extends TestPlayerNotifier {
  _RecPlayer(super.state);

  final List<Duration?> playSongPositions = <Duration?>[];

  @override
  bool get isRestoringPlaybackSession => false;

  @override
  Future<void> pause() async {
    state = state.copyWith(isPlaying: false);
  }

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
    playSongPositions.add(initialPosition);
    state = state.copyWith(
      currentSong: song,
      queue: queue ?? state.queue,
      currentIndex: index ?? state.currentIndex,
    );
  }
}

class _Req {
  _Req(this.method, this.path);

  final String method;
  final String path;

  @override
  String toString() => '$method $path';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MockSubsonicApiClient client;
  late _RecPlayer player;
  late ProviderContainer container;
  late CastPeerController ctrl;
  late List<_Req> reqs;
  Object? Function(String method, String path)? onCall;

  const remotePeer = PeerInfo(
    peerId: 'dlna-9',
    name: '书房音箱',
    kind: 'dlna',
    available: true,
  );

  final song = Song(
    id: 's1',
    title: '测试曲',
    artist: '歌手',
    albumId: 'al1',
    duration: 200,
  );

  Map<String, dynamic> defaultCall(String method, String path) {
    if (path.endsWith('/register')) {
      return <String, dynamic>{
        'peer': <String, dynamic>{'peerId': 'local-7'},
      };
    }
    if (path.endsWith('/heartbeat')) return <String, dynamic>{};
    if (path.endsWith('/local-status')) return <String, dynamic>{};
    if (path.endsWith('/status')) {
      return <String, dynamic>{
        'state': 'PLAYING',
        'position': 1.0,
        'duration': 10.0,
      };
    }
    if (path.endsWith('/reset')) return <String, dynamic>{'success': true};
    if (path.endsWith('/peers')) return <String, dynamic>{'peers': <dynamic>[]};
    if (path.endsWith('/sleep-timer')) return <String, dynamic>{'active': false};
    if (path.endsWith('/queue/play')) return <String, dynamic>{'success': true};
    if (path.endsWith('/play-mode')) return <String, dynamic>{'success': true};
    if (path.endsWith('/stop')) return <String, dynamic>{'success': true};
    if (path.endsWith('/queue')) {
      return <String, dynamic>{
        'items': <Map<String, dynamic>>[],
        'currentIndex': 0,
        'total': 0,
      };
    }
    return <String, dynamic>{};
  }

  Object? route(String method, String path) {
    reqs.add(_Req(method, path));
    final h = onCall;
    if (h != null) return h(method, path);
    return defaultCall(method, path);
  }

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    reqs = <_Req>[];
    onCall = null;
    client = MockSubsonicApiClient();
    player = _RecPlayer(PlayerState());
    container = ProviderContainer(
      overrides: <Override>[
        subsonicApiClientProvider.overrideWithValue(client),
        playerProvider.overrideWith((ref) => player),
      ],
    );
    ctrl = container.read(castPeerControllerProvider.notifier);

    when(() => client.postRaw(any())).thenAnswer((inv) async {
      return route('post', inv.positionalArguments[0] as String)
          as Map<String, dynamic>;
    });
    when(() => client.postRaw(
          any(),
          data: any(named: 'data'),
          receiveTimeout: any(named: 'receiveTimeout'),
        )).thenAnswer((inv) async {
      return route('post', inv.positionalArguments[0] as String)
          as Map<String, dynamic>;
    });
    when(() => client.getRaw(any())).thenAnswer((inv) async {
      return route('get', inv.positionalArguments[0] as String)
          as Map<String, dynamic>;
    });
    when(() => client.getRaw(
          any(),
          queryParameters: any(named: 'queryParameters'),
          receiveTimeout: any(named: 'receiveTimeout'),
        )).thenAnswer((inv) async {
      return route('get', inv.positionalArguments[0] as String)
          as Map<String, dynamic>;
    });
    when(() => client.deleteRaw(any())).thenAnswer((inv) async {
      return route('delete', inv.positionalArguments[0] as String)
          as Map<String, dynamic>;
    });
  });

  tearDown(() async {
    try {
      ctrl.stopHeartbeat();
    } catch (_) {}
    await Future<void>.delayed(const Duration(milliseconds: 10));
    container.dispose();
    await Future<void>.delayed(const Duration(milliseconds: 10));
  });

  test('pullPeerToLocal：源端进度可读 → 本机按同进度接续 + 重置源端', () async {
    onCall = (method, path) {
      if (path.endsWith('/queue') && method == 'get') {
        return <String, dynamic>{
          'items': <Map<String, dynamic>>[songToQueueItem(song)],
          'currentIndex': 0,
          'total': 1,
        };
      }
      if (path.endsWith('/status')) {
        return <String, dynamic>{
          'state': 'PLAYING',
          'position': 12.5,
          'duration': 200.0,
        };
      }
      return defaultCall(method, path);
    };

    expect(await ctrl.pullPeerToLocal(remotePeer), isTrue);
    expect(
      player.playSongPositions.single,
      const Duration(milliseconds: 12500),
      reason: '本机应从源端此刻的 12.5s 接续',
    );
    expect(reqs.any((r) => r.path.endsWith('/reset')), isTrue,
        reason: '搬完后彻底重置源端（/reset）');
  });

  test('pullPeerToLocal：源端进度非法（负数）→ initialPosition 为 null 仍成功', () async {
    onCall = (method, path) {
      if (path.endsWith('/queue') && method == 'get') {
        return <String, dynamic>{
          'items': <Map<String, dynamic>>[songToQueueItem(song)],
          'currentIndex': 0,
          'total': 1,
        };
      }
      if (path.endsWith('/status')) {
        return <String, dynamic>{
          'state': 'PLAYING',
          'position': -5.0,
          'duration': 200.0,
        };
      }
      return defaultCall(method, path);
    };

    expect(await ctrl.pullPeerToLocal(remotePeer), isTrue);
    expect(player.playSongPositions.single, isNull,
        reason: '非法进度 → 退化为从这首歌开头接续');
  });

  test('传输影子：pause 后滞后的 PLAYING 采样不得把播放态顶回去', () async {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    onCall = (method, path) {
      if (path.endsWith('/status')) {
        // reportedAt 明显早于 pause 命令 → 该采样不含本次命令结果。
        return <String, dynamic>{
          'state': 'PLAYING',
          'position': 5.0,
          'duration': 300.0,
          'reportedAt': nowMs - 5000,
        };
      }
      if (path.endsWith('/queue') && method == 'get') {
        return <String, dynamic>{
          'items': <Map<String, dynamic>>[songToQueueItem(song)],
          'currentIndex': 0,
          'total': 1,
        };
      }
      return defaultCall(method, path);
    };

    await ctrl.switchTo(remotePeer);
    // switchTo 内部首拍 tick 是 unawaited，等它落地。
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(ctrl.state.status.playing, isTrue);

    await ctrl.pause();
    await Future<void>.delayed(const Duration(milliseconds: 300));

    expect(ctrl.state.status.playing, isFalse,
        reason: '传输命令保护窗口内，滞后上报不应把暂停改回播放');
  });

  test('pushLocalToPeer：另一台客户端（local 但 self=false）不再被挡下', () async {
    const otherClient = PeerInfo(
      peerId: 'local-2',
      name: '另一台客户端',
      kind: 'local',
      available: true,
    );
    player.emit(PlayerState(
      queue: <Song>[song],
      currentIndex: 0,
      currentSong: song,
    ));

    expect(await ctrl.pushLocalToPeer(otherClient), isTrue);
    expect(
      reqs.any((r) => r.path.endsWith('/queue/play')),
      isTrue,
      reason: '推到非自身的本机播放端应走整队推送',
    );
  });
}
