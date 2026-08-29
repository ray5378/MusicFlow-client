import 'package:flutter_test/flutter_test.dart';
import 'package:musicflow_client/core/dlna/dlna_keepalive.dart';

/// 客户端保活引用计数回归测试（CI · 纯 Dart）。
///
/// 固定链路 B（局域网 DLNA 直投）后台续播的保活语义：
///   - 多调用方重叠持有/释放同一把锁时，只有 0→1 才应 acquire、1→0 才应 release，
///     重叠加/减不得重复触发原生挂/摘锁，否则会造成重复 acquire 或过早起解除锁
///     —— 一旦过早 release 唤醒锁，2s 轮询 timer 在熄屏/Doze 下停摆，曲毕看门狗
///     将无法在后台主动推下一首（无声音量时停播）。
void main() {
  group('唤醒锁引用计数（DLNA 后台续播保活）', () {
    DlnaKeepaliveController c() => DlnaKeepaliveController();

    test('首次 acquire 才返回需挂锁；二次 acquire 不重复挂', () {
      final k = c();
      expect(k.acquireWakeLock(), isTrue, reason: '第一个调用方应真正住锁');
      expect(k.acquireWakeLock(), isFalse, reason: '第二个调用方仅增加引用，不重复 acquire');
      expect(k.wakeLockHeld, isTrue);
      expect(k.wakeLockRefs, 2);
    });

    test('引用未归零前 release 不真正摘锁', () {
      final k = c();
      k.acquireWakeLock();
      k.acquireWakeLock();
      expect(k.releaseWakeLock(), isFalse, reason: '引用 2→1，仍处于持有态，不得提前摘锁');
      expect(k.wakeLockHeld, isTrue);
      expect(k.releaseWakeLock(), isTrue, reason: '引用 1→0，此时才应真正摘锁');
      expect(k.wakeLockHeld, isFalse);
    });

    test('未持有就 release 时幂等返回 false 且不引入负数', () {
      final k = c();
      expect(k.releaseWakeLock(), isFalse);
      expect(k.wakeLockRefs, 0);
      expect(k.wakeLockHeld, isFalse);
    });

    test('acquire→release 单次配对后回到未持有态', () {
      final k = c();
      expect(k.acquireWakeLock(), isTrue);
      expect(k.releaseWakeLock(), isTrue);
      expect(k.wakeLockRefs, 0);
      expect(k.wakeLockHeld, isFalse);
    });
  });

  group('多播锁引用计数（SSDP 扫描保活）', () {
    DlnaKeepaliveController c() => DlnaKeepaliveController();

    test('重叠持有只真正挂一次锁', () {
      final k = c();
      expect(k.acquireMulticastLock(), isTrue);
      expect(k.acquireMulticastLock(), isFalse);
      expect(k.multicastLockRefs, 2);
    });

    test('引用归零才真正摘锁', () {
      final k = c();
      k.acquireMulticastLock();
      k.acquireMulticastLock();
      expect(k.releaseMulticastLock(), isFalse);
      expect(k.releaseMulticastLock(), isTrue);
      expect(k.multicastLockHeld, isFalse);
    });
  });

  group('唤醒锁与多播锁互不干扰', () {
    test('两把锁引用独立计数', () {
      final k = DlnaKeepaliveController();
      k.acquireWakeLock();
      k.acquireMulticastLock();

      k.releaseWakeLock();
      expect(k.wakeLockHeld, isFalse);
      expect(k.multicastLockHeld, isTrue, reason: '释放唤醒锁不应影响多播锁');

      k.releaseMulticastLock();
      expect(k.multicastLockHeld, isFalse);
    });
  });

  group('reset（App 划掉任务强制回收）', () {
    test('清空所有锁引用', () {
      final k = DlnaKeepaliveController();
      k.acquireWakeLock();
      k.acquireWakeLock();
      k.acquireMulticastLock();
      k.reset();
      expect(k.wakeLockRefs, 0);
      expect(k.multicastLockRefs, 0);
      expect(k.wakeLockHeld, isFalse);
      expect(k.multicastLockHeld, isFalse);
    });
  });
}