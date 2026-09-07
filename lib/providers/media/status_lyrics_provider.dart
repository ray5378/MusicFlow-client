import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart' show LoopMode;

import 'package:musicflow_client/core/utils/logger.dart';
import 'package:musicflow_client/data/models/song.dart';
import 'package:musicflow_client/data/sources/local_storage.dart';
import 'package:musicflow_client/providers/media/lyrics_cover_provider.dart';
import 'package:musicflow_client/providers/player/player_provider.dart';
import 'package:musicflow_client/widgets/windows_title_bar.dart';

/// Windows 桌面歌词浮窗开关(默认关闭)。
final statusLyricsEnabledProvider = StateProvider<bool>((ref) => false);

/// 桌面歌词控制器:持久化开关,监听播放状态(歌名/歌手/歌词行/播放/喜欢/
/// 播放模式/音量)并把完整状态推送到桌面歌词浮窗(原生 Win32 悬浮窗,
/// 两行文本 + 悬停控制按钮)。在 MainScaffold 初始化时读取一次以激活监听。
final statusLyricsControllerProvider = Provider<StatusLyricsController>((ref) {
  final controller = StatusLyricsController(ref);
  ref.onDispose(controller.dispose);
  return controller;
});

class StatusLyricsController {
  StatusLyricsController(this._ref) {
    _enabled = _ref.read(statusLyricsEnabledProvider);
    _enabledSub = _ref.listen<bool>(
      statusLyricsEnabledProvider,
      (_, next) {
        _enabled = next;
        _syncSubscriptions();
        _apply();
      },
    );
    _syncSubscriptions();
    // 启动时恢复上次开关状态并立即应用(开启则显示浮窗并推送状态)。
    _restore();
  }

  final Ref _ref;
  bool _enabled = false;
  String? _lastPushedKey;
  ProviderSubscription<bool>? _enabledSub;
  final List<ProviderSubscription<dynamic>> _playerSubs = [];

  /// 仅在开启时订阅播放状态与歌词行,避免在关闭状态下无谓触发歌词网络拉取。
  void _syncSubscriptions() {
    if (_enabled && _playerSubs.isEmpty) {
      _playerSubs.addAll([
        _ref.listen<Song?>(
          playerProvider.select((s) => s.currentSong),
          (_, __) => _push(),
        ),
        _ref.listen<bool>(
          playerProvider.select((s) => s.isPlaying),
          (_, __) => _push(),
        ),
        _ref.listen<double>(
          playerProvider.select((s) => s.volume),
          (_, __) => _push(),
        ),
        _ref.listen<bool>(
          playerProvider.select((s) => s.shuffleEnabled),
          (_, __) => _push(),
        ),
        _ref.listen<LoopMode>(
          playerProvider.select((s) => s.loopMode),
          (_, __) => _push(),
        ),
        _ref.listen<String?>(
          currentLyricLineProvider,
          (_, __) => _push(),
        ),
      ]);
    } else if (!_enabled && _playerSubs.isNotEmpty) {
      for (final sub in _playerSubs) {
        sub.close();
      }
      _playerSubs.clear();
    }
  }

  Future<void> _restore() async {
    try {
      final enabled = await LocalStorage.getStatusLyricsEnabled();
      _ref.read(statusLyricsEnabledProvider.notifier).state = enabled;
    } catch (e) {
      Logger.warnWithTag('STATUS_LYRICS', 'restore failed', e);
    }
  }

  /// 把开关状态应用到浮窗:开启 → 显示并推送当前状态;关闭 → 隐藏。
  void _apply() {
    if (_enabled) {
      unawaited(setDesktopLyricVisible(true));
      _lastPushedKey = null;
      _push();
    } else {
      unawaited(setDesktopLyricVisible(false));
    }
  }

  /// 托盘菜单「显示桌面歌词」与设置页开关共用入口。
  Future<void> toggle() async {
    final next = !_enabled;
    _ref.read(statusLyricsEnabledProvider.notifier).state = next;
    try {
      await LocalStorage.setStatusLyricsEnabled(next);
    } catch (e) {
      Logger.warnWithTag('STATUS_LYRICS', 'persist failed', e);
    }
  }

  void _push() {
    if (!_enabled) return;
    final player = _ref.read(playerProvider);
    final song = player.currentSong;
    final title = song?.title ?? '';
    final artist = song?.artist?.trim() ?? '';
    final lyric = _ref.read(currentLyricLineProvider) ?? '';
    final playing = player.isPlaying;
    final liked = player.currentSong?.starred ?? false;
    // 播放模式(与 PlayerNotifier.playbackMode 同一推导,避免依赖 notifier):
    // shuffle → 'shuffle';单曲循环 → 'repeatOne';其余 → 'repeatAll'。
    final mode = player.shuffleEnabled
        ? 'shuffle'
        : (player.loopMode == LoopMode.one ? 'repeatOne' : 'repeatAll');
    final volume = double.parse(player.volume.toStringAsFixed(2));
    // 去重:任何字段都没变就不推。
    final key = '$title|$artist|$lyric|$playing|$liked|$mode|$volume';
    if (key == _lastPushedKey) return;
    _lastPushedKey = key;
    unawaited(setDesktopLyricState(
      song: title,
      artist: artist,
      lyric: lyric,
      playing: playing,
      liked: liked,
      mode: mode,
      volume: volume,
    ));
  }

  void dispose() {
    _enabledSub?.close();
    for (final sub in _playerSubs) {
      sub.close();
    }
  }
}
