import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:musicflow_client/data/models/song.dart';
import 'package:musicflow_client/data/sources/subsonic_api_client.dart';
import 'package:musicflow_client/data/sources/local_storage.dart';
import 'package:musicflow_client/data/repositories/music_repository.dart';
import 'package:musicflow_client/core/constants/api_constants.dart';
import 'package:musicflow_client/core/network/connectivity_monitor.dart';
import 'package:musicflow_client/core/platform/platform_file_bridge.dart';
import 'package:musicflow_client/core/utils/logger.dart';
import 'package:musicflow_client/providers/api/music_provider.dart';
import 'package:musicflow_client/providers/api/api_provider.dart';


const _logTag = 'PLAYER';

/// 独立的收藏/Scrobble 处理器
///
/// 从 PlayerNotifier 中提取，接收显式依赖以保持可测试性。
class FavoriteScrobbleHandler {
  final Ref _ref;

  FavoriteScrobbleHandler(this._ref);

  SubsonicApiClient get _apiClient => _ref.read(subsonicApiClientProvider);

  MusicRepository get _musicRepository =>
      _ref.read(musicRepositoryProvider) ?? MusicRepository(_apiClient);

  /// 上报播放记录（Scrobble）
  ///
  /// **必须用 GET**：Subsonic / OpenSubsonic 规范的 `/rest/scrobble` 是 GET 端点，
  /// 服务端也只注册了 GET（`rest/index.ts`）。此前这里用 POST，服务端直接 404
  /// —— 表现为「日志里 Failed to scrobble (404)、播放历史里查不到任何记录」
  /// （2026-09-15 实测）。参数仍走 query，与服务端 `getParam` 的读取方式一致。
  Future<void> scrobble(String songId, {required bool submission}) async {
    try {
      await _apiClient.get(
        ApiConstants.scrobble,
        queryParameters: {
          'id': songId,
          'time': DateTime.now().millisecondsSinceEpoch.toString(),
          'submission': submission.toString(),
        },
      );
      Logger.info('Scrobble: $songId (submission: $submission)');
    } catch (e) {
      Logger.warn('Failed to scrobble', e);
    }
  }

  /// 记录移动网络缓存命中节省的流量
  Future<void> recordMobileCacheSavedBytesForHit({
    required String songId,
    required String cacheFilePath,
    required String libraryId,
  }) async {
    if (kIsWeb) return;
    if (libraryId.isEmpty) return;

    try {
      final networkType = _ref
          .read(connectivityMonitorProvider)
          .currentNetworkType;
      if (networkType != NetworkType.mobile) return;

      if (!await fileExists(cacheFilePath)) return;
      final savedBytes = await fileLength(cacheFilePath);
      if (savedBytes <= 0) return;

      await LocalStorage.addMobileCacheSavedBytes(
        libraryId: libraryId,
        bytes: savedBytes,
      );
      Logger.infoWithTag(
        _logTag,
        'mobile cache hit recorded song=$songId savedBytes=$savedBytes',
      );
    } catch (e) {
      Logger.warnWithTag(
        _logTag,
        'failed to record mobile cache hit savings',
        e,
      );
    }
  }

  /// 切换指定歌曲的收藏状态
  ///
  /// 返回 (newStarred, updatedCurrentSong, updatedQueue)，
  /// 调用方负责更新 state 和 invalidate providers。
  Future<bool?> toggleSongFavorite({
    required Song song,
    required Song? currentSong,
    required List<Song> queue,
  }) async {
    try {
      Song? queueSong;
      for (final queued in queue) {
        if (queued.id == song.id) {
          queueSong = queued;
          break;
        }
      }
      final currentStarred =
          queueSong?.starred ??
          (currentSong?.id == song.id ? currentSong!.starred : song.starred);
      final newStarred = !currentStarred;
      await _musicRepository.setSongStarred(song.id, newStarred);
      Logger.info('Toggled favorite for ${song.title}: $newStarred');
      return newStarred;
    } catch (e) {
      Logger.error('Failed to toggle favorite', e);
      return null;
    }
  }

  /// 更新队列中指定歌曲的收藏状态
  List<Song> updateQueueStarred(
    List<Song> queue,
    String songId,
    bool starred,
  ) {
    return queue.map((s) {
      if (s.id != songId) return s;
      return s.copyWith(starred: starred);
    }).toList();
  }

  /// 刷新收藏相关的 provider
  void invalidateFavoriteProviders({String? albumId}) {
    // 收藏只影响「收藏相关」的数据，**不碰首页随机歌单**。
    // 原先这里会把 randomSongsProvider 失效并广播"随机歌曲变了"，于是点一次
    // 收藏/取消收藏，首页那份随机列表就整个重拉重排 —— 用户正在看的内容被换掉，
    // 明显不合理（收藏一首歌与"今天随机推荐哪些"毫无关系）。
    // 代价：首页随机列表里那几颗心的状态要等它下次自然刷新才对齐；
    // 播放器内（mini/大屏）的心形不受影响 —— 那边读的是 playerProvider 的
    // currentSong/queue，toggleSongFavorite 已经就地更新过。
    _ref.invalidate(starredProvider);
    _ref.invalidate(allSongsProvider);
    if (albumId != null && albumId.isNotEmpty) {
      _ref.invalidate(albumDetailProvider(albumId));
    }
  }
}
