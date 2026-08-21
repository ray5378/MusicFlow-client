import '../../core/utils/logger.dart';
import '../models/recommend.dart';
import '../sources/subsonic_api_client.dart';

/// 首页推荐仓库:对接主项目内部端点(非 Subsonic),
/// 获取固定推荐卡与不同插件的平台推荐歌单。
class RecommendRepository {
  final SubsonicApiClient _apiClient;

  RecommendRepository(this._apiClient);

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

  /// 不同插件的平台推荐频道(网易云/QQ 等)
  Future<List<RecommendChannel>> getRecommendChannels() async {
    try {
      final data = await _apiClient.getRaw(
        '/rest/api/v1/recommend',
      );
      final channels = data['channels'] as List? ?? [];
      return channels
          .map((e) => RecommendChannel.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (e) {
      Logger.error('Failed to get recommend channels', e);
      rethrow;
    }
  }
}
