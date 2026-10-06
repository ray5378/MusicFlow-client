// batch32 B 路 —— `lib/core/services/smtc_service.dart` 补测。
//
// 基线覆盖率 ~0%。SMTC 服务是 Windows 平台通道薄封装，测试环境（Linux host）
// 下 flutter_rust_bridge 原生库不可用 → init() 的 try/catch 兜底分支、
// `_smtc == null` 全部守卫分支是可测且确定的行为；成功路径（Rust 桥就绪）
// 依赖原生库，无法在 CI/测试环境覆盖，已记录为覆盖缺口。
//
// 钉住的不变量：
//   * init() 幂等（重复调用不重复建实例/不抛）；
//   * init 失败被吞（不向上抛）；
//   * 未初始化/已 dispose 后调用全部公开方法零异常（守卫分支）；
//   * dispose 幂等、dispose 后再 init 立即返回（_disposed 守卫）；
//   * updateMetadata 空串 thumbnail 归一为 null、updateStatus 时长 0 兜底
//     —— 这些参数整形逻辑在 `_smtc == null` 时不可观测，但「不抛异常」
//     这一守卫行为本身可测。

import 'package:flutter_test/flutter_test.dart';
import 'package:musicflow_client/core/services/smtc_service.dart';

void main() {
  group('SmtcService · 守卫分支（未初始化态）', () {
    test('未 init 时 updateMetadata / updateStatus / disable 零异常', () {
      final service = SmtcService();
      expect(
        () => service.updateMetadata(
          title: '歌名',
          artist: '歌手',
          album: '专辑',
          thumbnail: 'http://example.com/cover.jpg',
        ),
        returnsNormally,
      );
      expect(
        () => service.updateStatus(
          playing: true,
          position: const Duration(seconds: 10),
          duration: const Duration(minutes: 3),
        ),
        returnsNormally,
      );
      expect(() => service.disable(), returnsNormally);
    });

    test('onNext / onPrevious / onPlayPause 默认 null 且可安全赋值', () {
      final service = SmtcService();
      expect(service.onNext, isNull);
      expect(service.onPrevious, isNull);
      expect(service.onPlayPause, isNull);

      var nextCalls = 0;
      service.onNext = () => nextCalls++;
      service.onNext!();
      expect(nextCalls, 1);
    });
  });

  group('SmtcService · init 兜底', () {
    test('init() 在测试环境（Rust 桥不可用或可用）都不向上抛', () async {
      final service = SmtcService();
      await expectLater(service.init(), completes);
      // 失败被 catch 后 _smtc 保持 null：后续调用仍走守卫分支零异常。
      expect(
        () => service.updateMetadata(title: 't', artist: 'a', album: 'b'),
        returnsNormally,
      );
      expect(
        () => service.updateStatus(
          playing: false,
          position: Duration.zero,
          duration: Duration.zero,
        ),
        returnsNormally,
      );
    });

    test('init() 幂等：重复调用不抛且行为一致', () async {
      final service = SmtcService();
      await service.init();
      await expectLater(service.init(), completes);
      expect(
        () => service.updateMetadata(title: 't', artist: 'a', album: 'b'),
        returnsNormally,
      );
    });

    test('thumbnail 空串/非空串两种入参在守卫分支下均零异常', () async {
      final service = SmtcService();
      await service.init();
      expect(
        () => service.updateMetadata(
          title: 't',
          artist: 'a',
          album: 'b',
          thumbnail: '',
        ),
        returnsNormally,
        reason: '空串 thumbnail 归一为 null，不得抛',
      );
      expect(
        () => service.updateMetadata(
          title: 't',
          artist: 'a',
          album: 'b',
          thumbnail: 'https://example.com/x.jpg',
        ),
        returnsNormally,
      );
    });

    test('updateStatus duration=0 时 endMs 兜底 0，不抛', () async {
      final service = SmtcService();
      await service.init();
      expect(
        () => service.updateStatus(
          playing: true,
          position: const Duration(seconds: 999),
          duration: Duration.zero,
        ),
        returnsNormally,
      );
    });
  });

  group('SmtcService · dispose 生命周期', () {
    test('dispose 幂等且 dispose 后 update* / disable 零异常', () async {
      final service = SmtcService();
      await service.init();
      expect(() => service.dispose(), returnsNormally);
      expect(() => service.dispose(), returnsNormally, reason: 'dispose 幂等');
      expect(
        () => service.updateMetadata(title: 't', artist: 'a', album: 'b'),
        returnsNormally,
      );
      expect(
        () => service.updateStatus(
          playing: true,
          position: Duration.zero,
          duration: const Duration(seconds: 1),
        ),
        returnsNormally,
      );
      expect(() => service.disable(), returnsNormally);
    });

    test('dispose 后 init() 立即返回（_disposed 守卫）', () async {
      final service = SmtcService();
      service.dispose();
      await expectLater(service.init(), completes);
    });
  });
}
