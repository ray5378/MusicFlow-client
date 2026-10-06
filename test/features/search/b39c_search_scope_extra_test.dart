// b39c —— Route C 补测：`lib/features/search/search_scope.dart` 剩余缺口。
//
// 覆盖点：
//   * 70：SearchScopeSelection 默认构造（scope 默认 all）。
//   * 74/75：copyWith(scope: ...) 的表达式体与 fallback。
import 'package:flutter_test/flutter_test.dart';

import 'package:musicflow_client/features/search/search_scope.dart';

void main() {
  test('SearchScopeSelection 默认构造 + copyWith（70/74/75）', () {
    const selection = SearchScopeSelection();
    expect(selection.scope, SearchScope.all);

    final copied = selection.copyWith(scope: SearchScope.song);
    expect(copied.scope, SearchScope.song);

    // scope 未传 → 保留原值（?? this.scope 分支）。
    final unchanged = copied.copyWith();
    expect(unchanged.scope, SearchScope.song);
  });
}
