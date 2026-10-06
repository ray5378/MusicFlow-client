// b38b3 —— Route B：PeerRemoteControlNotifier 队列广播「遥控期陈旧回声」闸门补测。
//
// 覆盖 lcov 未命中行 155-161：本端正遥控远端时，到达的**无起播起点**的队列广播
// 属本机陈旧镜像回声，必须跳过，绝不能在本机强行起播（否则「遥控远端却本地出声」）。
//
// 产品代码零改动；仅新增 test/。

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:musicflow_client/providers/cast/peer_remote_control_provider.dart';
import 'package:musicflow_client/providers/player/player_provider.dart';

import '../../features/player/test_player_notifier.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late TestPlayerNotifier player;
  late ProviderContainer container;
  late PeerRemoteControlNotifier remote;

  setUp(() {
    player = TestPlayerNotifier(PlayerState());
    container = ProviderContainer(
      overrides: <Override>[
        playerProvider.overrideWith((ref) => player),
      ],
    );
    remote = container.read(peerRemoteControlProvider.notifier);
    remote.noteSelfPeerId('local-7');
  });

  tearDown(() {
    container.dispose();
  });

  test('遥控远端期间收到无起播起点的队列广播 → 跳过，不在本机起播', () async {
    remote.noteSelfRemoteControlling(true);

    await remote.handleServerMessage(<String, dynamic>{
      'type': 'peer_queue_changed',
      'peer_id': 'local-7',
      'queue': <String, dynamic>{
        'items': <Map<String, dynamic>>[
          <String, dynamic>{'id': 's1', 'title': 't'},
        ],
        'total': 1,
        'currentIndex': 0,
        'playMode': 'order',
      },
    });

    expect(
      player.state.queue,
      isEmpty,
      reason: '陈旧回声不得触发本机 playQueue 起播',
    );
    expect(player.state.currentSong, isNull);
  });

  test('非本端 peerId 的广播直接忽略', () async {
    remote.noteSelfRemoteControlling(true);

    await remote.handleServerMessage(<String, dynamic>{
      'type': 'peer_queue_changed',
      'peer_id': 'someone-else',
      'queue': <String, dynamic>{'items': <dynamic>[], 'total': 0},
    });

    expect(player.state.queue, isEmpty);
  });
}
