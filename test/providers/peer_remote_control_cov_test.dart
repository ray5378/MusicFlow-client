import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:musicflow_client/data/models/song.dart';
import 'package:musicflow_client/providers/api/api_provider.dart';
import 'package:musicflow_client/providers/cast/peer_remote_control_provider.dart';
import 'package:musicflow_client/providers/player/player_provider.dart';

import '../features/player/test_player_notifier.dart';
import '../helpers/mocks.dart';

/// 「被遥控」接收端单元测试(batest14 覆盖率缺口)。
///
/// 本机作为被遥控方时,服务端只推两类消息:`peer_command`(立即执行的传输指令)
/// 与 `peer_queue_changed`(权威队列变更 → 内容比对后跟随)。本文件把 PlayerNotifier
/// 换成可录调用的桩、把 SubsonicApiClient 换成可回放快照的桩,直接构造
/// [PeerRemoteControlNotifier] 打这两个入口,把状态迁移的每条分支跑一遍。
///
/// 桩说明:[_RecPlayerNotifier] 继承现成的 TestPlayerNotifier(补上 play /
/// playQueue / playSong / setVolume 四个 abstract 方法的录制),不构造真实音频引擎。
void main() {
  late MockSubsonicApiClient client;
  late _RecPlayerNotifier player;
  late ProviderContainer container;
  late PeerRemoteControlNotifier ctl;

  /// getRaw 被实际调用的 path(用来断言「什么时候该拉全队 / 拉了谁的队」)。
  final List<String> rawPaths = <String>[];

  /// 按 path 回放的假响应;不设 → 回 null(等价于服务端给了非法体)。
  Object? Function(String path)? rawResolver;

  setUp(() {
    rawPaths.clear();
    rawResolver = null;
    client = MockSubsonicApiClient();
    when(() => client.getRaw(any(), receiveTimeout: any(named: 'receiveTimeout')))
        .thenAnswer((invocation) async {
      final path = invocation.positionalArguments.first as String;
      rawPaths.add(path);
      final resolve = rawResolver;
      return resolve == null ? null : resolve(path);
    });
    player = _RecPlayerNotifier(PlayerState());
    container = ProviderContainer(
      overrides: <Override>[
        subsonicApiClientProvider.overrideWithValue(client),
        playerProvider.overrideWith((ref) => player),
      ],
    );
    // ProviderContainer 只实现 Ref<Object>,本文件要的是 Ref<Object?> —— 套一层转发。
    ctl = PeerRemoteControlNotifier(_ContainerRef(container));
  });

  tearDown(() {
    container.dispose();
  });

  // ==================== 构造辅助 ====================

  Song song(String id) => Song(
        id: id,
        title: id,
        artist: '歌手',
        albumId: 'al-$id',
        duration: 200,
      );

  Map<String, dynamic> item(String id) => <String, dynamic>{
        'songId': id,
        'title': id,
        'albumId': 'al-$id',
        'duration': 200,
      };

  /// 把本机镜像设成「指定的队列/游标/模式」。
  void localQueue(
    List<Song> songs, {
    int index = 0,
    PlaybackMode mode = PlaybackMode.all,
  }) {
    player.emit(
      PlayerState(
        queue: songs,
        currentIndex: index,
        playbackMode: mode,
        isPlaying: true,
      ),
    );
  }

  /// 服务端 `peer_queue_changed` 广播(与后端 QueueSnapshot 同形)。
  Map<String, dynamic> qMsg({
    String peerId = 'peer-a',
    List<Object?>? items,
    Object? total,
    Object? currentIndex = 0,
    Object? playMode = 'all',
    Object? startPosition,
  }) {
    final queue = <String, dynamic>{
      if (items != null) 'items': items,
      if (total != null) 'total': total,
      'currentIndex': currentIndex,
      if (playMode != null) 'playMode': playMode,
      if (startPosition != null) 'startPosition': startPosition,
    };
    return <String, dynamic>{
      'type': 'peer_queue_changed',
      'peer_id': peerId,
      'queue': queue,
    };
  }

  Map<String, dynamic> cmd(
    String action, {
    Object? payload,
  }) =>
      <String, dynamic>{
        'type': 'peer_command',
        'action': action,
        if (payload != null) 'payload': payload,
      };

  // ==================== 1. noteSelfPeerId：本端 peerId 绑定 ====================

  group('1. noteSelfPeerId 绑定本端 peerId', () {
    test('空串被忽略；未绑定前只忽略广播，绑定后只认该 peer', () async {
      ctl.noteSelfPeerId('');
      // 注:peer_command 不需要 peerId,但 queue_changed 必须等绑定。
      await ctl.handleServerMessage(qMsg(peerId: 'peer-a', items: <Object?>[item('s1')], total: 1));
      expect(player.calls, isEmpty, reason: '未注入 peerId → 不跟随任何队列广播');

      ctl.noteSelfPeerId('peer-a');
      ctl.noteSelfPeerId('peer-a'); // 同值重复调用应幂等(不会重新打日志刷屏)
      await ctl.handleServerMessage(qMsg(peerId: 'peer-a', items: <Object?>[item('s1')], total: 1));
      expect(player.calls, contains('playQueue'), reason: '绑定后同一 peer 的广播要跟随');

      await ctl.handleServerMessage(qMsg(peerId: 'peer-b', items: <Object?>[item('s1')], total: 1));
      expect(player.calls.length, 1, reason: '别人 peer 的广播不能打本机');
    });

    test('换 peerId 后旧值立即失效(同一广播不再命中)', () async {
      ctl.noteSelfPeerId('peer-a');
      await ctl.handleServerMessage(qMsg(peerId: 'peer-a', items: <Object?>[item('s1')], total: 1));
      final afterFirst = player.calls.length;
      expect(afterFirst, 1);

      ctl.noteSelfPeerId('peer-a-2');
      await ctl.handleServerMessage(
        qMsg(peerId: 'peer-a', items: <Object?>[item('s1')], total: 1),
      );
      expect(player.calls.length, afterFirst, reason: '旧 peerId 已作废');

      await ctl.handleServerMessage(
        qMsg(peerId: 'peer-a-2', items: <Object?>[item('s1')], total: 1),
      );
      expect(player.calls.length, afterFirst + 1, reason: '新 peerId 生效');
    });
  });

  // ==================== 2. peer_command：七种传输指令 ====================

  group('2. peer_command 传输指令', () {
    test('play / pause / stop 三种 action 各自落到正确的播放器方法', () async {
      await ctl.handleServerMessage(cmd('play'));
      expect(player.calls, <String>['play']);
      expect(ctl.state.lastAction, 'play');
      expect(ctl.state.lastAt, isNotNull);

      player.calls.clear();
      await ctl.handleServerMessage(cmd('pause'));
      expect(player.calls, <String>['pause']);
      await ctl.handleServerMessage(cmd('stop'));
      expect(player.calls, <String>['pause', 'pause'],
          reason: 'stop 与 pause 同义(只暂停,不清队列/不复位进度)');
      expect(player.clearCount, 0, reason: 'stop 不得清队列');
    });

    test('next / prev 落到 next()/previous()', () async {
      await ctl.handleServerMessage(cmd('next'));
      expect(player.nextCount, 1);
      await ctl.handleServerMessage(cmd('prev'));
      expect(player.previousCount, 1);
      expect(ctl.state.lastAction, 'prev');
    });

    test('seek 把 payload.seconds 换算成 Duration', () async {
      await ctl.handleServerMessage(cmd('seek', payload: <String, dynamic>{'seconds': 12}));
      expect(player.seeks, <Duration>[const Duration(seconds: 12)]);
      // 小数秒 → 毫秒取整
      await ctl.handleServerMessage(cmd('seek', payload: <String, dynamic>{'seconds': 12.5}));
      expect(
        player.seeks.last,
        const Duration(milliseconds: 12500),
        reason: '12.5s 必须无损成 12500ms(整数秒会吞掉 0.5s)',
      );
    });

    test('seek 缺 seconds / payload 非 Map → 静默丢弃', () async {
      await ctl.handleServerMessage(cmd('seek', payload: <String, dynamic>{}));
      await ctl.handleServerMessage(cmd('seek'));
      await ctl.handleServerMessage(cmd('seek', payload: 12345));
      expect(player.seeks, isEmpty);
      expect(ctl.state.lastAction, isNull, reason: '未落地的指令不该留下「已应用」留痕');
    });

    test('volume 把服务端 0-100 换算成本机 0..1 并夹紧', () async {
      await ctl.handleServerMessage(cmd('volume', payload: <String, dynamic>{'volume': 25}));
      expect(player.volumes, <double>[0.25]);
      await ctl.handleServerMessage(cmd('volume', payload: <String, dynamic>{'volume': 150}));
      expect(player.volumes.last, 1.0, reason: '越界必须夹到 1.0(写 1.5 会直接异常)');
      await ctl.handleServerMessage(cmd('volume', payload: <String, dynamic>{'volume': -50}));
      expect(player.volumes.last, 0.0, reason: '负值夹到 0.0');
    });

    test('volume 缺值 → 静默丢弃', () async {
      await ctl.handleServerMessage(cmd('volume', payload: <String, dynamic>{}));
      expect(player.volumes, isEmpty);
      expect(ctl.state.lastAction, isNull);
    });

    test('未知 action → 空转,不留痕', () async {
      await ctl.handleServerMessage(cmd('rewind'));
      await ctl.handleServerMessage(<String, dynamic>{'type': 'peer_command'});
      expect(player.calls, isEmpty);
      expect(ctl.state.lastAction, isNull);
    });

    test('其他 type → 直接返回', () async {
      await ctl.handleServerMessage(<String, dynamic>{'type': 'something_else'});
      await ctl.handleServerMessage(<String, dynamic>{'type': 'peer_command', 'action': 'play'});
      expect(player.calls, <String>['play']);
      expect(ctl.state.lastAction, 'play');
    });

    test('播放器抛错被 catch 吞掉,不留「已应用」假象', () async {
      player.throwOnPlay = true;
      await expectLater(
        ctl.handleServerMessage(cmd('play')),
        completes,
      );
      expect(player.calls, isEmpty);
      expect(ctl.state.lastAction, isNull, reason: '失败不等于应用过');
    });
  });

  // ==================== 3. peer_queue_changed 的投递过滤 ====================

  group('3. 队列广播过滤', () {
    test('peer_id 为空 → 忽略', () async {
      ctl.noteSelfPeerId('peer-a');
      await ctl.handleServerMessage(qMsg(peerId: '', items: <Object?>[item('s1')], total: 1));
      expect(player.calls, isEmpty);
    });

    test('queue 不是 Map → 忽略', () async {
      ctl.noteSelfPeerId('peer-a');
      await ctl.handleServerMessage(<String, dynamic>{
        'type': 'peer_queue_changed',
        'peer_id': 'peer-a',
        'queue': <Object>[],
      });
      expect(player.calls, isEmpty);
    });

    // ⚠️ [D-013] 已知缺陷(守卫用例):_startPositionOf 里的 `as num?` 是裸强转,
    // 服务端一旦给出非数值(如 startPosition: "12")就抛 TypeError,整条
    // handleServerMessage 的 Future 直接 reject(WS 转调处未必 catch)。
    // 现状断言:抛出。修好后应改为「解析不到就当没有起点」,本用例需翻转。
    test('畸形载荷(startPosition 非数值)会让整个 handler reject', () async {
      ctl.noteSelfPeerId('peer-a');
      localQueue(<Song>[song('s1')]);
      expect(
        ctl.handleServerMessage(
          qMsg(items: <Object?>[item('s1')], total: 1, startPosition: '12'),
        ),
        throwsA(isA<TypeError>()),
      );
      expect(player.calls, isEmpty, reason: '抛错发生在比对阶段,播放器一个动作都没做');
    });

    test('本机 queue 为空时,远端非空队列应被判定为差异并跟随', () async {
      ctl.noteSelfPeerId('peer-a');
      localQueue(const <Song>[]);
      await ctl.handleServerMessage(qMsg(items: <Object?>[item('s1')], total: 1));
      expect(player.playQueues.single.single.id, 's1');
    });
  });

  // ==================== 4. 内容比对：自回声跳过 vs 差异跟随 ====================

  group('4. 内容比对(自回声 / 差异)', () {
    test('完全一致 → 什么都不做', () async {
      ctl.noteSelfPeerId('peer-a');
      localQueue(<Song>[song('s1'), song('s2')]);
      await ctl.handleServerMessage(
        qMsg(items: <Object?>[item('s1'), item('s2')], total: 2, currentIndex: 0, playMode: 'all'),
      );
      expect(player.calls, isEmpty, reason: '自己上报造成的广播必须零动作(否则会反复起播)');
    });

    test('items 缺失(非 List)→ 保守不动作', () async {
      ctl.noteSelfPeerId('peer-a');
      localQueue(<Song>[song('s1')]);
      await ctl.handleServerMessage(qMsg(total: 1, playMode: 'all'));
      expect(player.calls, isEmpty);
    });

    test('摘要态(items 空)+ total/index/mode 全一致 → 跳过', () async {
      ctl.noteSelfPeerId('peer-a');
      localQueue(<Song>[song('s1'), song('s2')], index: 1, mode: PlaybackMode.shuffle);
      await ctl.handleServerMessage(
        qMsg(items: <Object?>[], total: 2, currentIndex: 1, playMode: 'shuffle'),
      );
      expect(player.calls, isEmpty);
    });

    test('摘要态 + 长度不一致 → 判定为外部改动,套外层并拉全队', () async {
      ctl.noteSelfPeerId('peer-a');
      localQueue(<Song>[song('s1')]);
      rawResolver = (_) => <String, dynamic>{
            'items': <Object?>[item('s1'), item('s2')],
            'currentIndex': 1,
          };
      await ctl.handleServerMessage(
        qMsg(items: <Object?>[], total: 50, currentIndex: 1, playMode: 'all'),
      );
      expect(rawPaths.single, endsWith('/peers/peer-a/queue'), reason: '长度对不上必须按本端 peerId 拉全队');
      expect(player.playQueues.single.map((s) => s.id), <String>['s1', 's2']);
      expect(player.playQueueStartIndexes, <int>[1]);
    });

    test('仅游标不同 → playSong 跳歌(不是整队重建)', () async {
      ctl.noteSelfPeerId('peer-a');
      localQueue(<Song>[song('s1'), song('s2')], index: 0);
      await ctl.handleServerMessage(
        qMsg(items: <Object?>[item('s1'), item('s2')], total: 2, currentIndex: 1, playMode: 'all'),
      );
      expect(player.calls, <String>['playSong']);
      expect(player.playSongTargets.single.id, 's2');
      expect(player.playSongIndexes, <int?>[1]);
      expect(player.playSongQueueLengths, <int?>[2], reason: '必须回传整队,否则队列会塌成一首');
      expect(player.playQueues, isEmpty, reason: '同一份歌单不能整队重建(会从头播)');
    });

    test('仅播放模式不同 → 只切模式,不动队列与游标', () async {
      ctl.noteSelfPeerId('peer-a');
      localQueue(<Song>[song('s1'), song('s2')], index: 0, mode: PlaybackMode.all);
      await ctl.handleServerMessage(
        qMsg(items: <Object?>[item('s1'), item('s2')], total: 2, currentIndex: 0, playMode: 'shuffle'),
      );
      expect(player.modeCalls, <PlaybackMode>[PlaybackMode.shuffle]);
      expect(player.calls, isEmpty, reason: '只切模式不该再播一次歌');
      expect(player.clearCount, 0);
    });

    test('带 startPosition 的快照一律判定为差异(即使三项全一致)', () async {
      ctl.noteSelfPeerId('peer-a');
      localQueue(<Song>[song('s1'), song('s2')], index: 0);
      await ctl.handleServerMessage(
        qMsg(
          items: <Object?>[item('s1'), item('s2')],
          total: 2,
          currentIndex: 0,
          playMode: 'all',
          startPosition: 42,
        ),
      );
      // 三项全一致 + 带起点 → 无处不不一致:走「只套外层」里的 seek 落位分支。
      expect(player.seeks, <Duration>[const Duration(seconds: 42)]);
      expect(player.calls, isEmpty, reason: '起点只 seek,不得重新起播');
      expect(ctl.state.lastAction, 'queue');
    });

    test('startPosition 为 0 / 负数 / 非有限值 → 视同「无起点」,不制造差异', () async {
      ctl.noteSelfPeerId('peer-a');
      localQueue(<Song>[song('s1'), song('s2')], index: 0);
      for (final bad in <num>[0, -5, double.infinity, double.nan]) {
        await ctl.handleServerMessage(
          qMsg(
            items: <Object?>[item('s1'), item('s2')],
            total: 2,
            currentIndex: 0,
            playMode: 'all',
            startPosition: bad,
          ),
        );
      }
      expect(player.calls, isEmpty, reason: '三项全一致 + 空起点 → 与「无起点」快照同形,按自回声跳过');
      expect(player.seeks, isEmpty, reason: '空起点不得触发 seek');
    });
  });

  // ==================== 5. _follow：四种落点 ====================

  group('5. _follow 队列落点', () {
    test('远端换歌单 → playQueue(整队 + startIndex + 起点)', () async {
      ctl.noteSelfPeerId('peer-a');
      localQueue(<Song>[song('s1'), song('s2')], index: 1);
      await ctl.handleServerMessage(
        qMsg(
          items: <Object?>[item('x'), item('y'), item('z')],
          total: 3,
          currentIndex: 2,
          playMode: 'one',
          startPosition: 7.5,
        ),
      );
      expect(player.playQueues.single.map((s) => s.id), <String>['x', 'y', 'z']);
      expect(player.playQueueStartIndexes, <int>[2]);
      expect(player.playQueuePositions, <Duration?>[const Duration(milliseconds: 7500)]);
      expect(player.modeCalls, <PlaybackMode>[PlaybackMode.one], reason: '整队起播后照常套权威模式');
      expect(ctl.state.lastAction, 'queue');
    });

    test('currentIndex 越界被夹到队尾', () async {
      ctl.noteSelfPeerId('peer-a');
      localQueue(<Song>[song('s1')]);
      await ctl.handleServerMessage(
        qMsg(items: <Object?>[item('x'), item('y')], total: 2, currentIndex: 99),
      );
      expect(player.playQueueStartIndexes, <int>[1]);
    });

    test('items 混有非 Map 条目 → 只取合法条目', () async {
      ctl.noteSelfPeerId('peer-a');
      localQueue(<Song>[song('s1')]);
      await ctl.handleServerMessage(
        qMsg(items: <Object?>['oops', item('x'), null, item('y')], total: 2, currentIndex: 0),
      );
      expect(player.playQueues.single.map((s) => s.id), <String>['x', 'y']);
    });

    test('items 全是非 Map → 视作远端清空 → clearQueue(keepCurrent:false)', () async {
      ctl.noteSelfPeerId('peer-a');
      localQueue(<Song>[song('s1'), song('s2')], index: 1);
      await ctl.handleServerMessage(qMsg(items: <Object?>['oops'], total: 1, currentIndex: 0));
      expect(player.clearKeepCurrent, <int>[0], reason: '远端清空必须全清,不能留当前歌');
      expect(rawPaths, isEmpty, reason: '清空不需要拉全队');
    });

    test('摘要态 + total==0 → 不套外层,直接全清', () async {
      ctl.noteSelfPeerId('peer-a');
      localQueue(<Song>[song('s1')], mode: PlaybackMode.all);
      await ctl.handleServerMessage(
        qMsg(items: <Object?>[], total: 0, currentIndex: 0, playMode: 'shuffle'),
      );
      expect(player.clearKeepCurrent, <int>[0]);
      expect(player.clearCount, 1);
    });
  });

  // ==================== 6. _adoptRemoteQueue：摘要态按需拉全队 ====================

  group('6. 摘要态按需拉全队', () {
    test('拉回来的快照带起点与模式 → playQueue + setPlaybackMode', () async {
      ctl.noteSelfPeerId('p 1/a');
      localQueue(<Song>[song('s1')]);
      rawResolver = (_) => <String, dynamic>{
            'items': <Object?>[item('x')],
            'currentIndex': 0,
            'startPosition': 3,
          };
      await ctl.handleServerMessage(
        qMsg(peerId: 'p 1/a', items: <Object?>[], total: 9, currentIndex: 0, playMode: 'order'),
      );
      expect(rawPaths.single, '/rest/api/v1/peers/p%201%2Fa/queue', reason: 'peerId 必须转义后进 path');
      expect(player.playQueues.single.single.id, 'x');
      expect(player.playQueuePositions, <Duration?>[const Duration(seconds: 3)]);
      expect(player.modeCalls, <PlaybackMode>[PlaybackMode.order]);
      expect(ctl.state.lastAction, 'queue');
    });

    test('同一条广播被投递两次 → 只拉一趟(在途去重)', () async {
      ctl.noteSelfPeerId('peer-a');
      localQueue(<Song>[song('s1')]);
      final gate = Completer<void>();
      rawResolver = (_) async {
        await gate.future;
        return <String, dynamic>{'items': <Object?>[item('x'), item('y')]};
      };
      final a = ctl.handleServerMessage(qMsg(items: <Object?>[], total: 9, playMode: 'all'));
      final b = ctl.handleServerMessage(qMsg(items: <Object?>[], total: 4, playMode: 'all'));
      await Future<void>.delayed(Duration.zero);
      expect(rawPaths, hasLength(1), reason: '两条广播不能拉两趟 MB 级队列');
      gate.complete();
      await Future.wait(<Future<void>>[a, b]);
      expect(player.playQueues.single.map((s) => s.id), <String>['x', 'y']);
    });

    test('快照不是 Map / items 为空 → 不接管,也不留痕', () async {
      ctl.noteSelfPeerId('peer-a');
      localQueue(<Song>[song('s1')]);
      rawResolver = (_) => <Object?>['not', 'a', 'map'];
      await ctl.handleServerMessage(qMsg(items: <Object?>[], total: 9, playMode: 'all'));
      expect(player.playQueues, isEmpty);
      expect(ctl.state.lastAction, isNull);

      rawResolver = (_) => <String, dynamic>{'items': <Object?>[]};
      await ctl.handleServerMessage(qMsg(items: <Object?>[], total: 9, playMode: 'all'));
      expect(player.playQueues, isEmpty);
      expect(rawPaths.length, 2);
    });

    test('拉取抛错被吞掉,且解锁后可再次拉取', () async {
      ctl.noteSelfPeerId('peer-a');
      localQueue(<Song>[song('s1')]);
      var tries = 0;
      rawResolver = (_) {
        tries += 1;
        if (tries == 1) throw StateError('network down');
        return <String, dynamic>{'items': <Object?>[item('x')]};
      };
      await expectLater(
        ctl.handleServerMessage(qMsg(items: <Object?>[], total: 9, playMode: 'all')),
        completes,
      );
      expect(player.playQueues, isEmpty, reason: '失败不能留下「已接管」的假象');

      await ctl.handleServerMessage(qMsg(items: <Object?>[], total: 9, playMode: 'all'));
      expect(player.playQueues.single.single.id, 'x', reason: 'in-flight 标记必须复位');
    });
  });

  // ==================== 7. _applyOuterFields：只套外层 ====================

  group('7. 外层字段套用', () {
    test('同曲同游标 + 带起点 → seek 落位(不重播)', () async {
      ctl.noteSelfPeerId('peer-a');
      localQueue(<Song>[song('s1'), song('s2')], index: 1);
      await ctl.handleServerMessage(
        qMsg(
          items: <Object?>[item('s1'), item('s2')],
          total: 2,
          currentIndex: 1,
          playMode: 'all',
          startPosition: 30,
        ),
      );
      expect(player.seeks, <Duration>[const Duration(seconds: 30)]);
      expect(player.calls, isEmpty, reason: '流转带过来的起点只 seek,不得重新起播');
      expect(ctl.state.lastAction, 'queue');
    });

    test('游标跳转 → playSong 带整队与起点', () async {
      ctl.noteSelfPeerId('peer-a');
      localQueue(<Song>[song('s1'), song('s2')], index: 0);
      await ctl.handleServerMessage(
        qMsg(
          items: <Object?>[item('s1'), item('s2')],
          total: 2,
          currentIndex: 1,
          playMode: 'all',
          startPosition: 11,
        ),
      );
      expect(player.playSongTargets.single.id, 's2');
      expect(player.playSongQueueLengths, <int?>[2]);
      expect(player.playSongIndexes, <int?>[1]);
      expect(player.playSongPositions, <Duration?>[const Duration(seconds: 11)]);
    });

    test('total 与本机长度不一致 → 只套模式,不动游标', () async {
      ctl.noteSelfPeerId('peer-a');
      localQueue(<Song>[song('s1'), song('s2')], index: 0, mode: PlaybackMode.all);
      await ctl.handleServerMessage(
        qMsg(items: <Object?>[item('s1'), item('s2')], total: 99, currentIndex: 1, playMode: 'one'),
      );
      expect(player.modeCalls, <PlaybackMode>[PlaybackMode.one]);
      expect(player.calls, isEmpty, reason: '长度对不上说明换了整份队列,游标不可信 → 不动');
    });

    test('index 越出本机队列 → 不动', () async {
      ctl.noteSelfPeerId('peer-a');
      localQueue(<Song>[song('s1'), song('s2')], index: 0);
      await ctl.handleServerMessage(
        qMsg(items: <Object?>[item('s1'), item('s2')], total: 2, currentIndex: 77, playMode: 'all'),
      );
      expect(player.calls, isEmpty);
    });

    test('index<0 / 与本机游标相同(无起点) → 不动', () async {
      ctl.noteSelfPeerId('peer-a');
      localQueue(<Song>[song('s1'), song('s2')], index: 0);
      await ctl.handleServerMessage(
        qMsg(items: <Object?>[item('s1'), item('s2')], total: 2, currentIndex: -1, playMode: 'all'),
      );
      await ctl.handleServerMessage(
        qMsg(items: <Object?>[item('s1'), item('s2')], total: 2, currentIndex: 0, playMode: 'all'),
      );
      expect(player.calls, isEmpty);
      expect(player.playSongTargets, isEmpty);
      expect(player.seeks, isEmpty);
    });
  });

  // ==================== 8. 播放模式映射 ====================

  group('9. provider 装配', () {
    test('peerRemoteControlProvider 投出同一个接收端,可直接收消息并留痕', () async {
      final viaProvider = container.read(peerRemoteControlProvider.notifier);
      expect(viaProvider, isA<PeerRemoteControlNotifier>());
      expect(identical(viaProvider, container.read(peerRemoteControlProvider.notifier)), isTrue,
          reason: '接收端必须是单例,否则每次 WS 转发都会丢状态');

      viaProvider.noteSelfPeerId('peer-a');
      localQueue(<Song>[song('s1'), song('s2')]);
      await viaProvider.handleServerMessage(
        qMsg(items: <Object?>[item('s1'), item('s2')], total: 2, currentIndex: 1),
      );
      expect(player.playSongTargets.single.id, 's2');
      expect(container.read(peerRemoteControlProvider).lastAction, 'queue');
      expect(container.read(peerRemoteControlProvider).lastAt, isNotNull);
    });
  });

  group('8. 播放模式映射', () {
    for (final pair in <MapEntry<String, PlaybackMode>>[
      const MapEntry<String, PlaybackMode>('order', PlaybackMode.order),
      const MapEntry<String, PlaybackMode>('all', PlaybackMode.all),
      const MapEntry<String, PlaybackMode>('one', PlaybackMode.one),
      const MapEntry<String, PlaybackMode>('shuffle', PlaybackMode.shuffle),
    ]) {
      test("服务端 '${pair.key}' → 本地 ${pair.value.name}", () async {
        ctl.noteSelfPeerId('peer-a');
        // 本机先摆一个**不同**的模式,保证每条映射都真的要下发一次。
        localQueue(
          <Song>[song('s1')],
          mode: pair.value == PlaybackMode.order ? PlaybackMode.all : PlaybackMode.order,
        );
        await ctl.handleServerMessage(qMsg(items: <Object?>[item('s1')], total: 1, playMode: pair.key));
        expect(player.modeCalls, <PlaybackMode>[pair.value]);
      });
    }

    test('模式未知 / 缺省 → 不套用', () async {
      ctl.noteSelfPeerId('peer-a');
      localQueue(<Song>[song('s1')], mode: PlaybackMode.all);
      await ctl.handleServerMessage(qMsg(items: <Object?>[item('s1')], total: 1, playMode: 'repeatAll'));
      await ctl.handleServerMessage(qMsg(items: <Object?>[item('s1')], total: 1, playMode: null));
      expect(player.modeCalls, isEmpty);
    });

    test('模式与本机一致 → 不重复下发', () async {
      ctl.noteSelfPeerId('peer-a');
      localQueue(<Song>[song('s1')], mode: PlaybackMode.shuffle);
      await ctl.handleServerMessage(qMsg(items: <Object?>[item('s1')], total: 1, playMode: 'shuffle'));
      expect(player.modeCalls, isEmpty);
      expect(player.calls, isEmpty, reason: '模式没变 → 整条广播应被自回声跳过');
    });
  });
}

/// 把 ProviderContainer 适配成 `Ref<Object?>`，供纯容器测试驱动
/// [PeerRemoteControlNotifier](内部只调 `ref.read`)。
class _ContainerRef implements Ref<Object?> {
  _ContainerRef(this.container);

  @override
  final ProviderContainer container;

  @override
  T read<T>(ProviderListenable<T> provider) => container.read(provider);

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('_ContainerRef.${invocation.memberName}');
}

/// 可录调用的播放器桩:在 TestPlayerNotifier 之上补 play / playQueue /
/// playSong / setVolume / setPlaybackMode / clearQueue 的录制。
class _RecPlayerNotifier extends TestPlayerNotifier {
  _RecPlayerNotifier(super.state);

  final List<String> calls = <String>[];
  final List<Duration> seeks = <Duration>[];
  final List<double> volumes = <double>[];
  final List<List<Song>> playQueues = <List<Song>>[];
  final List<int> playQueueStartIndexes = <int>[];
  final List<Duration?> playQueuePositions = <Duration?>[];
  final List<Song> playSongTargets = <Song>[];
  final List<int?> playSongIndexes = <int?>[];
  final List<int?> playSongQueueLengths = <int?>[];
  final List<Duration?> playSongPositions = <Duration?>[];
  final List<int> clearKeepCurrent = <int>[];
  final List<PlaybackMode> modeCalls = <PlaybackMode>[];

  /// 置 true 时 play() 抛错(覆盖 _handleCommand 的 catch 分支)。
  bool throwOnPlay = false;

  @override
  Future<void> play() async {
    if (throwOnPlay) throw StateError('simulated audio failure');
    calls.add('play');
  }

  @override
  Future<void> pause() async {
    calls.add('pause');
    await super.pause();
  }

  @override
  Future<void> seek(Duration position) async {
    seeks.add(position);
    await super.seek(position);
  }

  @override
  Future<void> playQueue(
    List<Song> songs, {
    int startIndex = 0,
    bool shuffleRandomStart = false,
    Duration? initialPosition,
  }) async {
    calls.add('playQueue');
    playQueues.add(songs);
    playQueueStartIndexes.add(startIndex);
    playQueuePositions.add(initialPosition);
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
    calls.add('playSong');
    playSongTargets.add(song);
    playSongIndexes.add(index);
    playSongQueueLengths.add(queue?.length);
    playSongPositions.add(initialPosition);
  }

  @override
  Future<void> setVolume(double volume) async {
    calls.add('setVolume');
    volumes.add(volume);
  }

  @override
  Future<void> setPlaybackMode(PlaybackMode mode, {bool persist = true}) async {
    modeCalls.add(mode);
    await super.setPlaybackMode(mode);
  }

  @override
  Future<void> clearQueue({bool keepCurrent = true}) async {
    calls.add('clearQueue');
    clearKeepCurrent.add(keepCurrent ? 1 : 0);
    await super.clearQueue(keepCurrent: keepCurrent);
  }
}

