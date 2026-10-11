import 'package:musicflow_client/data/models/song.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';

/// 歌曲「保存路径 / 来源」展示工具（歌曲信息弹窗等共用）。
///
/// - 平台(web)歌曲：`来源` = 「平台中文名（插件名）」，如「网易云（go-music-dl）」；
/// - 本地 / WebDAV 歌曲：`保存路径` = 剥掉 `w:<源id>:` 前缀后的真实路径/href。
///
/// 全部为纯函数、无副作用；文案一律走传入的 [AppLocalizations]，
/// 便于复用与单元测试（util 层拿不到 vue-i18n 那样的全局 t，故显式传入）。

/// 来源平台 slug → 本地化平台名。
///
/// 内置平台返回其本地化名；未知 slug 回退原名（仍可辨认来源）；空串回退空串。
String platformDisplayName(String? slug, AppLocalizations loc) {
  final raw = slug?.trim() ?? '';
  switch (raw.toLowerCase()) {
    case 'netease':
      return loc.platform_netease;
    case 'qq':
      return loc.platform_qq;
    case 'kugou':
      return loc.platform_kugou;
    case 'kuwo':
      return loc.platform_kuwo;
    case 'migu':
      return loc.platform_migu;
    case 'qianqian':
      return loc.platform_qianqian;
    case 'soda':
      return loc.platform_soda;
    case 'huawei':
      return loc.platform_huawei;
    case 'apple':
      return loc.platform_apple;
    default:
      return raw;
  }
}

/// WebDAV 路径形如 `w:<sourceId>:<href>`；UI 层剥掉前缀只显示真实路径/href。
///
/// 注意：[Song.path] 字段本身语义不改，剥前缀**仅在展示层**做。
/// 非 WebDAV（或不匹配）的路径原样返回。
String stripWebdavPrefix(String path) {
  final match = RegExp(r'^w:([^:]*):(.*)$', dotAll: true).firstMatch(path);
  return match == null ? path : (match.group(2) ?? '');
}

/// 是否为平台(web)歌曲：与主项目判定一致（[Song.isWeb] 或 [Song.rowType] == 'web'）。
bool isPlatformSong(Song song) => song.isWeb == true || song.rowType == 'web';

/// 「来源」行的值（平台歌）：「平台中文名（插件名）」。
/// 只有一侧有值时只显示那一侧；两侧都空返回空串（调用方据此隐藏整行）。
String platformSongSourceValue(Song song, AppLocalizations loc) {
  final platform = platformDisplayName(song.sourcePlatform, loc);
  final plugin = (song.sourcePluginId ?? '').trim();
  if (platform.isNotEmpty && plugin.isNotEmpty) return '$platform（$plugin）';
  return plugin.isNotEmpty ? plugin : platform;
}

/// 「保存路径」行的值（本地 / WebDAV）：剥掉 `w:<源id>:` 前缀的真实路径。
String savedPathValue(Song song) => stripWebdavPrefix((song.path ?? '').trim());
