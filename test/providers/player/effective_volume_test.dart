import 'package:flutter_test/flutter_test.dart';

import 'package:musicflow_client/providers/player/effective_volume.dart';

/// 有效音量纯函数单测:锁「直投 > peer > 本机」的显示优先级与
/// 「设备/peer 未回报音量回退本机」的兜底(避免显示成假的 0%)。
void main() {
  group('resolveEffectiveVolume', () {
    test('DLNA 直投且设备回报音量 → 设备音量(0-100 → 0-1)', () {
      expect(
        resolveEffectiveVolume(
          dlnaCasting: true,
          dlnaVolume: 40,
          peerActive: false,
          peerVolume: null,
          localVolume: 0.6,
        ),
        0.4,
      );
      expect(
        resolveEffectiveVolume(
          dlnaCasting: true,
          dlnaVolume: 100,
          peerActive: true,
          peerVolume: 20,
          localVolume: 0.6,
        ),
        1.0,
      );
    });

    test('DLNA 直投但设备未回报(0) → 回退本机音量(不是假 0%)', () {
      expect(
        resolveEffectiveVolume(
          dlnaCasting: true,
          dlnaVolume: 0,
          peerActive: false,
          peerVolume: null,
          localVolume: 0.6,
        ),
        0.6,
      );
    });

    test('peer 投屏且回报音量 → peer 音量(直投未激活时)', () {
      expect(
        resolveEffectiveVolume(
          dlnaCasting: false,
          dlnaVolume: 0,
          peerActive: true,
          peerVolume: 75,
          localVolume: 0.6,
        ),
        0.75,
      );
    });

    test('peer 投屏但未回报(null) → 回退本机音量', () {
      expect(
        resolveEffectiveVolume(
          dlnaCasting: false,
          dlnaVolume: 0,
          peerActive: true,
          peerVolume: null,
          localVolume: 0.6,
        ),
        0.6,
      );
    });

    test('本机(无投屏) → 本机音量', () {
      expect(
        resolveEffectiveVolume(
          dlnaCasting: false,
          dlnaVolume: 0,
          peerActive: false,
          peerVolume: null,
          localVolume: 0.35,
        ),
        0.35,
      );
    });

    test('peer 音量越界值收敛到 0..1', () {
      expect(
        resolveEffectiveVolume(
          dlnaCasting: false,
          dlnaVolume: 0,
          peerActive: true,
          peerVolume: 120,
          localVolume: 0.6,
        ),
        1.0,
      );
      expect(
        resolveEffectiveVolume(
          dlnaCasting: false,
          dlnaVolume: 0,
          peerActive: true,
          peerVolume: -5,
          localVolume: 0.6,
        ),
        0.0,
      );
    });
  });
}
