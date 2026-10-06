// batch37 C(2) —— `lib/core/services/smtc_service.dart` 平台盲区复核。
//
// 结论（与既有 b32b/b36c 一致）：SMTC 是 Windows 专属（smtc_windows FFI）。
// 在 Linux 测试宿主上 `SMTCWindows.initialize()` 必然失败 → init 走 catch 降级，
// 之后 `_smtc == null`，所有公开方法只执行守卫早退。
//
// 因此该文件**剩余 26 行不可达**，具体为：
//   * init 成功路径（Logger 24/28/42、SMTCWindows 构造 29-41）；
//   * _onButtonPress 的按键分发（49-61）；
//   * updateMetadata / updateStatus 真正调用原生 SMTC 的语句（73-82 / 101-112）；
//   * disable 的 disableSmtc 调用（121）；
//   * _disposeInternal 里对非空 _smtc.dispose() 的 await（133）。
// 需要一个真实 Windows + smtc_windows DLL 才能覆盖，属平台盲区。
//
// 本文件仅钉住「守卫分支 + 生命周期」的确定性不变量（防回归），并显式断言
// 降级后 _smtc 不可用状态下各方法零异常。
//
// 只写 test/，只读 lib/（产品代码零改动）。

import 'package:flutter_test/flutter_test.dart';

import 'package:musicflow_client/core/services/smtc_service.dart';

void main() {
  test('init 降级后：全部公开方法零异常，回调不被触发', () async {
    final service = SmtcService();
    await service.init(); // Linux：initialize 抛错 → catch → _smtc 保持 null
    await service.init(); // 幂等：仍安全

    var fired = 0;
    service.onNext = () => fired += 1;
    service.onPrevious = () => fired += 1;
    service.onPlayPause = (_) => fired += 1;

    expect(
      () => service.updateMetadata(title: 't', artist: 'a', album: 'b'),
      returnsNormally,
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
    expect(
      () => service.updateStatus(
        playing: true,
        position: const Duration(seconds: 5),
        duration: const Duration(seconds: 100),
      ),
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
    expect(() => service.disable(), returnsNormally);
    expect(fired, 0, reason: '未就绪时按钮回调不应被触发');
  });

  test('dispose 幂等；dispose 后 init/各方法仍安全', () async {
    final service = SmtcService();
    service.dispose();
    await Future<void>.delayed(Duration.zero);
    await service.init(); // _disposed 短路
    expect(
      () => service.updateStatus(
        playing: false,
        position: Duration.zero,
        duration: Duration.zero,
      ),
      returnsNormally,
    );
    expect(() => service.dispose(), returnsNormally);
  });
}
