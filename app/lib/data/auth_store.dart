import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart' as crypto;
import 'package:shared_preferences/shared_preferences.dart';

/// 服务器连接信息持久化 + Subsonic 鉴权参数生成。
class AuthStore {
  AuthStore(this._prefs);

  static const _kServer = 'mf.server';
  static const _kUser = 'mf.user';
  static const _kPassword = 'mf.password';
  static const _kApiKey = 'mf.apikey';

  final SharedPreferences _prefs;

  String server = '';
  String user = '';
  String password = '';
  String apiKey = '';

  bool get loggedIn => server.isNotEmpty && (apiKey.isNotEmpty || password.isNotEmpty);

  Future<void> load() async {
    server = _prefs.getString(_kServer) ?? '';
    user = _prefs.getString(_kUser) ?? '';
    password = _prefs.getString(_kPassword) ?? '';
    apiKey = _prefs.getString(_kApiKey) ?? '';
  }

  Future<void> save({
    required String server,
    required String user,
    String password = '',
    String apiKey = '',
  }) async {
    this.server = _normalize(server);
    this.user = user.trim();
    this.password = password;
    this.apiKey = apiKey.trim();
    await _prefs.setString(_kServer, this.server);
    await _prefs.setString(_kUser, this.user);
    await _prefs.setString(_kPassword, password);
    await _prefs.setString(_kApiKey, apiKey);
  }

  Future<void> clear() async {
    server = user = password = apiKey = '';
    await _prefs.remove(_kServer);
    await _prefs.remove(_kUser);
    await _prefs.remove(_kPassword);
    await _prefs.remove(_kApiKey);
  }

  /// 规范化：补 http://，去尾部斜杠。空 host 返回空。
  static String normalize(String raw) => _normalize(raw);

  static String _normalize(String raw) {
    var s = raw.trim();
    if (s.isEmpty) return '';
    if (!s.startsWith(RegExp(r'https?://'))) s = 'http://$s';
    while (s.endsWith('/')) {
      s = s.substring(0, s.length - 1);
    }
    return s;
  }

  /// 公共鉴权 query（token+salt 优先，apiKey 次之）。
  Map<String, String> authQuery() {
    final q = <String, String>{
      'v': '1.16.1',
      'c': 'MusicFlow',
      'f': 'json',
    };
    if (apiKey.isNotEmpty) {
      q
        ..['u'] = user
        ..['apiKey'] = apiKey;
      return q;
    }
    final salt = _salt();
    final token = crypto.md5.convert(utf8.encode('$password$salt')).toString();
    q
      ..['u'] = user
      ..['t'] = token
      ..['s'] = salt;
    return q;
  }

  static String _salt() {
    final r = Random.secure();
    return List.generate(12, (_) => 'abcdefghijklmnopqrstuvwxyz0123456789'[r.nextInt(36)]).join();
  }
}
