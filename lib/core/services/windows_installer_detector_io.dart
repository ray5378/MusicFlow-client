import 'dart:io';

import 'package:flutter/foundation.dart';

/// 判断当前 Windows 应用是「安装版」(Inno Setup)还是「绿色版」(zip 解压)。
///
/// 安装版特征(满足任一即判定为安装版):
/// 1. 可执行文件位于 Program Files 下(Inno Setup 默认安装目录);
/// 2. 同目录存在 `unins000.exe`(Inno Setup 卸载程序,绿色版不会有)。
///
/// 非 Windows 平台恒返回 false。
bool isWindowsInstallerBuild() {
  if (kIsWeb) return false;
  try {
    final exePath = Platform.resolvedExecutable;
    final dir = File(exePath).parent.path.toLowerCase();
    if (dir.contains('program files')) return true;
    return File(
      '$dir${Platform.pathSeparator}unins000.exe',
    ).existsSync();
  } catch (_) {
    return false;
  }
}
