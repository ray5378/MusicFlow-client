import 'dart:io';

import 'package:drift/drift.dart' hide isNull;
import 'package:flutter/foundation.dart'
    show TargetPlatform, debugDefaultTargetPlatformOverride;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musicflow_client/data/models/music_library.dart';
import 'package:musicflow_client/data/repositories/library_repository.dart';
import 'package:musicflow_client/data/sources/database/app_database.dart';

/// P1 / ADR-3：媒体库凭据治理回归。
///
/// 断言三件事：
///   1. 写入路径不再把 password/apiKey 明文落进 drift（SQLite）；
///   2. 读取路径（watchLibraries）从系统钥匙串回填凭据；
///   3. 历史明文一次性迁移进钥匙串并清空列；钥匙串不可用时保持明文兜底（不丢数据）。
///
/// 打法：真 drift（文件库，固定 /tmp/mf_b50a_lib_creds）+ 内存 Map 假扮
/// flutter_secure_storage 平台通道。
const MethodChannel _sec = MethodChannel(
  'plugins.it_nomads.com/flutter_secure_storage',
);
final Map<String, String> _kv = <String, String>{};

void _installSecureMock() {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_sec, (MethodCall call) async {
    final Map<Object?, Object?> args =
        (call.arguments as Map<Object?, Object?>?) ?? <Object?, Object?>{};
    final String? key = args['key'] as String?;
    switch (call.method) {
      case 'write':
        _kv[key!] = args['value'] as String;
        return null;
      case 'read':
        return _kv[key];
      case 'delete':
        _kv.remove(key);
        return null;
      case 'containsKey':
        return _kv.containsKey(key);
      default:
        return null;
    }
  });
}

String _pwdKey(String id) => 'cred_library_${id}_password';
String _apiKeyKey(String id) => 'cred_library_${id}_apiKey';

AppDatabase? _sharedDb;
AppDatabase get _db => _sharedDb ??= AppDatabase();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
    const MethodChannel('plugins.flutter.io/path_provider'),
    (MethodCall call) async => '/tmp/mf_b50a_lib_creds',
  );

  setUpAll(() {
    final dir = Directory('/tmp/mf_b50a_lib_creds');
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  late LibraryRepository repo;

  setUp(() {
    _kv.clear();
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    _installSecureMock();
    repo = LibraryRepository(_db);
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_sec, null);
  });

  MusicLibrary lib(String id, {String? password, String? apiKey}) => MusicLibrary(
        id: id,
        name: 'L-$id',
        authType: apiKey != null
            ? MusicLibraryAuthType.apiKey
            : MusicLibraryAuthType.token,
        username: 'u-$id',
        password: password,
        apiKey: apiKey,
        createdAt: DateTime.fromMillisecondsSinceEpoch(1700000000000),
        updatedAt: DateTime.fromMillisecondsSinceEpoch(1700000000000),
      );

  Future<MusicLibraryTableData> rawRow(String id) =>
      (_db.select(_db.musicLibraries)..where((t) => t.id.equals(id)))
          .getSingle();

  Future<MusicLibrary> watchOne(String id) async {
    final all = await repo.watchLibraries().first;
    return all.where((l) => l.id == id).single;
  }

  Future<void> insertRawPlaintext(
    String id, {
    String? password,
    String? apiKey,
  }) async {
    await _db.into(_db.musicLibraries).insert(
          MusicLibrariesCompanion.insert(
            id: id,
            name: 'legacy-$id',
            password: Value(password),
            apiKey: Value(apiKey),
            createdAt: 1700000000000,
            updatedAt: 1700000000000,
          ),
        );
  }

  // ---------------------------------------------------------------------------

  test('addLibrary：凭据进钥匙串，drift 列保持 NULL（无明文落库）', () async {
    await repo.addLibrary(lib('b50a-add', password: 'pw-1', apiKey: 'ak-1'));

    expect(_kv[_pwdKey('b50a-add')], 'pw-1');
    expect(_kv[_apiKeyKey('b50a-add')], 'ak-1');

    final row = await rawRow('b50a-add');
    expect(row.password, isNull, reason: 'drift 不应存明文 password');
    expect(row.apiKey, isNull, reason: 'drift 不应存明文 apiKey');
  });

  test('watchLibraries：从钥匙串回填 password/apiKey', () async {
    await repo.addLibrary(lib('b50a-read', password: 'pw-2', apiKey: 'ak-2'));

    final loaded = await watchOne('b50a-read');
    expect(loaded.password, 'pw-2');
    expect(loaded.apiKey, 'ak-2');
  });

  test('updateLibrary：覆盖钥匙串且 drift 列仍为空', () async {
    await repo.addLibrary(lib('b50a-upd', password: 'old'));
    await repo.updateLibrary(lib('b50a-upd', password: 'new'));

    expect(_kv[_pwdKey('b50a-upd')], 'new');
    final row = await rawRow('b50a-upd');
    expect(row.password, isNull);

    final loaded = await watchOne('b50a-upd');
    expect(loaded.password, 'new');
  });

  test('deleteLibrary：连带清除钥匙串凭据', () async {
    await repo.addLibrary(lib('b50a-del', password: 'pw-3', apiKey: 'ak-3'));
    expect(_kv.containsKey(_pwdKey('b50a-del')), isTrue);

    await repo.deleteLibrary('b50a-del');

    expect(_kv.containsKey(_pwdKey('b50a-del')), isFalse);
    expect(_kv.containsKey(_apiKeyKey('b50a-del')), isFalse);
  });

  test('migrateLegacyCredentials：历史明文搬进钥匙串并清空 drift 列', () async {
    await insertRawPlaintext('b50a-mig', password: 'legacy-pw', apiKey: 'legacy-ak');

    await repo.migrateLegacyCredentials();

    expect(_kv[_pwdKey('b50a-mig')], 'legacy-pw');
    expect(_kv[_apiKeyKey('b50a-mig')], 'legacy-ak');

    final row = await rawRow('b50a-mig');
    expect(row.password, isNull);
    expect(row.apiKey, isNull);

    // 迁移后读取路径仍能拿到原值。
    final loaded = await watchOne('b50a-mig');
    expect(loaded.password, 'legacy-pw');
    expect(loaded.apiKey, 'legacy-ak');
  });

  test('watchLibraries：订阅时自动完成历史明文迁移（端到端）', () async {
    await insertRawPlaintext('b50a-auto', password: 'auto-pw');

    final loaded = await watchOne('b50a-auto');

    expect(loaded.password, 'auto-pw');
    expect((await rawRow('b50a-auto')).password, isNull, reason: '订阅后明文应被清空');
    expect(_kv[_pwdKey('b50a-auto')], 'auto-pw');
  });

  test('迁移幂等：无明文时重复调用不产生副作用', () async {
    await repo.addLibrary(lib('b50a-idem', password: 'pw-4'));
    await repo.migrateLegacyCredentials();
    await repo.migrateLegacyCredentials();

    expect(_kv[_pwdKey('b50a-idem')], 'pw-4');
    final loaded = await watchOne('b50a-idem');
    expect(loaded.password, 'pw-4');
  });

  test('迁移守卫：钥匙串不可用时保留 drift 明文（不丢凭据）', () async {
    // 拆掉平台通道替身，模拟钥匙串不可用（未注册插件 / 缺 libsecret）。
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_sec, null);

    await insertRawPlaintext('b50a-safe', password: 'keep-me');

    await repo.migrateLegacyCredentials();

    final row = await rawRow('b50a-safe');
    expect(row.password, 'keep-me', reason: '写不进钥匙串时不得清空明文');

    // 读取路径仍能从 drift 兜底拿到值。
    final loaded = await watchOne('b50a-safe');
    expect(loaded.password, 'keep-me');
  });
}