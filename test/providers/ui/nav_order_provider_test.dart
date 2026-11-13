import 'package:flutter_test/flutter_test.dart';

import 'package:musicflow_client/providers/ui/nav_order_provider.dart';

void main() {
  group('normalizeNavOrder', () {
    test('null / empty falls back to defaults', () {
      expect(normalizeNavOrder(null, CategoryNavIds.defaults),
          CategoryNavIds.defaults);
      expect(normalizeNavOrder(<String>[], SidebarNavIds.defaults),
          SidebarNavIds.defaults);
    });

    test('keeps a valid saved order untouched', () {
      const saved = <String>[
        CategoryNavIds.cached,
        CategoryNavIds.study,
        CategoryNavIds.explore,
        CategoryNavIds.favorites,
        CategoryNavIds.playlists,
        CategoryNavIds.songs,
        CategoryNavIds.artists,
        CategoryNavIds.albums,
      ];
      expect(normalizeNavOrder(saved, CategoryNavIds.defaults), saved);
    });

    test('drops unknown ids and duplicates', () {
      final saved = <String>[
        CategoryNavIds.study,
        'removed-entry',
        CategoryNavIds.study,
        CategoryNavIds.explore,
      ];
      final result = normalizeNavOrder(saved, CategoryNavIds.defaults);
      expect(result.contains('removed-entry'), isFalse);
      expect(result.length, CategoryNavIds.defaults.length);
      expect(result.toSet().length, result.length);
      expect(result.toSet(), CategoryNavIds.defaults.toSet());
      // 已保存项之间的相对顺序必须保持。
      expect(
        result.where(<String>{CategoryNavIds.study, CategoryNavIds.explore}
            .contains).toList(),
        <String>[CategoryNavIds.study, CategoryNavIds.explore],
      );
    });

    test('升级补齐「学习」时插回默认位置而非末尾', () {
      // 老版本持久化顺序(没有 study)。
      const old = <String>[
        CategoryNavIds.explore,
        CategoryNavIds.favorites,
        CategoryNavIds.playlists,
        CategoryNavIds.songs,
        CategoryNavIds.artists,
        CategoryNavIds.albums,
        CategoryNavIds.cached,
      ];
      expect(normalizeNavOrder(old, CategoryNavIds.defaults),
          CategoryNavIds.defaults);

      const oldSidebar = <String>[
        SidebarNavIds.playlists,
        SidebarNavIds.music,
        SidebarNavIds.artists,
        SidebarNavIds.albums,
        SidebarNavIds.liked,
        SidebarNavIds.cached,
      ];
      expect(normalizeNavOrder(oldSidebar, SidebarNavIds.defaults),
          SidebarNavIds.defaults);
    });

    test('用户把「学习」拖到最前后，补齐其它项不改变已保存顺序', () {
      const saved = <String>[
        CategoryNavIds.study,
        CategoryNavIds.explore,
        CategoryNavIds.favorites,
      ];
      final result = normalizeNavOrder(saved, CategoryNavIds.defaults);
      expect(result.length, CategoryNavIds.defaults.length);
      expect(result.toSet(), CategoryNavIds.defaults.toSet());
      expect(result.indexOf(CategoryNavIds.study),
          lessThan(result.indexOf(CategoryNavIds.explore)));
      expect(result.indexOf(CategoryNavIds.explore),
          lessThan(result.indexOf(CategoryNavIds.favorites)));
    });
  });
}
