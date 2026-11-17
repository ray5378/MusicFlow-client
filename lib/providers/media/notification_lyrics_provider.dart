import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:musicflow_client/core/utils/logger.dart';
import 'package:musicflow_client/data/models/lyrics.dart';
import 'package:musicflow_client/providers/media/lyrics_cover_provider.dart';
import 'package:musicflow_client/providers/player/player_provider.dart';

/// Android 通知栏实时歌词控制器。
///
/// 把同步歌词按当前播放进度二分出的那一行，逐行推送到系统媒体通知的
/// **副标题行**（MediaItem.artist → METADATA_KEY_ARTIST）。主标题由 handler
/// 写成「歌名 - 歌手」；无歌词时副标题留空（不回落歌手，否则会被当成
/// 「歌词没加载」）。
///
/// 为什么是 artist：Android 11+ 的媒体通知由 SystemUI 用 MediaSession 元数据
/// 直接渲染，AOSP MediaDataManager 只取 `DISPLAY_TITLE ?? TITLE` 与
/// `METADATA_KEY_ARTIST`，`MediaData` 里没有 album/description 字段 ——
/// 写 displayDescription（setSubText）在 Android 11+ 上无人消费，就是
/// v5.17.2 「通知栏不显示歌词」的根因。通知栏只有两行，「底部那行」= artist。
///
/// ## 为什么不用 currentLyricLineProvider 直接监听
///
/// 那个 provider 的位置来自 `effectivePositionProvider`，而它的上游是
/// `just_audio.positionStream` —— 只在前台可靠推进。App 退到后台后该流可能
/// 完全停摆（表现为「后台切歌后歌词不更新，回前台才恢复」）。
///
/// 所以这里自持一个 300ms 的 [Timer]：
/// - 真实进度在推进（每次 tick 读到的值变了）→ 直接以它为准，无漂移；
/// - 真实进度停摆（后台典型）→ 用「上次真实值 + 经过时间」外推，歌词照常逐行走；
/// - 切歌 / seek 时真实值会跳变，下一拍立刻以真实值为新锚点，误差不累积。
///
/// Dart 定时器在 audio_service 的前台服务里始终运行（进程存活即有 CPU 时间），
/// 这就是后台歌词能继续走的依据；一旦系统整体冻结进程，音频本身也会停，
/// 那时歌词停走与播放状态一致，不是独立缺陷。
///
/// 仅移动平台激活：桌面没有 audio_service 通知（player_provider `_init` 显式
/// 抛 UnsupportedError），启动定时器只会白白触发歌词拉取。
final notificationLyricsControllerProvider =
    Provider<NotificationLyricsController>((ref) {
  final controller = NotificationLyricsController(ref);
  ref.onDispose(controller.dispose);
  return controller;
});

/// 纯函数（单测锁定）：决定本拍用于歌词二分的位置。
///
/// - [playing] 为假（暂停）→ 真实进度就是答案（暂停期间不该继续走）；
/// - [advanced] 为真（本次读到的真实进度变了，说明 position 流仍活着）→
///   完全信任真实值，零漂移；
/// - 两者都不成立 = **进度流停摆**（App 退到后台的典型情形）→
///   用「锚点位置 + 锚点以来的经过时间」外推，让歌词照常逐行前进。
///
/// 这就是「后台切歌后歌词不更新」的修复核心：不再假设 positionStream 在后台
/// 一定推进，也不依赖 UI 侧 provider 的重建时机。
Duration resolveLyricPosition({
  required Duration reported,
  required bool playing,
  required Duration anchorPosition,
  required DateTime anchorAt,
  required DateTime now,
  required bool advanced,
}) {
  if (!playing || advanced) return reported;
  final elapsed = now.difference(anchorAt);
  return elapsed.isNegative ? anchorPosition : anchorPosition + elapsed;
}

class NotificationLyricsController {
  NotificationLyricsController(this._ref) {
    if (_isDesktopLike) return;
    // 歌词表一到就立刻推一次（不等下一拍）；同时保持 currentLyricsProvider
    // 常驻 —— 它是 FutureProvider，没有监听者会被回收，后台自动切歌时就
    // 再也拉不到新歌的歌词。
    _lyricsSub = _ref.listen<AsyncValue<Lyrics?>>(
      currentLyricsProvider,
      (_, _) => _tick(),
    );
    _timer = Timer.periodic(
      const Duration(milliseconds: 300),
      (_) => _tick(),
    );
  }

  final Ref _ref;
  ProviderSubscription<AsyncValue<Lyrics?>>? _lyricsSub;
  Timer? _timer;

  /// 与 player_provider 的 `_isDesktopPlatform` 同口径（web 归为桌面）。
  static bool get _isDesktopLike =>
      kIsWeb ||
      defaultTargetPlatform == TargetPlatform.windows ||
      defaultTargetPlatform == TargetPlatform.linux ||
      defaultTargetPlatform == TargetPlatform.macOS;

  /// 外推锚点：最近一次「可信的真实进度」及其观察时刻。
  Duration _anchorPosition = Duration.zero;
  DateTime _anchorAt = DateTime.now();

  /// 上一拍读到的真实进度，用于判断进度流是否还在推进。
  Duration? _lastReported;

  /// 锚点所属歌曲：换歌时整体重置，绝不让上一首的进度参与新歌二分。
  String? _anchorSongId;

  /// 上一次真正推给通知的行（去重：原生每次 metadata 更新都会重建通知、
  /// 重解析封面位图，不能每 300ms 无脑推一遍）。
  String? _lastPushed;

  void _tick() {
    try {
      final state = _ref.read(playerProvider);
      final song = state.currentSong;
      final now = DateTime.now();

      if (song == null) {
        _resetTrack(null);
        _push(null);
        return;
      }

      if (_anchorSongId != song.id) {
        _resetTrack(song.id, now: now);
        // 上一首的歌词绝不能跟着新歌上屏：先清空，等 currentLyricsProvider
        // 拉到新歌词后由 listen 回调立刻补上第一行。
        _push(null);
        return;
      }

      final position = _resolvePosition(state.position, state.isPlaying, now);
      _emit(lyricLineAt(_ref.read(currentLyricsProvider).valueOrNull, position));
    } catch (e) {
      Logger.warnWithTag('NOTIF_LYRICS', 'tick', e);
    }
  }

  /// 取本拍用于二分的位置：优先真实进度，流停摆时用锚点外推。
  Duration _resolvePosition(Duration reported, bool playing, DateTime now) {
    final advanced = _lastReported != reported;
    _lastReported = reported;

    final position = resolveLyricPosition(
      reported: reported,
      playing: playing,
      anchorPosition: _anchorPosition,
      anchorAt: _anchorAt,
      now: now,
      advanced: advanced,
    );

    // 真实值可信时把锚点挪到它身上：外推误差不累积，seek / 切歌下一拍即校正。
    if (!playing || advanced) {
      _anchorPosition = reported;
      _anchorAt = now;
    }
    return position;
  }

  void _emit(String? line) {
    final normalized = (line == null || line.trim().isEmpty) ? null : line;
    if (normalized == _lastPushed) return;
    _lastPushed = normalized;
    _push(normalized);
  }

  void _resetTrack(String? songId, {DateTime? now}) {
    _anchorSongId = songId;
    _anchorPosition = Duration.zero;
    _anchorAt = now ?? DateTime.now();
    _lastReported = null;
    _lastPushed = null;
  }

  /// handler 每次从 playerProvider.notifier 现取而不是缓存：
  /// `_init` 的世代重跑（invalidate / 重新初始化）会整体换实例，
  /// 缓存引用会把歌词推到已废弃的旧 handler 上。
  void _push(String? line) {
    try {
      _ref
          .read(playerProvider.notifier)
          .audioHandler
          ?.updateNotificationLyric(line);
    } catch (e) {
      Logger.warnWithTag('NOTIF_LYRICS', 'push lyric to notification', e);
    }
  }

  void dispose() {
    _timer?.cancel();
    _timer = null;
    _lyricsSub?.close();
    _lyricsSub = null;
  }
}
