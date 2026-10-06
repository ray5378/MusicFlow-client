// b36a —— 「默认控制当前客户端」开关对 CastPeerController 启动自动选中
// 短路分支的补测（`lib/providers/cast/cast_peer_provider.dart`
// `_maybeAutoSelectPlayingTarget` 开头新增的短路段）。
//
// 语义：开关开启（true）→ 启动首次拉到播放端列表时**不做**自动切目标，保持本机；
// 关闭（false，默认）→ 沿用历史行为，自动接管「正在播放中」的播放器。
//
// 产品代码零改动；仅新增 test/。
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:musicflow_client/data/sources/local_storage.dart';
import 'package:musicflow_client/providers/api/api_provider.dart';
import 'package:musicflow_client/providers/cast/cast_peer_provider.dart';
import 'package:musicflow_client/providers/player/player_provider.dart';

import '../features/player/test_player_notifier.dart';
import '../helpers/mocks.dart';

class _RecPlayer extends TestPlayerNotifier {
  _RecPlayer(super.state);

  /// 测试环境无会话恢复流程，恒为 false（自动选中等待恢复落定的循环据此放行）。
  @override
  bool get isRestoringPlaybackSession => false;

  final List<String> calls = <String>[];

  @override
  Future<void> pause() async {
    calls.add('pause');
    await super.pause();
  }
}

class _Req {
  _Req(this.method, this.path);

  final String method;
  final String path;

  @override
  String toString() => '$method $path';
}

/// 一个「队列激活且在播」的候选端（`/peers` 列表项）。
const Map<String, dynamic> _inPlayingPeer = <String, dynamic>{
  'peerId': 'dlna-9',
  'name': '书房音箱',
  'kind': 'dlna',
  'available': true,
  'queue': <String, dynamic>{
    'isActive': true,
    'items': <Map<String, dynamic>>[],
  },
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MockSubsonicApiClient client;
  late _RecPlayer player;
  late ProviderContainer container;
  late CastPeerController ctrl;
  late List<_Req> reqs;

  Map<String, dynamic> respond(String path) {
    reqs.add(_Req('get', path));
    if (path.endsWith('/peers')) {
      return <String, dynamic>{
        'peers': <Map<String, dynamic>>[_inPlayingPeer],
      };
    }
    if (path.endsWith('/status')) {
      return <String, dynamic>{'state': 'PLAYING'};
    }
    return <String, dynamic>{};
  }

  void installStubs() {
    when(() => client.getRaw(any())).thenAnswer(
      (inv) async => respond(inv.positionalArguments[0] as String),
    );
    when(
      () => client.getRaw(
        any(),
        queryParameters: any(named: 'queryParameters'),
        receiveTimeout: any(named: 'receiveTimeout'),
      ),
    ).thenAnswer(
      (inv) async => respond(inv.positionalArguments[0] as String),
    );
    when(() => client.postRaw(any())).thenAnswer(
      (_) async => <String, dynamic>{},
    );
    when(
      () => client.postRaw(
        any(),
        data: any(named: 'data'),
        receiveTimeout: any(named: 'receiveTimeout'),
      ),
    ).thenAnswer((_) async => <String, dynamic>{});
  }

  void build() {
    client = MockSubsonicApiClient();
    player = _RecPlayer(PlayerState());
    installStubs();
    container = ProviderContainer(
      overrides: <Override>[
        subsonicApiClientProvider.overrideWithValue(client),
        playerProvider.overrideWith((ref) => player),
      ],
    );
    ctrl = container.read(castPeerControllerProvider.notifier);
  }

  setUp(() {
    reqs = <_Req>[];
    // 默认开关关闭；各用例按需覆写。
    SharedPreferences.setMockInitialValues(<String, Object>{});
    build();
  });

  tearDown(() async {
    try {
      ctrl.stopHeartbeat();
    } catch (_) {}
    await Future<void>.delayed(const Duration(milliseconds: 10));
    container.dispose();
    await Future<void>.delayed(const Duration(milliseconds: 10));
  });

  List<_Req> statusCalls() =>
      reqs.where((r) => r.path.endsWith('/status')).toList(growable: false);

  test('开关开启(true) → 短路：保持本机且不发起 /status 实时在播探测', () async {
    // 关键：在任何 prefs 读取前把开关置 true。
    SharedPreferences.setMockInitialValues(<String, Object>{
      'default_control_current_client': true,
    });
    expect(await LocalStorage.getDefaultControlCurrentClient(), isTrue);

    await ctrl.loadPeers();
    await Future<void>.delayed(const Duration(milliseconds: 200));

    expect(ctrl.state.activePeer, isNull, reason: '开启默认控制本机后不应自动切走');
    expect(statusCalls(), isEmpty, reason: '短路分支不应触碰 /status 探测');
    expect(player.calls, isNot(contains('pause')), reason: '不应暂停本机');
  });

  test('开关关闭(false) → 沿用历史行为：自动接管在播播放器并探测 /status', () async {
    // setUp 已把开关置为空 → false。
    await ctrl.loadPeers();
    await Future<void>.delayed(const Duration(milliseconds: 200));

    expect(ctrl.state.activePeer?.peerId, 'dlna-9');
    expect(statusCalls(), isNotEmpty, reason: '实时在播探测应发生');
  });

  test('开关开启 → 连续 loadPeers 仍不切（短路幂等）', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'default_control_current_client': true,
    });

    await ctrl.loadPeers();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    await ctrl.loadPeers();
    await Future<void>.delayed(const Duration(milliseconds: 200));

    expect(ctrl.state.activePeer, isNull);
    expect(statusCalls(), isEmpty);
  });

  test('运行中落盘开启 → 下一次评估即短路保持本机', () async {
    await LocalStorage.setDefaultControlCurrentClient(true);
    expect(await LocalStorage.getDefaultControlCurrentClient(), isTrue);

    await ctrl.loadPeers();
    await Future<void>.delayed(const Duration(milliseconds: 200));

    expect(ctrl.state.activePeer, isNull);
    expect(statusCalls(), isEmpty);
  });
}
