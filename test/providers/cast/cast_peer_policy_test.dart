// ADR-2「阶段 2a：cast 域纯策略外提」的**纯策略**单测。
//
// 覆盖范围（零成本可测，不需要宿主 controller / fake 平台）：
//   · lib/providers/cast/cast_peer_policy.dart
//       projectPolledPosition / isStaleSample / applyVolumeShadow /
//       applyTransportShadow / nextSmoothPosition / resolveProgressTickMs /
//       visiblePeers / selectAutoSelectCandidates
//
// 这些判定原先内联在 `cast_peer_provider.dart` 的 `CastPeerController`（StateNotifier）
// 里，属**库私有**成员、单测只能经整条控制器链路间接触达；阶段 2a 逐字搬运为顶层
// 纯函数后可直接做确定性覆盖（时间/平台等外部输入由入参注入）。宿主侧行为等价性
// 仍由既有 provider 回归（`test/providers/cast_peer_cov_test.dart` /
// `cast_peer_provider_test.dart`）兜底。
import 'package:flutter/foundation.dart' show TargetPlatform;
import 'package:flutter_test/flutter_test.dart';

import 'package:musicflow_client/data/models/peer.dart';
import 'package:musicflow_client/providers/cast/cast_peer_policy.dart';

PeerStatus _status({
  String state = 'PLAYING',
  double position = 0,
  double duration = 0,
  int? volume,
  bool muted = false,
  bool active = false,
  int? reportedAtMs,
}) =>
    PeerStatus(
      state: state,
      positionSeconds: position,
      durationSeconds: duration,
      volume: volume,
      muted: muted,
      active: active,
      reportedAtMs: reportedAtMs,
    );

PeerInfo _peer({
  required String id,
  required String name,
  String kind = 'dlna',
  bool available = true,
  bool self = false,
  bool queueActive = false,
}) =>
    PeerInfo(
      peerId: id,
      name: name,
      kind: kind,
      available: available,
      self: self,
      queueActive: queueActive,
    );

void main() {
  group('projectPolledPosition：客户端实例采样外推', () {
    test('非播放态 → 原样返回（暂停不漂移）', () {
      expect(
        projectPolledPosition(
          status: _status(
            state: 'PAUSED_PLAYBACK',
            position: 12,
            duration: 200,
            reportedAtMs: 1000,
          ),
          nowMs: 5000,
        ),
        12.0,
      );
    });

    test('无 reportedAt（设备型 peer）→ 原样返回', () {
      expect(
        projectPolledPosition(
          status: _status(position: 12, duration: 200),
          nowMs: 5000,
        ),
        12.0,
      );
    });

    test('reportedAt<=0 → 原样返回', () {
      expect(
        projectPolledPosition(
          status: _status(position: 12, duration: 200, reportedAtMs: 0),
          nowMs: 5000,
        ),
        12.0,
      );
    });

    test('age<=0（本端时钟落后）→ 原样返回', () {
      expect(
        projectPolledPosition(
          status: _status(position: 12, duration: 200, reportedAtMs: 9000),
          nowMs: 5000,
        ),
        12.0,
      );
    });

    test('age>30s（上报过旧）→ 原样返回', () {
      expect(
        projectPolledPosition(
          status: _status(position: 12, duration: 200, reportedAtMs: 1000),
          nowMs: 32000,
        ),
        12.0,
      );
    });

    test('age 恰为 30s → 仍外推（边界含上界）', () {
      expect(
        projectPolledPosition(
          status: _status(position: 10, duration: 200, reportedAtMs: 1000),
          nowMs: 31000,
        ),
        closeTo(40.0, 1e-9),
      );
    });

    test('正常外推：采样值 + age（连续推进）', () {
      expect(
        projectPolledPosition(
          status: _status(position: 10, duration: 200, reportedAtMs: 1000),
          nowMs: 5000,
        ),
        closeTo(14.0, 1e-9),
      );
    });

    test('有 duration → 夹紧到 [0, duration]', () {
      expect(
        projectPolledPosition(
          status: _status(position: 199, duration: 200, reportedAtMs: 1000),
          nowMs: 5000,
        ),
        200.0,
      );
    });

    test('duration<=0 → 不做夹紧（原样投影）', () {
      expect(
        projectPolledPosition(
          status: _status(position: 5, duration: 0, reportedAtMs: 1000),
          nowMs: 4000,
        ),
        closeTo(8.0, 1e-9),
      );
    });
  });

  group('isStaleSample：采样早于命令且在保护窗口内', () {
    test('无 reportedAt → 恒 false（设备型链路不受影响）', () {
      expect(
        isStaleSample(
          status: _status(position: 1),
          commandAtMs: 5000,
          nowMs: 5500,
        ),
        isFalse,
      );
    });

    test('commandAtMs<=0 → false', () {
      expect(
        isStaleSample(
          status: _status(reportedAtMs: 1000),
          commandAtMs: 0,
          nowMs: 5500,
        ),
        isFalse,
      );
    });

    test('超出保护窗口 → false（超时后恢复采纳服务端值）', () {
      expect(
        isStaleSample(
          status: _status(reportedAtMs: 1000),
          commandAtMs: 5000,
          nowMs: 5000 + kCommandShadowWindowMs + 1,
        ),
        isFalse,
      );
    });

    test('窗口边界（now-command == window）→ 仍判定为陈旧', () {
      expect(
        isStaleSample(
          status: _status(reportedAtMs: 4000),
          commandAtMs: 5000,
          nowMs: 13000,
          windowMs: 8000,
        ),
        isTrue,
      );
    });

    test('采样早于命令 → true', () {
      expect(
        isStaleSample(
          status: _status(reportedAtMs: 4000),
          commandAtMs: 5000,
          nowMs: 6000,
        ),
        isTrue,
      );
    });

    test('采样追上命令（at>=command）→ false', () {
      expect(
        isStaleSample(
          status: _status(reportedAtMs: 5000),
          commandAtMs: 5000,
          nowMs: 6000,
        ),
        isFalse,
      );
      expect(
        isStaleSample(
          status: _status(reportedAtMs: 6000),
          commandAtMs: 5000,
          nowMs: 6000,
        ),
        isFalse,
      );
    });
  });

  group('applyVolumeShadow：音量类命令的滞后采样影子', () {
    test('陈旧采样 → 沿用本地 volume/muted，其余取上报值', () {
      final incoming = _status(
        state: 'PLAYING',
        position: 3,
        duration: 100,
        volume: 50,
        muted: true,
        active: true,
        reportedAtMs: 4000,
      );
      final current = _status(volume: 30, muted: false, active: true);
      final out = applyVolumeShadow(
        incoming: incoming,
        current: current,
        commandAtMs: 5000,
        nowMs: 6000,
      );
      expect(out.volume, 30);
      expect(out.muted, isFalse);
      expect(out.state, 'PLAYING');
      expect(out.positionSeconds, 3.0);
      expect(out.durationSeconds, 100.0);
      expect(out.active, isTrue);
      expect(out.reportedAtMs, 4000);
    });

    test('非陈旧（采样追上命令）→ 原样返回', () {
      final incoming = _status(volume: 50, muted: true, reportedAtMs: 6000);
      final current = _status(volume: 30, muted: false);
      final out = applyVolumeShadow(
        incoming: incoming,
        current: current,
        commandAtMs: 5000,
        nowMs: 6000,
      );
      expect(out.volume, 50);
      expect(out.muted, isTrue);
    });
  });

  group('applyTransportShadow：传输类命令的滞后采样影子', () {
    test('陈旧采样 → 沿用本地 state/active，其余取上报值', () {
      final incoming = _status(
        state: 'PLAYING',
        position: 3,
        duration: 100,
        volume: 50,
        muted: true,
        active: true,
        reportedAtMs: 4000,
      );
      final current = _status(state: 'PAUSED_PLAYBACK', active: false);
      final out = applyTransportShadow(
        incoming: incoming,
        current: current,
        commandAtMs: 5000,
        nowMs: 6000,
      );
      expect(out.state, 'PAUSED_PLAYBACK');
      expect(out.active, isFalse);
      expect(out.positionSeconds, 3.0);
      expect(out.volume, 50);
      expect(out.muted, isTrue);
      expect(out.reportedAtMs, 4000);
    });

    test('非陈旧 → 原样返回（含 PLAYING 覆盖 PAUSED）', () {
      final incoming =
          _status(state: 'PLAYING', active: true, reportedAtMs: 6000);
      final current = _status(state: 'PAUSED_PLAYBACK', active: false);
      final out = applyTransportShadow(
        incoming: incoming,
        current: current,
        commandAtMs: 5000,
        nowMs: 6000,
      );
      expect(out.state, 'PLAYING');
      expect(out.active, isTrue);
    });
  });

  group('nextSmoothPosition：平滑进度插值', () {
    test('非播放态 → 原样', () {
      expect(
        nextSmoothPosition(
          smoothPositionSeconds: 5,
          status: _status(state: 'PAUSED_PLAYBACK', duration: 200),
          tickMs: 500,
        ),
        5.0,
      );
    });

    test('duration<=0 → 原样', () {
      expect(
        nextSmoothPosition(
          smoothPositionSeconds: 5,
          status: _status(duration: 0),
          tickMs: 500,
        ),
        5.0,
      );
    });

    test('播放中按 tick 递增', () {
      expect(
        nextSmoothPosition(
          smoothPositionSeconds: 5,
          status: _status(duration: 200),
          tickMs: 500,
        ),
        closeTo(5.5, 1e-9),
      );
    });

    test('夹紧到 duration', () {
      expect(
        nextSmoothPosition(
          smoothPositionSeconds: 199.9,
          status: _status(duration: 200),
          tickMs: 500,
        ),
        200.0,
      );
    });
  });

  group('resolveProgressTickMs：插值间隔', () {
    test('Web → 250（不受平台影响）', () {
      expect(
        resolveProgressTickMs(isWeb: true, platform: TargetPlatform.android),
        250,
      );
    });

    test('桌面三平台 → 500', () {
      for (final p in <TargetPlatform>[
        TargetPlatform.windows,
        TargetPlatform.macOS,
        TargetPlatform.linux,
      ]) {
        expect(resolveProgressTickMs(isWeb: false, platform: p), 500);
      }
    });

    test('移动/其它 → 250', () {
      for (final p in <TargetPlatform>[
        TargetPlatform.android,
        TargetPlatform.iOS,
        TargetPlatform.fuchsia,
      ]) {
        expect(resolveProgressTickMs(isWeb: false, platform: p), 250);
      }
    });
  });

  group('visiblePeers / selectAutoSelectCandidates：启动自动选中', () {
    test('visiblePeers：available 或 self 均可见', () {
      final peers = <PeerInfo>[
        _peer(id: 'a', name: 'A', available: true),
        _peer(id: 'b', name: 'B', available: false),
        _peer(id: 'c', name: 'C', available: false, self: true),
      ];
      expect(visiblePeers(peers).map((p) => p.peerId), <String>['a', 'c']);
    });

    test('selectAutoSelectCandidates：排除 self / 不可用 / 无活跃队列', () {
      final visible = <PeerInfo>[
        _peer(id: 'self', name: '本机', kind: 'local', self: true, queueActive: true),
        _peer(id: 'off', name: '离线', available: false, queueActive: true),
        _peer(id: 'idle', name: '空闲', queueActive: false),
        _peer(id: 'ok', name: '在播', queueActive: true),
      ];
      expect(
        selectAutoSelectCandidates(visible).map((p) => p.peerId),
        <String>['ok'],
      );
    });

    test('selectAutoSelectCandidates：按 类别序(本机>群组>其它) → 名称 排序', () {
      final visible = <PeerInfo>[
        _peer(id: 'dlna-z', name: 'Z DLNA', kind: 'dlna', queueActive: true),
        _peer(id: 'grp-b', name: 'B 群组', kind: 'group', queueActive: true),
        _peer(id: 'loc-a', name: 'A 本机', kind: 'local', queueActive: true),
        _peer(id: 'dlna-a', name: 'A DLNA', kind: 'dlna', queueActive: true),
        _peer(id: 'grp-a', name: 'A 群组', kind: 'group', queueActive: true),
      ];
      expect(
        selectAutoSelectCandidates(visible).map((p) => p.peerId),
        <String>['loc-a', 'grp-a', 'grp-b', 'dlna-a', 'dlna-z'],
      );
    });

    test('selectAutoSelectCandidates：空输入 → 空列表', () {
      expect(selectAutoSelectCandidates(<PeerInfo>[]), isEmpty);
    });
  });
}
