import 'dart:async';

import 'package:smtc_windows/smtc_windows.dart';

import 'package:musicflow_client/core/utils/logger.dart';

/// Windows 系统媒体传输控制（SMTC）服务。
///
/// 驱动系统音量浮层 / 锁屏媒体卡片：显示正在播放的歌曲
/// （标题/歌手/专辑/封面）、进度时间轴与上一首/暂停/下一首按钮。
/// 仅 Windows 平台使用；移动端走 audio_service 通知栏，Linux/macOS 不启用。
class SmtcService {
  SMTCWindows? _smtc;
  bool _disposed = false;

  /// SMTC 按钮回调（由 PlayerNotifier 注册）。
  void Function()? onNext;
  void Function()? onPrevious;
  void Function(bool play)? onPlayPause;

  /// 初始化并启用 SMTC。幂等：重复调用只建一次实例。
  Future<void> init() async {
    if (_smtc != null || _disposed) return;
    Logger.info('SMTC: initializing...');
    try {
      // smtc_windows 1.1.0：先初始化 Rust 桥接库，再创建实例。
      await SMTCWindows.initialize();
      Logger.info('SMTC: rust bridge ready');
      final smtc = SMTCWindows(
        config: const SMTCConfig(
          fastForwardEnabled: false,
          rewindEnabled: false,
          nextEnabled: true,
          prevEnabled: true,
          playEnabled: true,
          pauseEnabled: true,
          stopEnabled: false,
        ),
      );
      smtc.buttonPressStream.listen(_onButtonPress);
      _smtc = smtc;
      Logger.info('SMTC: initialized');
    } catch (e) {
      Logger.warn('SMTC: init failed: $e');
      _smtc = null;
    }
  }

  void _onButtonPress(PressedButton button) {
    switch (button) {
      case PressedButton.play:
        onPlayPause?.call(true);
      case PressedButton.pause:
        onPlayPause?.call(false);
      case PressedButton.next:
        onNext?.call();
      case PressedButton.previous:
        onPrevious?.call();
      default:
        break;
    }
  }  /// 推送歌曲元数据（切歌时调用）。
  /// [thumbnail] 为封面 URL（SMTC 支持远程 http(s) 与本地路径）。
  void updateMetadata({
    required String title,
    required String artist,
    required String album,
    String? thumbnail,
  }) {
    final smtc = _smtc;
    if (smtc == null) return;
    try {
      smtc.updateMetadata(
        MusicMetadata(
          title: title,
          artist: artist,
          album: album,
          thumbnail: (thumbnail != null && thumbnail.isNotEmpty)
              ? thumbnail
              : null,
        ),
      );
    } catch (e) {
      Logger.warn('SMTC: updateMetadata failed: $e');
    }
  }

  /// 同步播放状态 + 时间轴（播放/暂停切换、seek、切歌时调用）。
  /// SMTC 由系统按 [playing] 与速率自行推进显示位置，无需逐帧推送。
  void updateStatus({
    required bool playing,
    required Duration position,
    required Duration duration,
  }) {
    final smtc = _smtc;
    if (smtc == null) return;
    try {
      final endMs = duration > Duration.zero
          ? duration.inMilliseconds
          : 0;
      smtc.updateTimeline(
        PlaybackTimeline(
          startTimeMs: position.inMilliseconds.clamp(0, endMs),
          endTimeMs: endMs,
          positionMs: position.inMilliseconds.clamp(0, endMs),
          minSeekTimeMs: 0,
          maxSeekTimeMs: endMs,
        ),
      );
      smtc.setPlaybackStatus(
        playing ? PlaybackStatus.playing : PlaybackStatus.paused,
      );
    } catch (e) {
      Logger.warn('SMTC: updateStatus failed: $e');
    }
  }

  /// 停用 SMTC（清空系统媒体卡片）。
  void disable() {
    try {
      _smtc?.disableSmtc();
    } catch (_) {}
  }

  void dispose() {
    _disposed = true;
    unawaited(_disposeInternal());
    _smtc = null;
  }

  Future<void> _disposeInternal() async {
    try {
      await _smtc?.dispose();
    } catch (_) {}
  }
}
