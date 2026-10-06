// b36c —— `lib/utils/pinyin_helper.dart` 纯函数补测（原 2/14）。
//
// 覆盖：getFirstChar 的空串 / 英文首字母 / 中文拼音首字母 / 非字母回落 '#'
// 四路；getPinyin 的正常转换与 defPinyin 参数；getPinyinTags 的标签索引与
// 排序拼音（含空串与数字串回落 '#'）。
//
// 产品代码零改动；只读 lib。

import 'package:lpinyin/lpinyin.dart' as lp;
import 'package:flutter_test/flutter_test.dart';

import 'package:musicflow_client/utils/pinyin_helper.dart';

void main() {
  group('PinyinUtils.getFirstChar', () {
    test('空串返回 #', () {
      expect(PinyinUtils.getFirstChar(''), '#');
    });

    test('英文取首字母并大写', () {
      expect(PinyinUtils.getFirstChar('beatles'), 'B');
      expect(PinyinUtils.getFirstChar('Taylor'), 'T');
    });

    test('中文取拼音首字母并大写', () {
      expect(PinyinUtils.getFirstChar('我爱你'), 'W');
      expect(PinyinUtils.getFirstChar('北京'), 'B');
    });

    test('数字等非字母回落 #', () {
      expect(PinyinUtils.getFirstChar('123'), '#');
      expect(PinyinUtils.getFirstChar('###'), '#');
    });
  });

  group('PinyinUtils.getPinyin', () {
    test('默认转为不带声调拼音', () {
      expect(PinyinUtils.getPinyin('我爱你'), 'woaini');
      expect(PinyinUtils.getPinyin('ABC'), 'ABC');
    });

    test('可显式指定带声调格式', () {
      final withTone = PinyinUtils.getPinyin(
        '妈',
        format: lp.PinyinFormat.WITH_TONE_MARK,
      );
      expect(withTone.isNotEmpty, isTrue);
      // 不带声调与带声调两种格式结果应不同（验证 format 参数被透传）。
      expect(withTone, isNot(equals(PinyinUtils.getPinyin('妈'))));
    });

    test('defPinyin 参数在转换异常时作为兜底（正常输入不触发）', () {
      // 正常输入走 try 返回真实拼音；defPinyin 仅在异常分支生效。
      expect(PinyinUtils.getPinyin('hello', defPinyin: 'ZZZ'), 'hello');
    });
  });

  group('PinyinUtils.getPinyinTags', () {
    test('中文返回大写首字母索引与全大写拼音', () {
      final tags = PinyinUtils.getPinyinTags('我爱你');
      expect(tags['tagIndex'], 'W');
      expect(tags['namePinyin'], 'WOAINI');
    });

    test('英文返回大写索引与拼音原值', () {
      final tags = PinyinUtils.getPinyinTags('hello');
      expect(tags['tagIndex'], 'H');
      expect(tags['namePinyin'], 'HELLO');
    });

    test('空串与数字回落 # 索引', () {
      final empty = PinyinUtils.getPinyinTags('');
      expect(empty['tagIndex'], '#');
      expect(empty['namePinyin'], isEmpty);

      final digits = PinyinUtils.getPinyinTags('123');
      expect(digits['tagIndex'], '#');
    });
  });
}
