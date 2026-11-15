import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'package:musicflow_client/core/utils/logger.dart';

const String _logTag = 'APK_DLM';

/// DownloadManager 里一次下载的瞬时状态（原生 `query` 的返回值）。
@immutable
class ApkDownloadStatus {
  const ApkDownloadStatus({
    required this.status,
    required this.downloaded,
    required this.total,
    this.localUri,
    this.reason = 0,
  });

  /// `pending` / `running` / `paused` / `successful` / `failed` / `unknown`。
  final String status;

  /// 已下载字节数。
  final int downloaded;

  /// 总字节数（未知时为 0 或 -1）。
  final int total;

  /// 成功后系统给出的 `content://` 或 `file://` URI 字符串。
  final String? localUri;

  /// 系统给的失败原因码（`DownloadManager.COLUMN_REASON`）。
  final int reason;

  bool get isSuccessful => status == 'successful';
  bool get isFailed => status == 'failed';
  bool get isRunning =>
      status == 'running' || status == 'pending' || status == 'paused';

  /// 系统已落盘的绝对路径（`localUri` 转 path；拿不到返回 null）。
  String? get localPath {
    final uri = localUri;
    if (uri == null || uri.isEmpty) return null;
    try {
      final parsed = Uri.parse(uri);
      if (parsed.scheme == 'file') return parsed.path;
      // 兜底：部分 ROM 直接回裸路径字符串。
      if (parsed.scheme.isEmpty) return uri;
      return null;
    } catch (_) {
      return null;
    }
  }

  /// 解析原生 Map；结构不对返回 null（当作 unknown，不抛）。
  static ApkDownloadStatus? fromMap(Object? raw) {
    if (raw is! Map) return null;
    final status = raw['status'];
    if (status is! String) return null;
    return ApkDownloadStatus(
      status: status,
      downloaded: (raw['downloaded'] as num?)?.toInt() ?? 0,
      total: (raw['total'] as num?)?.toInt() ?? 0,
      localUri: raw['localUri'] as String?,
      reason: (raw['reason'] as num?)?.toInt() ?? 0,
    );
  }

  @override
  String toString() =>
      'ApkDownloadStatus($status, $downloaded/$total, reason=$reason)';
}

/// Android `DownloadManager` 的 Dart 封装（通道 `com.musicflow.app/apk_download`）。
///
/// ## 为什么后台下载必须交给原生
///
/// Flutter 的 Dart 执行环境在 App 退到后台后**不保证存活** —— Android 会冻结
/// 甚至回收进程，`dio.download()` 会随之中断。「后台继续下 + 通知栏进度」
/// 只能交给系统 `DownloadManager`：通知栏进度条是系统自带的，进程被杀也由系统
/// 接管继续下，GitHub 的 302 跳转也是它自己跟。
///
/// 取舍如实记在这里：系统通知样式**显示不了下载速度**（有进度条与百分比），
/// 换来的是杀进程 / 切后台都不断、失败自动重试。
///
/// 本类刻意**不做平台判断**：调用方（`ApkDownloadService`）负责决定用不用它，
/// 这样单元测试可以直接 mock 通道、逐字验证契约。
class ApkDownloadManager {
  /// 通道名与 `MainActivity` 里的常量必须逐字一致。
  @visibleForTesting
  static const MethodChannel channel = MethodChannel(
    'com.musicflow.app/apk_download',
  );

  /// 系统是否真有 DownloadManager（几乎恒 true，留作异常 ROM 的兜底开关）。
  Future<bool> isAvailable() async {
    try {
      return await channel.invokeMethod<bool>('isAvailable') ?? false;
    } on MissingPluginException catch (e) {
      Logger.debugWithTag(_logTag, 'isAvailable unsupported', e);
      return false;
    } on PlatformException catch (e) {
      Logger.errorWithTag(_logTag, 'isAvailable failed: ${e.code}');
      return false;
    } catch (e) {
      Logger.errorWithTag(_logTag, 'isAvailable threw', e);
      return false;
    }
  }

  /// 交给系统下载，返回 download id；失败返回 null（不抛）。
  ///
  /// [fileName] 必须与落盘文件名一致：原生侧会写到
  /// `getExternalFilesDir(DIRECTORY_DOWNLOADS)/<fileName>`，并在 enqueue 前删掉
  /// 同名旧文件（DownloadManager 遇到重名会自动加 `-1` 后缀，必须避免）。
  Future<int?> enqueue({
    required String url,
    required String fileName,
    required String title,
    required String description,
  }) async {
    try {
      return await channel.invokeMethod<int>('enqueue', <String, dynamic>{
        'url': url,
        'fileName': fileName,
        'title': title,
        'description': description,
      });
    } on MissingPluginException catch (e) {
      Logger.debugWithTag(_logTag, 'enqueue unsupported', e);
      return null;
    } on PlatformException catch (e) {
      Logger.errorWithTag(
        _logTag,
        'enqueue failed: ${e.code} ${e.message ?? ''}',
      );
      return null;
    } catch (e) {
      Logger.errorWithTag(_logTag, 'enqueue threw', e);
      return null;
    }
  }

  /// 查一次状态；查不到返回 null（不抛）。
  Future<ApkDownloadStatus?> query(int id) async {
    try {
      final raw = await channel.invokeMethod<Object?>(
        'query',
        <String, dynamic>{'id': id},
      );
      return ApkDownloadStatus.fromMap(raw);
    } on MissingPluginException catch (e) {
      Logger.debugWithTag(_logTag, 'query unsupported', e);
      return null;
    } on PlatformException catch (e) {
      Logger.errorWithTag(_logTag, 'query failed: ${e.code}');
      return null;
    } catch (e) {
      Logger.errorWithTag(_logTag, 'query threw', e);
      return null;
    }
  }

  /// 取消并删除下载；返回是否真的删掉了。
  Future<bool> cancel(int id) async {
    try {
      return await channel.invokeMethod<bool>('cancel', <String, dynamic>{
            'id': id,
          }) ??
          false;
    } on MissingPluginException catch (e) {
      Logger.debugWithTag(_logTag, 'cancel unsupported', e);
      return false;
    } on PlatformException catch (e) {
      Logger.errorWithTag(_logTag, 'cancel failed: ${e.code}');
      return false;
    } catch (e) {
      Logger.errorWithTag(_logTag, 'cancel threw', e);
      return false;
    }
  }
}
