import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart' show LoopMode;

import 'package:musicflow_client/core/utils/logger.dart';
import 'package:musicflow_client/data/models/song.dart';
import 'package:musicflow_client/data/sources/local_storage.dart';
import 'package:musicflow_client/providers/cast/cast_peer_provider.dart';
import 'package:musicflow_client/providers/cast/dlna_provider.dart';
import 'package:musicflow_client/providers/media/desktop_lyric_popup.dart';
import 'package:musicflow_client/providers/media/lyrics_cover_provider.dart';
import 'package:musicflow_client/providers/player/effective_playback_provider.dart';
import 'package:musicflow_client/providers/player/effective_volume.dart';
import 'package:musicflow_client/providers/player/player_provider.dart';
import 'package:musicflow_client/widgets/windows_title_bar.dart';

/// Windows 桌面歌词浮窗开关(默认关闭)。
final statusLyricsEnabledProvider = StateProvider<bool>((ref) => false);

/// 桌面歌词播放模式字符串推导(纯函数,单测锁定):
/// shuffle → 'shuffle';单曲循环 → 'repeatOne';其余 → 'repeatAll'。
/// 与 PlayerNotifier.playbackMode 同一规则,原生层按
/// 0=shuffle / 1=repeatAll / 2=repeatOne 解释。
String deriveDesktopLyricMode({
  required bool shuffleEnabled,
  required LoopMode loopMode,
}) {
  if (shuffleEnabled) return 'shuffle';
  return loopMode == LoopMode.one ? 'repeatOne' : 'repeatAll';
}

/// cast 链路 playMode(order|one|all|shuffle) → 歌词窗模式串
/// (shuffle/repeatOne/repeatAll/order,原生层按 0=shuffle/1=repeatAll/
/// 2=repeatOne/3=order 解释)。order 单独透传:迷你条顺序播放图形是
/// 有序列表(list_ordered_2),与列表循环(repeat_2 箭头)不同,歌词窗同步区分。
/// 纯函数,带单测。
String castPlayModeToLyricMode(String playMode) {
  switch (playMode) {
    case 'shuffle':
      return 'shuffle';
    case 'one':
      return 'repeatOne';
    case 'order':
      return 'order';
    default:
      return 'repeatAll';
  }
}

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
        // 播放态/音量:统一链路源(effective provider)——投屏时是设备侧
        // 状态,与迷你播放条同源;设备端/其他端改音量也实时反映到歌词窗。
        _ref.listen<bool>(
          effectiveIsPlayingProvider,
          (_, __) => _push(),
        ),
        _ref.listen<double>(
          effectiveVolumeProvider,
          (_, __) => _push(),
        ),
        // 播放模式:投屏链路是设备/后端独立的 playMode,变化也要推。
        _ref.listen(
          dlnaCastProvider.select((s) => (s.isCasting, s.playMode)),
          (_, __) => _push(),
        ),
        _ref.listen(
          castPeerControllerProvider.select(
            (s) => (s.activePeer != null, s.playMode),
          ),
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
        // 「播放队列」弹窗:队列/当前曲/任一链路投屏状态变化时推送
        // (select 窄化,避免 500ms 进度 tick 触发无谓组拼)。
        _ref.listen<List<Song>>(
          playerProvider.select((s) => s.queue),
          (_, __) => _pushQueue(),
        ),
        _ref.listen<int>(
          playerProvider.select((s) => s.currentIndex),
          (_, __) => _pushQueue(),
        ),
        _ref.listen(
          castPeerControllerProvider.select(
            (s) => (s.activePeer, s.castQueue, s.castIndex, s.offline),
          ),
          (_, __) => _pushQueue(),
        ),
        _ref.listen(
          dlnaCastProvider.select((s) => (s.isCasting, s.currentIndex)),
          (_, __) => _pushQueue(),
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
      _lastQueueKey = null;
      _push();
      _pushQueue();
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
    // 播放态/音量:统一链路源(直投/peer 投屏时取设备侧状态,与本机无关)。
    final playing = _ref.read(effectiveIsPlayingProvider);
    final liked = player.currentSong?.starred ?? false;
    // 播放模式:本机按 deriveDesktopLyricMode 推导(纯函数,带单测);
    // 投屏链路取设备/后端独立 playMode(对齐迷你播放条模式按钮)。
    final mode = _effectiveLyricMode(player);
    final volume = double.parse(
      _ref.read(effectiveVolumeProvider).toStringAsFixed(2),
    );
    // 歌词填充色:固定暖黄(不随封面/主题取色变化)。
    const lyricColor = 0xFFC233;
    // 去重:任何字段都没变就不推。
    final key =
        '$title|$artist|$lyric|$playing|$liked|$mode|$volume|$lyricColor';
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
      lyricColor: lyricColor,
    ));
  }

  /// 歌词窗播放模式串:投屏链路取设备/后端 playMode(order|one|all|shuffle),
  /// 与本机 shuffle/loopMode 无关;本机沿用 deriveDesktopLyricMode。
  String _effectiveLyricMode(PlayerState player) {
    final dlna = _ref.read(dlnaCastProvider);
    if (dlna.isCasting) return castPlayModeToLyricMode(dlna.playMode);
    final cast = _ref.read(castPeerControllerProvider);
    if (cast.activePeer != null) return castPlayModeToLyricMode(cast.playMode);
    return deriveDesktopLyricMode(
      shuffleEnabled: player.shuffleEnabled,
      loopMode: player.loopMode,
    );
  }

  // ==================== 播放队列 / 切换播放器弹窗 ====================

  String? _lastQueueKey;

  /// 组拼并推送「播放队列」弹窗数据(内容没变不推)。
  void _pushQueue() {
    if (!_enabled) return;
    final player = _ref.read(playerProvider);
    final cast = _ref.read(castPeerControllerProvider);
    final dlna = _ref.read(dlnaCastProvider);
    final data = composeDesktopLyricQueue(
      castActive: cast.activePeer != null,
      castQueue: cast.castQueue,
      castIndex: cast.castIndex,
      localQueue: player.queue,
      localIndex: player.currentIndex,
      dlnaCasting: dlna.isCasting,
      dlnaIndex: dlna.currentIndex,
    );
    final key =
        '${data.index}|${data.items.length}|${data.items.join('\u0001')}';
    if (key == _lastQueueKey) return;
    _lastQueueKey = key;
    unawaited(setDesktopLyricQueue(items: data.items, index: data.index));
  }

  /// 点队列行回传:按当前链路路由(与右侧队列面板同一跳播链路)。
  Future<void> jumpToQueueIndex(int index) async {
    final cast = _ref.read(castPeerControllerProvider);
    if (cast.activePeer != null) {
      await _ref.read(castPeerControllerProvider.notifier).jumpTo(index);
      return;
    }
    if (_ref.read(dlnaCastProvider).isCasting) {
      await _ref.read(dlnaCastProvider.notifier).playAt(index);
      return;
    }
    await _ref.read(playerProvider.notifier).skipToQueueItem(index);
  }

  void dispose() {
    _enabledSub?.close();
    for (final sub in _playerSubs) {
      sub.close();
    }
  }
}
