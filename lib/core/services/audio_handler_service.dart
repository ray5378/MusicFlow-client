import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:just_audio/just_audio.dart';
import 'package:musicflow_client/core/l10n/localizations.dart';
import 'package:musicflow_client/core/player/audio_load_config.dart';
import 'package:musicflow_client/core/services/android_platform_info.dart';
import 'package:musicflow_client/core/services/notification_permission_service.dart';
import 'package:musicflow_client/core/utils/logger.dart';
import 'package:musicflow_client/core/theme/color_scheme.dart';

const musicFlowPlaybackSystemActions = <MediaAction>{MediaAction.seek};

/// 通知栏收藏按钮的 custom action 名：`MediaControl.custom(name:)` 与
/// [MusicFlowAudioHandler.customAction] 的 `name` 必须一致，系统点击后原样回传。
const String kNotificationFavoriteAction = 'toggleFavorite';

/// 收藏已开启（实心红心）的 Android drawable 资源名。
const String kNotificationFavoriteIconOn = 'drawable/ic_notif_favorite';

/// 收藏未开启（空心红心）的 Android drawable 资源名。
const String kNotificationFavoriteIconOff = 'drawable/ic_notif_favorite_border';

/// 通知栏收藏按钮（纯函数，单测锁定图标/名称/文案契约）。
///
/// 图标只能是「包内 drawable 资源名」：SystemUI 用
/// `Icon.createWithResource(packageName, customAction.icon)` 加载，资源缺失
/// 时按钮会变成空白方块——两个 drawable 必须随代码一起打包。
MediaControl notificationFavoriteControl({
  required bool starred,
  required String label,
}) {
  return MediaControl.custom(
    androidIcon:
        starred ? kNotificationFavoriteIconOn : kNotificationFavoriteIconOff,
    label: label,
    name: kNotificationFavoriteAction,
  );
}

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

  /// 「切换当前歌收藏」——由上层（PlayerNotifier）注册。
  ///
  /// 通知栏心形按钮点下去走的是原生 → [customAction]，本 handler 拿不到
  /// 收藏的业务依赖（队列、服务端接口、本地镜像）；所以只做转发，返回切换后
  /// 的 starred（失败返回 null，图标保持原样）。未注册时按钮点击静默无操作。
  Future<bool?> Function()? onToggleFavorite;

  /// 当前歌是否已收藏：决定通知栏心形是实心还是空心。
  ///
  /// 唯一真源是播放状态里的 `Song.starred`，本 handler 只缓存一份用于画图标；
  /// 每次切歌由 [updateMediaItem] 从 MediaItem.extras 重置，其它入口（迷你条、
  /// 列表页、服务端推送）改收藏后由上层调 [setFavoriteState] 对齐。
  bool _favoriteStarred = false;
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
  ///
  /// 收藏按钮排在最后：Android 13 的 SystemUI 把标准键填进前三个槽
  /// （play / next / prev），自定义 action 只会落到展开态的第 4、5 个槽
  /// （AOSP `MediaDataManager.createMediaButton`）。所以它只出现在下拉展开后
  /// 的一排按钮里，不挤占折叠态那三个常用键。
  List<MediaControl> _getControls(bool playing) {
    return [
      MediaControl.skipToPrevious,
      if (playing) MediaControl.pause else MediaControl.play,
      MediaControl.skipToNext,
      _favoriteControl(),
    ];
  }

  /// 收藏按钮：文案随语言偏好走 [l10nNowCurrent]（handler 没有 BuildContext；
  /// CI 的 `check-l10n.mjs --gate-cjk` 禁止硬编码文案）。
  MediaControl _favoriteControl() {
    final loc = l10nNowCurrent();
    return notificationFavoriteControl(
      starred: _favoriteStarred,
      label: _favoriteStarred
          ? loc.core_notification_unfavorite
          : loc.core_notification_favorite,
    );
  }

  /// 同步通知栏心形状态（收藏可能从任何入口改变：通知按钮、迷你条、列表页、
  /// 其它端推送）。变化时重推一次 playbackState —— 图标不同即
  /// [MediaControl] 不相等，原生侧才会更新按钮。
  void setFavoriteState(bool starred) {
    if (_favoriteStarred == starred) return;
    _favoriteStarred = starred;
    _broadcastState();
  }

  /// 接收通知栏自定义按钮点击：目前只有收藏。
  ///
  /// 只转发给 [onToggleFavorite]，拿返回值后再对一次图标——业务侧虽然也会
  /// 调 [setFavoriteState]，但这里兜底能保证「点了就该变」的直觉行为不会
  /// 因为上层某条路径漏同步而失效（幂等，重复设置同值直接早退）。
  @override
  Future<dynamic> customAction(String name, [Map<String, dynamic>? extras]) async {
    if (name == kNotificationFavoriteAction) {
      final toggle = onToggleFavorite;
      if (toggle == null) return null;
      final next = await toggle();
      if (next != null) setFavoriteState(next);
      return null;
    }
    return super.customAction(name, extras);
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
  /// 通知栏副标题会被改写成歌词行后再推一份 mediaItem，所以每行歌词都必须
  /// 从这份底稿重新派生——拿已经改写过的 mediaItem 当底稿，歌名/歌手会被
  /// 一次次叠加污染。
  MediaItem? _baseMediaItem;

  /// 当前曲目最后推送的那行歌词（null = 无歌词，副标题留空）。
  ///
  /// 存在的唯一理由：**同曲重推 mediaItem 时不能被清空**。切歌后播放器还会
  /// 因为交叉淡入/预加载/metadata 刷新再调几次 [updateMediaItem]，若每次都
  /// 按「无歌词」重推，副标题就会被反复打回空白，而 controller 只在歌词行
  /// *变化*时才推——于是通知栏卡在空白直到下一句歌词，表现为「切歌后歌词
  /// 不加载」。这里记住当前行，同曲重推时原样带回；换曲才清空。
  String? _lastLyric;

  /// 更新媒体信息（歌曲切换时调用）
  @override
  Future<void> updateMediaItem(MediaItem item) async {
    final previousSongId = _baseMediaItem?.id;
    _baseMediaItem = item;
    // 收藏状态随曲目重置：extras 由 player_provider 按 Song.starred 写成
    // '1'/'0'（Bundle 只安全承载基础类型）。这里必须在下面那次 playbackState
    // 广播之前赋值，否则新歌第一帧的心形会沿用上一首的状态。
    _favoriteStarred = item.extras?['starred'] == '1';
    // 同曲重推（交叉淡入 / metadata 刷新）保留已显示的歌词行；换曲则清空，
    // 副标题空着等新歌词到达，绝不用歌手名占位。
    _lastLyric = resolvePreservedLyric(
      previousSongId: previousSongId,
      nextSongId: item.id,
      lastLyric: _lastLyric,
    );
    mediaItem.add(
      applyNotificationLyric(
        base: item,
        lyric: _lastLyric,
        threeLineLayout: AndroidPlatformInfo.useLegacyThreeLineNotification,
      ) ??
          item,
    );

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

  /// 通知栏实时歌词：主标题保持纯歌名，副标题行整行放当前歌词。
  ///
  /// 布局依据（AOSP 取证）：Android 11+ 的媒体通知由 SystemUI 直接用
  /// MediaSession 元数据渲染（`MediaDataManager` 只取
  /// `DISPLAY_TITLE ?? TITLE` 与 `METADATA_KEY_ARTIST`，`MediaData` 结构里
  /// 连 album/description 字段都没有），audio_service 写进 displayDescription
  /// 的 setSubText 在 Android 11+ 上**没有任何消费方**。所以通知栏只有两行：
  /// 歌名 + 副标题，副标题独占歌词。
  ///
  /// 无歌词时副标题**留空**（不是回落到歌手）：歌手占位会让人误以为「歌词
  /// 没加载」，而切歌到新歌词到达之间必然有这个空窗，宁可空一行也不要给错
  /// 信息。歌手信息仍在 App 内（迷你条/播放页）与锁屏的其它区域可查。
  ///
  /// 每次都从[_baseMediaItem]重新派生，只动 metadata 不碰 playbackState：
  /// 进度条/播放态仍由 positionStream/playingStream 推进，歌词刷新不打断它们。
  void updateNotificationLyric(String? lyric) {
    final base = _baseMediaItem;
    if (base == null) return;
    final line = lyric?.trim();
    _lastLyric = (line == null || line.isEmpty) ? null : line;
    final next = applyNotificationLyric(
      base: base,
      lyric: _lastLyric,
      current: mediaItem.valueOrNull,
      threeLineLayout: AndroidPlatformInfo.useLegacyThreeLineNotification,
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

/// 副标题「无歌词」时写入的空串。
///
/// 为什么是空串而不是回落到歌手：SystemUI 只在 `METADATA_KEY_ARTIST` 为
/// **null** 时才 fallback 到通知正文，空串会被原样渲染成空行（TextView 高度
/// 归零，视觉上不占位）。给歌手名反而是在「没有歌词」时给出错误信息。
const String kNotificationEmptyLyric = '';

/// 换曲 / 同曲重推 mediaItem 时，决定副标题沿用的歌词行。
///
/// - 同曲（[previousSongId] == [nextSongId]）：返回 [lastLyric]。
///   交叉淡入、预加载完成、metadata 刷新都会再调一次 updateMediaItem，
///   每次都按「无歌词」重推会把已显示的歌词打回空白，而 controller 只在
///   歌词行*变化*时才推 → 通知栏卡在空白直到下一句，表现为「切歌后歌词
///   不加载」。
/// - 换曲（或首次推送 [previousSongId] 为 null）：返回 null —— 上一首的
///   歌词绝不能跟着新歌上屏。
String? resolvePreservedLyric({
  required String? previousSongId,
  required String nextSongId,
  required String? lastLyric,
}) {
  return previousSongId == nextSongId ? lastLyric : null;
}

/// 纯函数（单测锁定）：算出「按通知栏形态改写后的 MediaItem」，无需更新返回 null。
///
/// 两种布局按 Android 版本分叉（见 [AndroidPlatformInfo]）：
///
/// | API | 标题 | 副标题 | 第三行 subText |
/// |-----|------|--------|----------------|
/// | >= 30（SystemUI 媒体卡片） | 歌名 | 歌词（无歌词留空） | 不渲染 |
/// | < 30（自建 MediaStyle 通知） | 歌名 | 歌手 | 歌词（无歌词回落专辑） |
///
/// - [base] 是切歌时的原始 MediaItem（title = 纯歌名），**必须**用它派生，
///   不能拿已改写过的当前项当底稿；
/// - [lyric] 为空时：30+ 副标题留 [kNotificationEmptyLyric]（绝不回落歌手，
///   否则会被误认为「歌词没加载」）；< 30 第三行回落专辑名；
/// - [current] 用于去重：同曲同 id 同歌词就不重推（每次 metadata 更新在原生侧
///   都会重新解析封面位图并重建通知）。
MediaItem? applyNotificationLyric({
  required MediaItem base,
  required String? lyric,
  MediaItem? current,
  bool threeLineLayout = false,
}) {
  final line = lyric?.trim();
  final hasLine = line != null && line.isNotEmpty;

  final MediaItem target;
  if (threeLineLayout) {
    // Android 10 及以下：MediaStyle 标题/歌手/subText 三行都在。
    target = base.copyWith(
      artist: base.artist ?? kNotificationEmptyLyric,
      displayDescription: hasLine ? line : base.album,
    );
  } else {
    // Android 11+：只有两行，副标题整行让给歌词。
    target = base.copyWith(
      artist: hasLine ? line : kNotificationEmptyLyric,
    );
  }

  final cur = current;
  if (cur != null &&
      cur.id == target.id &&
      cur.title == target.title &&
      cur.artist == target.artist &&
      cur.displayDescription == target.displayDescription) {
    return null;
  }
  return target;
}

/// 初始化 AudioService
Future<MusicFlowAudioHandler> initAudioService() async {
  // 通知栏文本布局按 Android 版本分叉（30+ 两行 / <30 三行），必须在任何
  // mediaItem 推送之前拿到 API level；读失败降级为新布局，不阻塞启动。
  await AndroidPlatformInfo.load();
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
