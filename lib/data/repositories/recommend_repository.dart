import '../../core/utils/logger.dart';
import '../../core/l10n/localizations.dart';
import '../models/recommend.dart';
import '../sources/subsonic_api_client.dart';

/// 首页推荐仓库:对接主项目内部端点(非 Subsonic),
/// 获取固定推荐卡与不同插件的平台推荐歌单。
class RecommendRepository {
  final SubsonicApiClient _apiClient;

  RecommendRepository(this._apiClient);

  /// 首页分区清单:服务端决定首页展示哪些分区及其顺序。
  /// 端点位于 OpenSubsonic rest 路由,响应可能包在 subsonic-response 内,
  /// 此处兼容 unwrapped 与 wrapped 两种形态。加载失败由调用方兜底(回落默认顺序)。
  Future<List<HomeSection>> getHomeSections() async {
    try {
      final data = await _apiClient.getRaw('/rest/api/v1/home/sections');
      final body = data is Map<String, dynamic>
          ? (data['subsonic-response'] is Map<String, dynamic>
              ? data['subsonic-response'] as Map<String, dynamic>
              : data)
          : <String, dynamic>{};
      final homeSections = body['homeSections'];
      final sections = homeSections is Map<String, dynamic>
          ? homeSections['sections'] as List?
          : (body['sections'] as List?);
      return sections
              ?.whereType<Map<String, dynamic>>()
              .map(HomeSection.fromJson)
              .toList() ??
          const <HomeSection>[];
    } catch (e) {
      Logger.error('Failed to get home sections', e);
      rethrow;
    }
  }

  /// 首页固定推荐卡(每日推荐/今日漫游/本地推荐等)
  Future<List<HomeCard>> getHomeCards() async {
    try {
      final data = await _apiClient.getRaw(
        '/rest/api/v1/recommend/home-cards',
      );
      final cards = data['cards'] as List? ?? [];
      return cards
          .map((e) => HomeCard.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (e) {
      Logger.error('Failed to get home cards', e);
      rethrow;
    }
  }

  /// 不同插件的平台推荐频道(网易云/QQ 等)及提供方 providerId。
  /// providerId 用于把未入库的推荐歌单经 /v1/online/:providerId/recommend/import
  /// 导入成本地库歌单(返回真实 library playlistId 后播放,与主项目一致)。
  Future<RecommendResult> getRecommend() async {
    try {
      final data = await _apiClient.getRaw('/rest/api/v1/recommend');
      final providerId = data['providerId'] as String? ?? '';
      final channels = data['channels'] as List? ?? [];
      return RecommendResult(
        providerId: providerId,
        channels: channels
            .map((e) => RecommendChannel.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
    } catch (e) {
      Logger.error('Failed to get recommend channels', e);
      rethrow;
    }
  }

  /// 已入库的平台推荐歌单:经 /v1/online/:providerId/recommend/local
  /// 按远程歌单 id 反查本地 library playlistId;未找到返回 null。
  /// 用于「已入库的直接打开、未入库的才导入刷新」。
  Future<String?> findImportedPlaylistId(
    String providerId,
    String remoteId,
  ) async {
    try {
      final data = await _apiClient.getRaw(
        '/rest/api/v1/online/$providerId/recommend/local',
      );
      final list = data['playlists'] as List? ?? [];
      for (final e in list.whereType<Map>()) {
        if ((e['_remoteId'] as String? ?? '') == remoteId) {
          return e['id'] as String?;
        }
      }
      return null;
    } catch (e) {
      Logger.error('Failed to find imported recommend playlist', e);
      return null;
    }
  }

  /// 导入一个平台推荐歌单到本地库,返回真实 library playlistId。
  /// 与主项目一致:点推荐歌单即「导入(幂等 upsert)」,再以其 library id 播放。
  Future<String> importRecommendPlaylist(
    String providerId,
    Map<String, dynamic> info,
  ) async {
    try {
      final data = await _apiClient.postRaw(
        '/rest/api/v1/online/$providerId/recommend/import',
        data: info,
      ) as Map<String, dynamic>;
      if (data['success'] != true || data['playlistId'] == null) {
        throw Exception(data['error']?.toString() ?? l10nNowCurrent().import_recommend_playlist_failed);
      }
      return data['playlistId'] as String;
    } catch (e) {
      Logger.error('Failed to import recommend playlist', e);
      rethrow;
    }
  }
  /// 本地随机歌单(按平台分组):经 /v1/local-recommend 获取本地库随机歌单。
  /// 返回的歌单均为已入库本地歌单,可用其 id 直接打开/播放。
  Future<List<LocalRecommendChannel>> getLocalRecommend() async {
    try {
      final data = await _apiClient.getRaw('/rest/api/v1/local-recommend');
      final channels = data['channels'] as List? ?? [];
      return channels
          .map((e) => LocalRecommendChannel.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (e) {
      Logger.error('Failed to get local recommend channels', e);
      rethrow;
    }
  }
}
