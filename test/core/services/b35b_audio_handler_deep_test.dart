// b35b: audio_handler_service.dart 深水区补测(已有 audio_handler_service_test
// 未覆盖分支)。产品代码零改动。
// 覆盖: onTaskRemoved(停机+回调/异常容错)、play 的 canPlay 门禁、pause/stop/
// seek 回退到播放器、skipToNext/Previous 回调、setSpeed、updateMediaItem 状态
// 广播、setCastProgress 合成进度(playing/paused)与投屏期忽略本机流、
// position/processingState 流驱动广播、setPositionOffset 负值钳制。

import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:mocktail/mocktail.dart';

import 'package:musicflow_client/core/services/audio_handler_service.dart';

class _MockAudioPlayer extends Mock implements AudioPlayer {}

void main() {
  late _MockAudioPlayer player;
  late StreamController<bool> playingCtrl;
  late StreamController<Duration> positionCtrl;
  late StreamController<ProcessingState> processingCtrl;
  late MusicFlowAudioHandler handler;

  setUp(() {
    player = _MockAudioPlayer();
    playingCtrl = StreamController<bool>.broadcast();
    positionCtrl = StreamController<Duration>.broadcast();
    processingCtrl = StreamController<ProcessingState>.broadcast();
    when(() => player.playingStream).thenAnswer((_) => playingCtrl.stream);
    when(() => player.positionStream).thenAnswer((_) => positionCtrl.stream);
    when(() => player.processingStateStream)
        .thenAnswer((_) => processingCtrl.stream);
    when(() => player.playing).thenReturn(false);
    when(() => player.processingState).thenReturn(ProcessingState.ready);
    when(() => player.position).thenReturn(Duration.zero);
    when(() => player.bufferedPosition).thenReturn(Duration.zero);
    when(() => player.speed).thenReturn(1.0);
    when(() => player.play()).thenAnswer((_) async {});
    when(() => player.pause()).thenAnswer((_) async {});
    when(() => player.stop()).thenAnswer((_) async {});
    when(() => player.seek(any())).thenAnswer((_) async {});
    when(() => player.setSpeed(any())).thenAnswer((_) async {});
    when(() => player.dispose()).thenAnswer((_) async {});
    handler = MusicFlowAudioHandler(player);
  });

  tearDown(() async {
    await playingCtrl.close();
    await positionCtrl.close();
    await processingCtrl.close();
  });

  group('onTaskRemoved', () {
    test('停掉本机播放并执行外部回调', () async {
      var called = 0;
      handler.onTaskRemovedCallback = () async => called++;
      await handler.onTaskRemoved();
      verify(() => player.stop()).called(1);
      expect(called, 1);
    });

    test('player.stop 抛异常仍执行回调', () async {
      when(() => player.stop()).thenThrow(StateError('stop boom'));
      var called = 0;
      handler.onTaskRemovedCallback = () async => called++;
      await handler.onTaskRemoved();
      expect(called, 1);
    });

    test('回调抛异常不向上传播', () async {
      handler.onTaskRemovedCallback = () async => throw StateError('cb boom');
      await handler.onTaskRemoved();
      verify(() => player.stop()).called(1);
    });

    test('无回调时仅停播放', () async {
      await handler.onTaskRemoved();
      verify(() => player.stop()).called(1);
    });
  });

  group('play / pause / stop / seek / skip / speed', () {
    test('canPlay 为 false → 忽略 play,不驱动播放器', () async {
      handler.canPlay = () => false;
      await handler.play();
      verifyNever(() => player.play());
    });

    test('canPlay 未注册 → 默认放行 play', () async {
      await handler.play();
      verify(() => player.play()).called(1);
    });

    test('canPlay 为 true → play 放行', () async {
      handler.canPlay = () => true;
      await handler.play();
      verify(() => player.play()).called(1);
    });

    test('pause 委托播放器', () async {
      await handler.pause();
      verify(() => player.pause()).called(1);
    });

    test('stop 停播放器', () async {
      await handler.stop();
      verify(() => player.stop()).called(1);
    });

    test('无 onSeek 回调 → 直接 seek 播放器', () async {
      await handler.seek(const Duration(seconds: 9));
      verify(() => player.seek(const Duration(seconds: 9))).called(1);
    });

    test('skipToNext/Previous 触发回调', () async {
      var next = 0;
      var prev = 0;
      handler.onSkipToNext = () => next++;
      handler.onSkipToPrevious = () => prev++;
      await handler.skipToNext();
      await handler.skipToPrevious();
      expect(next, 1);
      expect(prev, 1);
    });

    test('setSpeed 委托播放器', () async {
      await handler.setSpeed(1.5);
      verify(() => player.setSpeed(1.5)).called(1);
    });
  });

  group('状态广播', () {
    test('updateMediaItem: 媒体信息写入且立即标记 ready/playing', () async {
      await handler.updateMediaItem(const MediaItem(id: 's1', title: 'T'));
      expect(handler.mediaItem.valueOrNull?.id, 's1');
      final ps = handler.playbackState.value;
      expect(ps.processingState, AudioProcessingState.ready);
      expect(ps.playing, isTrue);
      expect(ps.updatePosition, Duration.zero);
      expect(ps.speed, 1.0);
    });

    test('playingStream 事件 → 广播 playing 与对应控制按钮', () async {
      playingCtrl.add(true);
      await Future<void>.delayed(Duration.zero);
      final ps = handler.playbackState.value;
      expect(ps.playing, isFalse); // mock player.playing 默认 false
      // playing=false → 播放/暂停按钮应展示 play。
      expect(
        ps.controls.any((c) => c.action == MediaAction.play),
        isTrue,
      );

      when(() => player.playing).thenReturn(true);
      playingCtrl.add(true);
      await Future<void>.delayed(Duration.zero);
      expect(
        handler.playbackState.value.controls
            .any((c) => c.action == MediaAction.pause),
        isTrue,
      );
    });

    test('processingStateStream 事件 → 映射 completed', () async {
      when(() => player.processingState)
          .thenReturn(ProcessingState.completed);
      processingCtrl.add(ProcessingState.completed);
      await Future<void>.delayed(Duration.zero);
      expect(handler.playbackState.value.processingState,
          AudioProcessingState.completed);
    });

    test('positionStream 事件 → 逻辑位置 = 位置 + 偏移', () async {
      handler.setPositionOffset(const Duration(seconds: 30));
      positionCtrl.add(const Duration(seconds: 5));
      await Future<void>.delayed(Duration.zero);
      expect(handler.playbackState.value.updatePosition,
          const Duration(seconds: 35));
    });

    test('setPositionOffset 负值钳制为 0', () async {
      handler.setPositionOffset(const Duration(seconds: -5));
      positionCtrl.add(const Duration(seconds: 5));
      await Future<void>.delayed(Duration.zero);
      expect(handler.playbackState.value.updatePosition,
          const Duration(seconds: 5));
    });
  });

  group('投屏合成进度', () {
    test('cast 播放中: 通知栏 playing/速率/进度由投屏驱动', () async {
      handler.setCastProgress(
        active: true,
        playing: true,
        position: const Duration(minutes: 1),
      );
      final ps = handler.playbackState.value;
      expect(ps.playing, isTrue);
      expect(ps.speed, 1.0);
      expect(ps.updatePosition, const Duration(minutes: 1));
      expect(ps.bufferedPosition, const Duration(minutes: 1));
    });

    test('cast 暂停: 速率 0,进度保持', () async {
      handler.setCastProgress(
        active: true,
        playing: false,
        position: const Duration(seconds: 42),
      );
      final ps = handler.playbackState.value;
      expect(ps.playing, isFalse);
      expect(ps.speed, 0.0);
      expect(ps.updatePosition, const Duration(seconds: 42));
    });

    test('cast 激活期间: 本机 playing/position/processing 流被忽略', () async {
      handler.setCastProgress(
        active: true,
        playing: true,
        position: const Duration(seconds: 10),
      );
      when(() => player.playing).thenReturn(false);
      playingCtrl.add(false);
      positionCtrl.add(const Duration(seconds: 99));
      when(() => player.processingState)
          .thenReturn(ProcessingState.completed);
      processingCtrl.add(ProcessingState.completed);
      await Future<void>.delayed(Duration.zero);

      final ps = handler.playbackState.value;
      expect(ps.playing, isTrue); // 仍由 cast 驱动
      expect(ps.updatePosition, const Duration(seconds: 10));
      expect(ps.processingState, AudioProcessingState.ready); // 未被本机覆盖
    });

    test('cast 退出后: 恢复由本机播放器驱动', () async {
      handler.setCastProgress(
        active: true,
        playing: true,
        position: const Duration(seconds: 10),
      );
      handler.setCastProgress(
        active: false,
        playing: false,
        position: Duration.zero,
      );
      when(() => player.playing).thenReturn(false);
      when(() => player.position).thenReturn(const Duration(seconds: 7));
      playingCtrl.add(false);
      await Future<void>.delayed(Duration.zero);
      final ps = handler.playbackState.value;
      expect(ps.playing, isFalse);
      expect(ps.speed, 1.0); // 本机速率
      expect(ps.updatePosition, const Duration(seconds: 7));
    });

    test('dispose 释放播放器', () async {
      await handler.dispose();
      verify(() => player.dispose()).called(1);
    });
  });
}
