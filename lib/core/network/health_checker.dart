import 'dart:async';
import 'package:musicflow_client/core/network/address_pool.dart';
import 'package:musicflow_client/core/utils/logger.dart';
import 'package:musicflow_client/core/utils/network_error_notifier.dart';
import 'package:musicflow_client/data/models/server_address.dart';

class HealthChecker {
  static const _tag = 'HEALTH';
  final AddressPool _addressPool;
  Timer? _timer;

  /// 串行化护栏：上一轮 _check（探测 + 可能的切换，最坏 10s+）未结束时
  /// 跳过本次周期 tick，避免慢网下多个 30s 周期的检查重叠，重复
  /// probeAll / switchTo 引发状态竞态。
  bool _checking = false;

  HealthChecker(this._addressPool);

  void start() {
    stop();
    Logger.infoWithTag(_tag, 'health checker started');
    unawaited(_check()); // initial check
    _timer = Timer.periodic(
      const Duration(seconds: 30),
      (_) => unawaited(_check()),
    );
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    Logger.infoWithTag(_tag, 'health checker stopped');
  }

  Future<void> _check() async {
    if (_checking) {
      Logger.debugWithTag(_tag, 'previous health check still running, skip');
      return;
    }
    _checking = true;
    try {
      final active = _addressPool.activeAddress;
      Logger.debugWithTag(
        _tag,
        'health check tick, active=${active?.label ?? 'none'}',
      );

      // Check if current active connection is still good
      if (active != null) {
        final probedCurrent = await _addressPool.probeAddress(active);
        _addressPool.updateProbedAddress(probedCurrent);

        if (probedCurrent.status != ServerAddressStatus.ok) {
          Logger.warnWithTag(
            _tag,
            'active address unhealthy: ${probedCurrent.label}',
          );
          // 手动模式 + 自动回退关闭时，不自动切换
          if (_addressPool.isManualMode && !_addressPool.autoFallback) {
            Logger.warnWithTag(
              _tag,
              'manual mode with autoFallback disabled, skip recovery',
            );
            return;
          }

          final next = _addressPool.getNextAvailable();
          if (next != null && next.id != probedCurrent.id) {
            Logger.infoWithTag(
              _tag,
              'recovering by switching to ${next.label}',
            );
            await _addressPool.switchTo(next, manual: false);
          }
        } else {
          // Current is OK.
          // 连接恢复正常：取消启动期或未确认的连接失败提示。
          NetworkErrorNotifier.cancelPending();

          // 手动模式下不自动回退到更高优先级
          if (_addressPool.isManualMode) {
            return;
          }

          // Check if we are using suboptimal connection (fallback).
          // Try to recover to higher priority address if available.
          final sorted = _addressPool.addresses;

          if (sorted.isNotEmpty && active.id != sorted.first.id) {
            final best = sorted.first;
            final bestProbed = await _addressPool.probeAddress(best);
            _addressPool.updateProbedAddress(bestProbed);

            if (bestProbed.status == ServerAddressStatus.ok) {
              Logger.infoWithTag(
                _tag,
                'promoting higher-priority address: ${bestProbed.label}',
              );
              await _addressPool.switchTo(bestProbed, manual: false);
            }
          }
        }
      } else {
        // No active address. Maybe try to find one?
        Logger.warnWithTag(_tag, 'no active address, triggering probeAll');
        _addressPool.probeAll();
      }
    } finally {
      _checking = false;
    }
  }
}
