// 起播缓冲标定（AudioLoadConfiguration 单一常量源）守卫。
//
// 背景（2026-10-13）：该配置原先在 `lib/core/services/audio_handler_service.dart`
// （AudioService 初始化）与 `lib/providers/player/player_provider.dart`（桌面端降级
// 路径）各复制粘贴一份。合并为 `lib/core/player/audio_load_config.dart` 单一常量源
// 后，本文件两道守卫：
//   ① 常量值钉死（5s/10s 起播档 + 10min/15min 驻留窗 + Darwin 10min）——
//      与服务端「首字节后 13~21MB/s 瞬间填满、非起播瓶颈」的实测认知对齐；
//   ② 静态防漂移：两处原复制粘贴点不得再出现内联 LoadControl 参数，必须引用
//      单一常量源（重新内联即失败）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:musicflow_client/core/player/audio_load_config.dart';

void main() {
  group('AudioLoadConfiguration 单一常量源', () {
    test('① 标定值钉死（与服务端起播策略的认知对齐）', () {
      const cfg = kAudioLoadConfiguration;
      final android = cfg.androidLoadControl!;
      expect(android.bufferForPlaybackDuration, const Duration(seconds: 5));
      expect(
        android.bufferForPlaybackAfterRebufferDuration,
        const Duration(seconds: 10),
      );
      expect(android.minBufferDuration, const Duration(minutes: 10));
      expect(android.maxBufferDuration, const Duration(minutes: 15));
      expect(
        cfg.darwinLoadControl?.preferredForwardBufferDuration,
        const Duration(minutes: 10),
      );
    });

    test('② 防漂移：两处调用方引用单一常量源，无内联 LoadControl 参数', () {
      const sites = <String>[
        'lib/core/services/audio_handler_service.dart',
        'lib/providers/player/player_provider.dart',
      ];
      for (final path in sites) {
        final src = File(path).readAsStringSync();
        expect(
          src.contains('AndroidLoadControl('),
          isFalse,
          reason: '$path 不得再内联 AndroidLoadControl（应引用 kAudioLoadConfiguration）',
        );
        expect(
          src.contains('kAudioLoadConfiguration'),
          isTrue,
          reason: '$path 应引用 kAudioLoadConfiguration',
        );
      }
    });
  });
}
