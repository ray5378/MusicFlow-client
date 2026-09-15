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

/// 遥控**远端客户端实例**时的进度守卫(2026-09-16)。
///
/// 与 HA 卡片 v2.4.1 修的是同一个 bug:客户端实例的 `position` 是**周期性上报的
/// 采样**(实测约 4s 一次),采样时刻由 `/status` 的 `reportedAt` 给出。本端 2s 轮询
/// 却把采样值当「此刻」直接写进 `smoothPositionSeconds`,于是每两轮就把本地已在推进
/// 的时钟(250/500ms tick)**拽回**旧值 —— 表现为进度条 / 歌词「前进一段又回退」
/// (回退幅度 = 一个上报周期,约 2~4s,不是固定 2s)。
///
/// 这里锁定的契约:
///   1. 播放中 + 有 reportedAt → 必须外推到此刻;
///   2. 无 reportedAt(设备型 peer 走实时查询) → 原样,**绝不外推**;
///   3. 暂停 → 不外推(否则暂停态会漂移);
///   4. 本端刚 seek 过 → 丢弃「seek 之前采样」的上报(否则进度条被拽回 seek 之前)。
/// 第 2 条同时是**边界**:保证设备型链路(DLNA/AirPlay/Sendspin/群组)行为完全不变。
void main() {
  late MockSubsonicApiClient client;
  late TestPlayerNotifier playerNotifier;
  late ProviderContainer container;
  late CastPeerController controller;

  // 另一台客户端实例(非 self,才会进入「遥控远端」而非「回本机」分支)。
  final remotePeer = PeerInfo(
    peerId: 'local:u:abc123',
    name: 'HomePC',
    kind: 'local',
    available: true,
    self: false,
    platform: 'windows',
  );

  final song = Song(
    id: 's1',
    title: '远端曲',
    artist: '歌手',
    albumId: 'al1',
    duration: 200,
  );

  String statusPath(String peerId) => '/rest/api/v1/peers/$peerId/status';
  String queuePath(String peerId) => '/rest/api/v1/peers/$peerId/queue';

  Map<String, dynamic> statusBody({
    String state = 'PLAYING',
    double position = 10,
    double duration = 200,
    int? reportedAt,
  }) =>
      <String, dynamic>{
        'state': state,
        'position': position,
        'duration': duration,
        if (reportedAt != null) 'reportedAt': reportedAt,
      };

  Map<String, dynamic> queueSnapshot() => <String, dynamic>{
        'currentIndex': 0,
        'total': 1,
        'playMode': 'all',
        'shuffleOrder': <int>[],
        'shufflePos': -1,
        'items': <Map<String, dynamic>>[
          <String, dynamic>{
            'songId': 's1',
            'title': '远端曲',
            'artist': '歌手',
            'albumId': 'al1',
            'duration': 200,
          },
        ],
      };

  /// 当前 /status 的桩响应(测试中可替换)。
  Map<String, dynamic> _statusBody = <String, dynamic>{};

  /// 按**路径后缀**分流:peerId 经 `Uri.encodeComponent` 后 `:` 变 `%3A`,
  /// 精确匹配易对不上,这里只认 `/status` 与 `/queue` 结尾。
  void stubAll() {
    when(
      () => client.getRaw(
        any(),
        queryParameters: any(named: 'queryParameters'),
        receiveTimeout: any(named: 'receiveTimeout'),
      ),
    ).thenAnswer((invocation) async {
      final path = invocation.positionalArguments.first as String;
      return path.endsWith('/status') ? _statusBody : queueSnapshot();
    });
  }

  void stubStatus(Map<String, dynamic> body) => _statusBody = body;

  setUp(() {
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
    stubAll();
  });

  tearDown(() {
    controller.stopHeartbeat();
    container.dispose();
  });

  /// 切到远端客户端实例(建立投屏态 + 启动轮询)。
  Future<void> switchToRemote() => controller.switchTo(remotePeer);

  group('远端客户端实例进度外推', () {
    test('播放中 + 有 reportedAt:外推到此刻(采样值 + 已过去的时间)', () async {
      stubStatus(statusBody(
        position: 10,
        // 采样发生在 3s 前 → 此刻应约为 13。
        reportedAt: DateTime.now().millisecondsSinceEpoch - 3000,
      ));
      await switchToRemote();

      await controller.pollOnce();

      expect(
        controller.state.smoothPositionSeconds,
        closeTo(13.0, 0.6),
        reason: '客户端实例的 position 是周期上报的采样,必须按 reportedAt 外推;'
            '直接写采样值(10)会让进度条/歌词每两轮回退一次',
      );
    });

    test('无 reportedAt(设备型 peer):原样返回,绝不外推', () async {
      // DLNA / AirPlay / Sendspin / 群组的 status 走实时查询,没有 reportedAt。
      stubStatus(statusBody(position: 10));
      await switchToRemote();

      await controller.pollOnce();

      expect(
        controller.state.smoothPositionSeconds,
        10.0,
        reason: '设备型链路不受影响:没有采样时刻就不该外推,否则凭空多出几秒',
      );
    });

    test('暂停时保持上报值,不外推', () async {
      // 先播一轮,建立 _lastPollPosition 基线。
      stubStatus(statusBody(
        position: 10,
        reportedAt: DateTime.now().millisecondsSinceEpoch - 3000,
      ));
      await switchToRemote();
      await controller.pollOnce();

      // 同一 position(不满足「前进」自愈条件)+ PAUSED → 不外推。
      stubStatus(statusBody(
        state: 'PAUSED_PLAYBACK',
        position: 10,
        reportedAt: DateTime.now().millisecondsSinceEpoch - 3000,
      ));
      await controller.pollOnce();

      expect(
        controller.state.smoothPositionSeconds,
        10.0,
        reason: '暂停态外推会让进度条自己往前跑',
      );
    });
  });

  group('seek 后丢弃陈旧采样', () {
    test('本端刚 seek 过:不采纳 seek 之前采样的上报', () async {
      when(
        () => client.postRaw(
          any(),
          queryParameters: any(named: 'queryParameters'),
          data: any(named: 'data'),
          receiveTimeout: any(named: 'receiveTimeout'),
        ),
      ).thenAnswer((_) async => <String, dynamic>{'success': true});

      stubStatus(statusBody(
        position: 10,
        reportedAt: DateTime.now().millisecondsSinceEpoch - 1000,
      ));
      await switchToRemote();
      await controller.pollOnce();

      // 拖到 60s;远端此刻上报的仍是**旧位置**(要等它下一个上报周期)。
      await controller.seek(const Duration(seconds: 60));
      // 补一次轮询:stub 的采样时刻早于本次 seek → 必须被丢弃。
      stubStatus(statusBody(
        position: 10,
        reportedAt: DateTime.now().millisecondsSinceEpoch - 5000,
      ));
      await controller.pollOnce();

      expect(
        controller.state.smoothPositionSeconds,
        60.0,
        reason: '采纳 seek 之前的采样会把刚拖好的进度条拽回 seek 之前'
            '(与 HA 卡片 _seekIssuedAt 同款)',
      );
    });
  });
}
