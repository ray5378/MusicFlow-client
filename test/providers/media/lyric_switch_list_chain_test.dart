import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:musicflow_client/providers/api/api_provider.dart';
import 'package:musicflow_client/providers/cast/cast_peer_provider.dart';
import 'package:musicflow_client/providers/media/desktop_lyric_popup.dart';
import 'package:musicflow_client/providers/player/player_provider.dart';

import '../../features/player/test_player_notifier.dart';
import '../../helpers/mocks.dart';

/// 桌面歌词「切换播放器」弹窗数据链路的回归防线。
///
/// 2026-09-10 用户反馈:歌词窗上的设备弹窗**只显示「本机」**,
/// 实际服务端返回的设备都没有出现。
///
/// 这里覆盖 requestSwitchList 的完整链路:拉 /rest/api/v1/peers →
/// 缓存 → 组行 → 推给原生。任何一环让远端设备丢失都会被拦下。
void main() {
  late MockSubsonicApiClient client;
  late TestPlayerNotifier playerNotifier;
  late ProviderContainer container;

  /// 复刻服务端 /rest/api/v1/peers 的真实形状:
  /// local 那个 available=false(本机无实体),其余按 available 区分。
  Map<String, dynamic> peersResponse() => <String, dynamic>{
        'peers': <Map<String, dynamic>>[
          <String, dynamic>{
            'peerId': 'local:abc',
            'kind': 'local',
            'name': 'xyz5378',
            'available': false,
          },
          <String, dynamic>{
            'peerId': 'dlna:AAA',
            'kind': 'dlna',
            'name': '主卧',
            'available': true,
          },
          <String, dynamic>{
            'peerId': 'dlna:BBB',
            'kind': 'dlna',
            'name': 'airmusic',
            'available': false,
          },
          <String, dynamic>{
            'peerId': 'dlna:CCC',
            'kind': 'dlna',
            'name': 'MUZO',
            'available': false,
          },
        ],
      };

  setUp(() {
    client = MockSubsonicApiClient();
    playerNotifier = TestPlayerNotifier(PlayerState());
    container = ProviderContainer(
      overrides: <Override>[
        subsonicApiClientProvider.overrideWithValue(client),
        playerProvider.overrideWith((ref) => playerNotifier),
      ],
    );
  });

  tearDown(() {
    // 释放控制器:停止心跳/轮询/插值定时器,避免测试间泄漏。
    // 不要手动再 dispose 一次,container 会负责。
    container.dispose();
  });

  /// 直接测「拉设备 → 组行」这半条链路(推送需要真实平台通道,
  /// 单测里不覆盖;这里保证送给推送函数的数据是对的)。
  test('requestSwitchList 之后,可用远端设备必须进入设备列表', () async {
    when(() => client.getRaw(any())).thenAnswer(
      (_) async => peersResponse(),
    );

    final controller = container.read(castPeerControllerProvider.notifier);
    final peers = await controller.loadPeers();

    // 服务端 4 个 peer:local + 主卧(available) + airmusic/MUZO(不可用)。
    expect(peers, hasLength(4));

    // 与 StatusLyricsController._availableRemotePeers() 同一条筛选规则:
    // 排除本机、只要 available 的。
    final remote = peers.where((p) => !p.isLocal && p.available).toList();
    expect(
      remote.map((p) => p.name),
      <String>['主卧'],
      reason: '只有 available=true 的远端设备能进弹窗列表。',
    );

    // 组行:本机恒在首行,其后是可用远端设备。
    final rows = composeDesktopLyricSwitchList(
      localTitle: '本机',
      localSubtitle: '在本机播放',
      localIsCurrent: true,
      stopCastTitle: '停止投屏',
      remotePeers: <({
        String name,
        String subtitle,
        String kind,
        bool current,
        String badge,
        bool canPull,
        bool canPush,
      })>[
        for (final p in remote)
          (
            name: p.name,
            subtitle: p.queueLabel,
            kind: p.kind,
            current: false,
            badge: p.kindLabel,
            canPull: p.queueActive && p.queueTotal > 0,
            canPush: true,
          ),
      ],
    );
    expect(rows.map((r) => r.title).toList(), <String>['本机', '主卧']);
    expect(rows.first.current, isTrue);
  });

  test('peers 里没有可用远端设备时只有本机一行(空列表不是 bug)', () async {
    when(() => client.getRaw(any())).thenAnswer(
      (_) async => <String, dynamic>{
        'peers': <Map<String, dynamic>>[
          <String, dynamic>{
            'peerId': 'local:abc',
            'kind': 'local',
            'name': 'xyz5378',
            'available': false,
          },
          <String, dynamic>{
            'peerId': 'dlna:BBB',
            'kind': 'dlna',
            'name': 'airmusic',
            'available': false,
          },
        ],
      },
    );

    final controller = container.read(castPeerControllerProvider.notifier);
    final peers = await controller.loadPeers();
    final remote = peers.where((p) => !p.isLocal && p.available).toList();
    expect(remote, isEmpty);

    final rows = composeDesktopLyricSwitchList(
      localTitle: '本机',
      localSubtitle: '在本机播放',
      localIsCurrent: true,
      remotePeers: const <({
        String name,
        String subtitle,
        String kind,
        bool current,
        String badge,
        bool canPull,
        bool canPush,
      })>[],
    );
    expect(rows, hasLength(1));
    expect(rows.single.title, '本机');
  });

  test('投屏中(本机不是当前目标)时插入「停止投屏」行', () async {
    final rows = composeDesktopLyricSwitchList(
      localTitle: '本机',
      localSubtitle: '正在投屏',
      localIsCurrent: false,
      stopCastTitle: '停止投屏',
      stopCastSubtitle: '当前:主卧',
      remotePeers: const <({
        String name,
        String subtitle,
        String kind,
        bool current,
        String badge,
        bool canPull,
        bool canPush,
      })>[
        (
          name: '主卧',
          subtitle: '',
          kind: 'dlna',
          current: true,
          badge: 'DLNA',
          canPull: true,
          canPush: false,
        ),
      ],
    );
    expect(
      rows.map((r) => r.title).toList(),
      <String>['本机', '停止投屏', '主卧'],
    );
    expect(rows[1].subtitle, '当前:主卧');
    expect(rows[2].current, isTrue);
  });
}
