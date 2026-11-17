// 通知栏「远端控制目标」路由行为锁（**阻塞**）。
//
// 语义（用户口径，2026-11-17）：通知栏跟首页一致 —— **用户选了哪个设备，
// 显示并控制的就是哪个设备**，不是「谁正在出声就控制谁」。设备缓冲、暂停、
// 离线都不改变「选择」，所以同一次点击在任何时刻都打到同一个设备上。
//
// 本文件锁的是 handler 层接线（纯函数测不到）：
//   - isRemoteTarget 为真时，play/pause/上下一首/seek 一律交给远端委托，
//     绝不驱动本机 just_audio —— 投屏中让本机出声就是双声道；
//   - 委托缺失（未注册/冷启动竞态）时命令被**丢弃**，不回落本机；
//   - 远端选中时 processingState 恒 ready：本机 idle 会让 SystemUI 判定
//     「播放结束」并拆掉通知与前台服务，而远端还在播；
//   - setCastProgress 的节流：播放态/开关变化立刻推，位置按 1s 阈值推。
//
// 为什么必须 `TestWidgetsFlutterBinding.ensureInitialized()`：`AudioPlayer()`
// 内部要实例化 AudioSession，后者依赖 MethodChannel（见同目录 handler 测试）。

import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:musicflow_client/core/services/android_platform_info.dart';
import 'package:musicflow_client/core/services/audio_handler_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MusicFlowAudioHandler handler;
  late bool remote;
  late List<String> remoteCalls;
  late List<Duration> remoteSeeks;

  setUp(() {
    handler = MusicFlowAudioHandler(AudioPlayer());
    remote = true;
    remoteCalls = <String>[];
    remoteSeeks = <Duration>[];
    handler.isRemoteTarget = () => remote;
    handler.onRemotePlay = () async => remoteCalls.add('play');
    handler.onRemotePause = () async => remoteCalls.add('pause');
    handler.onRemoteSkipToNext = () async => remoteCalls.add('next');
    handler.onRemoteSkipToPrevious = () async => remoteCalls.add('previous');
    handler.onRemoteSeek = (position) async => remoteSeeks.add(position);
  });

  tearDown(() async {
    AndroidPlatformInfo.debugSetSdkInt(0);
    await handler.dispose();
  });

  group('远端选中时，通知栏命令交给选中的设备', () {
    test('play / pause 只调远端委托，不驱动本机播放器', () async {
      await handler.play();
      await handler.pause();

      expect(remoteCalls, ['play', 'pause']);
      // 本机 just_audio 完全没被碰过：投屏中本机出声就是双声道。
      expect(handler.audioPlayer.playing, isFalse);
    });

    test('上下一首走远端，本机回调不被触发', () async {
      final local = <String>[];
      handler.onSkipToNext = () => local.add('next');
      handler.onSkipToPrevious = () => local.add('previous');

      await handler.skipToNext();
      await handler.skipToPrevious();

      expect(remoteCalls, ['next', 'previous']);
      expect(local, isEmpty);
    });

    test('seek 下发给设备，本机 onSeek 不被调用', () async {
      final localSeeks = <Duration>[];
      handler.onSeek = (position) async => localSeeks.add(position);

      await handler.seek(const Duration(seconds: 42));

      expect(remoteSeeks, [const Duration(seconds: 42)]);
      expect(localSeeks, isEmpty);
    });

    test('委托缺失时丢弃命令，绝不回落本机', () async {
      handler.onRemotePlay = null;
      handler.onRemotePause = null;
      handler.onRemoteSkipToNext = null;
      handler.onRemoteSkipToPrevious = null;
      handler.onRemoteSeek = null;
      var local = 0;
      handler.onSkipToNext = () => local++;

      await handler.play();
      await handler.pause();
      await handler.skipToNext();
      await handler.skipToPrevious();
      await handler.seek(const Duration(seconds: 5));

      expect(local, 0);
      expect(handler.audioPlayer.playing, isFalse);
    });

    test('未选中远端时维持原路径（本机回调照旧）', () async {
      remote = false;
      final local = <String>[];
      handler.onSkipToNext = () => local.add('next');
      handler.onSkipToPrevious = () => local.add('previous');

      await handler.skipToNext();
      await handler.skipToPrevious();

      expect(local, ['next', 'previous']);
      expect(remoteCalls, isEmpty);
    });
  });

  group('远端选中时不能让系统以为播放结束', () {
    test('本机 idle 也上报 ready（否则通知与前台服务被拆）', () async {
      // setFavoriteState 变值会触发一次 _broadcastState，借它读 processingState。
      handler.setFavoriteState(true);
      expect(
        handler.playbackState.value.processingState,
        AudioProcessingState.ready,
      );
    });

    test('未选中远端时本机 idle 如实上报 idle', () async {
      remote = false;
      handler.setFavoriteState(true);
      expect(
        handler.playbackState.value.processingState,
        AudioProcessingState.idle,
      );
    });

    test('投屏切歌不把进度拽回 0，也不硬报播放中', () async {
      handler.setCastProgress(
        active: true,
        playing: false,
        position: const Duration(seconds: 73),
      );
      await handler.updateMediaItem(MediaItem(id: 'song-2', title: '新歌'));

      final state = handler.playbackState.value;
      expect(state.updatePosition, const Duration(seconds: 73));
      expect(state.playing, isFalse);
      expect(state.speed, 0.0);
    });
  });

  group('投屏进度节流', () {
    test('播放态变化立刻推，位置小幅变化不重复推', () async {
      handler.setCastProgress(
        active: true,
        playing: true,
        position: const Duration(seconds: 10),
      );
      var updates = 0;
      final sub = handler.playbackState.skip(1).listen((_) => updates++);

      handler.setCastProgress(
        active: true,
        playing: true,
        position: const Duration(milliseconds: 10250),
      );
      await Future<void>.delayed(Duration.zero);
      expect(updates, 0, reason: '只差 250ms：系统会按 speed 外推，不必重推');

      handler.setCastProgress(
        active: true,
        playing: false,
        position: const Duration(milliseconds: 10250),
      );
      await Future<void>.delayed(Duration.zero);
      expect(updates, 1, reason: '播放态变化必须立刻推，按钮图标看它');

      await sub.cancel();
    });

    test('位置累计超过 1s 会重推', () async {
      handler.setCastProgress(
        active: true,
        playing: true,
        position: const Duration(seconds: 10),
      );
      var updates = 0;
      final sub = handler.playbackState.skip(1).listen((_) => updates++);

      handler.setCastProgress(
        active: true,
        playing: true,
        position: const Duration(seconds: 11),
      );
      await Future<void>.delayed(Duration.zero);
      expect(updates, 1);

      await sub.cancel();
    });
  });
}
