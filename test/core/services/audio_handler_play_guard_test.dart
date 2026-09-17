// 系统播控中心的「播放」守卫 —— 已清空的会话不许从通知栏/锁屏复活。
//
// 背景（与 test/providers/player/queue_clear_test.dart 同源）：
// 迷你条上的播放键走 PlayerNotifier.togglePlayPause → play()，那条路已经加了
// 空会话守卫。但**通知栏 / 锁屏 / 耳机线控**的播放键走的是 MusicFlowAudioHandler
// 的 play()，它直接驱动 just_audio，**绕开** PlayerNotifier 的整套状态判断。
//
// just_audio 没有公开的卸源 API，stop() 之后已加载的源依然存在 ——
// 于是「清空队列 / 移除当前曲」之后，系统播控中心按一下播放就能让已销毁的
// 会话出声，而 App 内迷你条正显示「未在播放」。两头说法不一致，正是用户报的
// 「还留着孤儿状态」最难察觉的那一半。
//
// 守卫机制：handler 暴露 canPlay 回调，由 PlayerNotifier 注册为
// `() => state.currentSong != null`；未注册时默认放行（不改变既有行为）。
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:mocktail/mocktail.dart';
import 'package:musicflow_client/core/services/audio_handler_service.dart';

class _MockAudioPlayer extends Mock implements AudioPlayer {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _MockAudioPlayer player;

  setUp(() {
    player = _MockAudioPlayer();
    // handler 的 _init() 会订阅这三条流；不桩就会在 null 上调 listen。
    when(() => player.playingStream).thenAnswer((_) => const Stream<bool>.empty());
    when(
      () => player.positionStream,
    ).thenAnswer((_) => const Stream<Duration>.empty());
    when(
      () => player.processingStateStream,
    ).thenAnswer((_) => const Stream<ProcessingState>.empty());
  });

  test('无当前曲（canPlay 为 false）→ 播控中心的播放键不出声', () async {
    final handler = MusicFlowAudioHandler(player);
    handler.canPlay = () => false;

    await handler.play();

    verifyNever(() => player.play());
  });

  test('有当前曲（canPlay 为 true）→ 照常驱动播放器', () async {
    final handler = MusicFlowAudioHandler(player);
    handler.canPlay = () => true;
    when(() => player.play()).thenAnswer((_) async {});

    await handler.play();

    verify(() => player.play()).called(1);
  });

  test('未注册 canPlay → 默认放行（不改变既有行为）', () async {
    final handler = MusicFlowAudioHandler(player);
    when(() => player.play()).thenAnswer((_) async {});

    await handler.play();

    verify(() => player.play()).called(1);
  });

  test('canPlay 每次调用实时求值（不是构造时快照）', () async {
    final handler = MusicFlowAudioHandler(player);
    when(() => player.play()).thenAnswer((_) async {});
    var hasSong = false;
    handler.canPlay = () => hasSong;

    await handler.play();
    verifyNever(() => player.play());

    hasSong = true; // 用户重新起播后，同一个 handler 必须恢复可用
    await handler.play();
    verify(() => player.play()).called(1);
  });
}
