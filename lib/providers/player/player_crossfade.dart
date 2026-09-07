part of 'player_provider.dart';

mixin PlayerCrossfadeInternals on PlayerNotifier {
  /// 取消正在进行的淡入淡出动画并将音量恢复为用户设置值（state.volume）。
  void _cancelFade() {
    _fadeTimer?.cancel();
    _fadeTimer = null;
    final completer = _fadeCompleter;
    _fadeCompleter = null;
    if (completer != null && !completer.isCompleted) {
      completer.complete();
    }
    _audioPlayer?.setVolume(state.volume);
  }

  /// 淡出当前正在播放的歌曲。
  /// 如果用户未启用淡入淡出或当前未在播放，则立即返回。
  Future<void> _fadeOut(int session) async {
    _cancelFade();
    final durationMs = _ref.read(crossfadeDurationMsProvider);
    if (durationMs <= 0) return;
    final player = _audioPlayer;
    if (player == null || !player.playing) return;

    // 淡出只使用一半时长，另一半留给淡入
    final fadeMs = durationMs ~/ 2;
    const stepMs = 20;
    final steps = (fadeMs / stepMs).ceil().clamp(1, 500);
    // 从用户设置音量淡出到 0（不覆盖用户音量）
    final volumeStep = state.volume / steps;
    var currentVolume = state.volume;

    _playDbg('sid=$session fadeOut start durationMs=$fadeMs steps=$steps');

    final completer = Completer<void>();
    _fadeCompleter = completer;
    _fadeTimer = Timer.periodic(const Duration(milliseconds: stepMs), (timer) {
      // 会话已变（用户快速切歌）→ 立即中止
      if (_playDebugSession != session) {
        timer.cancel();
        _fadeTimer = null;
        if (identical(_fadeCompleter, completer)) {
          _fadeCompleter = null;
        }
        // 恢复用户音量而非置 0：若新源随后加载失败进暂停态，
        // 音量卡在 0 会造成"无声假死"（与 _cancelFade 的恢复语义一致）。
        player.setVolume(state.volume);
        if (!completer.isCompleted) completer.complete();
        return;
      }
      currentVolume = (currentVolume - volumeStep).clamp(0.0, 1.0);
      player.setVolume(currentVolume);
      if (currentVolume <= 0.0) {
        timer.cancel();
        _fadeTimer = null;
        if (identical(_fadeCompleter, completer)) {
          _fadeCompleter = null;
        }
        _playDbg('sid=$session fadeOut complete');
        if (!completer.isCompleted) completer.complete();
      }
    });

    return completer.future;
  }

  /// 淡入新歌曲：从 0.0 渐变到用户设置音量（state.volume）
  void _fadeIn() {
    _cancelFade();
    final durationMs = _ref.read(crossfadeDurationMsProvider);
    if (durationMs <= 0) {
      _audioPlayer?.setVolume(state.volume);
      return;
    }
    final player = _audioPlayer;
    if (player == null) return;

    // 淡入使用另一半时长
    final fadeMs = durationMs ~/ 2;
    const stepMs = 20;
    final steps = (fadeMs / stepMs).ceil().clamp(1, 500);
    final volumeStep = state.volume / steps;
    var currentVolume = 0.0;
    player.setVolume(0.0);

    final session = _playDebugSession;
    _playDbg('sid=$session fadeIn start durationMs=$fadeMs steps=$steps');

    _fadeTimer = Timer.periodic(const Duration(milliseconds: stepMs), (timer) {
      if (_playDebugSession != session) {
        timer.cancel();
        _fadeTimer = null;
        player.setVolume(state.volume);
        return;
      }
      currentVolume = (currentVolume + volumeStep).clamp(0.0, state.volume);
      player.setVolume(currentVolume);
      if (currentVolume >= state.volume) {
        timer.cancel();
        _fadeTimer = null;
        _playDbg('sid=$session fadeIn complete');
      }
    });
  }

}
