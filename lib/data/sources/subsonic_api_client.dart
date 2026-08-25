import 'package:dio/dio.dart';
import '../../core/constants/api_constants.dart';
import '../../core/network/fallback_interceptor.dart';
import '../../core/utils/server_url_security.dart';
import '../../core/utils/subsonic_auth.dart';
import '../../core/utils/logger.dart';
import '../models/music_library.dart';

/// Subsonic API Client
/// Updated to support MusicLibrary model and injected Dio.
class SubsonicApiClient {
  final Dio _dio;
  MusicLibrary? _library;

  // 稳定凭证:若每次 _addAuthParamsMap 都重新生成随机 salt,getCoverArtUrl 每次
  // 返回的 URL 都会不同,Image.network 会因 URL 变化反复重新加载 → 播放时封面闪烁。
  // 因此在同一次登录会话内复用同一组 salt/token,切换账号时再重新生成。
  String? _tokenSalt;
  String? _tokenDigest;

  SubsonicApiClient({required Dio dio}) : _dio = dio {
    // Remove any existing auth interceptor (may reference a stale client instance)
    // then add a new one pointing to this client.
    _dio.interceptors.removeWhere((i) => i is _SubsonicAuthInterceptor);
    _dio.interceptors.add(_SubsonicAuthInterceptor(this));
  }

  /// Set the current music library configuration
  void setLibrary(MusicLibrary? library) {
    _library = library;
    _tokenSalt = null;
    _tokenDigest = null;
    // Note: Base URL is handled by AddressPool/Dio options updates in Provider.
    // Here we just store library for Auth params.
  }

  MusicLibrary? get library => _library;

  /// Check response status (Subsonic specific)
  void _checkResponse(Map<String, dynamic> data) {
    if (!data.containsKey('subsonic-response')) {
      // Some servers might return plain JSON if error?
      // throw Exception('Invalid response: missing subsonic-response');
      return; // Or throw?
    }
    final response = data['subsonic-response'];
    if (response == null) return;

    final status = response['status'];
    if (status != 'ok') {
      final error = response['error'];
      final message = error?['message'] ?? 'Unknown error';
      final code = error?['code'] ?? 0;
      throw SubsonicException(message, code);
    }
  }

  /// Ping
  Future<PingResult> ping() async {
    try {
      final response = await _dio.get(ApiConstants.ping);
      final data = response.data as Map<String, dynamic>;
      _checkResponse(data);

      final subsonicResponse = data['subsonic-response'];

      return PingResult(
        success: true,
        isOpenSubsonic: subsonicResponse['openSubsonic'] == true,
        serverType: subsonicResponse['type'] as String?,
        serverVersion: subsonicResponse['serverVersion'] as String?,
      );
    } on DioException catch (e) {
      Logger.error('Ping failed', e);
      return PingResult(success: false, errorMessage: e.message);
    } catch (e) {
      Logger.error('Ping failed', e);
      return PingResult(success: false, errorMessage: e.toString());
    }
  }

  /// Get OpenSubsonic Extensions
  Future<List<String>> getOpenSubsonicExtensions() async {
    try {
      final response = await _dio.get(ApiConstants.getOpenSubsonicExtensions);
      final data = response.data as Map<String, dynamic>;
      _checkResponse(data);

      final subsonicResponse = data['subsonic-response'];
      final extensions = subsonicResponse['openSubsonicExtensions'] as List?;

      if (extensions == null) return [];

      return extensions
          .map((e) => (e as Map<String, dynamic>)['name'] as String)
          .toList();
    } catch (e) {
      Logger.warn('Failed to get OpenSubsonic extensions', e);
      return [];
    }
  }

  /// Generic GET
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? queryParameters,
    bool allowFallbackRetry = true,
  }) async {
    final response = await _dio.get(
      path,
      queryParameters: queryParameters,
      options: Options(
        extra: <String, dynamic>{
          FallbackInterceptor.allowRetryExtraKey: allowFallbackRetry,
        },
      ),
    );
    final data = response.data as Map<String, dynamic>;
    _checkResponse(data);
    return data['subsonic-response'];
  }

  /// Raw GET for non-Subsonic endpoints (e.g. /rest/api/v1/...).
  /// Returns the decoded JSON body directly (no subsonic-response unwrap,
  /// no status check), but still carries the auth interceptor.
  Future<dynamic> getRaw(
    String path, {
    Map<String, dynamic>? queryParameters,
  }) async {
    final response = await _dio.get(path, queryParameters: queryParameters);
    return response.data;
  }

  /// Raw POST for non-Subsonic endpoints (e.g. /rest/api/v1/online/.../recommend/import).
  /// Sends [data] as JSON and returns the decoded JSON body directly.
  Future<dynamic> postRaw(
    String path, {
    Map<String, dynamic>? queryParameters,
    dynamic data,
  }) async {
    final response = await _dio.post(
      path,
      queryParameters: queryParameters,
      data: data,
      options: Options(contentType: 'application/json'),
    );
    return response.data;
  }

  /// Raw DELETE for non-Subsonic endpoints (e.g. /rest/api/v1/...).
  /// Returns the decoded JSON body directly (no subsonic-response unwrap).
  Future<dynamic> deleteRaw(
    String path, {
    Map<String, dynamic>? queryParameters,
  }) async {
    final response = await _dio.delete(path, queryParameters: queryParameters);
    return response.data;
  }

  /// Generic POST
  Future<Map<String, dynamic>> post(
    String path, {
    Map<String, dynamic>? queryParameters,
    dynamic data,
    bool allowFallbackRetry = true,
  }) async {
    final response = await _dio.post(
      path,
      queryParameters: queryParameters,
      data: data,
      options: Options(
        extra: <String, dynamic>{
          FallbackInterceptor.allowRetryExtraKey: allowFallbackRetry,
        },
      ),
    );
    final responseData = response.data as Map<String, dynamic>;
    _checkResponse(responseData);
    return responseData['subsonic-response'];
  }

  /// Get Dio instance
  Dio get dio => _dio;

  /// Generate Cover Art URL
  String getCoverArtUrl(String coverArtId, {int? size}) {
    if (_library == null) return '';
    // Use current dio baseUrl
    final baseUrl = _dio.options.baseUrl;
    if (baseUrl.isEmpty) return '';

    final params = <String, String>{};
    _addAuthParamsMap(params);

    params['id'] = coverArtId;
    if (size != null) {
      params['size'] = size.toString();
    }

    // 必须用 joinServerUrl：baseUrl 带尾斜杠时直接相加会产生 '//rest/getCoverArt',
    // 服务端对此返回 200 + SPA index.html,图片解码静默失败 → 封面全不显示。
    final uri = Uri.parse(joinServerUrl(baseUrl, ApiConstants.getCoverArt));
    final urlWithParams = uri.replace(queryParameters: params);
    return urlWithParams.toString();
  }

  /// Generate Stream URL
  String getStreamUrl(
    String songId, {
    int? maxBitRate,
    String? format,
    int? timeOffset,
  }) {
    if (_library == null) return '';
    final baseUrl = _dio.options.baseUrl;
    if (baseUrl.isEmpty) return '';

    final params = <String, String>{};
    _addAuthParamsMap(params);

    params['id'] = songId;
    if (maxBitRate != null) {
      params['maxBitRate'] = maxBitRate.toString();
    }
    if (format != null) {
      params['format'] = format;
    }
    if (timeOffset != null && timeOffset > 0) {
      params['timeOffset'] = timeOffset.toString();
    }

    // 流式播放始终使用 /rest/stream（包括转码）
    // joinServerUrl 防双斜杠：'//rest/stream' 会返回 200 + HTML,播放器拿到 HTML
    // 后无法解码 → 所有歌曲都放不出声，且没有任何报错。
    final uri = Uri.parse(joinServerUrl(baseUrl, ApiConstants.stream));
    final urlWithParams = uri.replace(queryParameters: params);
    return urlWithParams.toString();
  }

  /// 远程插件歌曲流地址(/rest/stream-remote):与主项目一致,带 provider/source/id,
  /// 以及标题/艺术家/专辑/时长/封面等透传参数,确保插件侧能正确解析并回源。
  /// 鉴权参数由 _addAuthParamsMap 注入(query),播放器可直接用此 URL 拉流。
  String getRemoteStreamUrl({
    required String provider,
    required String source,
    required String id,
    String? title,
    String? artist,
    String? album,
    int? duration,
    String? cover,
  }) {
    if (_library == null) return '';
    final baseUrl = _dio.options.baseUrl;
    if (baseUrl.isEmpty) return '';

    final params = <String, String>{};
    _addAuthParamsMap(params);

    params['provider'] = provider;
    params['source'] = source;
    params['id'] = id;
    if (title != null && title.isNotEmpty) params['title'] = title;
    if (artist != null && artist.isNotEmpty) params['artist'] = artist;
    if (album != null && album.isNotEmpty) params['album'] = album;
    if (duration != null) params['duration'] = duration.toString();
    if (cover != null && cover.isNotEmpty) params['cover'] = cover;

    final uri = Uri.parse(joinServerUrl(baseUrl, '/rest/stream-remote'));
    return uri.replace(queryParameters: params).toString();
  }

  /// Generate Download URL（始终下载原始无损文件）
  String getDownloadUrl(String songId) {
    if (_library == null) return '';
    final baseUrl = _dio.options.baseUrl;
    if (baseUrl.isEmpty) return '';

    final params = <String, String>{};
    _addAuthParamsMap(params);
    params['id'] = songId;

    final uri = Uri.parse(joinServerUrl(baseUrl, ApiConstants.download));
    final urlWithParams = uri.replace(queryParameters: params);
    return urlWithParams.toString();
  }

  /// Get Music Folders
  Future<List<Map<String, dynamic>>> getMusicFolders() async {
    try {
      final response = await _dio.get(ApiConstants.getMusicFolders);
      final data = response.data as Map<String, dynamic>;
      _checkResponse(data);

      final subsonicResponse = data['subsonic-response'];
      final folders = subsonicResponse['musicFolders']?['musicFolder'];

      if (folders is List) {
        return folders.cast<Map<String, dynamic>>();
      } else if (folders is Map) {
        // Single folder potentially
        return [folders as Map<String, dynamic>];
      }
      return [];
    } catch (e) {
      Logger.warn('Failed to get music folders', e);
      return [];
    }
  }

  void _addAuthParamsMap(Map<String, String> params) {
    if (_library == null) {
      // Just common params if no library
      params['v'] = ApiConstants.apiVersion;
      params['c'] = ApiConstants.clientName;
      params['f'] = ApiConstants.format;
      return;
    }

    if (_library!.authType == MusicLibraryAuthType.apiKey &&
        _library!.apiKey != null) {
      params.addAll(
        SubsonicAuth.generateApiKeyAuthParams(
          apiKey: _library!.apiKey!,
          version: ApiConstants.apiVersion,
          clientName: ApiConstants.clientName,
          format: ApiConstants.format,
        ),
      );
    } else if (_library!.password != null) {
      _ensureTokenAuth(_library!.password!);
      params.addAll({
        'u': _library!.username ?? '',
        't': _tokenDigest!,
        's': _tokenSalt!,
        'v': ApiConstants.apiVersion,
        'c': ApiConstants.clientName,
        'f': ApiConstants.format,
      });
    } else {
      // Only common params if auth data incomplete
      params['v'] = ApiConstants.apiVersion;
      params['c'] = ApiConstants.clientName;
      params['f'] = ApiConstants.format;
    }
  }

  /// 为当前账号生成一次 salt/token 并复用,保证 URL/凭证在会话内确定。
  /// 若每次调用都生成随机 salt,封面 URL 每次重建都不同,
  /// Image.network 会因此反复重新加载 → 音乐播放时封面持续闪烁。
  void _ensureTokenAuth(String password) {
    if (_tokenSalt != null && _tokenDigest != null) return;
    final salt = SubsonicAuth.generateSalt();
    _tokenSalt = salt;
    _tokenDigest = SubsonicAuth.generateToken(password, salt);
  }
}

class _SubsonicAuthInterceptor extends Interceptor {
  final SubsonicApiClient _client;
  _SubsonicAuthInterceptor(this._client);

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    final params = <String, String>{};
    _client._addAuthParamsMap(params);
    options.queryParameters.addAll(params);
    handler.next(options);
  }
}

class PingResult {
  final bool success;
  final bool isOpenSubsonic;
  final String? serverType;
  final String? serverVersion;
  final String? errorMessage;

  PingResult({
    required this.success,
    this.isOpenSubsonic = false,
    this.serverType,
    this.serverVersion,
    this.errorMessage,
  });
}

class SubsonicException implements Exception {
  final String message;
  final int code;
  SubsonicException(this.message, this.code);
  @override
  String toString() => 'SubsonicException: $message (code: $code)';
}
