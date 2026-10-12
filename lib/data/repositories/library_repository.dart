import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:musicflow_client/core/services/credentials_store.dart';
import 'package:musicflow_client/core/utils/logger.dart';
import 'package:musicflow_client/data/models/music_library.dart';
import 'package:musicflow_client/data/models/server_address.dart';
import 'package:musicflow_client/data/sources/database/app_database.dart';
// Note: imports of table files are not strictly needed if we access via AppDatabase getters,
// but we need the Data classes (Row classes).
// AppDatabase exports them or they are available part of it?
// Usually generated code contains them.
// But we can import the table definitions if needed for type reference if distinct.
// Actually generated classes are in app_database.g.dart usually.
// Let's rely on AppDatabase's types.

class LibraryRepository {
  static const _tag = 'LIB_REPO';
  final AppDatabase _db;

  LibraryRepository(this._db);

  /// 媒体库凭据字段：明文曾直接落在 drift(SQLite)，治理后只进钥匙串。
  static const List<String> _credentialFields = ['password', 'apiKey'];

  Stream<List<MusicLibrary>> watchLibraries() async* {
    // 凭据治理（幂等）：把历史遗留的明文凭据搬进系统钥匙串并清空 drift 列。
    // 只在流建立前跑一次，避免在 watch 的 asyncMap 里写库触发二次发射。
    await migrateLegacyCredentials();

    yield* (_db.select(_db.musicLibraries)..orderBy([
          (t) => OrderingTerm(mode: OrderingMode.asc, expression: t.createdAt),
        ]))
        .watch()
        .asyncMap((rows) async {
          Logger.debugWithTag(_tag, 'watchLibraries emission count=${rows.length}');
          final libraries = <MusicLibrary>[];
          for (final row in rows) {
            final addresses =
                await (_db.select(_db.serverAddresses)
                      ..where((t) => t.libraryId.equals(row.id))
                      ..orderBy([
                        (t) => OrderingTerm(
                          mode: OrderingMode.asc,
                          expression: t.priority,
                        ),
                      ]))
                    .get();

            libraries.add(await _mapLibrary(row, addresses));
          }
          return libraries;
        });
  }

  /// 把 drift 里残留的历史明文凭据迁移到 CredentialsStore 并清空列。
  /// 幂等：无明文时零开销；钥匙串不可用时保留明文兜底（不丢数据）。
  Future<void> migrateLegacyCredentials() async {
    final rows = await _db.select(_db.musicLibraries).get();
    var migrated = 0;
    for (final row in rows) {
      final legacyPassword = row.password;
      final legacyApiKey = row.apiKey;
      final hasPlaintext =
          (legacyPassword != null && legacyPassword.isNotEmpty) ||
          (legacyApiKey != null && legacyApiKey.isNotEmpty);
      if (!hasPlaintext) continue;

      // 钥匙串里已有的值优先（可能是更晚写入的），只补缺。
      final existing = await CredentialsStore.readAll(
        CredentialsStore.scopeLibrary,
        row.id,
        _credentialFields,
      );
      final desired = <String, String?>{
        'password': existing['password'] ?? legacyPassword,
        'apiKey': existing['apiKey'] ?? legacyApiKey,
      };
      await CredentialsStore.writeAll(
        CredentialsStore.scopeLibrary,
        row.id,
        desired,
      );

      // 回读校验：只有确认凭据已真正落到钥匙串，才清空 drift 明文列。
      // 钥匙串不可用（未注册插件 / Linux 缺 libsecret 等）时保持明文兜底，
      // 宁可留旧明文也不丢凭据。
      final verify = await CredentialsStore.readAll(
        CredentialsStore.scopeLibrary,
        row.id,
        _credentialFields,
      );
      final persisted = desired.entries
          .where((e) => e.value != null && e.value!.isNotEmpty)
          .every((e) => verify[e.key] == e.value);
      if (!persisted) {
        Logger.warnWithTag(
          _tag,
          'secure storage unavailable; keep plaintext for id=${row.id}',
        );
        continue;
      }

      await (_db.update(_db.musicLibraries)..where((t) => t.id.equals(row.id)))
          .write(
        MusicLibrariesCompanion(
          password: const Value<String?>(null),
          apiKey: const Value<String?>(null),
        ),
      );
      migrated++;
    }
    if (migrated > 0) {
      Logger.infoWithTag(
        _tag,
        'migrated $migrated library credential row(s) to secure storage',
      );
    }
  }

  Future<void> addLibrary(MusicLibrary library) async {
    Logger.infoWithTag(_tag, 'addLibrary id=${library.id} name=${library.name}');
    // 凭据只进系统钥匙串，drift 不入明文（ADR-3）。
    await CredentialsStore.writeAll(
      CredentialsStore.scopeLibrary,
      library.id,
      {'password': library.password, 'apiKey': library.apiKey},
    );
    await _db.transaction(() async {
      await _db
          .into(_db.musicLibraries)
          .insert(
            MusicLibrariesCompanion.insert(
              id: library.id,
              name: library.name,
              authType: Value(library.authType.name),
              username: Value(library.username),
              serverType: Value(library.serverType),
              serverVersion: Value(library.serverVersion),
              isOpenSubsonic: Value(library.isOpenSubsonic),
              extensions: Value(jsonEncode(library.extensions)),
              isActive: Value(library.isActive),
              createdAt: library.createdAt.millisecondsSinceEpoch,
              updatedAt: library.updatedAt.millisecondsSinceEpoch,
            ),
          );

      for (final addr in library.addresses) {
        await _db
            .into(_db.serverAddresses)
            .insert(
              ServerAddressesCompanion.insert(
                id: addr.id,
                libraryId: library.id,
                label: addr.label,
                url: addr.url,
                priority: addr.priority,
                isLocked: Value(addr.isLocked),
                lastLatencyMs: Value(addr.lastLatencyMs),
                lastStatus: Value(addr.status.name),
              ),
            );
      }
    });
  }

  Future<void> updateLibrary(MusicLibrary library) async {
    Logger.infoWithTag(
      _tag,
      'updateLibrary id=${library.id} name=${library.name}',
    );
    // 凭据只进系统钥匙串，drift 列显式清空（ADR-3）。
    await CredentialsStore.writeAll(
      CredentialsStore.scopeLibrary,
      library.id,
      {'password': library.password, 'apiKey': library.apiKey},
    );
    await _db.transaction(() async {
      await (_db.update(
        _db.musicLibraries,
      )..where((t) => t.id.equals(library.id))).write(
        MusicLibrariesCompanion(
          name: Value(library.name),
          authType: Value(library.authType.name),
          username: Value(library.username),
          password: const Value<String?>(null),
          apiKey: const Value<String?>(null),
          extensions: Value(jsonEncode(library.extensions)),
          updatedAt: Value(DateTime.now().millisecondsSinceEpoch),
          isActive: Value(
            library.isActive,
          ), // Ideally handle active switching separately
          // ...
        ),
      );

      // For addresses, simplest is to delete all and re-insert, or diff.
      // For now, let's assume addresses are updated via separate methods or full replace?
      // If we pass the full library with addresses, we should probably sync addresses.
      // But users might update just library info.
      // Let's assume this method updates library info. Addresses are managed separately or we implement logic.
      // Given the plan says "Edit Library" includes addresses management, maybe we just handle address updates separately in UI logic.
      // But let's implement basic update.
    });
  }

  Future<void> updateAddress(ServerAddress addr) async {
    Logger.debugWithTag(
      _tag,
      'updateAddress id=${addr.id} label=${addr.label} status=${addr.status.name}',
    );
    await (_db.update(
      _db.serverAddresses,
    )..where((t) => t.id.equals(addr.id))).write(
      ServerAddressesCompanion(
        label: Value(addr.label),
        url: Value(addr.url),
        priority: Value(addr.priority),
        isLocked: Value(addr.isLocked),
        lastLatencyMs: Value(addr.lastLatencyMs),
        lastStatus: Value(addr.status.name),
      ),
    );
  }

  Future<void> deleteLibrary(String id) async {
    Logger.infoWithTag(_tag, 'deleteLibrary id=$id');
    // 连同钥匙串中的凭据一并清除，避免孤儿凭据残留（ADR-3）。
    await CredentialsStore.deleteAll(
      CredentialsStore.scopeLibrary,
      id,
      _credentialFields,
    );
    await (_db.delete(_db.musicLibraries)..where((t) => t.id.equals(id))).go();
  }

  Future<void> addAddress(ServerAddress addr) async {
    Logger.infoWithTag(
      _tag,
      'addAddress id=${addr.id} libraryId=${addr.libraryId} label=${addr.label}',
    );
    await _db
        .into(_db.serverAddresses)
        .insert(
          ServerAddressesCompanion.insert(
            id: addr.id,
            libraryId: addr.libraryId,
            label: addr.label,
            url: addr.url,
            priority: addr.priority,
            isLocked: Value(addr.isLocked),
            lastStatus: Value(addr.status.name),
          ),
        );
  }

  Future<void> deleteAddress(String id) async {
    Logger.infoWithTag(_tag, 'deleteAddress id=$id');
    await (_db.delete(_db.serverAddresses)..where((t) => t.id.equals(id))).go();
  }

  Future<void> setActiveLibrary(String id) async {
    if (id.isEmpty) {
      Logger.warnWithTag(_tag, 'setActiveLibrary called with empty id');
    } else {
      Logger.infoWithTag(_tag, 'setActiveLibrary id=$id');
    }
    await _db.transaction(() async {
      await (_db.update(_db.musicLibraries)
            ..where((t) => t.isActive.equals(true)))
          .write(const MusicLibrariesCompanion(isActive: Value(false)));

      await (_db.update(_db.musicLibraries)..where((t) => t.id.equals(id)))
          .write(const MusicLibrariesCompanion(isActive: Value(true)));
    });
  }

  Future<MusicLibrary> _mapLibrary(
    MusicLibraryTableData row,
    List<ServerAddressTableData> addrRows,
  ) async {
    // 凭据从系统钥匙串回填；drift 列仅作历史明文兜底（迁移完成前生效）。
    final creds = await CredentialsStore.readAll(
      CredentialsStore.scopeLibrary,
      row.id,
      _credentialFields,
    );
    return MusicLibrary(
      id: row.id,
      name: row.name,
      authType: MusicLibraryAuthType.values.byName(row.authType),
      username: row.username,
      password: creds['password'] ?? row.password,
      apiKey: creds['apiKey'] ?? row.apiKey,
      serverType: row.serverType,
      serverVersion: row.serverVersion,
      isOpenSubsonic: row.isOpenSubsonic,
      extensions: row.extensions != null
          ? jsonDecode(row.extensions!) as Map<String, dynamic>
          : {},
      isActive: row.isActive,
      createdAt: DateTime.fromMillisecondsSinceEpoch(row.createdAt),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(row.updatedAt),
      addresses: addrRows
          .map(
            (a) => ServerAddress(
              id: a.id,
              libraryId: a.libraryId,
              label: a.label,
              url: a.url,
              priority: a.priority,
              isLocked: a.isLocked,
              lastLatencyMs: a.lastLatencyMs,
              status: ServerAddressStatus.values.byName(a.lastStatus),
            ),
          )
          .toList(),
    );
  }
}
