// b38b3 —— Route B：data 模型剩余缺口补测。
//
// 覆盖 lcov 未命中行：
//   * SearchHistoryEntry.fromJson 非 int 时间戳回退 now（19）
//   * SearchHistoryEntry.copyWith（28-31）
//   * ServerConfig.copyWith 默认分支（76/81）
//   * Playlist.fromJson 经 `_parseDate` 的「空格分隔无 T」兜底解析（114/116）
//
// 产品代码零改动；仅新增 test/。

import 'package:flutter_test/flutter_test.dart';

import 'package:musicflow_client/data/models/playlist.dart';
import 'package:musicflow_client/data/models/search_history.dart';
import 'package:musicflow_client/data/models/server_config.dart';

void main() {
  group('SearchHistoryEntry', () {
    test('fromJson 缺失/非整数时间戳回退 DateTime.now', () {
      final before = DateTime.now().subtract(const Duration(seconds: 1));
      final missing = SearchHistoryEntry.fromJson(<String, dynamic>{'q': 'foo'});
      expect(missing.query, 'foo');
      expect(missing.timestamp.isAfter(before), isTrue);

      final nonInt = SearchHistoryEntry.fromJson(<String, dynamic>{
        'q': 'bar',
        'ts': '1700000000000',
      });
      expect(nonInt.query, 'bar');
      expect(nonInt.timestamp.isAfter(before), isTrue, reason: '非 int → now()');

      final withTs = SearchHistoryEntry.fromJson(<String, dynamic>{
        'q': 'baz',
        'ts': 1700000000000,
      });
      expect(
        withTs.timestamp,
        DateTime.fromMillisecondsSinceEpoch(1700000000000),
      );
    });

    test('copyWith 全量与缺省', () {
      final base = SearchHistoryEntry(
        query: 'old',
        timestamp: DateTime.fromMillisecondsSinceEpoch(1000),
      );
      final full = base.copyWith(
        query: 'new',
        timestamp: DateTime.fromMillisecondsSinceEpoch(2000),
      );
      expect(full.query, 'new');
      expect(full.timestamp.millisecondsSinceEpoch, 2000);

      final partial = base.copyWith(query: 'only');
      expect(partial.query, 'only');
      expect(partial.timestamp, base.timestamp);

      expect(base.copyWith().query, base.query);
      expect(base.toJson(), <String, dynamic>{'q': 'old', 'ts': 1000});
    });
  });

  group('ServerConfig.copyWith', () {
    test('缺省参数保留原值（76/81）', () {
      const base = ServerConfig(
        serverUrl: 'http://a',
        username: 'u',
        authType: AuthType.token,
      );
      final same = base.copyWith();
      expect(same.serverUrl, 'http://a');
      expect(same.username, 'u');
      expect(same.isOpenSubsonic, false);

      final updated = base.copyWith(
        serverUrl: 'http://b',
        username: 'v',
        password: 'p',
        apiKey: 'k',
        authType: AuthType.apiKey,
        isOpenSubsonic: true,
        serverType: 'navidrome',
        serverVersion: '0.53',
        extensions: const <String>['x'],
      );
      expect(updated.serverUrl, 'http://b');
      expect(updated.isOpenSubsonic, isTrue);
      expect(updated.extensions, <String>['x']);
    });
  });

  group('Playlist.fromJson 日期容错', () {
    test('空格分隔时间（无 T）走兜底解析（114/116）', () {
      final p = Playlist.fromJson(<String, dynamic>{
        'id': 'p1',
        'name': 'collection',
        'created': '2024-01-01 12:30:00',
        'changed': '2024-02-02 08:00:00',
      });
      expect(p.created, isNotNull);
      expect(p.created!.year, 2024);
      expect(p.changed, isNotNull);
      expect(p.changed!.month, 2);
    });

    test('数值 epoch 与不可解析字符串', () {
      final numeric = Playlist.fromJson(<String, dynamic>{
        'id': 'p2',
        'name': 'n',
        'created': 1700000000,
        'changed': 'not-a-date',
      });
      expect(numeric.created, isNotNull, reason: '秒级 epoch 数值');
      expect(numeric.changed, isNull, reason: '不可解析 → null 不抛');
    });
  });
}
