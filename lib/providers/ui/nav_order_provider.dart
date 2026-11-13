import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:musicflow_client/core/utils/logger.dart';
import 'package:musicflow_client/data/sources/local_storage.dart';

/// 分类导航（安卓窄屏首页顶部）稳定 id。
///
/// 顺序持久化只存 id：文案/图标/页面变化不影响用户已保存的排序。
abstract final class CategoryNavIds {
  static const String explore = 'explore';
  static const String favorites = 'favorites';
  static const String playlists = 'playlists';
  static const String study = 'study';
  static const String songs = 'songs';
  static const String artists = 'artists';
  static const String albums = 'albums';
  static const String cached = 'cached';

  /// 默认顺序：探索、喜欢、歌单、学习、歌曲、艺术家、专辑、已缓存。
  static const List<String> defaults = <String>[
    explore,
    favorites,
    playlists,
    study,
    songs,
    artists,
    albums,
    cached,
  ];
}

/// Windows 宽屏侧栏曲库入口稳定 id。
abstract final class SidebarNavIds {
  static const String playlists = 'playlists';
  static const String music = 'music';
  static const String artists = 'artists';
  static const String albums = 'albums';
  static const String liked = 'liked';
  static const String study = 'study';
  static const String cached = 'cached';

  /// 默认顺序：歌单、音乐、艺术家、专辑、我喜欢、学习、已缓存音乐。
  static const List<String> defaults = <String>[
    playlists,
    music,
    artists,
    albums,
    liked,
    study,
    cached,
  ];
}

/// 两端导航顺序（按平台各自持久化，互不影响）。
class NavOrderState {
  const NavOrderState({required this.category, required this.sidebar});

  final List<String> category;
  final List<String> sidebar;
}

/// 补全/去重已保存顺序：丢掉未知 id，并按默认顺序把「新增项」插到它在
/// 默认清单里的相邻位置（老版本升级后「学习」不会跑到最末尾）。
List<String> normalizeNavOrder(List<String>? saved, List<String> defaults) {
  if (saved == null || saved.isEmpty) return List<String>.of(defaults);
  final valid = <String>[];
  for (final id in saved) {
    if (defaults.contains(id) && !valid.contains(id)) valid.add(id);
  }
  for (var i = 0; i < defaults.length; i++) {
    final id = defaults[i];
    if (valid.contains(id)) continue;
    // 插到默认清单里「它后面第一个仍然存在」的项之前；都没有则追加到末尾。
    var insertAt = valid.length;
    for (var j = i + 1; j < defaults.length; j++) {
      final nextIndex = valid.indexOf(defaults[j]);
      if (nextIndex >= 0) {
        insertAt = nextIndex;
        break;
      }
    }
    valid.insert(insertAt, id);
  }
  return valid;
}

/// 导航顺序状态：启动时从本地读取，拖拽后即时更新并落盘。
class NavOrderNotifier extends AsyncNotifier<NavOrderState> {
  static const String _logTag = 'NAV_ORDER';

  @override
  Future<NavOrderState> build() async {
    List<String>? category;
    List<String>? sidebar;
    try {
      category = await LocalStorage.getCategoryNavOrder();
      sidebar = await LocalStorage.getSidebarNavOrder();
    } catch (e) {
      Logger.warnWithTag(_logTag, 'failed to read nav order', e);
    }
    return NavOrderState(
      category: normalizeNavOrder(category, CategoryNavIds.defaults),
      sidebar: normalizeNavOrder(sidebar, SidebarNavIds.defaults),
    );
  }

  NavOrderState get _current =>
      state.valueOrNull ??
      const NavOrderState(
        category: CategoryNavIds.defaults,
        sidebar: SidebarNavIds.defaults,
      );

  /// 拖拽结束：`newIndex` 为 ReorderableListView 语义（插入位）。
  Future<void> reorderCategory(int oldIndex, int newIndex) async {
    final ids = List<String>.of(_current.category);
    final moved = _move(ids, oldIndex, newIndex);
    if (moved == null) return;
    state = AsyncData(
      NavOrderState(category: ids, sidebar: _current.sidebar),
    );
    try {
      await LocalStorage.setCategoryNavOrder(ids);
    } catch (e) {
      Logger.warnWithTag(_logTag, 'failed to save category nav order', e);
    }
  }

  /// 拖拽结束：`newIndex` 为 ReorderableListView 语义（插入位）。
  Future<void> reorderSidebar(int oldIndex, int newIndex) async {
    final ids = List<String>.of(_current.sidebar);
    final moved = _move(ids, oldIndex, newIndex);
    if (moved == null) return;
    state = AsyncData(
      NavOrderState(category: _current.category, sidebar: ids),
    );
    try {
      await LocalStorage.setSidebarNavOrder(ids);
    } catch (e) {
      Logger.warnWithTag(_logTag, 'failed to save sidebar nav order', e);
    }
  }

  static String? _move(List<String> ids, int oldIndex, int newIndex) {
    if (oldIndex < 0 || oldIndex >= ids.length) return null;
    var target = newIndex;
    if (target > oldIndex) target -= 1;
    if (target < 0) target = 0;
    if (target >= ids.length) target = ids.length - 1;
    if (target == oldIndex) return null;
    final id = ids.removeAt(oldIndex);
    ids.insert(target, id);
    return id;
  }
}

final navOrderProvider =
    AsyncNotifierProvider<NavOrderNotifier, NavOrderState>(
  NavOrderNotifier.new,
);
