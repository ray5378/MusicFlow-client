import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:musicflow_client/core/network/address_pool.dart';
import 'package:musicflow_client/core/utils/logger.dart';
import 'package:musicflow_client/core/utils/network_error_notifier.dart';
import 'package:flutter/foundation.dart';

/// 网络类型枚举
enum NetworkType { wifi, mobile, none }

class ConnectivityMonitor {
  static const _tag = 'CONNECTIVITY';
  final AddressPool _addressPool;
  List<ConnectivityResult> _lastResults = [ConnectivityResult.none];

  /// 当前网络类型的 StreamController
  final _networkTypeController = StreamController<NetworkType>.broadcast();

  /// 当前网络类型
  NetworkType _currentNetworkType = NetworkType.none;

  ConnectivityMonitor(this._addressPool);

  StreamSubscription<List<ConnectivityResult>>? _subscription;

  /// 当前网络类型 Stream
  Stream<NetworkType> get networkTypeStream => _networkTypeController.stream;

  /// 当前网络类型
  NetworkType get currentNetworkType => _currentNetworkType;

  void start() {
    _subscription?.cancel();
    Logger.infoWithTag(_tag, 'connectivity monitor started');

    // 初始检测
    Connectivity().checkConnectivity().then((results) {
      _updateNetworkType(results);
    }).catchError((e) {
      Logger.warnWithTag(_tag, 'initial connectivity check failed', e);
    });

    _subscription = Connectivity().onConnectivityChanged.listen((results) {
      if (!listEquals(results, _lastResults)) {
        _lastResults = results;
        Logger.infoWithTag(_tag, 'connectivity changed: $results');
        _updateNetworkType(results);

        final hasConnection = results.any((r) => r != ConnectivityResult.none);
        if (hasConnection) {
          Logger.infoWithTag(
            _tag,
            'connection available, probing address pool',
          );
          // 网络恢复：取消启动期或未确认的连接失败提示。
          NetworkErrorNotifier.cancelPending();
          _addressPool.probeAll();
        }
      }
    }, onError: (e) {
      Logger.warnWithTag(_tag, 'connectivity stream error', e);
    });
  }

  /// 把一次插件回报的结果落地成「当前网络类型」并同步给地址池。
  void _updateNetworkType(List<ConnectivityResult> results) {
    final newType = _resolveNetworkType(results);
    // 同步给地址池：拦截器据此跳过「延时重试波」（attempt >= 1）。
    // 放在「类型是否变化」判定**之外**：即使类型没变也要写，否则
    // 断开 → 重连 → 再断开 时最后一次会漏同步。
    _addressPool.isNetworkDown = newType == NetworkType.none;
    if (newType != _currentNetworkType) {
      _currentNetworkType = newType;
      _networkTypeController.add(newType);
      Logger.infoWithTag(_tag, 'network type changed: $newType');
    }
  }

  /// 测试专用入口：把一次插件回报的结果灌进来。
  ///
  /// 做成 **static** 而不是给实例加一个公开方法，是因为本类被多处测试用
  /// `implements ConnectivityMonitor` 伪造（例如
  /// `test/widgets/b35c_visible_remote_retry_scope_test.dart:32`）——
  /// 给实例加任何公开成员都会让那些 fake 编译不过（Dart 的 `implements`
  /// 要求实现全部实例成员），而 static 成员不属于实例接口，天然不受影响。
  @visibleForTesting
  static void applyNetworkTypeForTest(
    ConnectivityMonitor monitor,
    List<ConnectivityResult> results,
  ) {
    monitor._updateNetworkType(results);
  }

  NetworkType _resolveNetworkType(List<ConnectivityResult> results) {
    if (results.contains(ConnectivityResult.wifi)) {
      return NetworkType.wifi;
    } else if (results.contains(ConnectivityResult.mobile)) {
      return NetworkType.mobile;
    } else if (results.contains(ConnectivityResult.ethernet)) {
      return NetworkType.wifi; // 有线视为 Wi-Fi（不限流量）
    } else if (results.contains(ConnectivityResult.vpn)) {
      // VPN 下保守处理，视为 mobile
      return NetworkType.mobile;
    } else if (results.every((r) => r == ConnectivityResult.none)) {
      return NetworkType.none;
    }
    // 其他情况（bluetooth 等）视为 mobile
    return NetworkType.mobile;
  }

  void stop() {
    _subscription?.cancel();
    Logger.infoWithTag(_tag, 'connectivity monitor stopped');
    _networkTypeController.close();
  }
}
