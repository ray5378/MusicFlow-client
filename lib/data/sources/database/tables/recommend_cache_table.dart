import 'package:drift/drift.dart';

/// 推荐类首页数据缓存表（通用 KV-JSON）。
///
/// 发现页三个最慢数据源（home-cards / recommend / local-recommend）此前无
/// 客户端缓存，冷启动白屏等网络。此表以 scope 为键整份存取 JSON payload：
/// - scope 形如 `'home_cards:<libraryId>'`，按活跃库隔离；
/// - payload 为模型 toJson 后的 JSON 文本（HomeCard 列表 / RecommendResult /
///   LocalRecommendChannel 列表），读取时容忍性解析；
/// - cachedAt 记录写入时间（毫秒），便于诊断缓存新鲜度。
///
/// 选型取舍：三份数据均为纯 JSON 模型（无按列查询需求，读取永远是整份取回），
/// 单张 KV 表与元数据缓存仓库「每 scope 一份 JSON」的语义一致，迁移最省
/// （onUpgrade 仅一次 createTable），故不拆三张结构化表。
@DataClassName('RecommendCacheTableData')
class RecommendCaches extends Table {
  TextColumn get scope => text()();
  TextColumn get payload => text()();
  IntColumn get cachedAt => integer()();

  @override
  Set<Column> get primaryKey => {scope};
}
