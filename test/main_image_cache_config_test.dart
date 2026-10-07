// b43 —— ImageCache 内存上限钉子。
//
// 用户约定：封面等图片类数据只走内存缓存不落盘，内存配额按拍板固定
// 128MB（2026-10-08）。本测试钉住 main.dart 的启动配置：
//   1) kImageCacheMaximumSizeBytes == 128MB；
//   2) main() 内 imageCache.maximumSizeBytes 确实使用该常量；
//   3) 旧值 32MB 不再出现。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:musicflow_client/main.dart';

void main() {
  test('kImageCacheMaximumSizeBytes 钉住 128MB（用户拍板 2026-10-08）', () {
    expect(kImageCacheMaximumSizeBytes, 128 << 20);
    // 防呆：明确不允许回退到旧的 32MB 配额。
    expect(kImageCacheMaximumSizeBytes, isNot(32 << 20));
    expect(kImageCacheMaximumSizeBytes, greaterThan(32 << 20));
  });

  test('main.dart 的 imageCache 配置使用该常量，且不再硬编码 32<<20', () {
    final source = File('lib/main.dart').readAsStringSync();
    expect(
      source.contains('maximumSizeBytes = kImageCacheMaximumSizeBytes'),
      isTrue,
      reason: 'main() 应通过常量配置 imageCache 上限',
    );
    expect(
      source.contains('32 << 20'),
      isFalse,
      reason: '旧配额 32MB 应被完全移除',
    );
  });
}
