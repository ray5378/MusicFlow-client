// batch41 E1 —— 清理项回归：playlist.dart _parseDate 死分支删除后行为不变。
//
// DateTime.parse 本身接受 "2024-01-01 00:00:00" 空格分隔格式，被删的
// replaceFirst(' ', 'T') 二次兜底不可达。此文件验证：删除后空格格式仍解析、
// 非法输入仍容错返回 null、epoch 数值分支不受影响。
import 'package:flutter_test/flutter_test.dart';
import 'package:musicflow_client/data/models/playlist.dart';

Map<String, dynamic> _json({Object? created}) => <String, dynamic>{
      'id': 'p1',
      'name': '歌单',
      'songCount': 3,
      'duration': 300,
      if (created != null) 'created': created,
    };

void main() {
  group('Playlist._parseDate 回归（b41e1 清理后）', () {
    test('空格分隔的日期时间仍正常解析（被删分支的等价路径）', () {
      final p = Playlist.fromJson(_json(created: '2024-01-01 00:00:00'));
      expect(p.created, DateTime.parse('2024-01-01 00:00:00'));
      expect(p.created, DateTime(2024, 1, 1));
    });

    test('标准 ISO 8601 解析不变', () {
      final p = Playlist.fromJson(_json(created: '2024-06-15T08:30:00Z'));
      expect(p.created, DateTime.utc(2024, 6, 15, 8, 30));
    });

    test('非法字符串容错返回 null', () {
      final p = Playlist.fromJson(_json(created: 'not-a-date'));
      expect(p.created, isNull);
    });

    test('epoch 毫秒数值分支不受影响', () {
      final ms = DateTime.utc(2024, 3, 1).millisecondsSinceEpoch;
      final p = Playlist.fromJson(_json(created: ms));
      expect(p.created, DateTime.utc(2024, 3, 1));
    });
  });
}
