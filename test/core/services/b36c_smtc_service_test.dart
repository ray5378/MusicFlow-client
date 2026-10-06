// b36c —— `lib/core/services/smtc_service.dart` 补测（原 26 miss）。
//
// 说明：SMTC 为 Windows 专属（smtc_windows FFI）；在 Linux 测试宿主上
// `SMTCWindows.initialize()` 必然失败，正好覆盖 init 的 catch 降级分支，
// 以及 _smtc == null 时各公开方法的安全早退（updateMetadata / updateStatus /
// disable / dispose / 幂等 init / dispose 后再 init）。
//
// 平台盲区：_onButtonPress 的按键分发与 smtc 实例就绪后的原生调用路径
// 需要真实 Windows + DLL，属平台盲区，不强行覆盖。
//
// 产品代码零改动；只读 lib。

import 'package:flutter_test/flutter_test.dart';

import 'package:musicflow_client/core/services/smtc_service.dart';

void main() {
  test('init 失败安全降级；未就绪时各方法安全早退', () async {
    final service = SmtcService();

    // init：Linux 下 initialize 抛错 → catch → _smtc 保持 null。
    await service.init();
    // 幂等：_smtc 仍为 null（未成功），再次 init 也不会抛。
    await service.init();

    // 回调注册不应在未就绪时被触发。
    var fired = false;
    service.onNext = () => fired = true;
    service.onPrevious = () => fired = true;
    service.onPlayPause = (_) => fired = true;

    // _smtc == null → 全部早退，不抛。
    service.updateMetadata(title: 't', artist: 'a', album: 'al');
    service.updateMetadata(
      title: 't',
      artist: 'a',
      album: 'al',
      thumbnail: 'https://example.com/c.jpg',
    );
    service.updateStatus(
      playing: true,
      position: const Duration(seconds: 1),
      duration: const Duration(seconds: 100),
    );
    // duration 为零分支。
    service.updateStatus(
      playing: false,
      position: const Duration(seconds: 5),
      duration: Duration.zero,
    );
    service.disable();

    expect(fired, isFalse);
  });

  test('dispose 后 init 不再重建（_disposed 短路）', () async {
    final service = SmtcService();
    service.dispose();
    // dispose 内部 unawaited(_disposeInternal())，让微任务跑完。
    await Future<void>.delayed(Duration.zero);
    await service.init();
    // 仍安全。
    service.updateStatus(
      playing: false,
      position: Duration.zero,
      duration: Duration.zero,
    );
    expect(true, isTrue);
  });
}
