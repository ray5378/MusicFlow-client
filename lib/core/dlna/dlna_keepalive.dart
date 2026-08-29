/// 客户端保活引用计数控制器。纯 Dart，不依赖平台通道，可在任意平台单测。
///
/// 用途：链路 B（局域网 DLNA 直投）在后台续播时，需要向原生申请
/// Wi-Fi 多播锁 / PARTIAL 唤醒锁（CPU 常醒让 2s 轮询 timer 持续触发）。
/// 多个调用方（投屏、扫描、曲末看门狗）可能重叠持有/释放同一把锁，
/// 由这里统一做「引用计数」：从 0→1 才真正向原生 acquire，1→0 才真正 release，
/// 中间的重叠加/减不触发原生调用，避免重复 acquire / 过早 release。
class DlnaKeepaliveController {
  int _wakeRefs = 0;
  int _multicastRefs = 0;

  /// 当前唤醒锁引用数（>0 表示处于持有态）。
  int get wakeLockRefs => _wakeRefs;
  bool get wakeLockHeld => _wakeRefs > 0;

  /// 当前多播锁引用数（>0 表示处于持有态）。
  int get multicastLockRefs => _multicastRefs;
  bool get multicastLockHeld => _multicastRefs > 0;

  /// 增加一次唤醒锁引用。
  /// 返回 true 表示发生 0→1（此时应向原生 acquire）；false 表示引用数只是从 1 增加，不应重复 acquire。
  bool acquireWakeLock() {
    final needsHold = _wakeRefs == 0;
    _wakeRefs++;
    return needsHold;
  }

  /// 减少一次唤醒锁引用。
  /// 返回 true 表示发生 1→0（此时应向原生 release）；false 表示引用数仍在 1 之上，不应只靠这一次就释放。
  bool releaseWakeLock() {
    if (_wakeRefs == 0) return false;
    _wakeRefs--;
    return _wakeRefs == 0;
  }

  /// 增加一次多播锁引用，语义同 [acquireWakeLock]。
  bool acquireMulticastLock() {
    final needsHold = _multicastRefs == 0;
    _multicastRefs++;
    return needsHold;
  }

  /// 减少一次多播锁引用，语义同 [releaseWakeLock]。
  bool releaseMulticastLock() {
    if (_multicastRefs == 0) return false;
    _multicastRefs--;
    return _multicastRefs == 0;
  }

  /// 清空所有锁引用（如 App 被划掉任务回收时强制释放）。
  void reset() {
    _wakeRefs = 0;
    _multicastRefs = 0;
  }
}