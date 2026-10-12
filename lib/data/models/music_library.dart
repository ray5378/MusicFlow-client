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
    // 凭据来源约定：这两个字段**运行时由 CredentialsStore（系统钥匙串）回填**
    // （见 LibraryRepository._mapLibrary）；写入时经 writeAll 进钥匙串，
    // drift 的 password/apiKey 列不入明文（ADR-3，历史明文由
    // LibraryRepository.migrateLegacyCredentials 一次性迁移）。
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
