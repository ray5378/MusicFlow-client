import 'package:dio/dio.dart';
import 'package:musicflow_client/core/network/address_pool.dart';
import 'package:musicflow_client/core/l10n/localizations.dart';
import 'package:musicflow_client/core/utils/logger.dart';
import 'package:musicflow_client/core/utils/server_url_security.dart';
import 'package:musicflow_client/core/utils/toast_notifier.dart';

class FallbackInterceptor extends Interceptor {
  static const _tag = 'FALLBACK';
  static const allowRetryExtraKey = 'musicflow.allowFallbackRetry';
  final AddressPool _addressPool;
  final Dio _dio; // The customized Dio instance (with this interceptor)

  int _consecutiveFailures = 0;

  /// 故障切换重入护栏：切换 + 重试属「全链路」动作，多条在途请求并发
  /// 失败时只允许一条执行，其余直接向上抛。
  bool _failoverInFlight = false;

  FallbackInterceptor(this._addressPool, this._dio);

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    final active = _addressPool.activeAddress;
    if (active != null) {
      // 归一化去尾斜杠：baseUrl 会被封面/流 URL 手工拼接复用，带尾斜杠会
      // 拼出 '//rest/...'（服务端返回 200 + SPA HTML，导致静默全挂）。
      options.baseUrl = normalizeServerBaseUrl(active.url);
    }
    Logger.debugWithTag(
      _tag,
      'request ${options.method} ${options.path} via '
      '${active?.label ?? 'no-active-address'}',
    );
    super.onRequest(options, handler);
  }

  @override
  void onResponse(Response response, ResponseInterceptorHandler handler) {
    if (_consecutiveFailures != 0) {
      Logger.debugWithTag(_tag, 'reset consecutive failure counter');
      _consecutiveFailures = 0;
    }
    // 单行响应摘要，替代原来 LogInterceptor 的整版 body 打印。
    Logger.debugWithTag(
      _tag,
      '${response.requestOptions.method} ${response.requestOptions.path} '
      '-> ${response.statusCode}',
    );
    super.onResponse(response, handler);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) async {
    if (_isConnectionError(err)) {
      if (err.requestOptions.extra[allowRetryExtraKey] == false) {
        Logger.warnWithTag(
          _tag,
          'skip automatic replay for non-idempotent request '
          'path=${err.requestOptions.path}',
          err,
        );
        super.onError(err, handler);
        return;
      }
      // 并发重入护栏：一次切换/重试未结束前，其余在途连接错误直接向上抛，
      // 避免多条请求同时「markFailed + 切换 + 重试 + 弹提示」，造成重复切换、
      // 切到刚切走的线路、弹多条提示等竞态。
      if (_failoverInFlight) {
        Logger.debugWithTag(
          _tag,
          'failover in flight, skip duplicate handling '
          'path=${err.requestOptions.path}',
        );
        super.onError(err, handler);
        return;
      }
      _consecutiveFailures++;
      Logger.warnWithTag(
        _tag,
        'connection error, consecutiveFailures=$_consecutiveFailures '
        'path=${err.requestOptions.path}',
        err,
      );

      // 手动模式 + 自动回退关闭时，不自动切换线路
      if (_addressPool.isManualMode && !_addressPool.autoFallback) {
        Logger.warnWithTag(
          _tag,
          'manual mode with autoFallback disabled, skip switch',
        );
        super.onError(err, handler);
        return;
      }

      if (_consecutiveFailures >= 2) {
        final currentAddress = _addressPool.activeAddress;
        if (currentAddress != null) {
          _failoverInFlight = true;
          try {
            _addressPool.markFailed(currentAddress);

            final next = _addressPool.getNextAvailable();
            if (next != null && next.id != currentAddress.id) {
              // Try probing/switching to next
              Logger.infoWithTag(
                _tag,
                'trying switch: ${currentAddress.label} -> ${next.label}',
              );
              final success = await _addressPool.switchTo(next, manual: false);
              if (success) {
                _consecutiveFailures = 0;
                ToastNotifier.show(
                  l10nNowCurrent().core_network_switched_notice(next.label),
                );

                // Retry with new address
                final opts = err.requestOptions;
                opts.baseUrl = next.url;

                try {
                  final response = await _dio.fetch(opts);
                  Logger.infoWithTag(
                    _tag,
                    'retry succeeded on ${next.label} path=${opts.path}',
                  );
                  return handler.resolve(response);
                } catch (e) {
                  // 重试请求若再失败，会经同一拦截器再次触发 onError，但已被
                  // 上面的 in-flight 护栏短路；这里只需把重试错误向上抛。
                  Logger.warnWithTag(
                    _tag,
                    'retry failed on ${next.label} path=${opts.path}',
                    e,
                  );
                  if (e is DioException) {
                    return handler.next(e);
                  }
                }
              } else {
                Logger.warnWithTag(
                  _tag,
                  'switch rejected by address pool: ${next.label}',
                );
              }
            } else {
              Logger.warnWithTag(
                _tag,
                'no next address available for fallback',
              );
            }
          } finally {
            _failoverInFlight = false;
          }
        }
      }
    } else {
      if (_consecutiveFailures != 0) {
        Logger.debugWithTag(_tag, 'reset consecutive failure counter');
      }
      _consecutiveFailures = 0;
    }

    super.onError(err, handler);
  }

  bool _isConnectionError(DioException err) {
    return err.type == DioExceptionType.connectionTimeout ||
        err.type == DioExceptionType.receiveTimeout ||
        err.type == DioExceptionType.connectionError ||
        (err.type == DioExceptionType.unknown &&
            err.message?.contains('SocketException') == true);
  }
}
