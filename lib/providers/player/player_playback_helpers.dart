part of 'player_provider.dart';

const int _probeCacheMaxEntries = 500;
const int _deadSongsMaxEntries = 200;
const int _probeWindow = 3;

mixin PlayerPlaybackInternals on PlayerNotifier {
  /// 异步补充歌曲元数据（格式/码率/位深/采样率/声道数），不阻塞播放流程。
  Future<void> _enrichSongMetadata(String songId, int session) async {
    try {
      final fullSong = await _musicRepository.getSong(songId);
      if (fullSong == null) return;
      // 会话已切换 → 丢弃
      if (!mounted || _playDebugSession != session) return;
      final current = state.currentSong;
      if (current == null || current.id != songId) return;
      // 仅在缺失时补充
      final needsUpdate =
          current.suffix == null ||
          current.bitRate == null ||
          current.bitDepth == null ||
          current.samplingRate == null ||
          current.channelCount == null;
      if (!needsUpdate) return;
      final enriched = current.copyWith(
        suffix: current.suffix ?? fullSong.suffix,
        bitRate: current.bitRate ?? fullSong.bitRate,
        bitDepth: current.bitDepth ?? fullSong.bitDepth,
        samplingRate: current.samplingRate ?? fullSong.samplingRate,
        channelCount: current.channelCount ?? fullSong.channelCount,
      );
      if (mounted && state.currentSong?.id == songId) {
        state = state.copyWith(currentSong: enriched);
        // 同步更新队列中的歌曲对象
        final idx = state.currentIndex;
        if (idx >= 0 &&
            idx < state.queue.length &&
            state.queue[idx].id == songId) {
          final updatedQueue = List<Song>.from(state.queue);
          updatedQueue[idx] = enriched;
          state = state.copyWith(queue: updatedQueue);
        }
        if (_currentStreamSongId == songId &&
            _sourcePositionOffset == Duration.zero) {
          final useServerTimeOffsetSeek = shouldUseServerTimeOffsetSeek(
            requestedFormat: _currentStreamFormat,
            requestedMaxBitRate: _currentStreamMaxBitRate,
            sourceFormat: enriched.suffix,
            sourceBitRate: enriched.bitRate,
          );
          if (useServerTimeOffsetSeek != _seekByReloadStream) {
            _seekByReloadStream = useServerTimeOffsetSeek;
            _seekDbg(
              'updated timeOffset seek after metadata refresh '
              'song=$songId bitRate=${enriched.bitRate} '
              'maxBitRate=$_currentStreamMaxBitRate '
              'enabled=$useServerTimeOffsetSeek',
            );
          }
        }
      }
    } catch (e) {
      Logger.debug('Failed to enrich song metadata for $songId: $e');
    }
  }

  /// 把歌曲标记为已确认不可播（与预探测结果共用 _deadSongs 集合，带上限）。
  void _markSongDead(String songId) {
    if (_probeCache.length >= _probeCacheMaxEntries) {
      _probeCache.clear();
      _deadSongs.clear();
    }
    _probeCache[songId] = false;
    if (_deadSongs.length >= _deadSongsMaxEntries) {
      _deadSongs.clear();
    }
    _deadSongs.add(songId);
  }

  /// 预探测接下来可能播放的歌曲是否可用（与主项目前端 probeUpcoming 一致）。
  /// 后端 POST /rest/api/v1/stream/probe 对本地歌曲零开销,
  /// 对 web 歌曲做 Range 探测并自动换源写回 DB；不可用的歌提前标记跳过。
  Future<void> _probeUpcoming() async {
    if (_probing || state.queue.isEmpty) return;
    final queue = state.queue;
    final currentIndex = state.currentIndex;
    final cands = <String>[];

    // 远程歌(未入库,走 /rest/stream-remote)跳过预探测:后端 probe 按 DB songId
    // 判可用性,远程歌不入库,后端没有该 songId 会误判为不可播(对齐主项目前端
    // probeUpcoming 的 !s.streamUrl 排除)。试听歌同理不走 probe。
    bool isRemoteSong(Song s) => s.isPreview || s.id.startsWith('remote:');

    // 收集接下来 _probeWindow 首未探测过的非远程歌曲 ID
    for (var i = 1; i <= _probeWindow; i++) {
      final idx = currentIndex + i;
      if (idx < queue.length) {
        final s = queue[idx];
        if (s.id.isNotEmpty &&
            !isRemoteSong(s) &&
            !_probeCache.containsKey(s.id)) {
          cands.add(s.id);
        }
      } else if (idx >= queue.length && state.loopMode != LoopMode.off) {
        // 循环模式下回绕
        final wrap = idx % queue.length;
        if (wrap != currentIndex) {
          final s = queue[wrap];
          if (s.id.isNotEmpty &&
              !isRemoteSong(s) &&
              !_probeCache.containsKey(s.id)) {
            cands.add(s.id);
          }
        }
      }
    }
    if (cands.isEmpty) return;

    _probing = true;
    try {
      final client = _apiClient;
      // 业务 API（非 OpenSubsonic）→ 必须用 postRaw，post 会按 subsonic-response
      // 解包返回 null，导致下面的 results['results'] 每次都抛错、预探测永不生效。
      final results = await client.postRaw(
        '/rest/api/v1/stream/probe',
        data: {'songIds': cands},
      );
      final items = (results is Map ? (results['results'] as List?) : null) ??
          const [];
      for (final r in items.whereType<Map>()) {
        final songId = (r['songId'] as String?) ?? '';
        if (songId.isEmpty) continue;
        final ok = r['ok'] == true;
        // 带上限：超限时整体重置（一次性清空），避免无界增长。
        if (_probeCache.length >= _probeCacheMaxEntries) {
          _probeCache.clear();
          _deadSongs.clear();
        }
        _probeCache[songId] = ok;
        if (!ok) {
          if (_deadSongs.length >= _deadSongsMaxEntries) {
            _deadSongs.clear();
          }
          _deadSongs.add(songId);
          Logger.warnWithTag(
            _playerLogTag,
            'pre-probe unplayable, skip ahead: $songId (${r['reason'] ?? 'no usable audio source'})',
          );
        } else {
          _deadSongs.remove(songId);
        }
      }
    } catch (e) {
      // 探测失败不阻塞播放：交给播放时的失败兜底
      Logger.debugWithTag(_playerLogTag, 'pre-probe failed: $e');
    } finally {
      _probing = false;
    }
  }

}
