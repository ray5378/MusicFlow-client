/// Windows 安装版/绿色版检测的条件导出入口:
/// - 桌面(支持 dart:io)→ 真实检测(Program Files / unins000.exe);
/// - Web(无 dart:io)→ stub 恒 false。
export 'windows_installer_detector_stub.dart'
    if (dart.library.io) 'windows_installer_detector_io.dart';
