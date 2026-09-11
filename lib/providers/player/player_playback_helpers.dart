part of 'player_provider.dart';

const int _probeCacheMaxEntries = 500;
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

  /// 该歌是否有「明确的、未过期的不可播」判定。
  ///
  /// §8.3 护栏 3:**无记录 / 已过期 → false(未知 → 照常播放)**。
  /// 绝不把「不知道」当成「死的」—— 这是拆除永久拉黑时定下的边界。
  bool _isKnownUnplayable(String songId) {
    final e = _probeCache[songId];
    final unplayable = isProbeEntryUnplayable(e, DateTime.now().millisecondsSinceEpoch);
    if (e != null && !unplayable && !e.ok) {
      // 已过期:清掉,后续重探。
      _probeCache.remove(songId);
    }
    return unplayable;
  }

  /// 本机播放预跳过(§8.3):顺序推进时越过「明确的、未过期的不可播」的歌。
  ///
  /// 边界(全部有意为之):
  ///   - 只做顺序推进(order/all);**shuffle 模式不在这里预跳** —— shuffle
  ///     沿服务端权威序列推进并在 `_pickServerShuffleNext` 里用同一套
  ///     `_isKnownUnplayable` 判据跳死链(2026-09-11 补齐 SPEC);无服务端
  ///     序列的离线随机模式交给播放失败兜底(失败后随机重抽,语义等价)。
  ///   - 只在队列范围内跳,**不回绕** —— all 模式回绕后的死源由下一轮
  ///     next 的预跳过/播放失败兜底接力;
  ///   - **不改队列**(护栏 4):只推进游标,items 原样;
  ///   - 连跳合并成一条提示(护栏 5):静默连跳 10 首会让用户以为点错了。
  ///
  /// 返回实际应播放的 index(可能与入参相同)。
  int _skipKnownUnplayable(int startIndex) {
    final idx = resolvePreProbeSkipIndex(
      startIndex: startIndex,
      queueLength: state.queue.length,
      isKnownUnplayable: (i) => _isKnownUnplayable(state.queue[i].id),
    );
    final skippedTitles = <String>[];
    for (var i = startIndex; i < idx && i < state.queue.length; i++) {
      skippedTitles.add(state.queue[i].title);
    }
    if (skippedTitles.isNotEmpty) {
      final l10n = l10nNowCurrent();
      final message = skippedTitles.length == 1
          ? l10n.provider_preprobe_skipped_one(skippedTitles.first)
          : l10n.provider_preprobe_skipped_many(skippedTitles.length);
      ToastNotifier.show(message, kind: MusicFlowMessageKind.warning);
      Logger.infoWithTag(
        _playerLogTag,
        'pre-probe skip ahead: skipped ' + skippedTitles.length.toString() + ' unplayable song(s)',
      );
    }
    return idx;
  }

  /// 预探测接下来可能播放的歌曲是否可用（服务端裁决,与主项目前端 probeUpcoming 一致）。
  ///
  /// 后端 POST /rest/api/v1/stream/probe 对本地歌曲零开销,对 web 歌曲做 Range 探测
  /// 并自动换源写回 DB,返回**四态判定**(playable/unplayable/transient/unknown)。
  /// 结果固化进 _probeCache → 顺序推进(order/all)时 `_skipKnownUnplayable` 据此
  /// **只在 unplayable 时预跳**;transient/unknown 照常播放,由播放失败兜底无限跳。
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
    //
    // shuffle:沿**服务端权威洗牌序列**取候选(2026-09-11 补齐 SPEC)——
    // 随机模式下线性窗口扫到的位置根本不会播,纯浪费;沿序列扫才能让
    // 服务端/客户端预探测真正覆盖「接下来实际会听的歌」。序列拿不到
    // (离线/未注册)则退回线性窗口,保持旧行为不劣化。
    var usedShuffleSeq = false;
    if (state.shuffleEnabled) {
      final seqOk = await _refreshServerShuffleSeq();
      final order = _srvShuffleOrder;
      if (seqOk && order != null && order.isNotEmpty) {
        var pos = _srvShufflePos;
        if (pos < 0 || pos >= order.length || order[pos] != currentIndex) {
          pos = order.indexOf(currentIndex);
        }
        if (pos >= 0) {
          usedShuffleSeq = true;
          for (var k = 1; k <= _probeWindow && pos + k < order.length; k++) {
            final s = queue[order[pos + k]];
            if (s.id.isNotEmpty &&
                !isRemoteSong(s) &&
                !_probeCache.containsKey(s.id)) {
              cands.add(s.id);
            }
          }
        }
      }
    }
    if (!usedShuffleSeq) {
      for (var i = 1; i <= _probeWindow; i++) {
        final idx = currentIndex + i;
        if (idx < queue.length) {
          final s = queue[idx];
          if (s.id.isNotEmpty &&
              !isRemoteSong(s) &&
              !_probeCache.containsKey(s.id)) {
            cands.add(s.id);
          }
        } else if (idx >= queue.length && state.playbackMode == PlaybackMode.all) {
          // 列表循环(all)回绕;order 到末尾不回绕(未来没有歌,窗口自然缩短)
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
        // 服务端四态判定(2026-09-11):playable/unplayable/transient/unknown。
        // 旧服务端无 verdict → 按 ok 推断(向后兼容)。
        final verdict = (r['verdict'] as String?) ?? (ok ? 'playable' : 'unknown');
        // 只固化「确定」的两态：transient/unknown 不写缓存 → 下次推进仍会重问,
        // 网络恢复后自动复活(与服务端 negativeTtlSeconds 语义一致)。
        if (verdict != 'playable' && verdict != 'unplayable') continue;
        // 带上限：超限时整体重置（一次性清空），避免无界增长。
        if (_probeCache.length >= _probeCacheMaxEntries) {
          _probeCache.clear();
        }
        _probeCache[songId] = ProbeCacheEntry(
          ok: verdict == 'playable',
          at: DateTime.now().millisecondsSinceEpoch,
          verdict: verdict,
        );
        if (verdict == 'unplayable') {
          Logger.warnWithTag(
            _playerLogTag,
            'pre-probe unplayable → skip: $songId (${r['reason'] ?? 'no usable audio source'})',
          );
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
