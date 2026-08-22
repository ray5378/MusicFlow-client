import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';

import '../data/api_client.dart';
import '../data/models.dart';
import 'dlna_service.dart';

/// 播放目标：本机或某台 DLNA 设备。
typedef TargetChanged = void Function();

/// 统一播放控制器：
/// - 队列与播放模式（顺序/随机/单曲循环）；
/// - 「切换播放器」：target=local 时驱动 just_audio，target=device 时驱动 SOAP；
///   进度/时长/播放态始终反映当前目标（对齐主项目 remote-peer 行为）。
class PlayerService extends ChangeNotifier {

  final ApiClient _api;
  final DlnaService dlna;

  final AudioPlayer _player = AudioPlayer();

  PlayerService(this._api, this.dlna) {
    // 播完自动下一首（单曲循环在 _onTrackEnded 内处理）。
    _player.playerStateStream.listen((state) {
      if (state.processingState == ProcessingState.completed) {
        unawaited(_onTrackEnded());
      }
    });
    // 本机播放进度变化时刷新 UI。
    _player.positionStream.listen((_) {
      if (!isCasting) notifyListeners();
    });
  }

  List<Song> queue = [];
  int index = -1;
  bool shuffle = false;
  bool repeatOne = false;

  /// 当前投屏设备（null = 本机）。
  DlnaDevice? targetDevice;
  Timer? _pollTimer;

  Song? get current => (index >= 0 && index < queue.length) ? queue[index] : null;

  // ---- 有效播放状态（UI 唯一数据源）----
  bool get playing => isCasting
      ? dlna.status.value.state == 'PLAYING'
      : _player.playing;
  Duration get position => isCasting ? dlna.status.value.position : _player.position;
  Duration get duration {
    if (isCasting) return dlna.status.value.duration;
    final d = _player.duration ?? Duration.zero;
    return d;
  }

  bool get isCasting => targetDevice != null && dlna.status.value.active;

  String get targetName => isCasting ? targetDevice!.name : '本机';

  Future<void> playQueue(List<Song> songs, {int startIndex = 0}) async {
    queue = List.of(songs);
    await jumpTo(startIndex.clamp(0, songs.length - 1));
  }

  /// 播放在线聚合搜索结果：/rest/stream-remote 直连（主项目同款端点）。
  /// 以合成 id 入队，便于上一首/下一首在结果列表内切换。
  Future<void> playRemote(RemoteSong song) async {
    final url = _api.remoteStreamUrl(song);
    final s = Song(
      id: 'remote:${song.providerId}:${song.source}:${song.id}',
      title: song.name,
      artist: [song.artist, if (song.platformLabel != null) '[${song.platformLabel}]']
          .whereType<String>()
          .join(' · '),
      album: song.album,
      durationSeconds: song.durationSeconds,
      suffix: song.suffix,
    );
    // 单首入队（聚合结果的连续播放 v2 再做导入转本地）。
    queue = [s];
    index = 0;
    notifyListeners();
    await stopCast(notify: false);
    try {
      await _player.setUrl(url);
      await _player.play();
    } catch (_) {
      // 失败保持暂停态，用户可重试。
    }
    notifyListeners();
  }

  Future<void> jumpTo(int i, {bool keepTarget = true}) async {
    if (queue.isEmpty || i < 0 || i >= queue.length) return;
    index = i;
    final song = queue[index];
    notifyListeners();
    unawaited(_api.scrobble(song.id));
    if (keepTarget && isCasting && targetDevice != null) {
      final url = _api.streamUrl(song.id);
      await dlna.cast(targetDevice!, url,
          title: song.title, artist: song.artist);
      notifyListeners();
      return;
    }
    // 切到本机播放：先停投屏避免双声。
    await stopCast(notify: false);
    try {
      await _player.setUrl(_api.streamUrl(song.id));
      await _player.play();
    } catch (_) {
      // 网络失败静默，UI 显示暂停态可重试。
    }
    notifyListeners();
  }

  Future<void> toggle() async {
    if (isCasting) {
      dlna.status.value.state == 'PLAYING' ? await dlna.pause() : await dlna.resume();
    } else {
      _player.playing ? await _player.pause() : await _player.play();
    }
    notifyListeners();
  }

  Future<void> next() async {
    if (queue.isEmpty) return;
    var i = index + 1;
    if (i >= queue.length) i = 0;
    await jumpTo(i);
  }

  Future<void> previous() async {
    if (queue.isEmpty) return;
    var i = index - 1;
    if (i < 0) i = queue.length - 1;
    await jumpTo(i);
  }

  Future<void> seekTo(Duration d) async {
    if (isCasting) {
      await dlna.seek(d);
    } else {
      await _player.seek(d);
    }
    notifyListeners();
  }

  Future<void> setShuffle(bool v) async {
    shuffle = v;
    if (shuffle) {
      queue.shuffle(_rng);
      index = queue.indexWhere((s) => s.id == current?.id);
    }
    notifyListeners();
  }

  void setRepeatOne(bool v) {
    repeatOne = v;
    _player.setLoopMode(v ? LoopMode.one : LoopMode.off);
    notifyListeners();
  }

  /// 切换播放器 → 指定设备（投屏当前曲目）。
  Future<bool> castTo(DlnaDevice device) async {
    final song = current;
    if (song == null) return false;
    final url = _api.streamUrl(song.id);
    final ok = await dlna.cast(device, url, title: song.title, artist: song.artist);
    if (ok) {
      targetDevice = device;
      await _player.pause();
      _startPolling();
    }
    notifyListeners();
    return ok;
  }

  /// 回到本机。
  Future<void> useLocalDevice({bool resumeLocal = true}) async {
    await stopCast(resume: resumeLocal);
    notifyListeners();
  }

  Future<void> _onTrackEnded() async {
    if (repeatOne) {
      await _player.seek(Duration.zero);
      await _player.play();
      return;
    }
    await next();
  }

  Future<void> stopCast({bool notify = true, bool resume = false}) async {
    _pollTimer?.cancel();
    _pollTimer = null;
    await dlna.stop();
    targetDevice = null;
    if (resume && current != null && !_player.playing) {
      try {
        final pos = Duration.zero;
        await _player.setUrl(_api.streamUrl(current!.id));
        await _player.seek(pos);
        await _player.play();
      } catch (_) {}
    }
    if (notify) notifyListeners();
  }

  void _startPolling() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(seconds: 2), (_) async {
      await dlna.pollStatus();
      notifyListeners();
      if (!dlna.status.value.active && targetDevice != null) {
        // 设备离线自动回本机（保持队列位置）。
        targetDevice = null;
        notifyListeners();
      }
    });
  }

  final Random _rng = Random();

  Future<void> disposeAll() async {
    _pollTimer?.cancel();
    await _player.dispose();
    super.dispose();
  }
}
