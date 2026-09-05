/// 动态歌单封面识别。
///
/// 今日漫游 / 每日推荐 / 本地推荐 / 随机歌曲 这类「每日自动随机生成」的歌单，
/// 其 `coverArtId` 固定但对应图片每天变化 → 封面必须每次冷启动重新拉取，
/// **不得**写入离线缓存、也不得从离线缓存读旧图。
///
/// 最可靠的判别来自调用方（首页固定 `HomeCard` 统一传 `alwaysFresh: true`）；
/// 这里再提供按名称关键字的兜底判断，供后台缓存守护在缓存歌单封面时防误存。
class DynamicCoverKeys {
  DynamicCoverKeys._();

  /// 已知动态歌单名称关键字（对齐主项目推荐插件命名）。
  static const List<String> _keywords = [
    '今日漫游',
    '每日推荐',
    '本地推荐',
    '随机歌曲',
    'daily recommend',
    'today roam',
    'local recommend',
    'random',
  ];

  /// 按名称/ID 判断是否为动态歌单（兜底，命中断言避免缓存）。
  static bool isDynamicPlaylist(String? name, {String? id}) {
    final haystack = '${name ?? ''} ${id ?? ''}'.toLowerCase();
    for (final kw in _keywords) {
      if (haystack.contains(kw.toLowerCase())) return true;
    }
    return false;
  }
}