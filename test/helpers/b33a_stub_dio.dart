// Shared test-only Dio stub used by the b33a_ source unit tests.
//
// This file lives under test/ and contains NO production code. It lets the
// cover/lyrics source classes perform their real JSON parsing & branching
// logic against canned HTTP responses, with zero network access.
//
// NOTE: `Dio` is an abstract class with a factory constructor, so we cannot
// subclass it. Instead we return a fully-configured `Dio` instance whose
// request interceptor resolves/rejects every call.
import 'dart:async';

import 'package:dio/dio.dart';

/// Decides the [Response] (or throws) for each intercepted request.
typedef StubHandler = FutureOr<Response<dynamic>> Function(
  RequestOptions options,
);

/// Build a [Dio] whose requests are intercepted by [handler].
Dio stubDio({StubHandler? handler}) {
  final dio = Dio();
  dio.interceptors.clear();
  dio.interceptors.add(_StubInterceptor(handler));
  return dio;
}

/// Respond to every request with [data] and [statusCode].
Dio stubDioRespond(dynamic data, {int statusCode = 200}) {
  return stubDio(
    handler: (options) => Response<dynamic>(
      requestOptions: options,
      data: data,
      statusCode: statusCode,
    ),
  );
}

/// Reject every request with a [DioException] wrapping [error].
Dio stubDioThrowing(Object error) {
  return stubDio(
    handler: (options) => throw DioException(
      requestOptions: options,
      error: error,
      type: DioExceptionType.unknown,
    ),
  );
}

class _StubInterceptor extends Interceptor {
  _StubInterceptor(this._handler);

  final StubHandler? _handler;

  @override
  void onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    final h = _handler;
    if (h == null) {
      handler.resolve(
        Response<dynamic>(requestOptions: options, data: null, statusCode: 200),
      );
      return;
    }
    try {
      final resp = await h(options);
      handler.resolve(resp);
    } on DioException catch (e) {
      handler.reject(e);
    } catch (e) {
      handler.reject(
        DioException(
          requestOptions: options,
          error: e,
          type: DioExceptionType.unknown,
        ),
      );
    }
  }
}
