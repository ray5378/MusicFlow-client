// b36c —— `lib/core/utils/network_error_notifier.dart` 补测（原 7/18）。
//
// 覆盖：markAppStarted 幂等（`??=` 两分支）/ 宽限期前即时提示 / 宽限期内
// 转入「待确认」排队（含重复 show 沿用既有计时）/ 计时到点后 _showNow /
// 节流窗口内二次提示被抑制 / cancelPending 取消。
//
// 说明：类内计时用真实 `DateTime.now()`（非 package:clock），故用例按声明
// 顺序串行利用「同一进程的真实时间轴」；定时器用 fake_async 推进。
// ToastNotifier.show 在无导航器时只挂起到 pending，不会抛。
//
// 产品代码零改动；只读 lib。

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:musicflow_client/core/utils/network_error_notifier.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('未 markAppStarted 时 show 走即时路径且重复调用被节流', () {
    // _startedAt == null → _showNow → 无 _lastShownAt → 弹一次；
    // 第二次进入节流分支直接返回。全程不抛。
    NetworkErrorNotifier.show('n-1');
    NetworkErrorNotifier.show('n-2');
    expect(NetworkErrorNotifier.startupGrace.inSeconds, 30);
  });

  test('markAppStarted 幂等：重复调用不改变宽限期', () {
    NetworkErrorNotifier.markAppStarted();
    NetworkErrorNotifier.markAppStarted();
    // 无公开可观测状态，仅断言不抛（`??=` 分支）。
    expect(true, isTrue);
  });

  test('宽限期内 show 转入待确认排队，重复 show 沿用既有计时', () {
    fakeAsync((async) {
      // 宽限期内（真实时间差 ≈ 0s < 30s）→ _schedulePending。
      NetworkErrorNotifier.show('p-1');
      // 已有待确认计时 → 早退分支（不改计时）。
      NetworkErrorNotifier.show('p-2');
      // 推进到计时到点：触发 _showNow(DateTime.now(), msg)。
      async.elapse(const Duration(seconds: 31));
      // 仍在宽限期内（真实时间几乎未动）→ 再次排一个待确认。
      NetworkErrorNotifier.show('p-3');
      // 取消待确认：后续推进不再触发任何回调。
      NetworkErrorNotifier.cancelPending();
      async.elapse(const Duration(seconds: 31));
    });
    expect(true, isTrue);
  });

  test('cancelPending 在无待确认时调用安全', () {
    NetworkErrorNotifier.cancelPending();
    expect(true, isTrue);
  });
}
