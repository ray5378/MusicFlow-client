// batch41 E1 —— 清理项回归：search_result_blocks 的 SearchScope.all 断言 arm。
//
// stackedScopes 永不含 all 是 search_result_blocks.dart 中
// `SearchScope.all => throw StateError(...)` 断言 arm 不可达的前提，
// 用纯单测钉住该契约；一旦有人改 stackedScopes 让 all 混进去，这里先炸。
import 'package:flutter_test/flutter_test.dart';
import 'package:musicflow_client/features/search/search_scope.dart';

void main() {
  group('SearchScope.stackedScopes 契约（b41e1 清理守护）', () {
    test('任何 scope 的 stackedScopes 都不含 SearchScope.all', () {
      for (final scope in SearchScope.values) {
        expect(
          scope.stackedScopes.contains(SearchScope.all),
          isFalse,
          reason: '$scope.stackedScopes 含 all 会击穿 search_result_blocks '
              '的「all 不可达」断言 arm',
        );
      }
    });

    test('all → kSearchScopeStackOrder（四档堆叠，不含 all）', () {
      expect(SearchScope.all.stackedScopes, kSearchScopeStackOrder);
      expect(kSearchScopeStackOrder, hasLength(4));
    });

    test('单类型档 → 只含自身', () {
      expect(SearchScope.song.stackedScopes, <SearchScope>[SearchScope.song]);
      expect(
          SearchScope.playlist.stackedScopes, <SearchScope>[SearchScope.playlist]);
      expect(
          SearchScope.artist.stackedScopes, <SearchScope>[SearchScope.artist]);
      expect(SearchScope.album.stackedScopes, <SearchScope>[SearchScope.album]);
    });
  });
}
