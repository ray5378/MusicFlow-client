import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'package:musicflow_client/core/utils/logger.dart';

const String _logTag = 'APK_INSTALL';

/// 原生「安装未知应用」通道的 Dart 封装。
///
/// 为什么必须走原生：`permission_handler` **没有**「安装未知应用」这一项
/// （它不是普通运行时权限，而是 `Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES`
/// 对应的特殊应用访问权限），所以只能自建 MethodChannel。
///
/// 契约（与 `MainActivity.kt` 的 `_apkInstallHandler` 一一对应）：
/// - `canRequestPackageInstalls` → `Boolean`
/// - `openUnknownSourcesSettings` → `Boolean`（是否成功拉起设置页）
/// - `installApk(path)` → `Boolean`（安装器是否被成功拉起）
///
/// **所有方法都不向上抛**：平台通道缺失（桌面 / 测试环境）、ROM 阉割、权限
/// 被策略禁用…… 一律降级成 `false` 并留一条日志，由编排层决定兜底动作。
class ApkInstaller {
  /// 通道名与 `MainActivity` 里的常量必须逐字一致。
  @visibleForTesting
  static const MethodChannel channel = MethodChannel(
    'com.musicflow.app/apk_install',
  );

  /// 是否允许安装未知来源应用。
  ///
  /// Android 8.0（API 26）以下没有这个开关，恒为 true（由原生侧判定）。
  Future<bool> canRequestPackageInstalls({
    TargetPlatform? platform,
    bool isWeb = kIsWeb,
  }) async {
    if (isWeb ||
        (platform ?? defaultTargetPlatform) != TargetPlatform.android) {
      return false;
    }
    return _invokeBool('canRequestPackageInstalls');
  }

  /// 拉起「安装未知应用」授权页。
  ///
  /// 部分 ROM（及部分精简系统）没有这一页，原生侧会回退到「应用管理」总页；
  /// 再失败则回 `result.error`，这里兜成 false。
  Future<bool> openUnknownSourcesSettings({
    TargetPlatform? platform,
    bool isWeb = kIsWeb,
  }) async {
    if (isWeb ||
        (platform ?? defaultTargetPlatform) != TargetPlatform.android) {
      return false;
    }
    return _invokeBool('openUnknownSourcesSettings');
  }

  /// 唤起系统安装器安装 [filePath] 指向的 apk。
  ///
  /// ⚠️ 返回 true **只代表安装器界面被拉起了**，不代表装完。真正的字节流由
  /// 系统安装器异步读取 —— 所以调用方**绝不能**在这之后立刻删文件。
  Future<bool> installApk(
    String filePath, {
    TargetPlatform? platform,
    bool isWeb = kIsWeb,
  }) async {
    if (isWeb ||
        (platform ?? defaultTargetPlatform) != TargetPlatform.android) {
      return false;
    }
    return _invokeBool('installApk', <String, dynamic>{'path': filePath});
  }

  Future<bool> _invokeBool(String method, [Map<String, dynamic>? args]) async {
    try {
      final result = await channel.invokeMethod<bool>(method, args);
      return result ?? false;
    } on MissingPluginException catch (e) {
      Logger.debugWithTag(
        _logTag,
        '$method unsupported (no native handler)',
        e,
      );
      return false;
    } on PlatformException catch (e) {
      Logger.errorWithTag(
        _logTag,
        '$method failed: ${e.code} ${e.message ?? ''}',
      );
      return false;
    } catch (e) {
      // 兜住「归类之外」的一切（通道被别的插件抢占、engine 已销毁……）。
      Logger.errorWithTag(_logTag, '$method threw', e);
      return false;
    }
  }
}
