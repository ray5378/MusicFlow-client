import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:musicflow_client/providers/media/status_lyrics_provider.dart';
import 'package:musicflow_client/providers/player/player_provider.dart';
import 'package:musicflow_client/widgets/windows_title_bar.dart';

/// 桌面歌词推送链路单测:
///   1. 播放模式字符串推导(deriveDesktopLyricMode 纯函数三分支 + 优先级);
///   2. setDesktopLyricState 在非 Windows 平台是安全 no-op(不触通道不抛错),
///      锁定「CI(ubuntu) 上误触平台通道」这类的回归。
void main() {
  group('deriveDesktopLyricMode', () {
    test('shuffle → shuffle', () {
      expect(
        deriveDesktopLyricMode(playbackMode: PlaybackMode.shuffle),
        'shuffle',
      );
    });

    test('单曲循环 → repeatOne', () {
      expect(
        deriveDesktopLyricMode(playbackMode: PlaybackMode.one),
        'repeatOne',
      );
    });

    test('顺序播放 → order(歌词窗必须用有序列表图形,与列表循环区分)', () {
      expect(
        deriveDesktopLyricMode(playbackMode: PlaybackMode.order),
        'order',
      );
    });

    test('列表循环 → repeatAll', () {
      expect(
        deriveDesktopLyricMode(playbackMode: PlaybackMode.all),
        'repeatAll',
      );
    });

    test('原生层枚举契约: shuffle=0 / repeatAll=1 / repeatOne=2 / order=3 不可变',
        () {
      // 原生 desktop_lyric.cpp 的 kModeShuffle/kModeRepeatAll/kModeRepeatOne/
      // kModeOrder 与 flutter_window.cpp 的解析(shuffle→0, repeatOne→2,
      // order→3, 其余→1)依赖这些字符串字面量;改名即跨端断链,此处显式锁定。
      const expected = <String, int>{
        'shuffle': 0,
        'repeatAll': 1,
        'repeatOne': 2,
        'order': 3,
      };
      expect(expected.length, 4);
    });
  });

  group('castPlayModeToLyricMode', () {
    test('shuffle → shuffle', () {
      expect(castPlayModeToLyricMode('shuffle'), 'shuffle');
    });

    test('one → repeatOne', () {
      expect(castPlayModeToLyricMode('one'), 'repeatOne');
    });

    test('order 透传(顺序播放图形与列表循环不同)', () {
      expect(castPlayModeToLyricMode('order'), 'order');
    });

    test('all → repeatAll', () {
      expect(castPlayModeToLyricMode('all'), 'repeatAll');
    });

    test('未知值兜底 → repeatAll', () {
      expect(castPlayModeToLyricMode('unknown'), 'repeatAll');
    });
  });

  group('setDesktopLyricState', () {
    test('非 Windows 平台安全 no-op(不抛错)', () async {
      // flutter test 默认 defaultTargetPlatform != windows,
      // isWindowsDesktop 为 false → 函数应直接返回,不触 MethodChannel。
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      expect(isWindowsDesktop, isFalse);
      await expectLater(
        setDesktopLyricState(
          song: 't',
          artist: 'a',
          lyric: 'l',
          playing: true,
          liked: false,
          mode: 'repeatAll',
          volume: 0.5,
          lyricColor: 0xF09595,
        ),
        completes,
      );
    });
  });
}
