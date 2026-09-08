import 'package:shared_preferences/shared_preferences.dart';

export 'package:shared_preferences/shared_preferences.dart';

/// SharedPreferences 统一入口。
/// 全仓库禁止直接调用 SharedPreferences.getInstance()，一律经此获取。
///
/// 约定：任何可能膨胀的大数据（缓存/会话/队列等）一律写 JsonFileStore，
/// 禁止塞进 prefs——Windows 的 shared_preferences 实现是「每次写任意键都
/// 全量 JSON 序列化 + 同步重写整个文件」，prefs 里只要有一个大键就会把
/// 平台线程烧满（历史恶性 bug，详见 metadata_cache_repository）。
Future<SharedPreferences> getPrefs() => SharedPreferences.getInstance();
