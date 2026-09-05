import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, TargetPlatform, kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:musicflow_client/core/offline/dynamic_cover_keys.dart';
import 'package:musicflow_client/core/offline/offline_cache_manager.dart';
import 'package:musicflow_client/core/utils/logger.dart';
import 'package:musicflow_client/data/models/audio_quality.dart';
import 'package:musicflow_client/data/models/song.dart';
import 'package:musicflow_client/providers/audio_quality_provider.dart';
import 'package:musicflow_client/providers/api_provider.dart';
import 'package:musicflow_client/providers/lyrics_cover_provider.dart';
import 'package:musicflow_client/providers/offline_provider.dart';
import 'package:path_provider/path_provider.dart';

/// 背景缓存服务：在线播放成功后，把「当前曲 + 队列下一首可播曲 + 当前曲封面」
/// 写入离线缓存，供断网/后端不可达时回退播放。
///
/// 以播放为信号驱动（`_busy` 串行，不抢占主线程）。歌词/歌单封面分别在
/// 对应读取路径写入（见歌词仓库与首页封面）。
final offlineCacheDaemonProvider = Provider<OfflineCacheDaemon>((ref) {
  return OfflineCacheDaemon(ref);
});

class OfflineCacheDaemon {
  OfflineCacheDaemon(this._ref);

  final Ref _ref;
  bool _busy = false;

  /// 在线播放一首歌进入「就绪」后调用。串行执行：当前曲→实际下一首→当前曲封面。
  Future<void> onSongStartedOnline({
    required Song song,
    required List<Song> queue,
    required int index,
    Song? upcomingSong,
  }) async {
    if (_busy) return;
    if (song.isPreview) return;
    // 仅在线时缓存（离线就算有缓存也不去重复拉流）。
    if (_ref.read(isOfflineProvider)) return;
    final cache = _ref.read(offlineCacheManagerProvider);
    await _ref.read(offlineCacheReadyProvider.future);
    _busy = true;
    try {
      await _cacheSongData(cache, song);
      // 预缓存实际「下一首将播放」的歌曲:随机模式由 player 侧 _resolveUpcomingSongForCache
      // 按随机语义取样给出,而非顺序队列的 index+1;未传时回退到顺序下一首。
      final next = upcomingSong ?? _nextFromQueue(queue, index);
      if (next != null && !next.isPreview) {
        await _cacheSongData(cache, next);
        await _cacheSongCover(cache, next);
        await _cacheSongLyrics(cache, next);
      }
      await _cacheSongCover(cache, song);
    } catch (e) {
      Logger.warn('offline cache daemon error', e);
    } finally {
      _busy = false;
    }
  }

  /// 顺序模式下取「队列里下一首可播曲」（跳过客户端会跳过的不可播曲）作为回退候选。
  static Song? _nextFromQueue(List<Song> queue, int index) {
    for (var i = index + 1; i < queue.length; i++) {
      if (!queue[i].isPreview) return queue[i];
    }
    return null;
  }

  Future<void> _cacheSongData(OfflineCacheManager cache, Song song) async {
    if (cache.hasSong(song.id)) return;
    final tmp = await _downloadStreamBytes(song);
    if (tmp == null) return;
    await cache.putSongFromFile(song.id, tmp, meta: _metaOf(song));
    try {
      await tmp.delete();
    } catch (_) {}
  }

  /// 缓存的歌曲附带展示元数据（供「已缓存音乐」页离线展示）。
  static Map<String, dynamic> _metaOf(Song song) => {
        'songId': song.id,
        'title': song.title,
        'artist': song.artist ?? '',
        if (song.album != null) 'album': song.album,
        if (song.duration != null) 'duration': song.duration,
        if (song.coverArt != null) 'coverArt': song.coverArt,
      };

  /// 缓存某首歌曲的歌词（在线时）。用于预缓存下一首时随附。

  Future<void> _cacheSongLyrics(OfflineCacheManager cache, Song song) async {
    if (cache.lyricsCached(song.id)) return;
    try {
      final repo = _ref.read(lyricsRepositoryProvider);
      final lyrics = await repo.getLyrics(
        songId: song.id,
        title: song.title,
        artist: song.artist ?? '',
        album: song.album,
        duration:
            song.duration != null ? Duration(seconds: song.duration!) : null,
      );
      if (lyrics != null && !lyrics.isEmpty) {
        await cache.putLyrics(song.id, jsonEncode(lyrics.toJson()));
      }
    } catch (_) {
      // 歌词拉取失败不阻塞预缓存。
    }
  }

  Future<void> _cacheSongCover(OfflineCacheManager cache, Song song) async {
    final coverArt = song.coverArt;
    if (coverArt == null || coverArt.isEmpty) return;
    if (cache.hasCover(coverArt)) return;
    final client = _ref.read(subsonicApiClientProvider);
    final url = client.getCoverArtUrl(coverArt, size: 300);
    if (url.isEmpty) return;
    final bytes = await _ref
        .read(subsonicApiClientProvider)
        .dio
        .get<List<int>>(
          url,
          options: Options(
            responseType: ResponseType.bytes,
            followRedirects: true,
            receiveTimeout: const Duration(seconds: 10),
          ),
        )
        .then((r) => r.data)
        .catchError((Object e) => <int>[]);
    if (bytes == null || bytes.isEmpty) return;
    await cache.putCover(coverArt, bytes, owners: [song.id]);
  }

  /// 缓存歌单封面（供首页离线展示）。
  ///
  /// 动态歌单（今日漫游/每日推荐/本地推荐/随机歌曲，见 [DynamicCoverKeys]）的
  /// 封面图每日变化，**不落缓存**；调用处对动态歌单传 `alwaysFresh: true`，
  /// 保证冷启动每次都绕过缓存重拉。
  Future<void> cachePlaylistCover(String coverKey, {String? playlistName}) async {
    if (coverKey.isEmpty) return;
    if (_ref.read(isOfflineProvider)) return;
    if (playlistName != null &&
        DynamicCoverKeys.isDynamicPlaylist(playlistName)) {
      return;
    }
    final cache = _ref.read(offlineCacheManagerProvider);
    await _ref.read(offlineCacheReadyProvider.future);
    if (cache.hasPlaylistCover(coverKey)) return;
    final clean = coverKey.trim();
    if (clean.isEmpty) return;
    final client = _ref.read(subsonicApiClientProvider);
    final url = client.getCoverArtUrl(clean, size: 320);
    if (url.isEmpty) return;
    final bytes = await client.dio
        .get<List<int>>(
          url,
          options: Options(
            responseType: ResponseType.bytes,
            followRedirects: true,
            receiveTimeout: const Duration(seconds: 15),
          ),
        )
        .then((r) => r.data)
        .catchError((Object e) => <int>[]);
    if (bytes == null || bytes.isEmpty) return;
    await cache.putPlaylistCover(clean, bytes);
  }

  /// 按与播放器一致的音质/转码参数下载歌曲流，落盘到临时文件后返回。
  Future<File?> _downloadStreamBytes(Song song) async {
    final client = _ref.read(subsonicApiClientProvider);
    final baseUrl = client.dio.options.baseUrl;
    if (baseUrl.isEmpty) return null;
    final quality = _ref.read(effectiveQualityProvider);
    final format = _needsTranscoding(song.suffix);
    final int? maxBitRate;
    if (format != null) {
      maxBitRate = quality == AudioQualityLevel.original
          ? null
          : (quality.maxBitRate ?? 320);
    } else if (quality == AudioQualityLevel.original) {
      maxBitRate = null;
    } else {
      maxBitRate = quality.maxBitRate;
    }
    final url = client.getStreamUrl(
      song.id,
      maxBitRate: maxBitRate,
      format: format,
    );
    if (url.isEmpty) return null;

    final tmpDir = await getTemporaryDirectory();
    final tmp = File('${tmpDir.path}/${song.id}_cache_${DateTime.now().millisecondsSinceEpoch}.tmp');
    try {
      await client.dio.download(
        url,
        tmp.path,
        options: Options(
          followRedirects: true,
          receiveTimeout: const Duration(seconds: 60),
        ),
      );
    } catch (e) {
      Logger.warn('offline cache stream download failed: ${song.id}', e);
      try {
        await tmp.delete();
      } catch (_) {}
      return null;
    }
    return await tmp.exists() ? tmp : null;
  }

  /// 与播放器一致的转码判定（跨平台统一；缓存曲也按原始可播格式落盘）。
  static String? _needsTranscoding(String? suffix) {
    if (suffix == null) return null;
    final lower = suffix.toLowerCase();
    const universallyUnsupported = [
      'ape', 'wv', 'tta', 'dff', 'dsf', 'tak',
    ];
    if (universallyUnsupported.contains(lower)) return 'mp3';
    final isApple =
        !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.iOS ||
            defaultTargetPlatform == TargetPlatform.macOS);
    if (!isApple) {
      const androidUnsupported = ['m4a', 'alac'];
      if (androidUnsupported.contains(lower)) return 'mp3';
    }
    return null;
  }
}
