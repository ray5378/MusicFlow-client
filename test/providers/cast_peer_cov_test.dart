// batch15 覆盖率补齐：`lib/providers/cast/cast_peer_provider.dart`（投屏/流转播放主控制器）。
//
// 第一批专门打**既有 cast_peer_provider_test.dart 没碰到的分支**：本地状态上报、
// 本机队列镜像、各类失败日志分支、定时暂停、群组、流转搬运、seek 护栏、
// 轮询失败退避/offline、以及 _advanceSmooth 插值。
//
// 打桩：MockSubsonicApiClient（全部 /rest/api/v1/peers* 网络调用）+ 一个会**录调用**
// 的 TestPlayerNotifier 子类（基类不录 pause/seek/playSong，见文末踩坑 #20）。
import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart' show LoopMode;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:musicflow_client/data/models/peer.dart';
import 'package:musicflow_client/data/models/song.dart';
import 'package:musicflow_client/providers/api/api_provider.dart';
import 'package:musicflow_client/providers/cast/cast_peer_provider.dart';
import 'package:musicflow_client/providers/player/player_provider.dart';

import '../features/player/test_player_notifier.dart';
import '../helpers/mocks.dart';

/// 会录调用的播放器桩：基类 `TestPlayerNotifier` 的 pause/seek/playSong 等只改状态、
/// 不记调用，这里全部重写并记账，断言才不会「期望 1 次实际 0 次」。
class _RecPlayer extends TestPlayerNotifier {
  _RecPlayer(super.state);

  final List<String> calls = <String>[];
  final List<Duration> seeks = <Duration>[];
  final List<Song> playSongs = <Song>[];
  int syncCalls = 0;
  int restoreCalls = 0;
  int? lastSyncIndex;
  int? clearKeepCurrent;
  Duration? lastRestorePosition;

  /// 让 [playSong] 抛错，用来模拟「本机起播失败」。
  bool throwOnPlaySong = false;

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
  Future<void> togglePlayPause() async {
    calls.add('toggle');
    await super.togglePlayPause();
  }

  @override
  Future<void> next() async {
    calls.add('next');
    await super.next();
  }

  @override
  Future<void> previous() async {
    calls.add('previous');
    await super.previous();
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
    playSongs.add(song);
    if (throwOnPlaySong) throw StateError('simulated play failure');
  }

  @override
  Future<void> clearQueue({bool keepCurrent = true}) async {
    calls.add('clearQueue');
    clearKeepCurrent = keepCurrent ? 1 : 0;
    await super.clearQueue(keepCurrent: keepCurrent);
  }

  @override
  void restoreStateForCast({
    required List<Song> queue,
    required int currentIndex,
    required Song? currentSong,
    required Duration position,
    required LoopMode loopMode,
    required bool shuffleEnabled,
    required bool isPlaying,
  }) {
    calls.add('restore');
    restoreCalls += 1;
    lastRestorePosition = position;
  }

  @override
  void syncQueueForCast(List<Map<String, dynamic>> items, int index) {
    calls.add('sync');
    syncCalls += 1;
    lastSyncIndex = index;
  }
}

/// 一次网络调用（捕获用例断言用）。
class _Req {
  _Req(this.method, this.path, this.data);

  final String method;
  final String path;
  final Map<String, dynamic>? data;

  @override
  String toString() => '$method $path $data';
}

void main() {
  late MockSubsonicApiClient client;
  late _RecPlayer player;
  late ProviderContainer container;
  late CastPeerController ctrl;
  // 每例给 **新 list**（不是 clear()）：上一例 unawaited 的 register/heartbeat/
  // local-status 会迟到打到下一例，共享 list 会把邻例请求算到本例头上。
  late List<_Req> reqs;

  /// 网络响应分发：用例按需覆盖（抛错即让对应 Future reject）。
  Object? Function(
    String method,
    String path,
    Map<String, dynamic>? data,
    Map<String, dynamic>? query,
  )? onCall;

  /// `/status` 响应附加覆盖（在 [defaultCall] 的兜底返回里以 `...?statusOverride`
  /// 展开），用来造「带/不带 reportedAt 的周期上报」采样。
  Map<String, dynamic>? statusOverride;

  const dlnaPeer = PeerInfo(
    peerId: 'dlna-1',
    name: '客厅音箱',
    kind: 'dlna',
    available: true,
  );
  const otherPeer = PeerInfo(
    peerId: 'dlna-2',
    name: '卧室音箱',
    kind: 'dlna',
    available: true,
  );
  const selfLocal = PeerInfo(
    peerId: 'local-7',
    name: '本机',
    kind: 'local',
    available: true,
    self: true,
  );
  final song = Song(
    id: 's1',
    title: '测试曲',
    artist: '歌手',
    albumId: 'al1',
    duration: 200,
  );
  final song2 = Song(
    id: 's2',
    title: '第二曲',
    artist: '歌手',
    albumId: 'al1',
    duration: 180,
  );

  Map<String, dynamic> item([String id = 's1']) => <String, dynamic>{
        'songId': id,
        'title': '测试曲',
        'artist': '歌手',
        'albumId': 'al1',
        'duration': 200,
        'coverArt': 'so-$id',
      };

  Map<String, dynamic> snap({
    int currentIndex = 0,
    List<Map<String, dynamic>>? items,
    String playMode = 'all',
  }) =>
      <String, dynamic>{
        'currentIndex': currentIndex,
        'total': items?.length ?? 1,
        'playMode': playMode,
        'shuffleOrder': <int>[0, 1],
        'shufflePos': 0,
        'isActive': true,
        'items': items ?? <Map<String, dynamic>>[item()],
      };

  PlayerState localState({
    List<Song> queue = const <Song>[],
    int index = 0,
    Song? currentSong,
    bool isPlaying = false,
    Duration position = Duration.zero,
  }) =>
      PlayerState(
        queue: queue,
        currentIndex: index,
        currentSong: currentSong,
        isPlaying: isPlaying,
        position: position,
        duration: const Duration(seconds: 200),
        volume: 0.4,
        playbackMode: PlaybackMode.all,
      );

  Object? defaultCall(
    String method,
    String path,
    Map<String, dynamic>? data,
    Map<String, dynamic>? query,
  ) {
    if (path.endsWith('/register')) {
      return <String, dynamic>{'peer': <String, dynamic>{'peerId': 'local-7'}};
    }
    if (path.endsWith('/heartbeat')) return <String, dynamic>{};
    if (path.endsWith('/local-status')) return <String, dynamic>{};
    if (path.endsWith('/status')) {
      return <String, dynamic>{
        'state': 'PLAYING',
        'position': 1.0,
        'duration': 10.0,
        ...?statusOverride,
      };
    }
    if (path.endsWith('/reset')) return <String, dynamic>{'success': true};
    if (path.endsWith('/peers')) {
      return <String, dynamic>{
        'peers': <Map<String, dynamic>>[
          <String, dynamic>{'peerId': 'dlna-1', 'name': '客厅音箱', 'kind': 'dlna'},
          <String, dynamic>{'peerId': 'local-7', 'name': '我的客户端', 'kind': 'local'},
        ],
      };
    }
    if (path.endsWith('/groups')) {
      return <String, dynamic>{'groups': <dynamic>[<String, dynamic>{'id': 'g1'}]};
    }
    if (path.endsWith('/sleep-timer')) return <String, dynamic>{'active': false};
    if (path.endsWith('/play')) return <String, dynamic>{'success': true};
    if (path.endsWith('/queue')) return snap();
    if (path.endsWith('/transfer-from')) return <String, dynamic>{'success': true};
    return <String, dynamic>{};
  }

  /// 唯一的网络分发点：记录请求 → 交给用例 [onCall] 覆盖 或 [defaultCall] 兜底。
  /// ⚠️ 下面的 mocktail 桩必须 `return return ...)`（当返回值用），不能只当副作用
  /// 调用后自己 `return <String, dynamic>{}` —— 否则所有响应恒为 {}，注册拿不到
  /// peerId、队列拿不到 currentIndex，整批用例会连带变红（踩坑 #21）。
  Object? route(
    String method,
    String path,
    Map<String, dynamic>? data,
    Map<String, dynamic>? query,
  ) {
    reqs.add(_Req(method, path, data));
    if (onCall != null) return onCall!(method, path, data, query);
    return defaultCall(method, path, data, query);
  }

  setUp(() {
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

    // 先给「默认返回」兜底，再把带命名参的重载登记在后面（mocktail 后注册者优先）。
    // ⚠️ 每个桩都必须 `return route(...)`:route() 的返回值就是伪造的 HTTP 响应。
    // 只当副作用调用（写一行 `route(...); return <String, dynamic>{};`）会让所有
    // 响应恒为 {} —— 注册拿不到 peerId、队列拿不到 currentIndex,整批用例连带变红。
    when(() => client.postRaw(any())).thenAnswer((inv) async {
      return route('post', inv.positionalArguments[0] as String,
          inv.namedArguments[#data] as Map<String, dynamic>?, null)
          as Map<String, dynamic>;
    });
    when(() => client.postRaw(
          any(),
          data: any(named: 'data'),
          receiveTimeout: any(named: 'receiveTimeout'),
        )).thenAnswer((inv) async {
      return route('post', inv.positionalArguments[0] as String,
          inv.namedArguments[#data] as Map<String, dynamic>?, null)
          as Map<String, dynamic>;
    });
    when(() => client.getRaw(any())).thenAnswer((inv) async {
      return route('get', inv.positionalArguments[0] as String, null, null)
          as Map<String, dynamic>;
    });
    when(() => client.getRaw(
          any(),
          queryParameters: any(named: 'queryParameters'),
          receiveTimeout: any(named: 'receiveTimeout'),
        )).thenAnswer((inv) async {
      return route('get', inv.positionalArguments[0] as String, null,
          inv.namedArguments[#queryParameters] as Map<String, dynamic>?)
          as Map<String, dynamic>;
    });
    when(() => client.deleteRaw(any())).thenAnswer((inv) async {
      return route('delete', inv.positionalArguments[0] as String, null, null)
          as Map<String, dynamic>;
    });
  });

  tearDown(() async {
    // 先停心跳（cancel 定时器），再排空仍在飞的 unawaited 异步，最后 dispose。
    try {
      ctrl.stopHeartbeat();
    } catch (_) {}
    await Future<void>.delayed(const Duration(milliseconds: 10));
    container.dispose();
    await Future<void>.delayed(const Duration(milliseconds: 10));
  });

  List<_Req> postsMatching(String tail) =>
      reqs.where((r) => r.method == 'post' && r.path.endsWith(tail)).toList();
  List<_Req> callsMatching(String tail) =>
      reqs.where((r) => r.path.endsWith(tail)).toList();

  // ==================== 一、注册 / 心跳 / 本机状态上报 ====================

  test('registerAndHeartbeat 注册成功并暴露 localPeerId（含设备名片）', () async {
    await ctrl.registerAndHeartbeat();

    expect(ctrl.localPeerId, 'local-7'); // 覆盖 getter 行
    final reg = reqs.firstWhere((r) => r.path.endsWith('/register'));
    expect(reg.data!['name'], '');
    expect(reg.data!['platform'], isNotEmpty);
  });

  test('注册返回空的 peerId 时 localPeerId 保持 null', () async {
    onCall = (m, p, d, q) => <String, dynamic>{'peer': <String, dynamic>{'peerId': ''}};

    await ctrl.registerAndHeartbeat();

    expect(ctrl.localPeerId, isNull);
  });

  test('注册两次都失败时吞掉异常、不影响调用方', () async {
    var tries = 0;
    onCall = (m, p, d, q) {
      tries += 1;
      throw StateError('register boom $tries');
    };

    await expectLater(ctrl.registerAndHeartbeat(), completes); // 内部 900ms 重试一次
    expect(tries, 2);
    expect(ctrl.localPeerId, isNull);
  });

  test('心跳失败被吞（不抛、不改状态）', () async {
    onCall = (m, p, d, q) {
      if (p.endsWith('/heartbeat')) throw StateError('hb boom');
      return defaultCall(m, p, d, q);
    };
    await ctrl.registerAndHeartbeat();
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(reqs.any((r) => r.path.endsWith('/heartbeat')), isTrue);
    expect(ctrl.localPeerId, 'local-7');
  });

  test('未注册时心跳回调补注册（fake async 推进 30s）', () {
    fakeAsync((async) {
      onCall = (m, p, d, q) =>
          p.endsWith('/register') ? <String, dynamic>{} : defaultCall(m, p, d, q);
      // 先让注册失败（拿不到 peerId），再推进一个心跳周期。
      ctrl.startHeartbeat();
      async.elapse(const Duration(seconds: 31));
      async.flushMicrotasks();
      expect(ctrl.localPeerId, isNull);
    });
  });

  test('本机在播时上报 PLAYING 并带 songId', () async {
    await ctrl.registerAndHeartbeat();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    reqs.clear();

    player.emit(localState(queue: <Song>[song], currentSong: song, isPlaying: true));
    // emit 会触发 controller 的队列/状态监听（内部是 debounce Timer），
    // 本端队列镜像是 **600ms debounce**（见源码 _watchLocalQueue），等满 700ms 才算
// 把这一拍排干净，否则回调会落到下一例去（踩坑 #23）。
    await Future<void>.delayed(const Duration(milliseconds: 700));
    await Future<void>.delayed(const Duration(milliseconds: 20));

    final pushed = callsMatching('/local-status');
    expect(pushed, hasLength(1));
    expect(pushed.single.data!['state'], 'PLAYING');
    expect(pushed.single.data!['songId'], 's1');
    expect(pushed.single.data!['volume'], 40); // 0.4 * 100
  });

  test('投屏中上报 STOPPED 且位置归零（不冒充在播）', () async {
    await ctrl.registerAndHeartbeat();
    await ctrl.switchTo(dlnaPeer);
    reqs.clear();

    player.emit(localState(queue: <Song>[song], currentSong: song, isPlaying: true));
    // emit 会触发 controller 的队列/状态监听（内部是 debounce Timer），
    // 本端队列镜像是 **600ms debounce**（见源码 _watchLocalQueue），等满 700ms 才算
// 把这一拍排干净，否则回调会落到下一例去（踩坑 #23）。
    await Future<void>.delayed(const Duration(milliseconds: 700));
    await Future<void>.delayed(const Duration(milliseconds: 20));

    final pushed = callsMatching('/local-status');
    expect(pushed, isNotEmpty);
    expect(pushed.last.data!['state'], 'STOPPED');
    expect(pushed.last.data!['position'], 0.0);
    expect(pushed.last.data!.containsKey('songId'), isFalse);
  });

  test('stopHeartbeat 之后再推进 3 个心跳周期也不再上报（fake async）', () {
    fakeAsync((async) {
      unawaited(ctrl.registerAndHeartbeat());
      async.flushMicrotasks();

      // startHeartbeat 会立即发一拍，随后 timer 每 30s 一拍。
      async.elapse(const Duration(seconds: 31));
      async.flushMicrotasks();
      expect(callsMatching('/heartbeat'), isNotEmpty);

      ctrl.stopHeartbeat();
      async.elapse(const Duration(seconds: 95));
      async.flushMicrotasks();

      // 已发的两拍 = 启动立即那 1 拍 + 第一个 30s 周期那 1 拍；
      // stopHeartbeat 之后再推进 95s，这 3 个周期必须一个都不再发。
      expect(callsMatching('/heartbeat'), hasLength(2));
    });
  });

  // ==================== 二、本机队列镜像 ====================

  test('syncLocalQueueNow 未注册时直接返回（不推队列）', () async {
    await ctrl.syncLocalQueueNow();
    expect(callsMatching('/queue/play'), isEmpty);
  });

  test('syncLocalQueueNow 在投屏态下不写本机队列', () async {
    await ctrl.registerAndHeartbeat();
    await ctrl.switchTo(dlnaPeer);
    reqs.clear();

    await ctrl.syncLocalQueueNow();
    expect(callsMatching('/queue/play'), isEmpty);
  });

  test('syncLocalQueueNow 推整队 + 随后补发 play-mode', () async {
    await ctrl.registerAndHeartbeat();
    player.emit(localState(queue: <Song>[song, song2], currentSong: song));
    // emit 会触发 controller 的队列/状态监听（内部是 debounce Timer），
    // 本端队列镜像是 **600ms debounce**（见源码 _watchLocalQueue），等满 700ms 才算
// 把这一拍排干净，否则回调会落到下一例去（踩坑 #23）。
    await Future<void>.delayed(const Duration(milliseconds: 700));
    reqs.clear();

    await ctrl.syncLocalQueueNow();

    expect(postsMatching('/queue/play'), hasLength(1));
    final body = postsMatching('/queue/play').single.data!;
    expect(body['items'], hasLength(2));
    expect(body['startIndex'], 0);
    expect(postsMatching('/play-mode'), hasLength(1));
    expect(postsMatching('/play-mode').single.data!['mode'], 'all');
  });

  test('本机队列镜像失败被吞（不抛）', () async {
    await ctrl.registerAndHeartbeat();
    player.emit(localState(queue: <Song>[song]));
    // emit 会触发 controller 的队列/状态监听（内部是 debounce Timer），
    // 本端队列镜像是 **600ms debounce**（见源码 _watchLocalQueue），等满 700ms 才算
// 把这一拍排干净，否则回调会落到下一例去（踩坑 #23）。
    await Future<void>.delayed(const Duration(milliseconds: 700));
    onCall = (m, p, d, q) {
      if (p.endsWith('/queue/play')) throw StateError('sync boom');
      return defaultCall(m, p, d, q);
    };

    await expectLater(ctrl.syncLocalQueueNow(), completes);
  });

  test('fetchLocalQueueForRestore 在测试环境短路返回 null', () async {
    expect(await ctrl.fetchLocalQueueForRestore(), isNull);
    expect(reqs, isEmpty);
  });

  // ==================== 三、切换 / 回本机 / 停止投屏 ====================

  test('switchTo 选本机（self）→ 走 backToLocal 并恢复快照', () async {
    player.emit(localState(queue: <Song>[song], currentSong: song, position: const Duration(seconds: 9)));
    // emit 会触发 controller 的队列/状态监听（内部是 debounce Timer），
    // 本端队列镜像是 **600ms debounce**（见源码 _watchLocalQueue），等满 700ms 才算
// 把这一拍排干净，否则回调会落到下一例去（踩坑 #23）。
    await Future<void>.delayed(const Duration(milliseconds: 700));
    await ctrl.switchTo(dlnaPeer); // 先离开本机（存快照）
    expect(player.calls, contains('pause'));

    await ctrl.switchTo(selfLocal);

    expect(ctrl.state.activePeer, isNull);
    expect(player.calls, contains('restore'));
    expect(player.lastRestorePosition, const Duration(seconds: 9));
  });

  test('switchTo 远端设备 → 先存快照并暂停本机', () async {
    player.emit(localState(queue: <Song>[song], currentSong: song, isPlaying: true));
    // emit 会触发 controller 的队列/状态监听（内部是 debounce Timer），
    // 本端队列镜像是 **600ms debounce**（见源码 _watchLocalQueue），等满 700ms 才算
// 把这一拍排干净，否则回调会落到下一例去（踩坑 #23）。
    await Future<void>.delayed(const Duration(milliseconds: 700));
    player.calls.clear();

    await ctrl.switchTo(dlnaPeer);

    expect(ctrl.state.activePeer, dlnaPeer);
    expect(player.calls, contains('pause'));
    expect(ctrl.state.status.state, 'BUFFERING');
  });

  test('stopCasting：stop / deactivate 失败各自被吞', () async {
    onCall = (m, p, d, q) {
      if (p.endsWith('/stop')) throw StateError('stop boom');
      if (p.endsWith('/queue/deactivate')) throw StateError('deactivate boom');
      return defaultCall(m, p, d, q);
    };
    await ctrl.switchTo(dlnaPeer);
    reqs.clear();

    await expectLater(ctrl.stopCasting(), completes);

    expect(postsMatching('/stop'), isNotEmpty);
    expect(postsMatching('/queue/deactivate'), isNotEmpty);
    expect(ctrl.state.activePeer, isNull);
  });

  // ==================== 四、peer 摘要 / 搬移 / 群组 ====================

  test('fetchPeerNowPlaying：currentIndex=0 直接取 meta 的 items', () async {
    final now = await ctrl.fetchPeerNowPlaying('dlna-1');

    expect(now, isNotNull);
    expect(now!.currentIndex, 0);
    expect(now.title, '测试曲');
    expect(now.coverArt, 'so-s1');
    expect(now.isActive, isTrue);
  });

  test('fetchPeerNowPlaying：currentIndex>0 时按该下标再拉一页', () async {
    onCall = (m, p, d, q) {
      // meta 页与 offset=3 页必须是**同一形状的合法快照**：
      // 源码先按 meta 的 currentIndex/total 判「有没有当前项」，越界就压根不拉第二页、
      // 标题恒为空。所以两页都要满足 currentIndex(3) < total(5)。
      return snap(
        currentIndex: 3,
        items: <Map<String, dynamic>>[
          item('s1'),
          item('s2'),
          item('s3'),
          item('s4'),
          item('s5'),
        ],
      );
    };

    final now = await ctrl.fetchPeerNowPlaying('dlna-1');

    expect(now!.currentIndex, 3);
    expect(now.title, '测试曲'); // meta 页 items 为空时的兜底
  });

  test('fetchPeerNowPlaying：currentMedia 无标题时回落到队列当前项', () async {
    onCall = (m, p, d, q) => snap(currentIndex: 0)
      ..['currentMedia'] = <String, dynamic>{
          'coverArt': '',
        };

    final now = await ctrl.fetchPeerNowPlaying('dlna-1');

    expect(now!.title, '测试曲');
    expect(now.coverArt, 'so-s1');
  });

  test('fetchPeerNowPlaying：拉失败返回 null（不抛）', () async {
    onCall = (m, p, d, q) => throw StateError('now playing boom');

    expect(await ctrl.fetchPeerNowPlaying('dlna-1'), isNull);
  });

  test('destroyPeer 销毁本机 → 弃本机会话 + reset（投屏目标不受影响）', () async {
    await ctrl.registerAndHeartbeat();
    await ctrl.switchTo(dlnaPeer);
    player.calls.clear();

    final ok = await ctrl.destroyPeer(selfLocal);

    expect(ok, isTrue);
    expect(player.calls, contains('clearQueue'));
    // 本机那台不是当前遥控对象：不触发 backToLocal，投屏会话原样保留。
    expect(ctrl.state.activePeer, dlnaPeer);
  });

  test('destroyPeer 销毁当前遥控对象 → reset 之后回本机', () async {
    await ctrl.registerAndHeartbeat();
    await ctrl.switchTo(dlnaPeer);
    expect(ctrl.state.activePeer, dlnaPeer);

    final ok = await ctrl.destroyPeer(dlnaPeer);

    expect(ok, isTrue);
    expect(ctrl.state.activePeer, isNull);
  });

  test('destroyPeer 销毁的不是当前遥控对象 → 不回本机', () async {
    await ctrl.registerAndHeartbeat();
    await ctrl.switchTo(dlnaPeer);
    player.calls.clear();

    final ok = await ctrl.destroyPeer(otherPeer);

    expect(ok, isTrue);
    expect(ctrl.state.activePeer, dlnaPeer);
  });

  test('fetchGroups：正常返回列表；异常 / 非 List 返回 null', () async {
    expect(await ctrl.fetchGroups(), hasLength(1));

    onCall = (m, p, d, q) => throw StateError('groups boom');
    expect(await ctrl.fetchGroups(), isNull);
  });

  test('setGroupMembership：join / remove / 无 memberIds 三种落点', () async {
    onCall = (m, p, d, q) => <String, dynamic>{
          'group': <String, dynamic>{'memberIds': <dynamic>['sendspin:a1']},
        };

    final joined = await ctrl.setGroupMembership('g1', 'sendspin:a1', join: true);
    expect(joined, <String>['sendspin:a1']);
    expect(postsMatching('/members').last.data!['add'], <String>['sendspin:a1']);

    onCall = (m, p, d, q) => <String, dynamic>{'group': <String, dynamic>{}};
    expect(await ctrl.setGroupMembership('g1', 'a', join: false), isNull);
    expect(postsMatching('/members').last.data!['remove'], <String>['a']);

    onCall = (m, p, d, q) => throw StateError('members boom');
    expect(await ctrl.setGroupMembership('g1', 'a', join: true), isNull);
  });

  test('transferQueue：同端 / 从本机推 / 到本机拉 三条路由', () async {
    expect(await ctrl.transferQueue(dlnaPeer, dlnaPeer), isFalse);

    await ctrl.registerAndHeartbeat();
    player.emit(localState(queue: <Song>[song, song2], currentSong: song));
    // emit 会触发 controller 的队列/状态监听（内部是 debounce Timer），
    // 本端队列镜像是 **600ms debounce**（见源码 _watchLocalQueue），等满 700ms 才算
// 把这一拍排干净，否则回调会落到下一例去（踩坑 #23）。
    await Future<void>.delayed(const Duration(milliseconds: 700));
    reqs.clear();
    expect(await ctrl.transferQueue(selfLocal, dlnaPeer), isTrue);
    expect(postsMatching('/queue/play'), isNotEmpty);

    player.calls.clear();
    reqs.clear();
    expect(await ctrl.transferQueue(dlnaPeer, selfLocal), isTrue);
    expect(player.calls, contains('playSong'));
  });

  test('transferQueue 远端→远端：成功 reset 源端，失败返回 false', () async {
    expect(await ctrl.transferQueue(otherPeer, dlnaPeer), isTrue);
    expect(postsMatching('/transfer-from'), hasLength(1));

    onCall = (m, p, d, q) {
      if (p.endsWith('/transfer-from')) throw StateError('transfer boom');
      return defaultCall(m, p, d, q);
    };
    expect(await ctrl.transferQueue(otherPeer, dlnaPeer), isFalse);
  });

  test('pushLocalToPeer：推给自己 / 空队列 都被挡下', () async {
    await ctrl.registerAndHeartbeat();
    expect(await ctrl.pushLocalToPeer(selfLocal), isFalse);

    player.emit(localState(queue: const <Song>[], currentSong: null));
    // emit 会触发 controller 的队列/状态监听（内部是 debounce Timer），
    // 本端队列镜像是 **600ms debounce**（见源码 _watchLocalQueue），等满 700ms 才算
// 把这一拍排干净，否则回调会落到下一例去（踩坑 #23）。
    await Future<void>.delayed(const Duration(milliseconds: 700));
    expect(await ctrl.pushLocalToPeer(dlnaPeer), isFalse);
    // 只约束「没往远端推队列」：本机状态上报 / 心跳本来就该发，不能一刀切判空。
    expect(reqs.where((r) => r.path.endsWith('/queue')), isEmpty);
  });

  test('fetchPeerNowPlaying：响应体不带 isActive/currentIndex 时产出「未在播」摘要', () async {
    // `res is! Map` 之外还有一种畸形：Map 但没有 isActive/currentIndex ——
    // 不抛、不返回 null，而是给一条 isActive=false、currentIndex=-1 的摘要，
    // 界面据此显示「未在播放」（与拉失败返回 null 区分开）。
    onCall = (m, p, d, q) => <String, dynamic>{'x': 1};

    final now = await ctrl.fetchPeerNowPlaying('dlna-1');

    expect(now, isNotNull);
    expect(now!.isActive, isFalse);
    expect(now.currentIndex, -1);
    expect(now.title, '');
  });

  test('pullPeerToLocal：拉队列失败 / 空队列 都返回 false', () async {
    onCall = (m, p, d, q) => throw StateError('queue boom');
    expect(await ctrl.pullPeerToLocal(dlnaPeer), isFalse);

    onCall = (m, p, d, q) => snap(items: <Map<String, dynamic>>[]);
    expect(await ctrl.pullPeerToLocal(dlnaPeer), isFalse);
  });

  test('pullPeerToLocal：本机起播失败被吞、返回 false', () async {
    onCall = (m, p, d, q) => p.endsWith('/status')
        ? <String, dynamic>{'state': 'PLAYING', 'position': 12.0, 'duration': 200.0}
        : defaultCall(m, p, d, q);
    player.throwOnPlaySong = true;

    expect(await ctrl.pullPeerToLocal(dlnaPeer), isFalse);
  });

  // ==================== 五、传输控制 / 模式 / 定时 ====================

  test('toggle / pause 在无投屏对象时落到本机播放器', () async {
    player.calls.clear();
    await ctrl.toggle();
    await ctrl.pause();
    await ctrl.next();
    await ctrl.previous();
    await ctrl.seek(const Duration(seconds: 7));

    expect(player.calls, contains('toggle'));
    expect(player.calls, contains('pause'));
    expect(player.calls, contains('next'));
    expect(player.calls, contains('previous'));
    expect(player.seeks, <Duration>[const Duration(seconds: 7)]);
  });

  test('toggle / pause 在投屏态下发远端命令', () async {
    await ctrl.switchTo(dlnaPeer);
    player.calls.clear();
    reqs.clear();

    await ctrl.toggle(); // 乐观置 PLAYING
    expect(ctrl.state.status.state, 'PLAYING');
    expect(postsMatching('/play'), isNotEmpty);

    // status 处于 PLAYING（toggle 乐观置位 + 轮询未被拦截），pause 会真下发远端。
    await ctrl.pause();
    expect(postsMatching('/pause'), isNotEmpty);
  });

  test('setSleepTimer：未投屏不请求 / 取消走 DELETE / 设置超时向外抛', () async {
    await ctrl.setSleepTimer(const Duration(minutes: 5));
    expect(reqs.where((r) => r.path.endsWith('sleep-timer')), isEmpty);

    await ctrl.switchTo(dlnaPeer);
    reqs.clear();
    await ctrl.setSleepTimer(null);
    expect(reqs.any((r) => r.method == 'delete' && r.path.endsWith('sleep-timer')), isTrue);

    onCall = (m, p, d, q) {
      if (p.endsWith('sleep-timer')) throw TimeoutException('slow', Duration.zero);
      return defaultCall(m, p, d, q);
    };
    await expectLater(
      ctrl.setSleepTimer(const Duration(minutes: 5)),
      throwsA(isA<TimeoutException>()),
    );
  });

  test('getSleepTimerRemaining：未投屏 null / 未设置 null / 有值返回 Duration', () async {
    // 未投屏时压根不会去问服务端（peerId 为空直接 return null）。
    expect(await ctrl.getSleepTimerRemaining(), isNull);

    await ctrl.switchTo(dlnaPeer);

    onCall = (m, p, d, q) => <String, dynamic>{'active': false, 'remainingMs': 60000};
    expect(await ctrl.getSleepTimerRemaining(), isNull);

    onCall = (m, p, d, q) => <String, dynamic>{'active': true, 'remainingMs': 60000};
    expect(await ctrl.getSleepTimerRemaining(), const Duration(minutes: 1));
  });

  test('投屏态的 setVolume / setMuted / setPlayMode / cyclePlayMode', () async {
    await ctrl.switchTo(dlnaPeer);
    reqs.clear();

    await ctrl.setVolume(42);
    await ctrl.setMuted(true);
    // 乐观置位必须在 setPlayMode 之前断言：后者会 unawaited(pollOnce())，
    // 而轮询回写的 /status 响应不含 volume/muted，会把刚置上的乐观值冲回 null。
    expect(ctrl.state.status.volume, 42);
    expect(ctrl.state.status.muted, isTrue);

    await ctrl.setPlayMode('shuffle');
    await ctrl.cyclePlayMode(); // shuffle → order

    expect(postsMatching('/volume').single.data!['volume'], 42);
    expect(postsMatching('/mute').single.data!['muted'], isTrue);
    expect(postsMatching('/play-mode').first.data!['mode'], 'shuffle');
    expect(ctrl.state.playMode, 'order');
  });

  test('next / previous 在投屏态走远端命令', () async {
    await ctrl.switchTo(dlnaPeer);
    reqs.clear();

    await ctrl.next();
    await ctrl.previous();

    expect(reqs.any((r) => r.method == 'post' && r.path.endsWith('/next')), isTrue);
    expect(reqs.any((r) => r.method == 'post' && r.path.endsWith('/prev')), isTrue);
  });

  test('seek 在投屏态下发到服务端并乐观对齐进度', () async {
    await ctrl.switchTo(dlnaPeer);
    reqs.clear();

    await ctrl.seek(const Duration(seconds: 33));

    expect(postsMatching('/seek').single.data!['seconds'], 33);
    expect(ctrl.state.smoothPositionSeconds, 33);
  });

  test('seek 在投屏态即使命令失败也不抛（_post 已吞）', () async {
    await ctrl.switchTo(dlnaPeer);
    onCall = (m, p, d, q) {
      if (p.endsWith('/seek')) throw StateError('seek boom');
      return defaultCall(m, p, d, q);
    };

    await expectLater(ctrl.seek(const Duration(seconds: 5)), completes);
  });

  // ==================== 六、投屏队列操作 ====================

  test('playSongOnPeer：无队列上下文时已存在则跳播、否则追加', () async {
    await ctrl.switchTo(dlnaPeer);
    expect(await ctrl.playSongOnPeer(song), isTrue); // 追加
    expect(ctrl.state.castIndex, 0);

    expect(await ctrl.playSongOnPeer(song2, queue: <Song>[song, song2], index: 1), isTrue);
    expect(postsMatching('/queue/play').last.data!['startIndex'], 1);
  });

  test('playSongOnPeer 无投屏对象时返回 false', () async {
    expect(await ctrl.playSongOnPeer(song), isFalse);
  });

  test('enqueueSongs / jumpTo / removeQueueItem / reorderQueue / clearCastQueue', () async {
    await ctrl.switchTo(dlnaPeer);
    reqs.clear();

    await ctrl.enqueueSongs(<Song>[song, song2]);
    await ctrl.jumpTo(1);
    await ctrl.removeQueueItem(0);
    await ctrl.reorderQueue(0, 2);

    expect(postsMatching('/queue/enqueue'), hasLength(1));
    expect(postsMatching('/queue/jump').single.data!['index'], 1);
    expect(reqs.any((r) => r.method == 'delete' && r.path.endsWith('/queue/0')), isTrue);
    expect(postsMatching('/queue/reorder').single.data!['to'], 2);

    await ctrl.clearCastQueue();
    expect(ctrl.state.activePeer, isNull);
  });

  test('clearCastQueue 的 DELETE 失败被吞', () async {
    await ctrl.switchTo(dlnaPeer);
    onCall = (m, p, d, q) {
      if (p.endsWith('/queue')) throw StateError('clear boom');
      return defaultCall(m, p, d, q);
    };

    await expectLater(ctrl.clearCastQueue(), completes);
    expect(ctrl.state.activePeer, isNull);
  });

  test('无投屏对象时队列编辑类调用全部空转', () async {
    await ctrl.enqueueSongs(<Song>[song]);
    await ctrl.jumpTo(1);
    await ctrl.removeQueueItem(0);
    await ctrl.reorderQueue(0, 1);
    expect(reqs, isEmpty);
  });

  // ==================== 七、轮询 / seek 护栏 / 离线 ====================

  test('轮询连续失败 3 次置 offline 并清空状态', () async {
    await ctrl.switchTo(dlnaPeer);
    onCall = (m, p, d, q) {
      if (p.endsWith('/status')) throw StateError('poll boom');
      return defaultCall(m, p, d, q);
    };

    await ctrl.pollOnce();
    await ctrl.pollOnce();
    await expectLater(ctrl.pollOnce(), completes);

    expect(ctrl.state.offline, isTrue);
    expect(ctrl.state.status.state, '');
  });

  test('seek 之后遇到 TRANSITIONING-0 采样时屏蔽、保留乐观进度', () async {
    await ctrl.switchTo(dlnaPeer);
    onCall = (m, p, d, q) => p.endsWith('/status')
        ? <String, dynamic>{'state': 'STOPPED', 'position': 0.0, 'duration': 200.0}
        : defaultCall(m, p, d, q);

    await ctrl.seek(const Duration(seconds: 20)); // 乐观平滑进度 = 20
    await ctrl.pollOnce();

    expect(ctrl.state.smoothPositionSeconds, 20);
    expect(ctrl.state.status.positionSeconds, 0);
  });

  test('seek 位置已落位时解除屏蔽（正常采纳采样）', () async {
    await ctrl.switchTo(dlnaPeer);
    onCall = (m, p, d, q) => p.endsWith('/status')
        ? <String, dynamic>{'state': 'PLAYING', 'position': 19.0, 'duration': 200.0}
        : defaultCall(m, p, d, q);

    await ctrl.seek(const Duration(seconds: 20));
    await ctrl.pollOnce();

    expect(ctrl.state.smoothPositionSeconds, greaterThan(18));
    expect(ctrl.state.smoothPositionSeconds, lessThanOrEqualTo(19 + 1.5));
  });

  test('换歌时清空 seek 标记，新歌开头的 0 采样不再被屏蔽', () async {
    await ctrl.switchTo(dlnaPeer);
    onCall = (m, p, d, q) => p.endsWith('/status')
        ? <String, dynamic>{'state': 'STOPPED', 'position': 0.0, 'duration': 200.0}
        : (p.endsWith('/queue')
            ? snap(
                currentIndex: 4,
                items: <Map<String, dynamic>>[
                  item('s1'),
                  item('s2'),
                  item('s3'),
                  item('s4'),
                  item('s5'),
                ],
              )
            : defaultCall(m, p, d, q));

    await ctrl.seek(const Duration(seconds: 20));
    await ctrl.pollOnce();

    // 第一轮：识别到换歌（castIndex 4 ≠ 镜像里的旧值 → 清掉 seek 标记）。
    // 注意这一轮 keepOptimistic 是按**旧的** _seekTargetSeconds 算的，屏蔽窗口
    // 这一拍还开着，所以进度仍停在 20；第二轮才会采纳新歌开头的 0 采样。
    expect(ctrl.state.castIndex, 4);
    await ctrl.pollOnce();

    expect(ctrl.state.smoothPositionSeconds, 0);
  });

  test('平滑进度 tick 会推进 smoothPositionSeconds（fake async）', () {
    fakeAsync((async) {
      onCall = (m, p, d, q) => p.endsWith('/status')
          ? <String, dynamic>{'state': 'PLAYING', 'position': 1.0, 'duration': 300.0}
          : defaultCall(m, p, d, q);
      // 先让 switchTo 的异步链路（register/status/timers）落定，
      // 三个步骤必须在同一个 fakeAsync 作用域里顺序执行，否则 _tickTimer 还没注册。
      unawaited(container.read(castPeerControllerProvider.notifier).switchTo(dlnaPeer));
      async.flushMicrotasks();
      async.elapse(const Duration(milliseconds: 1500));
      async.flushMicrotasks();

      expect(
        container.read(castPeerControllerProvider).smoothPositionSeconds,
        greaterThan(0),
      );
    });
  });

  // ==================== 八、provider 装配 ====================

  test('isCastingProvider / castTargetNameProvider 随控制目标变化', () async {
    final containerRef = container;
    expect(containerRef.read(isCastingProvider), isFalse);

    await ctrl.switchTo(dlnaPeer);
    expect(containerRef.read(isCastingProvider), isTrue);
    expect(containerRef.read(castTargetNameProvider), '客厅音箱');
  });

  test('peerNowPlayingProvider 首次即产出一条摘要', () async {
    // provider 侧 .stream 在 Riverpod 3.0 才移除，这里以 ignore 显式钉住「订阅
    // StreamProvider 帧流」这一姿势；取第一条**数据**帧，不必等满一个 5s 轮询周期。
    // ignore: deprecated_member_use
    final frames = container.read(peerNowPlayingProvider('dlna-1').stream);
    final first = await frames.firstWhere((a) => a != null);

    expect(first, isNotNull);
    expect(first!.isActive, isTrue);
  });

  // ==================== 九、主通道点播 / 进度外推 / 音量影子 ====================

  test('playContentOnPeer：主通道成功 → 本地镜像按 songId 对齐游标', () async {
    await ctrl.switchTo(dlnaPeer);
    reqs.clear();

    final ok = await ctrl.playContentOnPeer(
      type: 'playlist',
      id: 'pl-1',
      songId: 's2',
      localItems: <Map<String, dynamic>>[item('s1'), item('s2'), item('s3')],
      localStartIndex: 2,
      positionSeconds: 7,
    );

    expect(ok, isTrue);
    final body = postsMatching('/rest/api/v1/play').single.data!;
    expect(body['peerId'], 'dlna-1');
    expect(body['type'], 'playlist');
    expect(body['songId'], 's2');
    // 传了 songId 就不让服务端按 startIndex 猜。
    expect(body.containsKey('startIndex'), isFalse);
    expect(ctrl.state.castIndex, 1); // items 里按 songId 找到的下标，不是 2
    expect(ctrl.state.smoothPositionSeconds, 7);
    expect(player.syncCalls, greaterThan(0));
  });

  test('playContentOnPeer：无投屏对象 / 空 type / 服务端拒 都返回 false', () async {
    expect(await ctrl.playContentOnPeer(type: 'playlist', id: 'pl-1'), isFalse);

    await ctrl.switchTo(dlnaPeer);
    expect(await ctrl.playContentOnPeer(type: '', id: 'pl-1'), isFalse);
    expect(await ctrl.playContentOnPeer(type: 'playlist', id: ''), isFalse);

    onCall = (m, p, d, q) => <String, dynamic>{'success': false};
    expect(await ctrl.playContentOnPeer(type: 'playlist', id: 'pl-1'), isFalse);
  });

  test('playContentOnPeer：不传 songId 时才让服务端按 startIndex 定位', () async {
    await ctrl.switchTo(dlnaPeer);
    reqs.clear();

    final ok = await ctrl.playContentOnPeer(
      type: 'album',
      id: 'al-9',
      startIndex: 3,
      localItems: <Map<String, dynamic>>[item('s1'), item('s2')],
    );

    expect(ok, isTrue);
    final body = postsMatching('/rest/api/v1/play').single.data!;
    expect(body['startIndex'], 3);
    expect(ctrl.state.castIndex, 3.clamp(0, 1)); // 越界本地行号 → 夹到 last
  });

  test('_projectPolledPosition：reportedAt 新鲜 → 外推并按时长夹紧', () async {
    // 上报时刻是「3 秒前」，采样 position=5 → 外推到 8。
    final now = DateTime.now().millisecondsSinceEpoch;
    onCall = (m, p, d, q) => p.endsWith('/status')
        ? <String, dynamic>{
            'state': 'PLAYING',
            'position': 5.0,
            'duration': 200.0,
            'reportedAt': now - 3000,
          }
        : defaultCall(m, p, d, q);

    await ctrl.switchTo(dlnaPeer);
    // switchTo 里 `_startPolling` 的首轮 tick 是 **unawaited**：await switchTo 返回时
    // 它还在飞，smooth 仍停在 0。必须再显式 await 一轮 pollOnce 才拿到采样结果。
    await ctrl.pollOnce();

    expect(ctrl.state.smoothPositionSeconds - 8, lessThan(1.0));
    expect(ctrl.state.smoothPositionSeconds, greaterThanOrEqualTo(8));
  });

  test('_projectPolledPosition：上报过旧(>30s) / 时钟超前 / 暂停 都原样采纳', () async {
    final now = DateTime.now().millisecondsSinceEpoch;
    /// 造一份客户端实例周期性上报的 status 采样（reportedAt 是服务端时钟 ms）。
    Object? statusAt(String st, double pos, int reportedAt) => <String, dynamic>{
          'state': st,
          'position': pos,
          'duration': 200.0,
          'reportedAt': reportedAt,
        };

    // 35s 前采的样 → 超过 30s 外推窗口，原样返回（不外推）。
    onCall = (m, p, d, q) => p.endsWith('/status')
        ? statusAt('PLAYING', 5.0, now - 35000)
        : defaultCall(m, p, d, q);
    await ctrl.switchTo(dlnaPeer);
    await ctrl.pollOnce(); // 同上：首轮 tick 是 unawaited，等它落位再断言
    // 用 closeTo：平滑 tick 每 250ms 会 +0.25s，断言值不能卡死到小数点后一位。
    expect(ctrl.state.smoothPositionSeconds, closeTo(5, 1.0));

    // 未来时刻（本端时钟落后于服务端 → age<0）→ 同样原样采纳。
    onCall = (m, p, d, q) => p.endsWith('/status')
        ? statusAt('PLAYING', 9.0, now + 60000)
        : defaultCall(m, p, d, q);
    await ctrl.pollOnce();
    expect(ctrl.state.smoothPositionSeconds, closeTo(9, 1.0));

    // 暂停态不做外推（避免暂停时进度继续爬）。
    // ⚠️ 采样 position 必须**不前进**（<= 上一轮采到的 9.0）：源码 `_tick` 有「position
    // 在前进 → 判在播」的**在播自愈**，若给一个还在前进的 STOPPED 采样，它会被强制
    // 改判成 PLAYING 后走外推（实测 12.0 + 1.003s = 13.003），断言必然红。
    onCall = (m, p, d, q) => p.endsWith('/status')
        ? statusAt('STOPPED', 8.0, now - 1000)
        : defaultCall(m, p, d, q);
    await ctrl.pollOnce();
    // 不播放 → `_advanceSmooth` 也直接 return，值稳定，可以卡死整数秒。
    expect(ctrl.state.smoothPositionSeconds, 8);
  });

  test('_applyVolumeShadow：采样不含刚下发的音量命令时，沿用本地乐观值', () async {
    await ctrl.switchTo(dlnaPeer);
    final now = DateTime.now().millisecondsSinceEpoch;

    await ctrl.setVolume(33);
    // 回执是**命令下发之前**采的样（reportedAt 早于命令时刻）→ 被影子拦住。
    onCall = (m, p, d, q) => p.endsWith('/status')
        ? <String, dynamic>{
            'state': 'PLAYING',
            'position': 1.0,
            'duration': 200.0,
            'volume': 80,
            'reportedAt': now - 5000,
          }
        : defaultCall(m, p, d, q);
    await ctrl.pollOnce();
    expect(ctrl.state.status.volume, 33); // 上报的 80 被顶掉，保留手上的 33

    // 采样时刻追上命令之后 → 恢复正常采纳。
    onCall = (m, p, d, q) => p.endsWith('/status')
        ? <String, dynamic>{
            'state': 'PLAYING',
            'position': 1.0,
            'duration': 200.0,
            'volume': 80,
            'reportedAt': now + 60000,
          }
        : defaultCall(m, p, d, q);
    await ctrl.pollOnce();
    expect(ctrl.state.status.volume, 80);
  });

  test('_applyVolumeShadow：设备型 peer 没有 reportedAt，音量照常采纳', () async {
    await ctrl.switchTo(dlnaPeer);
    await ctrl.setVolume(21);
    reqs.clear();

    onCall = (m, p, d, q) => p.endsWith('/status')
        ? <String, dynamic>{
            'state': 'PLAYING',
            'position': 1.0,
            'duration': 200.0,
            'volume': 64,
          } // 无 reportedAt
        : defaultCall(m, p, d, q);
    await ctrl.pollOnce();

    expect(ctrl.state.status.volume, 64);
  });
}
