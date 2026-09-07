part of 'player_provider.dart';

mixin PlayerStreamSourceInternals on PlayerNotifier {
  /// 判断格式是否需要强制转码
  /// 返回 null 表示直接使用原始格式，返回格式字符串表示需要转码
  String? _needsTranscoding(String? suffix) {
    if (suffix == null) return null;

    final lowerSuffix = suffix.toLowerCase();

    // macOS/iOS 原生支持 m4a/alac（AVFoundation/CoreAudio），无需转码
    // 所有平台都不支持的格式
    const universallyUnsupported = [
      'ape', // Monkey's Audio
      'wv', // WavPack
      'tta', // True Audio
      'dff', // DSD
      'dsf', // DSD
      'tak', // TAK
    ];

    if (universallyUnsupported.contains(lowerSuffix)) {
      return 'mp3';
    }

    // Android 上 m4a/alac 支持不完整，需要转码
    if (!_isApplePlatform) {
      const androidUnsupported = [
        'm4a', // 可能包含 ALAC 编码，Android 支持不完整
        'alac', // Apple Lossless
      ];
      if (androidUnsupported.contains(lowerSuffix)) {
        return 'mp3';
      }
    }

    // 其他格式优先尝试原始格式播放
    // 支持的格式包括：mp3, aac, flac, ogg, opus, wav 等
    return null;
  }

  int _normalizeBitRateKbps(int? bitRate) {
    if (bitRate == null || bitRate <= 0) return 0;
    // 兼容个别场景可能传入 bps（例如 320000）。
    if (bitRate >= 10000) return bitRate ~/ 1000;
    return bitRate;
  }

  int _parseBitRateFromText(String? text) {
    if (text == null) return 0;
    final match = RegExp(
      r'(\d{2,4})\s*kbps',
      caseSensitive: false,
    ).firstMatch(text);
    if (match == null) return 0;
    return int.tryParse(match.group(1) ?? '') ?? 0;
  }

  int _resolveCurrentBitRateKbps({
    required Song song,
    required AudioQualityLevel quality,
    required PlaybackSource source,
    int? maxBitRate,
  }) {
    final songBitRate = _normalizeBitRateKbps(song.bitRate);
    if (song.isPreview) {
      if (songBitRate > 0) return songBitRate;
      return _parseBitRateFromText(song.previewQualityLabel);
    }

    switch (source) {
      case PlaybackSource.stream:
        if (maxBitRate != null && maxBitRate > 0) return maxBitRate;
        if (quality != AudioQualityLevel.original &&
            quality.maxBitRate != null) {
          return quality.maxBitRate!;
        }
        return songBitRate;
    }
  }

  void _scheduleSongRemoteRefresh(Song song, int session) {
    unawaited(() async {
      final activeAddress = await _ensureActiveAddressForPlayback(
        session: session,
        reason: 'song_remote_refresh',
        logFailure: false,
      );
      if (activeAddress == null ||
          !mounted ||
          _playDebugSession != session ||
          state.currentSong?.id != song.id) {
        return;
      }
      _updateMediaItem(song);
      await _enrichSongMetadata(song.id, session);
    }());
  }

  ServerAddress? _syncImmediateActiveAddress({
    required int session,
    required String reason,
  }) {
    final pool = _ref.read(addressPoolProvider);
    final active = pool.activeAddress ?? _ref.read(activeAddressProvider);
    if (active == null) return null;

    final dio = _apiClient.dio;
    // 归一化去尾斜杠：getStreamUrl/getCoverArtUrl 手工拼接 baseUrl,带尾斜杠
    // 会拼出 '//rest/stream'（服务端返回 200 + SPA HTML → 一首都放不了）。
    final normalized = normalizeServerBaseUrl(active.url);
    if (dio.options.baseUrl != normalized) {
      dio.options.baseUrl = normalized;
      Logger.infoWithTag('API', 'switched base URL to: $normalized');
    }
    _playDbg(
      'sid=$session active_address_ready '
      'reason=$reason label=${active.label} url=${active.url}',
    );
    return active;
  }

  Future<ServerAddress?> _ensureActiveAddressForPlayback({
    required int session,
    required String reason,
    bool logFailure = true,
  }) async {
    final immediate = _syncImmediateActiveAddress(
      session: session,
      reason: reason,
    );
    if (immediate != null) return immediate;

    _playDbg('sid=$session active_address_wait start reason=$reason');
    try {
      final ensured = await _ref.read(ensureActiveAddressProvider.future);
      final dio = _apiClient.dio;
      final normalizedEnsured = normalizeServerBaseUrl(ensured.url);
      if (dio.options.baseUrl != normalizedEnsured) {
        dio.options.baseUrl = normalizedEnsured;
        Logger.infoWithTag('API', 'switched base URL to: $normalizedEnsured');
      }
      _playDbg(
        'sid=$session active_address_ready '
        'reason=$reason label=${ensured.label} url=${ensured.url}',
      );
      return ensured;
    } catch (e) {
      if (logFailure) {
        Logger.warnWithTag(
          _playerLogTag,
          'failed to ensure active address for $reason',
          e,
        );
      }
      _playDbg(
        'sid=$session active_address_wait failed '
        'reason=$reason err=$e',
      );
      return null;
    }
  }

  String _buildStreamUrlOrThrow(
    String songId, {
    required int session,
    required String source,
    int? maxBitRate,
    String? format,
    int? timeOffset,
  }) {
    final streamUrl = _apiClient.getStreamUrl(
      songId,
      maxBitRate: maxBitRate,
      format: format,
      timeOffset: timeOffset,
    );
    if (streamUrl.isEmpty) {
      final baseUrl = _apiClient.dio.options.baseUrl;
      _playDbg(
        'sid=$session $source stream_url_empty '
        'baseUrl=${baseUrl.isEmpty ? 'none' : baseUrl}',
      );
      throw StateError('No active server address available for stream URL');
    }
    return streamUrl;
  }

}
