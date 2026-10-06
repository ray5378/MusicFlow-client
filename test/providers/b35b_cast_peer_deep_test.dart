// b35b: cast_peer_provider.dart 深水区补测(既有 cast 测试未覆盖分支)。
// 产品代码零改动。覆盖: _registerSelf 就近重试链、waitForLocalPeerId 快路径/
// 注册落地唤醒/1.5s 预算放弃、loadPeers 周期刷新定时器(peersRev)、启动自动
// 选中(候选在播切换/全暂停不动/本机在播不发探测/复验放弃)、pushLocalToPeer
// 整队兜底 + _resetPeer('') 空转、destroyPeer /reset 失败降级 stop+清队列、
// setSleepTimer DELETE 失败被吞、getSleepTimerRemaining 异常/非数字分支。

import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:musicflow_client/data/models/peer.dart';
import 'package:musicflow_client/data/models/song.dart';
import 'package:musicflow_client/providers/api/api_provider.dart';
import 'package:musicflow_client/providers/cast/cast_peer_provider.dart';
import 'package:musicflow_client/providers/player/player_provider.dart';

import '../features/player/test_player_notifier.dart';
import '../helpers/mocks.dart';

class _RecPlayer extends TestPlayerNotifier {
  _RecPlayer(super.state);

  int syncCalls = 0;
  int clearCalls = 0;
  final List<String> calls = <String>[];

  /// 测试环境无会话恢复流程,恒为 false(自动选中等待恢复落定的循环据此放行)。
  @override
  bool get isRestoringPlaybackSession => false;

  @override
  Future<void> pause() async {
    calls.add('pause');
    await super.pause();
  }

  @override
  Future<void> clearQueue({bool keepCurrent = true}) async {
    calls.add('clearQueue');
    clearCalls += 1;
    await super.clearQueue(keepCurrent: keepCurrent);
  }

  @override
  void syncQueueForCast(List<Map<String, dynamic>> items, int index) {
    calls.add('sync');
    syncCalls += 1;
    super.syncQueueForCast(items, index);
  }
}

class _Req {
  _Req(this.method, this.path, this.data);

  final String method;
  final String path;
  final Map<String, dynamic>? data;

  @override
  String toString() => '$method $path $data';
}

void main() {
  // 启动自动选中会读取「默认控制当前客户端」开关（SharedPreferences），纯 Dart 单测需先初始化绑定并在 setUp 里 mock prefs。
  TestWidgetsFlutterBinding.ensureInitialized();
  late MockSubsonicApiClient client;
  late _RecPlayer player;
  late ProviderContainer container;
  late CastPeerController ctrl;
  late List<_Req> reqs;

  Object? Function(
    String method,
    String path,
    Map<String, dynamic>? data,
    Map<String, dynamic>? query,
  )? onCall;

  const dlnaPeer = PeerInfo(
    peerId: 'dlna-1',
    name: '客厅音箱',
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

  Map<String, dynamic> defaultCall(
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
      };
    }
    if (path.endsWith('/reset')) return <String, dynamic>{'success': true};
    if (path.endsWith('/peers')) {
      return <String, dynamic>{
        'peers': <Map<String, dynamic>>[
          <String, dynamic>{'peerId': 'dlna-1', 'name': '客厅音箱', 'kind': 'dlna'},
        ],
      };
    }
    if (path.endsWith('/sleep-timer')) return <String, dynamic>{'active': false};
    if (path.endsWith('/queue/play')) return <String, dynamic>{'success': true};
    if (path.endsWith('/play')) return <String, dynamic>{'success': true};
    if (path.endsWith('/queue')) return <String, dynamic>{'items': []};
    return <String, dynamic>{};
  }

  Object? route(
    String method,
    String path,
    Map<String, dynamic>? data,
    Map<String, dynamic>? query,
  ) {
    reqs.add(_Req(method, path, data));
    final h = onCall;
    if (h != null) return h(method, path, data, query);
    return defaultCall(method, path, data, query);
  }

  setUp(() {
    // 开关缺省为 false → 自动选中走历史路径（断言无需改动）。
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
    try {
      ctrl.stopHeartbeat();
    } catch (_) {}
    await Future<void>.delayed(const Duration(milliseconds: 10));
    container.dispose();
    await Future<void>.delayed(const Duration(milliseconds: 10));
  });

  List<_Req> callsMatching(String tail) => reqs
      .where((r) => r.path.endsWith(tail))
      .toList(growable: false);

  // ==================== 一、注册重试与 peerId 等待 ====================

  test('注册首次失败 → 就近重试成功并暴露 localPeerId', () async {
    var registerCalls = 0;
    onCall = (method, path, data, query) {
      if (path.endsWith('/register')) {
        registerCalls++;
        if (registerCalls == 1) throw StateError('cold start 401');
      }
      return defaultCall(method, path, data, query);
    };
    await ctrl.registerAndHeartbeat();
    expect(registerCalls, 2, reason: '失败后就近重试一次');
    expect(ctrl.localPeerId, 'local-7');
  });

  test('waitForLocalPeerId: 已注册 → 快路径立即返回', () async {
    await ctrl.registerAndHeartbeat();
    expect(await ctrl.waitForLocalPeerIdForTest(), 'local-7');
  });

  test('waitForLocalPeerId: 未注册挂信号,注册落地即刻唤醒', () async {
    final f = ctrl.waitForLocalPeerIdForTest();
    final pending = f.timeout(const Duration(milliseconds: 50),
        onTimeout: () => '__pending__');
    expect(await pending, '__pending__');
    await ctrl.registerAndHeartbeat();
    expect(await f, 'local-7');
  });

  test('waitForLocalPeerId: 注册迟迟不落地 → 1.5s 预算后放弃返回 null', () async {
    onCall = (method, path, data, query) {
      if (path.endsWith('/register')) throw StateError('server down');
      return defaultCall(method, path, data, query);
    };
    final f = ctrl.waitForLocalPeerIdForTest();
    expect(await f, isNull);
  }, timeout: const Timeout(Duration(seconds: 8)));

  // ==================== 二、loadPeers 周期刷新 ====================

  test('loadPeers 成功 → 周期定时器推进 peersRev(fake async)', () {
    fakeAsync((async) {
      final rev0 = ctrl.state.peersRev;
      unawaited(ctrl.loadPeers());
      async.elapse(const Duration(milliseconds: 50));
      async.elapse(const Duration(seconds: 21));
      expect(ctrl.state.peersRev, greaterThanOrEqualTo(rev0 + 2));
    });
  });

  test('loadPeers 失败 → 返回空列表且不起周期定时器', () {
    fakeAsync((async) {
      List<PeerInfo>? got;
      onCall = (method, path, data, query) {
        if (path.endsWith('/peers')) {
          throw StateError('server down');
        }
        return defaultCall(method, path, data, query);
      };
      unawaited(ctrl.loadPeers().then((p) => got = p));
      async.elapse(const Duration(seconds: 21));
      expect(got, isEmpty);
      expect(ctrl.state.peersRev, 0);
    });
  });

  // ==================== 三、启动自动选中 ====================

  Map<String, dynamic> peersResp(List<Map<String, dynamic>> list) =>
      <String, dynamic>{'peers': list};

  test('候选端真正在播 → 自动把控制目标切过去', () async {
    onCall = (method, path, data, query) {
      if (path.endsWith('/peers') && query == null && data == null) {
        return peersResp([
          {
            'peerId': 'dlna-9',
            'name': '书房音箱',
            'kind': 'dlna',
            'available': true,
            'queue': <String, dynamic>{
              'isActive': true,
              'items': <Map<String, dynamic>>[],
            },
          },
        ]);
      }
      return defaultCall(method, path, data, query);
    };
    await ctrl.loadPeers();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(ctrl.state.activePeer?.peerId, 'dlna-9');
    expect(callsMatching('/status'), isNotEmpty,
        reason: '实时在播探测应发生');
  });

  test('候选端都只有暂停队列 → 保持本机不切', () async {
    onCall = (method, path, data, query) {
      if (path.endsWith('/peers')) {
        return peersResp([
          {
            'peerId': 'dlna-9',
            'name': '书房音箱',
            'kind': 'dlna',
            'available': true,
            'queue': <String, dynamic>{
              'isActive': true,
              'items': <Map<String, dynamic>>[],
            },
          },
        ]);
      }
      if (path.endsWith('/status')) {
        return <String, dynamic>{'state': 'PAUSED', 'position': 1.0};
      }
      return defaultCall(method, path, data, query);
    };
    await ctrl.loadPeers();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(ctrl.state.activePeer, isNull);
  });

  test('本机正在播放 → 最高优先,不发起实时在播探测', () async {
    player.emit(PlayerState(isPlaying: true, currentSong: song));
    onCall = (method, path, data, query) {
      if (path.endsWith('/peers')) {
        return peersResp([
          {
            'peerId': 'dlna-9',
            'name': '书房音箱',
            'kind': 'dlna',
            'available': true,
            'queue': <String, dynamic>{
              'isActive': true,
              'items': <Map<String, dynamic>>[],
            },
          },
        ]);
      }
      return defaultCall(method, path, data, query);
    };
    await ctrl.loadPeers();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(callsMatching('/status'), isEmpty,
        reason: '本机在播即最高优先,不应探测远端');
    expect(ctrl.state.activePeer, isNull);
  });

  test('首轮探测在播但切前复验已暂停 → 整轮放弃保持本机', () async {
    var statusCalls = 0;
    onCall = (method, path, data, query) {
      if (path.endsWith('/peers')) {
        return peersResp([
          {
            'peerId': 'dlna-9',
            'name': '书房音箱',
            'kind': 'dlna',
            'available': true,
            'queue': <String, dynamic>{
              'isActive': true,
              'items': <Map<String, dynamic>>[],
            },
          },
        ]);
      }
      if (path.endsWith('/status')) {
        statusCalls++;
        return <String, dynamic>{
          'state': statusCalls == 1 ? 'PLAYING' : 'PAUSED',
        };
      }
      return defaultCall(method, path, data, query);
    };
    await ctrl.loadPeers();
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(statusCalls, greaterThanOrEqualTo(2), reason: '应有复验');
    expect(ctrl.state.activePeer, isNull);
  });

  test('可见端为空 → 本轮不置位,下一轮成功列表再评估', () async {
    var peersCalls = 0;
    onCall = (method, path, data, query) {
      if (path.endsWith('/peers')) {
        peersCalls++;
        if (peersCalls == 1) return peersResp([]);
        return peersResp([
          {
            'peerId': 'dlna-9',
            'name': '书房音箱',
            'kind': 'dlna',
            'available': true,
            'queue': <String, dynamic>{
              'isActive': true,
              'items': <Map<String, dynamic>>[],
            },
          },
        ]);
      }
      return defaultCall(method, path, data, query);
    };
    await ctrl.loadPeers();
    await ctrl.loadPeers();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(ctrl.state.activePeer?.peerId, 'dlna-9');
  });

  // ==================== 四、pushLocalToPeer / reset 降级 ====================

  test('pushLocalToPeer 无来源上下文 → 走整队兜底推送并抛弃本机会话', () async {
    player.emit(PlayerState(
      queue: [song],
      currentIndex: 0,
      currentSong: song,
    ));
    final ok = await ctrl.pushLocalToPeer(dlnaPeer);
    expect(ok, isTrue);
    expect(callsMatching('/queue/play'), isNotEmpty);
    expect(callsMatching('/play-mode'), isNotEmpty);
    expect(player.syncCalls, 1, reason: '乐观镜像本机队列');
    expect(player.clearCalls, 1, reason: '搬移语义:本机会话被抛弃');
    // 本机未注册(localPeerId=null) → _resetPeer('') 早退,不应有 DELETE 队列。
    expect(
      reqs.where((r) => r.method == 'delete' && r.path.contains('/queue')),
      isEmpty,
    );
  });

  test('destroyPeer /reset 失败 → 降级 stop+清队列,DELETE 失败被吞', () async {
    onCall = (method, path, data, query) {
      if (path.endsWith('/reset')) throw StateError('old server');
      if (path.endsWith('/queue') && method == 'delete') {
        throw StateError('delete failed');
      }
      return defaultCall(method, path, data, query);
    };
    final ok = await ctrl.destroyPeer(dlnaPeer);
    expect(ok, isTrue, reason: 'stop 成功即视为降级成功');
    expect(callsMatching('/stop'), isNotEmpty);
    expect(
      reqs.any((r) => r.method == 'delete' && r.path.endsWith('/queue')),
      isTrue,
    );
  });

  test('destroyPeer /reset 失败且 stop 也失败 → 返回 false', () async {
    onCall = (method, path, data, query) {
      if (path.endsWith('/reset')) throw StateError('old server');
      if (path.endsWith('/stop')) throw StateError('stop failed');
      return defaultCall(method, path, data, query);
    };
    expect(await ctrl.destroyPeer(dlnaPeer), isFalse);
  });

  // ==================== 五、sleep timer 容错分支 ====================

  test('setSleepTimer 取消时 DELETE 失败被吞不抛', () async {
    await ctrl.switchTo(dlnaPeer);
    onCall = (method, path, data, query) {
      if (path.endsWith('/sleep-timer') && method == 'delete') {
        throw StateError('delete failed');
      }
      return defaultCall(method, path, data, query);
    };
    await ctrl.setSleepTimer(Duration.zero);
    expect(
      reqs.any((r) => r.method == 'delete' && r.path.endsWith('/sleep-timer')),
      isTrue,
    );
  });

  test('getSleepTimerRemaining: remainingMs 非数字 → null', () async {
    await ctrl.switchTo(dlnaPeer);
    onCall = (method, path, data, query) {
      if (path.endsWith('/sleep-timer')) {
        return <String, dynamic>{'active': true, 'remainingMs': 'abc'};
      }
      return defaultCall(method, path, data, query);
    };
    expect(await ctrl.getSleepTimerRemaining(), isNull);
  });

  test('getSleepTimerRemaining: 请求异常 → null 不抛', () async {
    await ctrl.switchTo(dlnaPeer);
    onCall = (method, path, data, query) {
      if (path.endsWith('/sleep-timer')) throw StateError('server down');
      return defaultCall(method, path, data, query);
    };
    expect(await ctrl.getSleepTimerRemaining(), isNull);
  });
}
