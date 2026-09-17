// 清空会话的状态契约 —— 「队列清了、歌还在」这个孤儿状态的回归守卫。
//
// 背景（用户实测反馈，2026-09-17）：把本机播放器拖进流转页的回收站销毁后，
// 队列确实空了，但迷你条仍显示歌名、停在销毁那一刻的进度、完整时长，
// 点一下播放还能接着放。
//
// 根因就一行：PlayerState.copyWith 对可空字段用 `?? this.x` 兜底（这是**有意**
// 设计，调用方大量只改一两个字段），于是 `copyWith(currentSong: null)` 等价于
// 「未指定」—— clearQueue 里那句 `currentSong: null` 是**静默空操作**，
// 当前曲从未被清掉；removeFromQueue 移除当前项同理。
//
// 为什么现有测试没拦住：test/features/player/test_player_notifier.dart 那个替身
// 的 clearQueue 直接 `state = PlayerState()`（全新实例，真清干净），于是 cast
// 那一整套流转/销毁测试全绿 —— 替身把「应该怎样」写对了，真实实现静默偏离。
// 所以本文件**不依赖替身**，直接驱动真实的 PlayerNotifier。
//
// 三层防线，逐个锁：
//   A. copyWith 的清除语义（clearCurrentSong / clearPlaybackMeta /
//      clearBufferedPosition）—— 包括把「传 null 清不掉」这个陷阱语义写死，
//      免得有人又用 null 去表达「清空」；
//   B/C. 真实 clearQueue 的落点（全清 / 保留当前曲两种语义都不能改坏）；
//   D/E. 真实 removeFromQueue 的落点（移除当前项 = 会话结束；移除别的歌不动当前曲）。
//
// 关键点：清空**不能**用 `PlayerState()` 一把梭 —— 那会把用户设定（音量、
// 播放模式）一起重置回默认值。B/C 两条专门断言这一点。
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart' hide PlayerState;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:musicflow_client/data/models/audio_quality.dart';
import 'package:musicflow_client/data/models/song.dart';
import 'package:musicflow_client/providers/player/player_provider.dart';

Song _song(String id) => Song(
  id: id,
  title: '曲$id',
  artist: '歌手',
  albumId: 'al1',
  duration: 200,
);

/// 一个「正在播第 2 首」的完整会话：带着进度、时长、缓冲、音质与来源，
/// 并且用户设定（音量 / 播放模式）都不是默认值 —— 这样「清空」有没有
/// 误伤用户设定，一眼可判。
PlayerState _playingSession() => PlayerState(
  currentSong: _song('s2'),
  queue: <Song>[_song('s1'), _song('s2'), _song('s3')],
  currentIndex: 1,
  isPlaying: true,
  processingState: ProcessingState.ready,
  position: const Duration(seconds: 42),
  duration: const Duration(seconds: 200),
  bufferedPosition: const Duration(seconds: 60),
  loopMode: LoopMode.all,
  shuffleEnabled: true,
  playbackMode: PlaybackMode.shuffle,
  shuffleHistoryCount: 3,
  currentQuality: AudioQualityLevel.original,
  playbackSource: PlaybackSource.stream,
  currentBitRateKbps: 1411,
  volume: 0.35,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    // 平台隔离：把 targetPlatform 伪装成 linux，让 PlayerNotifier._init() 走
    // 「桌面 = 不初始化 AudioService」分支，直接构造裸 AudioPlayer。
    //
    // 为什么必须这样：默认（android）分支会调 `AudioService.init`，而它会同步
    // 触发 flutter_cache_manager 的 `DefaultCacheManager()`，其路径查询在测试
    // 环境没有实现 —— 那个异常抛在**脱离 try/catch 的异步链**上，会变成
    // unhandled error 记到第一个用例头上，跟被测逻辑毫无关系。
    // 选 linux 而不是 windows：windows 分支还会去初始化 SMTC 插件，同样打不通。
    //
    // 本文件测的是**状态迁移**（清空会话该落成什么样），与平台无关；
    // 被测的 clearQueue / removeFromQueue / play 都不触碰平台通道。
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
  });

  // ──────────────────────────────────────────────────────────────────
  // A. copyWith 的清除语义（根因所在层，纯函数）
  // ──────────────────────────────────────────────────────────────────
  group('A. PlayerState.copyWith 的清除语义', () {
    test('A1. 不传参数 = 原样保留（既有调用方的前提，不能被改坏）', () {
      final before = _playingSession();
      final after = before.copyWith();

      expect(after.currentSong?.id, 's2');
      expect(after.queue, hasLength(3));
      expect(after.position, const Duration(seconds: 42));
      expect(after.volume, 0.35);
      expect(after.playbackMode, PlaybackMode.shuffle);
    });

    test('A2. 传 currentSong: null **清不掉**（陷阱语义，写死防复踩）', () {
      final before = _playingSession();
      final after = before.copyWith(currentSong: null);

      // 这条断言记录的是「可空字段的 null = 未指定」这个有意约定。
      // 曾经的 bug 就是拿它当「清空」用了 —— 所以它不是坏行为，
      // 但必须被告知：要清空得走 clearCurrentSong。
      expect(
        after.currentSong?.id,
        's2',
        reason: 'copyWith 的 null 是「未指定」；要清空必须用 clearCurrentSong: true',
      );
    });

    test('A3. clearCurrentSong 只清当前曲，用户设定一律不动', () {
      final after = _playingSession().copyWith(clearCurrentSong: true);

      expect(after.currentSong, isNull);
      expect(after.queue, hasLength(3), reason: '只清当前曲，队列由调用方单独给');
      expect(after.volume, 0.35, reason: '音量是用户设定，清会话不该带走');
      expect(after.playbackMode, PlaybackMode.shuffle);
      expect(after.shuffleEnabled, isTrue);
      expect(after.loopMode, LoopMode.all);
    });

    test('A4. clearPlaybackMeta 清掉音质与播放来源两项可空元数据', () {
      final after = _playingSession().copyWith(clearPlaybackMeta: true);

      expect(after.currentQuality, isNull);
      expect(after.playbackSource, isNull);
      expect(after.currentBitRateKbps, 1411, reason: 'Kbps 是非空 int，走普通字段');
      expect(after.currentSong?.id, 's2', reason: '两项互不影响');
    });

    test('A5. clearBufferedPosition 把缓冲进度归零', () {
      final after = _playingSession().copyWith(clearBufferedPosition: true);

      expect(after.bufferedPosition, Duration.zero);
      expect(after.position, const Duration(seconds: 42), reason: '只清缓冲，不动播放位置');
    });

    test('A6. 三个开关可以同时用（clearQueue 的实际形状）', () {
      final after = _playingSession().copyWith(
        clearCurrentSong: true,
        clearPlaybackMeta: true,
        clearBufferedPosition: true,
      );

      expect(after.currentSong, isNull);
      expect(after.currentQuality, isNull);
      expect(after.playbackSource, isNull);
      expect(after.bufferedPosition, Duration.zero);
      expect(after.volume, 0.35, reason: '同时用也不许误伤用户设定');
    });
  });

  // ──────────────────────────────────────────────────────────────────
  // B/C/D/E. 真实 PlayerNotifier 的落点
  // ──────────────────────────────────────────────────────────────────
  //
  // 不复用 test/features/player/test_player_notifier.dart 那个替身 ——
  // 它自己 `state = PlayerState()` 就清干净了，正是它掩盖了真实实现的偏离。
  group('真实 PlayerNotifier 的清空落点', () {
    late ProviderContainer container;
    late PlayerNotifier notifier;

    setUp(() async {
      container = ProviderContainer();
      addTearDown(container.dispose);
      notifier = container.read(playerProvider.notifier);

      // 让构造期的异步起步先落地：`_init()` 会 `await _restorePlayerVolume()`，
      // 把音量写回 SharedPreferences 里的值。不等它，下面注入的「用户设定」
      // 会在断言中途被它改回默认值 —— 那是构造期行为，与本文件被测的
      // 「清空落点」无关，不该混进断言。
      await Future<void>.delayed(Duration.zero);

      notifier.state = _playingSession();
      // 注入必须真的生效，否则后面所有断言都在测空气。
      expect(
        container.read(playerProvider).volume,
        0.35,
        reason: '测试前置：会话已注入且未被构造期覆盖',
      );
    });

    test('B. clearQueue(keepCurrent: false) 把当前曲与整份播放态一起清掉', () async {
      await notifier.clearQueue(keepCurrent: false);
      final after = container.read(playerProvider);

      // 用户实测的四个症状，逐个钉死
      expect(after.currentSong, isNull, reason: '迷你条不该还显示歌名');
      expect(after.queue, isEmpty, reason: '队列清空（这条本来就已经生效）');
      expect(after.position, Duration.zero, reason: '不该还停在销毁那一刻的进度');
      expect(after.duration, Duration.zero, reason: '不该还显示完整时长');
      expect(after.bufferedPosition, Duration.zero);
      expect(after.currentQuality, isNull);
      expect(after.playbackSource, isNull);
      expect(after.isPlaying, isFalse);
      expect(after.processingState, ProcessingState.idle);
      expect(after.currentIndex, 0);
      expect(after.currentBitRateKbps, 0);

      // 但用户设定必须原样留下 —— 这是不能用 `PlayerState()` 一把梭的原因
      expect(after.volume, 0.35, reason: '音量是用户设定，销毁一个播放端不该重置它');
      expect(after.playbackMode, PlaybackMode.shuffle, reason: '播放模式是用户设定');
    });

    test('C. clearQueue(keepCurrent: true) 仍是「只清后续、留下当前曲」', () async {
      await notifier.clearQueue(keepCurrent: true);
      final after = container.read(playerProvider);

      expect(after.currentSong?.id, 's2', reason: '本地清空按钮的既有语义：留着正在播的这首');
      expect(after.queue, hasLength(1));
      expect(after.queue.single.id, 's2');
      expect(after.currentIndex, 0);
    });

    test('D. removeFromQueue(当前项) = 会话结束，整份播放态归零', () async {
      notifier.removeFromQueue(1); // 移除 s2，它就是当前曲
      final after = container.read(playerProvider);

      expect(after.currentSong, isNull, reason: '被移除的歌不该还挂在当前曲上');
      expect(after.queue.map((s) => s.id), <String>['s1', 's3'], reason: '其余歌守恒');
      expect(after.position, Duration.zero);
      expect(after.duration, Duration.zero);
      expect(after.bufferedPosition, Duration.zero);
      expect(after.isPlaying, isFalse);
      expect(after.processingState, ProcessingState.idle);
      expect(after.volume, 0.35, reason: '同样不许误伤用户设定');
    });

    test('E. removeFromQueue(非当前项) 不动当前曲与播放进度', () async {
      notifier.removeFromQueue(0); // 移除 s1，当前曲是 s2
      final after = container.read(playerProvider);

      expect(after.currentSong?.id, 's2');
      expect(after.queue.map((s) => s.id), <String>['s2', 's3']);
      expect(after.currentIndex, 0, reason: '移除位置在当前曲之前，游标要前移一位指回 s2');
      expect(after.position, const Duration(seconds: 42), reason: '删除别的歌不影响播放进度');
      expect(after.isPlaying, isTrue);
    });

    test('F. 空会话下 play() 不复活（已销毁的会话不能从播放键回来）', () async {
      await notifier.clearQueue(keepCurrent: false);
      expect(container.read(playerProvider).currentSong, isNull);

      await notifier.play();

      final after = container.read(playerProvider);
      expect(
        after.currentSong,
        isNull,
        reason: '空会话没有「可恢复的播放」，play() 不许把已加载的旧源带回来',
      );
      expect(after.isPlaying, isFalse, reason: '不许出声');
      expect(after.position, Duration.zero);
    });
  });
}
