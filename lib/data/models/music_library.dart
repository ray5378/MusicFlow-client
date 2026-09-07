import 'package:musicflow_client/data/models/server_address.dart';
import 'package:freezed_annotation/freezed_annotation.dart';

part 'music_library.freezed.dart';
part 'music_library.g.dart';

@freezed
sealed class MusicLibrary with _$MusicLibrary {
  const factory MusicLibrary({
    required String id,
    required String name,
    @Default(MusicLibraryAuthType.token) MusicLibraryAuthType authType,
    String? username,
    // ⚠️ 现实情况：这两个字段**并未加密**——当前以明文存在 drift(SQLite) 中
    // （表结构与模型一致，历史数据无法凭空解密）。彻底治理需把凭据迁到
    // CredentialsStore(flutter_secure_storage) 并做 schema 迁移，见审计报告
    // 凭据存储主题；改动前禁止再标注"Encrypted"误导后来人。
    String? password,
    String? apiKey,
    String? serverType,
    String? serverVersion,
    @Default(false) bool isOpenSubsonic,
    @Default({}) Map<String, dynamic> extensions,
    @Default(false) bool isActive,
    @Default([]) List<ServerAddress> addresses,
    required DateTime createdAt,
    required DateTime updatedAt,
  }) = _MusicLibrary;

  factory MusicLibrary.fromJson(Map<String, dynamic> json) =>
      _$MusicLibraryFromJson(json);
}

enum MusicLibraryAuthType { token, apiKey }
