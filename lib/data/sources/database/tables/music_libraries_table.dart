import 'package:drift/drift.dart';

@DataClassName('MusicLibraryTableData')
class MusicLibraries extends Table {
  TextColumn get id => text()();
  TextColumn get name => text()();
  TextColumn get authType =>
      text().withDefault(const Constant('token'))(); // 'apikey' / 'token'
  TextColumn get username => text().nullable()();
  // 凭据不落库：password/apiKey 存系统钥匙串（CredentialsStore，ADR-3）。
  // 这两列仅保留用于承接历史明文数据的迁移，写入路径恒为 NULL。
  TextColumn get password => text().nullable()();
  TextColumn get apiKey => text().nullable()();
  TextColumn get serverType => text().nullable()();
  TextColumn get serverVersion => text().nullable()();
  BoolColumn get isOpenSubsonic =>
      boolean().withDefault(const Constant(false))();
  TextColumn get extensions => text().nullable()(); // JSON
  BoolColumn get isActive => boolean().withDefault(const Constant(false))();
  IntColumn get createdAt => integer()();
  IntColumn get updatedAt => integer()();

  @override
  Set<Column> get primaryKey => {id};
}
