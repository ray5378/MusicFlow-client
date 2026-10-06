// b40e1 —— D-003 / D-004 补充用例。
//
// D-003：无时间戳行排到结果末尾（修复前被 `?? 0` 顶到最前）。
// D-004：时间标签小数位支持 1~3 位毫秒，按 10^(3-len) 补齐
//        （修复前正则只吃 2~3 位，[00:01.5] 整行被判为标签丢弃）。

import 'package:flutter_test/flutter_test.dart';
import 'package:musicflow_client/core/utils/lrc_parser.dart';

void main() {
  group('[D-003] 无时间戳行排序', () {
    test('多条无时间戳行全部排在带时间戳行之后,保持原文相对顺序', () {
      final s = LrcParser.parse('intro\n[00:02.00]b\nmid1\n[00:01.00]a\nmid2');
      expect(s.synced, isTrue);
      // 带时间戳的行按时间升序在前
      expect(s.lines[0].startMs, 1000);
      expect(s.lines[0].value, 'a');
      expect(s.lines[1].startMs, 2000);
      expect(s.lines[1].value, 'b');
      // 无时间戳行垫底,且彼此顺序不乱
      expect(s.lines.sublist(2).map((e) => e.value).toList(),
          ['intro', 'mid1', 'mid2']);
      expect(s.lines.sublist(2).every((e) => e.startMs == null), isTrue);
    });
  });

  group('[D-004] 1~3 位毫秒补齐', () {
    test('2 位毫秒按百分位补齐: [00:01.50] -> 1500ms', () {
      final s = LrcParser.parse('[00:01.50]x');
      expect(s.synced, isTrue);
      expect(s.lines.single.startMs, 1500);
    });

    test('1 位分钟 + 1 位毫秒: [0:02.1] -> 2100ms', () {
      final s = LrcParser.parse('[0:02.1]y');
      expect(s.synced, isTrue);
      expect(s.lines.single.startMs, 2100);
    });
  });
}
