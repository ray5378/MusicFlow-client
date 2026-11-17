// 通知栏歌词控制器的**运行时**行为锁（时钟 / 外推 / 切歌 / 去重）。
//
// 为什么单独一个文件：
//   `notification_lyrics_test.dart` 锁的是纯函数（resolveLyricPosition 等），
//   但「后台歌词不走」那次事故（v5.17.8）坏的不是公式，而是**谁来按拍子调用**：
//   just_audio 的 positionStream 退到后台会停摆，所以控制器必须自持 300ms 时钟，
//   并在真实进度不动时用锚点外推。这套时序只有跑起来才看得见，纯函数测不到。
//
// 依赖处理：
//   - playerProvider → 换成 TestPlayerNotifier 子类，state 可随时 emit；
//   - audioHandler    → 换成记录型 handler，把「推给通知栏的那一行」记下来；
//   - currentLyricsProvider → 直接给一份同步歌词；
//   - debugDefaultTargetPlatformOverride → android。控制器在桌面平台会直接 return
//     （桌面没有 audio_service 通知），不设它整个文件都测不到东西。
//
// 时间：用真实延迟。控制器是按真实 Timer 驱动的，fake_async 里 Riverpod 的异步
// provider 完成时机容易和时钟错位，宁可多等几秒也不要一个偶发红的用例。

// ignore_for_file: avoid_print

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart' hide PlayerState;
import 'package:musicflow_client/core/services/audio_handler_service.dart';
import 'package:musicflow_client/data/models/lyrics.dart';
import 'package:musicflow_client/data/models/lyrics_line.dart';
import 'package:musicflow_client/data/models/song.dart';
import 'package:musicflow_client/data/models/structured_lyrics.dart';
import 'package:musicflow_client/providers/media/lyrics_cover_provider.dart';
import 'package:musicflow_client/providers/media/notification_lyrics_provider.dart';
import 'package:musicflow_client/providers/player/player_provider.dart';

import '../features/player/test_player_notifier.dart';

/// 只记录推送、不真去改 MediaItem 的 handler。
class _RecordingHandler extends MusicFlowAudioHandler {
  _RecordingHandler() : super(AudioPlayer());

  final List<String?> pushes = <String?>[];

  @override
  void updateNotificationLyric(String? lyric) {
    pushes.add(lyric);
  }

  String? get last => pushes.isEmpty ? null : pushes.last;
}

class _FakePlayer extends TestPlayerNotifier {
  _FakePlayer(super.state);

  MusicFlowAudioHandler? handler;

  @override
  MusicFlowAudioHandler? get audioHandler => handler;
}

/// 三行同步歌词：0ms / 900ms / 1800ms。
Lyrics _lyrics() => Lyrics(
      sourceId: 'test',
      entries: [
        StructuredLyrics(
          synced: true,
          lines: [
            LyricsLine(startMs: 0, value: '第一句'),
            LyricsLine(startMs: 900, value: '第二句'),
            LyricsLine(startMs: 1800, value: '第三句'),
          ],
        ),
      ],
    );

PlayerState _state({
  String id = 'song-1',
  Duration position = Duration.zero,
  bool playing = true,
}) =>
    PlayerState(
      currentSong: Song(id: id, title: '歌名'),
      position: position,
      isPlaying: playing,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ProviderContainer container;
  late _FakePlayer player;
  late _RecordingHandler recorder;

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    player = _FakePlayer(_state());
    recorder = _RecordingHandler();
    player.handler = recorder;
    container = ProviderContainer(
      overrides: [
        playerProvider.overrideWith(() => player),
        currentLyricsProvider.overrideWith((ref) async => _lyrics()),
      ],
    );
  });

  tearDown(() {
    container.dispose();
    debugDefaultTargetPlatformOverride = null;
  });

  test('首拍就把当前行推给通知栏（不用等下一句歌词）', () async {
    container.read(notificationLyricsControllerProvider);
    await Future<void>.delayed(const Duration(milliseconds: 400));

    expect(recorder.pushes, isNotEmpty);
    expect(recorder.last, '第一句');
  });

  test('进度流停摆（后台）时按锚点外推，歌词继续逐行走', () async {
    container.read(notificationLyricsControllerProvider);
    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect(recorder.last, '第一句');

    // 关键：position 一直不动（后台 just_audio 的典型表现）。
    await Future<void>.delayed(const Duration(milliseconds: 1200));

    expect(
      recorder.pushes,
      contains('第二句'),
      reason: '真实进度停摆后必须靠「锚点 + 经过时间」继续走，否则后台歌词卡死',
    );
  });

  test('暂停时冻结在当前行，不随时间前进', () async {
    player.emit(_state(playing: false));
    container.read(notificationLyricsControllerProvider);
    await Future<void>.delayed(const Duration(milliseconds: 1300));

    expect(recorder.pushes, isNotEmpty);
    // 首拍会先推一次 null（锚点换曲 → 清空副标题），之后不许再往前走。
    expect(
      recorder.pushes.where((line) => line != null && line != '第一句'),
      isEmpty,
      reason: '暂停期间位置冻结，歌词不该自己往下滚',
    );
    expect(recorder.last, '第一句');
  });

  test('同一行不重复推送（原生每次 metadata 更新都会重建通知）', () async {
    player.emit(_state(playing: false));
    container.read(notificationLyricsControllerProvider);
    await Future<void>.delayed(const Duration(milliseconds: 1000));

    expect(recorder.pushes.where((line) => line == '第一句').length, 1);
  });

  test('切歌先推空行，上一首的歌词不许跟着新歌上屏', () async {
    container.read(notificationLyricsControllerProvider);
    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect(recorder.last, '第一句');

    player.emit(_state(id: 'song-2'));
    await Future<void>.delayed(const Duration(milliseconds: 400));

    expect(
      recorder.pushes,
      contains(null),
      reason: '换曲必须显式清空副标题，等新歌词到达再补第一行',
    );
    expect(recorder.last, isNot('第一句'));
  });

  test('dispose 之后不再推送（定时器与歌词订阅都要断）', () async {
    final controller = container.read(notificationLyricsControllerProvider);
    await Future<void>.delayed(const Duration(milliseconds: 400));
    final before = recorder.pushes.length;

    controller.dispose();
    await Future<void>.delayed(const Duration(milliseconds: 500));

    expect(recorder.pushes.length, before);
  });
}
