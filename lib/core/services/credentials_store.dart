import 'package:flutter/foundation.dart'
    show kIsWeb, defaultTargetPlatform, TargetPlatform;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'package:musicflow_client/core/utils/logger.dart';

/// 凭据安全存储：password / apiKey 落系统钥匙串
/// （Windows 走 DPAPI 加密文件、Android 走 Keystore 加密的 SharedPreferences），
/// 不再明文进 SharedPreferences / SQLite / 日志。
///
/// 作用域约定：
/// - `server_config`：当前服务器配置的凭据（LocalStorage.saveServerConfig 使用）；
/// - `library`：媒体库凭据（预留）。
class CredentialsStore {
  CredentialsStore._();

  static const String scopeServerConfig = 'server_config';
  static const String scopeLibrary = 'library';

  static const FlutterSecureStorage _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  static String _key(String scope, String id, String field) =>
      'cred_${scope}_${id}_$field';

  static bool get _supported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.windows ||
          defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.macOS);

  /// 写入一组凭据字段（value 为 null/空串的字段会被删除）。
  /// 全静默失败降级：钥匙串不可用时记录日志，不阻断登录/保存流程。
  static Future<void> writeAll(
    String scope,
    String id,
    Map<String, String?> values,
  ) async {
    if (!_supported) return;
    try {
      for (final entry in values.entries) {
        final key = _key(scope, id, entry.key);
        final value = entry.value;
        if (value == null || value.isEmpty) {
          await _storage.delete(key: key);
        } else {
          await _storage.write(key: key, value: value);
        }
      }
    } catch (e) {
      Logger.warnWithTag('CRED_STORE', 'write failed scope=$scope id=$id', e);
    }
  }

  /// 读取一组凭据字段。读取失败返回空 Map（调用方按无凭据处理）。
  static Future<Map<String, String>> readAll(
    String scope,
    String id,
    Iterable<String> fields,
  ) async {
    if (!_supported) return const {};
    final out = <String, String>{};
    try {
      for (final field in fields) {
        final value = await _storage.read(key: _key(scope, id, field));
        if (value != null && value.isNotEmpty) out[field] = value;
      }
    } catch (e) {
      Logger.warnWithTag('CRED_STORE', 'read failed scope=$scope id=$id', e);
    }
    return out;
  }

  /// 删除一组凭据字段（登出/删除库时调用）。
  static Future<void> deleteAll(
    String scope,
    String id,
    Iterable<String> fields,
  ) async {
    if (!_supported) return;
    try {
      for (final field in fields) {
        await _storage.delete(key: _key(scope, id, field));
      }
    } catch (e) {
      Logger.debugWithTag('CRED_STORE', 'delete failed scope=$scope id=$id: $e');
    }
  }
}
