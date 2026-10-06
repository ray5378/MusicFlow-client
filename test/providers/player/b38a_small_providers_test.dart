// b38a —— Route A 小体积 provider 补测。
//
// 针对 lcov 中本路线缺口单测：
//   * effective_volume.dart  : ThrottledVolumeSender 尾部补发(111-116) +
//                             setEffectiveVolume 投屏 peer 分支(79-80)
//   * audio_quality_provider : effectiveQualityProvider 网络切换分支(65-66)
//   * queue_origin_provider  : toString / fromJson 分支(75-76,85-86)
//   * shuffle_history.dart   : 历史栈溢出裁剪(42)
//   * sleep_timer_provider   : 链路 A 服务器计时 setSleepTimer(55,91) +
//                             本机到点本地暂停(70)
// 不可廉价覆盖（报告标注）：
//   * audio_quality 67：switch 的 `none` 分支是死代码（前面 `if (type==none)
//     return` 已提前返回），永远跑不到 → 跳过。
import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:musicflow_client/core/network/address_pool.dart';
import 'package:musicflow_client/core/network/connectivity_monitor.dart';
import 'package:musicflow_client/data/models/audio_quality.dart';
import 'package:musicflow_client/data/models/peer.dart';
import 'package:musicflow_client/providers/api/api_provider.dart';
import 'package:musicflow_client/providers/cast/cast_peer_provider.dart';
import 'package:musicflow_client/providers/player/audio_quality_provider.dart';
import 'package:musicflow_client/providers/player/effective_volume.dart';
import 'package:musicflow_client/providers/player/player_state.dart';
import 'package:musicflow_client/providers/player/queue_origin_provider.dart';
import 'package:musicflow_client/providers/player/shuffle_history.dart';
import 'package:musicflow_client/providers/player/sleep_timer_provider.dart';

const _peer = PeerInfo(
  peerId: 'peer1',
  name: 'p',
  kind: 'phone',
  available: true,
);

/// ConnectivityMonitor 替身：绕过真实平台连通性探测，直接给固定网络类型。
class _FakeMonitor extends ConnectivityMonitor {
  _FakeMonitor(this._t) : super(AddressPool(Dio()));
  final NetworkType _t;
  @override
  NetworkType get currentNetworkType => _t;
  @override
  Stream<NetworkType> get networkTypeStream => Stream.value(_t);
}

/// CastPeerController 替身：可控制是否处于投屏态，并记录关键调用。
class _FakeCastPeer extends CastPeerController {
  _FakeCastPeer(super.ref, {this.active = true}) {
    state = active
        ? const CastPeerState(activePeer: _peer, status: PeerStatus())
        : const CastPeerState();
  }
  final bool active;
  int setVolumeCalls = 0;
  int setSleepTimerCalls = 0;
  int pauseCalls = 0;

  @override
  Future<void> setVolume(int volume) async => setVolumeCalls++;
  @override
  Future<void> setSleepTimer(Duration? duration) async => setSleepTimerCalls++;
  @override
  Future<void> pause() async => pauseCalls++;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues(<String, Object>{});
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
    const MethodChannel('plugins.flutter.io/path_provider'),
    (MethodCall call) async => '/tmp/path-provider-fake',
  );

  // ───────────── effective_volume: ThrottledVolumeSender 尾部补发 ─────────────
  group('ThrottledVolumeSender', () {
    test('高频回调只发首帧,静默期后补发最新值(111-116)', () async {
      final sent = <double>[];
      final sender = ThrottledVolumeSender(
        onSend: (v) async => sent.add(v),
        interval: const Duration(milliseconds: 50),
      );
      sender.send(0.1); // 距上次无记录 → 立即发
      sender.send(0.2); // 节流窗口内 → 进 pending,等尾部补发
      sender.send(0.3); // 仍为 pending,覆盖
      await Future<void>.delayed(const Duration(milliseconds: 90));
      expect(sent, contains(0.1));
      expect(sent, contains(0.3), reason: '尾部补发应发最新 pending 值');
      expect(sent, isNot(contains(0.2)), reason: '被 0.3 覆盖,不应单独发出');
      sender.dispose();
    });
  });

  // ───────────── effective_volume: setEffectiveVolume 投屏 peer 分支 ─────────────
  // 注：setEffectiveVolume 先读 dlnaCastProvider.isCasting，而 DlnaCastNotifier
  // 构造体(line 288)会读 playerProvider.notifier 触发整条 PlayerNotifier 初始化
  // （含 5s 持久化 Timer）。该分支(79-80)要在本机/投屏无 player 实例的轻量容器
  // 下无法廉价覆盖，留待 Route A 的重型 harness(player_provider)用例统一覆盖。

  // ───────────── audio_quality: effectiveQualityProvider 网络切换 ─────────────
  group('effectiveQualityProvider', () {
    ProviderContainer build(NetworkType t) => ProviderContainer(
          overrides: <Override>[
            // 用默认 AudioQualitySettings（autoSwitch=true,
            // wifiQuality=original, mobileQuality=standard）即可验证切换分支。
            currentNetworkTypeProvider
                .overrideWith((ref) => Stream.value(t)),
            connectivityMonitorProvider.overrideWith((ref) => _FakeMonitor(t)),
          ],
        );

    test('Wi-Fi → wifiQuality(65)', () async {
      final c = build(NetworkType.wifi);
      expect(c.read(effectiveQualityProvider), AudioQualityLevel.original);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      c.dispose();
    });
    test('移动网络 → mobileQuality(66)', () async {
      final c = build(NetworkType.mobile);
      expect(c.read(effectiveQualityProvider), AudioQualityLevel.standard);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      c.dispose();
    });
  });

  // ───────────── queue_origin: toString / fromJson ─────────────
  group('QueueOrigin', () {
    test('toString 含 id(75-76)', () {
      expect(
        const QueueOrigin(QueueOriginKind.playlist, 'p1').toString(),
        'QueueOrigin(playlist:p1)',
      );
    });
    test('fromJson 合法 → 解析(85-86)', () {
      final o = QueueOrigin.fromJson(<String, dynamic>{
        'kind': 'album',
        'id': 'a1',
      });
      expect(o?.kind, QueueOriginKind.album);
      expect(o?.id, 'a1');
    });
    test('fromJson 非法 → null', () {
      expect(QueueOrigin.fromJson(null), isNull);
      expect(
        QueueOrigin.fromJson(<String, dynamic>{'id': 'x'}),
        isNull,
        reason: '缺 kind 应安全降级',
      );
    });
    test('serverContentType: 可解析来源返回类型,其余 null', () {
      expect(
        const QueueOrigin(QueueOriginKind.playlist, 'p1').serverContentType,
        'playlist',
      );
      expect(
        const QueueOrigin(QueueOriginKind.discover).serverContentType,
        isNull,
      );
    });
  });

  // ───────────── shuffle_history: 溢出裁剪(42) ─────────────
  group('ShuffleHistory overflow', () {
    test('超过上限时丢弃最旧(42)', () {
      final h = ShuffleHistory();
      for (var i = 0; i < maxShuffleHistoryEntries + 5; i++) {
        h.pushBack(ShuffleHistoryEntry(songId: 's$i', preferredIndex: 0));
      }
      expect(h.backCount, maxShuffleHistoryEntries);
    });
  });

  // ───────────── sleep_timer: 链路 A 服务器计时 + 本机暂停 ─────────────
  group('SleepTimerNotifier', () {
    test('投屏态 start/cancel → 经服务器 setSleepTimer(55,91)', () async {
      final c = ProviderContainer(
        overrides: [
          castPeerControllerProvider.overrideWith((r) => _FakeCastPeer(r)),
        ],
      );
      final n = c.read(sleepTimerProvider.notifier);
      await n.start(const Duration(seconds: 60));
      final fake =
          c.read(castPeerControllerProvider.notifier) as _FakeCastPeer;
      expect(fake.setSleepTimerCalls, 1, reason: 'start 应命令服务器计时(55)');
      expect(n.serverTracked, isTrue);
      await n.cancel();
      expect(fake.setSleepTimerCalls, 2, reason: 'cancel 应取消服务器计时(91)');
      c.dispose();
    });

    test('本机态到点 → 本地暂停(70)', () async {
      final c = ProviderContainer(
        overrides: [
          castPeerControllerProvider
              .overrideWith((r) => _FakeCastPeer(r, active: false)),
        ],
      );
      final n = c.read(sleepTimerProvider.notifier);
      await n.start(const Duration(milliseconds: 10));
      await Future<void>.delayed(const Duration(seconds: 2));
      final fake =
          c.read(castPeerControllerProvider.notifier) as _FakeCastPeer;
      expect(fake.pauseCalls, 1, reason: '到点应本地暂停(70)');
      await n.cancel();
      c.dispose();
    });
  });
}
