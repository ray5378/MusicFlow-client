import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/utils/logger.dart';
import '../data/sources/local_storage.dart';
import '../widgets/windows_title_bar.dart';
import 'lyrics_cover_provider.dart';
import 'player_provider.dart';

/// Windows 托盘/任务栏「状态栏歌词」开关(默认关闭)。
final statusLyricsEnabledProvider = StateProvider<bool>((ref) => false);

/// 状态栏歌词控制器:持久化开关、监听当前歌词并把当前行推送到托盘 tooltip。
/// 在 MainScaffold 初始化时读取一次以激活监听。
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
        _syncLyricsSubscription();
        _push();
      },
    );
    _syncLyricsSubscription();
    // 启动时恢复上次开关状态并立即推送一次。
    _restore();
  }

  final Ref _ref;
  bool _enabled = false;
  String? _lastPushed;
  ProviderSubscription<bool>? _enabledSub;
  ProviderSubscription<String?>? _lyricsSub;

  /// 仅在开启时订阅当前歌词行,避免在关闭状态下无谓触发歌词网络拉取。
  void _syncLyricsSubscription() {
    if (_enabled && _lyricsSub == null) {
      _lyricsSub = _ref.listen<String?>(
        currentLyricLineProvider,
        (_, __) => _push(),
      );
    } else if (!_enabled && _lyricsSub != null) {
      _lyricsSub!.cancel();
      _lyricsSub = null;
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

  /// 托盘菜单「显示状态栏歌词」与设置页开关共用入口。
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
    final String text;
    if (!_enabled) {
      text = '';
    } else {
      text = _ref.read(currentLyricLineProvider) ?? _fallbackText();
    }
    if (text == _lastPushed) return;
    _lastPushed = text;
    unawaited(setTrayTooltip(text));
  }

  String _fallbackText() {
    final song = _ref.read(playerProvider.select((s) => s.currentSong));
    if (song == null) return 'MusicFlow';
    final title = song.title;
    final artist = song.artist?.trim() ?? '';
    return artist.isEmpty ? title : '$title - $artist';
  }

  void dispose() {
    _enabledSub?.cancel();
    _lyricsSub?.cancel();
  }
}
