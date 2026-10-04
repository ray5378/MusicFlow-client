import 'dart:io';

import 'package:drift/drift.dart';
import 'package:flutter/services.dart';
import 'package:musicflow_client/data/models/music_library.dart';
import 'package:musicflow_client/data/models/server_address.dart';
import 'package:musicflow_client/data/repositories/library_repository.dart';
import 'package:musicflow_client/data/sources/database/app_database.dart';
import 'package:flutter_test/flutter_test.dart';

/// batch29-B：`lib/data/repositories/library_repository.dart`
/// 补测（覆盖率洼地 6/137 = 4.38%）。
///
/// 打法：整文件共用**一个真实 drift 实例**（避免 drift 的「重复创建数据库」
/// 告警），把仓库的 9 个公有方法 + `_mapLibrary` 映射分支全部走一遍真实
/// SQLite，不打任何桩——仓储层本来就是 DB 门面，用内存替身反而测不到
/// Companion 字段映射错误。
AppDatabase? _sharedDb;

AppDatabase get _db => _sharedDb ??= AppDatabase();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // AppDatabase 的 LazyDatabase 走 getApplicationDocumentsDirectory，
  // 纯测试下必须 mock 平台通道，否则 path_provider 抛 MissingPluginException。
  // 踩坑 #195-D：通道名必须是 'plugins.flutter.io/path_provider'（不是
  // 'path_provider'），否则 setMockMethodCallHandler 装了个空壳，异常照抛。
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
    const MethodChannel('plugins.flutter.io/path_provider'),
    (MethodCall call) async => '/tmp/mf_b29b_library_repo',
  );

  late LibraryRepository repo;

  // 踩坑 #202-D：本文件用**真 drift** 且库目录固定在 /tmp/mf_b29b_library_repo。
  // 上一次进程跑完留下的 db.sqlite 会让「库为空」断言失败、重复 insert 撞
  // UNIQUE constraint failed: music_libraries.id。所以在整个文件真正开库之前
  // （setUpAll 早于任何查询，AppDatabase 的 LazyDatabase 此刻还没打开连接）
  // 一次性清干净该目录，保证文件可反复重跑。
  //
  // 注意不能在 setUp（每用例）里删：那时 drift 的连接已经开着，把 sqlite
  // 文件从下面 unlink 掉会让后续所有查询炸（曾导致 13 例只剩 1 例通过）。
  setUpAll(() {
    final dir = Directory('/tmp/mf_b29b_library_repo');
    if (dir.existsSync()) {
      dir.deleteSync(recursive: true);
    }
  });

  setUp(() {
    repo = LibraryRepository(_db);
  });

  Future<List<MusicLibrary>> _watch() => repo.watchLibraries().first;

  MusicLibrary _lib(
    String id, {
    String name = 'L',
    List<ServerAddress> addresses = const <ServerAddress>[],
    Map<String, dynamic> extensions = const <String, dynamic>{},
  }) =>
      MusicLibrary(
        id: id,
        name: name,
        authType: MusicLibraryAuthType.token,
        username: 'user-$id',
        password: 'pw-$id',
        serverType: 'navidrome',
        serverVersion: '1.0',
        extensions: extensions,
        addresses: addresses,
        createdAt: DateTime.fromMillisecondsSinceEpoch(1700000000000),
        updatedAt: DateTime.fromMillisecondsSinceEpoch(1700000000000),
      );

  ServerAddress _addr(
    String id, {
    String libraryId = 'lib-x',
    String? label,
    String? url,
    int priority = 0,
    ServerAddressStatus status = ServerAddressStatus.unknown,
    bool isLocked = false,
    int? latency,
  }) =>
      ServerAddress(
        id: id,
        libraryId: libraryId,
        label: label ?? '线路 $id',
        url: url ?? 'http://$id.local',
        priority: priority,
        isLocked: isLocked,
        lastLatencyMs: latency,
        status: status,
      );

  Future<MusicLibrary> _find(List<MusicLibrary> all, String id) async =>
      all.where((l) => l.id == id).single;

  // ---------------------------------------------------------------------------
  // watchLibraries
  // ---------------------------------------------------------------------------

  test('watchLibraries 在库中无库时返回空列表', () async {
    expect(await _watch(), isEmpty);
  });

  test('watchLibraries 把库行与地址行映射成 MusicLibrary，地址按优先级升序',
      () async {
    await repo.addLibrary(
      _lib(
        'b29b-watch-1',
        addresses: <ServerAddress>[
          _addr('b29b-w-addr-2', priority: 5, status: ServerAddressStatus.ok),
          _addr('b29b-w-addr-1', priority: 1, status: ServerAddressStatus.failed),
        ],
      ),
    );

    final list = await _watch();
    final lib = await _find(list, 'b29b-watch-1');

    expect(lib.name, 'L');
    expect(lib.authType, MusicLibraryAuthType.token);
    expect(lib.username, 'user-b29b-watch-1');
    expect(lib.password, 'pw-b29b-watch-1');
    expect(lib.serverType, 'navidrome');
    expect(lib.serverVersion, '1.0');
    expect(lib.createdAt, DateTime.fromMillisecondsSinceEpoch(1700000000000));
    expect(lib.addresses.map((a) => a.id).toList(), <String>[
      'b29b-w-addr-1',
      'b29b-w-addr-2',
    ]);
    expect(lib.addresses.first.status, ServerAddressStatus.failed);
    expect(lib.addresses.last.status, ServerAddressStatus.ok);
  });

  // ---------------------------------------------------------------------------
  // addLibrary
  // ---------------------------------------------------------------------------

  test('addLibrary 一次写入库行与全部地址行', () async {
    await repo.addLibrary(
      _lib(
        'b29b-add-1',
        addresses: <ServerAddress>[
          _addr(
            'b29b-add-addr-1',
            libraryId: 'b29b-add-1',
            priority: 2,
            status: ServerAddressStatus.ok,
            isLocked: true,
            latency: 12,
          ),
        ],
      ),
    );

    final lib = await _find(await _watch(), 'b29b-add-1');
    expect(lib.addresses.single.url, 'http://b29b-add-addr-1.local');
    expect(lib.addresses.single.label, '线路 b29b-add-addr-1');
    expect(lib.addresses.single.priority, 2);
    expect(lib.addresses.single.isLocked, isTrue);
    expect(lib.addresses.single.lastLatencyMs, 12);
    expect(lib.addresses.single.status, ServerAddressStatus.ok);
  });

  test('addLibrary 把 extensions 字段做 json 往返', () async {
    await repo.addLibrary(
      _lib(
        'b29b-add-ext',
        extensions: const <String, dynamic>{
          'cover': <String, dynamic>{'priority': 0},
          'lyrics': <String, dynamic>{'priority': 1},
        },
      ),
    );

    final lib = await _find(await _watch(), 'b29b-add-ext');
    expect(lib.extensions['cover'], isA<Map<String, dynamic>>());
    expect(lib.extensions['cover']['priority'], 0);
    expect(lib.extensions['lyrics']['priority'], 1);
  });

  // ---------------------------------------------------------------------------
  // _mapLibrary
  // ---------------------------------------------------------------------------

  test('库行 extensions 列为 NULL 时映射为空 Map（jsonDecode 分支不炸）',
      () async {
    await _db.into(_db.musicLibraries).insert(
      MusicLibrariesCompanion.insert(
        id: 'b29b-ext-null',
        name: 'ExtNull',
        createdAt: 1700000000000,
        updatedAt: 1700000000000,
      ),
    );

    final lib = await _find(await _watch(), 'b29b-ext-null');
    expect(lib.extensions, isEmpty);
    expect(lib.addresses, isEmpty);
    expect(lib.isActive, isFalse);
  });

  test('库行带 apiKey / isOpenSubsonic 时映射透传', () async {
    await _db.into(_db.musicLibraries).insert(
      MusicLibrariesCompanion.insert(
        id: 'b29b-extra',
        name: 'Extra',
        apiKey: Value('secret-key'),
        isOpenSubsonic: Value(true),
        isActive: Value(true),
        createdAt: 1700000000000,
        updatedAt: 1700000000000,
      ),
    );

    final lib = await _find(await _watch(), 'b29b-extra');
    expect(lib.apiKey, 'secret-key');
    expect(lib.isOpenSubsonic, isTrue);
    expect(lib.isActive, isTrue);
  });

  // ---------------------------------------------------------------------------
  // updateLibrary
  // ---------------------------------------------------------------------------

  test('updateLibrary 更新名称 / 认证方式 / extensions / active 开关',
      () async {
    await repo.addLibrary(_lib('b29b-upd-1', name: 'before'));
    final updated = _lib('b29b-upd-1', name: 'after');
    await repo.updateLibrary(updated);

    final lib = await _find(await _watch(), 'b29b-upd-1');
    expect(lib.name, 'after');
    expect(lib.username, 'user-b29b-upd-1');
    expect(lib.isActive, isFalse);
  });

  // ---------------------------------------------------------------------------
  // addAddress / updateAddress / deleteAddress
  // ---------------------------------------------------------------------------

  test('addAddress 给已存在的库追加一条地址', () async {
    await repo.addLibrary(_lib('b29b-addr-add'));
    await repo.addAddress(
      _addr('b29b-addr-1', libraryId: 'b29b-addr-add', priority: 3),
    );
    await repo.addAddress(
      _addr('b29b-addr-2', libraryId: 'b29b-addr-add', priority: 4),
    );

    final lib = await _find(await _watch(), 'b29b-addr-add');
    expect(lib.addresses.map((a) => a.id).toList(), <String>[
      'b29b-addr-1',
      'b29b-addr-2',
    ]);
  });

  test('updateAddress 改名 / 改 URL / 改优先级 / 改锁定与延迟', () async {
    await repo.addLibrary(
      _lib(
        'b29b-addr-upd',
        addresses: <ServerAddress>[_addr('b29b-addr-u1', priority: 1)],
      ),
    );

    await repo.updateAddress(
      _addr(
        'b29b-addr-u1',
        libraryId: 'b29b-addr-upd',
        label: '改后标签',
        url: 'http://new.local',
        priority: 9,
        status: ServerAddressStatus.ok,
        isLocked: true,
        latency: 42,
      ),
    );

    final lib = await _find(await _watch(), 'b29b-addr-upd');
    final addr = lib.addresses.single;
    expect(addr.label, '改后标签');
    expect(addr.url, 'http://new.local');
    expect(addr.priority, 9);
    expect(addr.isLocked, isTrue);
    expect(addr.lastLatencyMs, 42);
    expect(addr.status, ServerAddressStatus.ok);
  });

  test('deleteAddress 只删除指定 id 的那一条地址', () async {
    await repo.addLibrary(
      _lib(
        'b29b-addr-del',
        addresses: <ServerAddress>[
          _addr('b29b-addr-d1', libraryId: 'b29b-addr-del'),
          _addr('b29b-addr-d2', libraryId: 'b29b-addr-del'),
        ],
      ),
    );

    await repo.deleteAddress('b29b-addr-d1');

    final lib = await _find(await _watch(), 'b29b-addr-del');
    expect(lib.addresses.map((a) => a.id).toList(), <String>['b29b-addr-d2']);
  });

  // ---------------------------------------------------------------------------
  // deleteLibrary
  // ---------------------------------------------------------------------------

  test('deleteLibrary 删除库行后地址随外键级联消失', () async {
    await repo.addLibrary(
      _lib(
        'b29b-lib-del',
        addresses: <ServerAddress>[
          _addr('b29b-libdel-addr', libraryId: 'b29b-lib-del'),
        ],
      ),
    );
    expect((await _watch()).where((l) => l.id == 'b29b-lib-del'), hasLength(1));

    await repo.deleteLibrary('b29b-lib-del');

    expect(
      (await _watch()).where((l) => l.id == 'b29b-lib-del'),
      isEmpty,
    );
  });

  // ---------------------------------------------------------------------------
  // setActiveLibrary
  // ---------------------------------------------------------------------------

  test('setActiveLibrary 把目标库置为 active 且其余全部置为 inactive', () async {
    await repo.addLibrary(_lib('b29b-active-a'));
    await repo.addLibrary(_lib('b29b-active-b'));

    await repo.setActiveLibrary('b29b-active-b');

    final all = await _watch();
    expect(
      all.where((l) => l.isActive).map((l) => l.id).toList(),
      <String>['b29b-active-b'],
    );
  });

  test('setActiveLibrary 传入空 id 时走告警分支且不激活任何库', () async {
    await repo.addLibrary(_lib('b29b-active-empty'));
    await repo.setActiveLibrary('');

    final all = await _watch();
    expect(all.where((l) => l.id == 'b29b-active-empty'), hasLength(1));
    expect(all.any((l) => l.isActive), isFalse);
  });
}
