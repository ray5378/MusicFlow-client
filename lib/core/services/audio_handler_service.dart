import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:just_audio/just_audio.dart';
import 'package:musicflow_client/core/player/audio_load_config.dart';
import 'package:musicflow_client/core/services/notification_permission_service.dart';
import 'package:musicflow_client/core/utils/logger.dart';
import 'package:musicflow_client/core/theme/color_scheme.dart';

const musicFlowPlaybackSystemActions = <MediaAction>{MediaAction.seek};

/// 音频处理器 - 处理后台播放和通知栏控制
class MusicFlowAudioHandler extends BaseAudioHandler with QueueHandler, SeekHandler {
  final AudioPlayer _audioPlayer;

  // 暴露 AudioPlayer 给外部使用
  AudioPlayer get audioPlayer => _audioPlayer;

  // 用于通知外部的回调
  Function()? onSkipToNext;
  Function()? onSkipToPrevious;
  Future<void> Function(Duration position)? onSeek;

  /// 「当前是否有可播放的曲目」——由上层（PlayerNotifier）注册。
  ///
  /// 通知栏/锁屏/耳机按键的播放键走的是本 handler 的 [play]，它直接驱动
  /// just_audio，**绕开** PlayerNotifier 的状态。而 just_audio 的已加载源在
  /// stop() 之后依然存在，于是「清空队列 / 移除当前曲」之后，系统播控中心
  /// 按一下播放就能让已清空的会话出声，而 App 内迷你条正显示「未在播放」。
  /// 默认 true（未注册时不改变原有行为）。
  bool Function()? canPlay;
  Duration _positionOffset = Duration.zero;

  /// 投屏/直投期间的合成进度：本机已暂停，位置不再自增，改为由投屏侧进度驱动，
  /// 避免系统播控中心（下拉通知/锁屏）的进度条定住在投屏那一瞬间。
  bool _castActive = false;
  bool _castPlaying = true;
  Duration _castPosition = Duration.zero;

  /// 用户手动从后台任务划掉 App 时的回调（由外部注册，如 DLNA 客户端释放保活）。
  /// 本 handler 本身负责停掉本机播放；回调交上层处理投屏等对外资源。
  Future<void> Function()? onTaskRemovedCallback;

  /// 用户手动清理 App（从后台任务划掉）时触发：直接结束 App——
  /// 停掉本机播放，让前台媒体服务随通知消失被回收；由于没有 START_STICKY
  /// 前台服务可重启，进程随后即可被系统回收，不再后台保活/自动重启。
  @override
  Future<void> onTaskRemoved() async {
    try {
      await _audioPlayer.stop();
    } catch (_) {}
    try {
      await onTaskRemovedCallback?.call();
    } catch (_) {}
  }

  MusicFlowAudioHandler(this._audioPlayer) {
    _init();
  }

  /// 设置并广播投屏/直投的合成进度。
  /// [active] 处于投屏态时 true（用投屏进度驱动，忽略暂停的本机播放器）；
  /// [playing] 设备是否正在播放；[position] 投屏当前进度。
  void setCastProgress({
    required bool active,
    required bool playing,
    required Duration position,
  }) {
    _castActive = active;
    _castPlaying = playing;
    _castPosition = position;
    _broadcastState();
  }

  /// 初始化监听器
  void _init() {
    // 监听播放状态变化，同步到通知栏
    _audioPlayer.playingStream.listen((playing) {
      if (_castActive) return; // 投屏中，由投屏进度驱动，忽略本机暂停状态。
      _broadcastState();
    });

    // 监听播放位置
    _audioPlayer.positionStream.listen((position) {
      if (_castActive) return; // 投屏中，位置由 setCastProgress 驱动。
      playbackState.add(
        playbackState.value.copyWith(
          updatePosition: _logicalPosition(position),
        ),
      );
    });

    // 监听播放完成
    _audioPlayer.processingStateStream.listen((processingState) {
      if (_castActive) return;
      _broadcastState();
    });
  }

  /// 广播当前状态到通知栏
  void _broadcastState() {
    final castActive = _castActive;
    final playing = castActive ? _castPlaying : _audioPlayer.playing;
    final position =
        castActive ? _castPosition : _logicalPosition(_audioPlayer.position);
    playbackState.add(
      playbackState.value.copyWith(
        controls: _getControls(playing),
        androidCompactActionIndices: const [0, 1, 2],
        // Explicitly advertise seeking so OEM MediaStyle implementations do
        // not render the notification progress control as disabled.
        systemActions: musicFlowPlaybackSystemActions,
        processingState: _getProcessingState(),
        playing: playing,
        updatePosition: position,
        bufferedPosition: castActive
            ? _castPosition
            : _logicalPosition(_audioPlayer.bufferedPosition),
        // 投屏直接用播放速率让通知栏在两帧推送间平滑外推进度。
        speed: castActive ? (_castPlaying ? 1.0 : 0.0) : _audioPlayer.speed,
      ),
    );
  }

  /// 获取控制按钮
  List<MediaControl> _getControls(bool playing) {
    return [
      MediaControl.skipToPrevious,
      if (playing) MediaControl.pause else MediaControl.play,
      MediaControl.skipToNext,
    ];
  }

  /// 获取处理状态
  AudioProcessingState _getProcessingState() {
    switch (_audioPlayer.processingState) {
      case ProcessingState.idle:
        return AudioProcessingState.idle;
      case ProcessingState.loading:
        return AudioProcessingState.loading;
      case ProcessingState.buffering:
        return AudioProcessingState.buffering;
      case ProcessingState.ready:
        return AudioProcessingState.ready;
      case ProcessingState.completed:
        return AudioProcessingState.completed;
    }
  }

  /// 切歌时的「原始」MediaItem（title = 纯歌名，artist = 真实歌手）。
  ///
  /// 通知栏把主标题改写成「歌名 - 歌手」、副标题改写成歌词行之后再推一份
  /// mediaItem，所以后续每行歌词都必须从这份底稿重新派生——拿已经改写过的
  /// mediaItem 当底稿，歌手名会永久丢失、歌名还会被反复拼接。
  MediaItem? _baseMediaItem;

  /// 更新媒体信息（歌曲切换时调用）
  @override
  Future<void> updateMediaItem(MediaItem item) async {
    _baseMediaItem = item;
    // 立刻按通知栏形态推送（主标题「歌名 - 歌手」+ 副标题歌手），不等第一句
    // 歌词：切歌瞬间通知栏与锁屏就是最终布局，不会先闪一下纯歌名。
    mediaItem.add(applyNotificationLyric(base: item, lyric: null) ?? item);

    // 立即设置为播放状态，激活 MediaSession
    playbackState.add(
      playbackState.value.copyWith(
        controls: _getControls(true),
        androidCompactActionIndices: const [0, 1, 2],
        systemActions: musicFlowPlaybackSystemActions,
        processingState: AudioProcessingState.ready,
        playing: true, // 关键：标记为正在播放
        updatePosition: Duration.zero,
        bufferedPosition: Duration.zero,
        // 倍速播放时通知栏进度也按同一速率外推(否则首帧按 1x 走,下一拍才纠正)。
        speed: _audioPlayer.speed,
      ),
    );
  }

  /// 通知栏实时歌词：主标题保持「歌名 - 歌手」，副标题行放当前歌词。
  ///
  /// 为什么要把歌手并进主标题：Android 11+ 的媒体通知由 SystemUI 直接用
  /// MediaSession 元数据渲染（AOSP `MediaDataManager` 只取
  /// `DISPLAY_TITLE ?? TITLE` 与 `METADATA_KEY_ARTIST`，`MediaData` 结构里
  /// 连 album/description 字段都没有），audio_service 写进 displayDescription
  /// 的 setSubText 在 Android 11+ 上**没有任何消费方**。通知栏只有两行，
  /// 想同时保留歌手信息就只能合并进标题，把副标题整行让给歌词。
  ///
  /// 每次都从[_baseMediaItem]重新派生，只动 metadata 不碰 playbackState：
  /// 进度条/播放态仍由 positionStream/playingStream 推进，歌词刷新不打断它们。
  void updateNotificationLyric(String? lyric) {
    final base = _baseMediaItem;
    if (base == null) return;
    final next = applyNotificationLyric(
      base: base,
      lyric: lyric,
      current: mediaItem.valueOrNull,
    );
    if (next == null) return;
    mediaItem.add(next);
  }

  // ===== 播放控制 =====

  @override
  Future<void> play() async {
    Logger.info('AudioHandler: play');
    // 无当前曲（已清空会话 / 当前曲被移除）时不出声：此时没有「可恢复的播放」，
    // 放行只会让一个已被销毁的会话从系统播控中心复活（见 [canPlay]）。
    if (!(canPlay?.call() ?? true)) {
      Logger.info('AudioHandler: play ignored (no current song)');
      return;
    }
    // Android 13+ 媒体通知权限：本地播放同样依赖媒体前台服务通知，
    // 首次播放时申请一次（幂等、全静默失败降级，不阻断播放）。
    unawaited(ensureMediaNotificationPermission());
    await _audioPlayer.play();
  }

  @override
  Future<void> pause() async {
    Logger.info('AudioHandler: pause');
    await _audioPlayer.pause();
  }

  @override
  Future<void> stop() async {
    Logger.info('AudioHandler: stop');
    await _audioPlayer.stop();
    await super.stop();
  }

  @override
  Future<void> seek(Duration position) async {
    Logger.info('AudioHandler: seek to $position');
    final callback = onSeek;
    if (callback != null) {
      await callback(position);
      return;
    }
    await _audioPlayer.seek(position);
  }

  /// Sets the logical song offset of the currently loaded source.
  ///
  /// A Subsonic `timeOffset` stream starts its decoder timeline at zero even
  /// though it contains audio from the middle of the song. Media-session
  /// progress must add this offset, and seek actions must be delegated back to
  /// PlayerNotifier so it can rebuild the stream URL.
  void setPositionOffset(Duration offset) {
    _positionOffset = offset < Duration.zero ? Duration.zero : offset;
    _broadcastState();
  }

  Duration _logicalPosition(Duration sourcePosition) {
    return sourcePosition + _positionOffset;
  }

  @override
  Future<void> skipToNext() async {
    Logger.info('AudioHandler: skipToNext');
    onSkipToNext?.call();
  }

  @override
  Future<void> skipToPrevious() async {
    Logger.info('AudioHandler: skipToPrevious');
    onSkipToPrevious?.call();
  }

  @override
  Future<void> setSpeed(double speed) async {
    await _audioPlayer.setSpeed(speed);
  }

  /// 清理资源
  Future<void> dispose() async {
    await _audioPlayer.dispose();
  }
}

/// 通知栏副标题在「无歌词」时回落的歌手名占位符（player_provider 侧兜底）。
const String _unknownArtist = 'Unknown Artist';

/// 通知栏主标题：把歌名与歌手合并成「歌名 - 歌手」。
///
/// - 歌手缺失或为 'Unknown Artist' 占位符时只用歌名，不拼出
///   「歌名 - Unknown Artist」这种噪声；
/// - 底稿已是合并形态（`歌名 - 歌手`）时原样返回，避免重复拼接（幂等）。
///
/// 公开给单测锁定；handler 内部只经 [applyNotificationLyric] 使用。
String notificationTitleFor(MediaItem base) {
  final artist = (base.artist ?? '').trim();
  if (artist.isEmpty || artist == _unknownArtist) return base.title;
  final title = base.title.trim();
  if (title.isEmpty) return base.title;
  if (title.endsWith(' - $artist')) return base.title;
  return '$title - $artist';
}

/// 纯函数（单测锁定）：算出「按通知栏形态改写后的 MediaItem」，无需更新返回 null。
///
/// - [base] 是切歌时的原始 MediaItem（title = 纯歌名，artist = 真实歌手），
///   **必须**用它派生，不能拿已改写过的当前项当底稿（歌手名会永久丢失、
///   歌名会被反复拼接后缀）；
/// - 主标题恒为「歌名 - 歌手」（见 [notificationTitleFor]）；
/// - [lyric] 非空 → artist 副标题换成该行；为空 → 还原 [base] 的歌手行；
/// - [current] 是当前已推给平台的项，用于去重：同曲同 title 同 artist 就不重推
///   （每次 metadata 更新在原生侧都会重解析封面位图并重建通知）。
MediaItem? applyNotificationLyric({
  required MediaItem base,
  required String? lyric,
  MediaItem? current,
}) {
  final line = lyric?.trim();
  final hasLine = line != null && line.isNotEmpty;
  final title = notificationTitleFor(base);
  final target = base.copyWith(
    title: title,
    artist: hasLine ? line : base.artist,
  );
  final cur = current;
  if (cur != null &&
      cur.id == target.id &&
      cur.title == target.title &&
      cur.artist == target.artist) {
    return null;
  }
  return target;
}

/// 初始化 AudioService
Future<MusicFlowAudioHandler> initAudioService() async {
  // 缓冲标定取全 App 单一常量源（原两份复制粘贴，2026-10-13 合并，防漂移）。
  final audioPlayer = AudioPlayer(
    audioLoadConfiguration: kAudioLoadConfiguration,
  );

  final handler = await AudioService.init(
    builder: () => MusicFlowAudioHandler(audioPlayer),
    config: const AudioServiceConfig(
      androidNotificationChannelId: 'com.ray5378.musicflow.audio',
      androidNotificationChannelName: "'MusicFlow Playback'",
      androidNotificationChannelDescription: "'MusicFlow playback control'",
      // Android 通知进度条/强调元素使用的底色，避免浅色主题下不可见。
      notificationColor: AppColorScheme.defaultSeedColor,
      androidNotificationOngoing: false, // 允许用户手动关闭通知
      androidNotificationIcon: 'drawable/ic_notification',
      androidShowNotificationBadge: true,
      androidStopForegroundOnPause: false, // 暂停时保持通知栏
      fastForwardInterval: Duration(seconds: 10),
      rewindInterval: Duration(seconds: 10),
    ),
  );

  return handler;
}
