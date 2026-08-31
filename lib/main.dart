import 'dart:async';
import 'dart:ui';

import 'package:musicflow_client/core/utils/network_error_notifier.dart';
import 'package:musicflow_client/core/utils/logger.dart';
import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio_media_kit/just_audio_media_kit.dart';
import 'app.dart';
import 'data/sources/local_storage.dart';

Future<void> main() async {
  runZonedGuarded(
    () async {
      await WidgetsFlutterBinding.ensureInitialized();

      // 收紧 Flutter 内部图片内存缓存：禁止磁盘/内存图片缓存的策略下，
      // 只保留极小的解码缓存兜底，并允许在切库/线路变化时快速清理。
      // 具体请求仍走 CoverArtImage 的 size 预算与视口优先加载。
      PaintingBinding.instance.imageCache
        ..maximumSize = 64
        ..maximumSizeBytes = 32 << 20;

      // 应用持久化的日志开关（默认关闭，需用户在设置里手动开启）。
      // 注意：不能在 runApp 前 await 平台存储（SharedPreferences）——桌面端
      // 平台插件在 C++ runner 的 OnCreate→RegisterPlugins 阶段才注册，Dart 侧
      // 在 runApp 前 await 该 channel 会因插件未就绪而永久挂起，导致首帧永不
      // 渲染、窗口透明只剩外框（Windows 尤甚，安卓注册路径不同不触发）。改为
      // 异步应用，绝不阻塞首帧。
      unawaited(
        LocalStorage.getLoggingEnabled()
            .then((enabled) => Logger.setLoggingEnabled(enabled)),
      );

      // 开启「连接失败」提示的启动宽限期：打开软件后 10 秒内先待确认，
      // 避免首屏未就绪时立刻误报连接失败。
      NetworkErrorNotifier.markAppStarted();

      final isDesktopMediaKitPlatform =
          !kIsWeb &&
          (defaultTargetPlatform == TargetPlatform.linux ||
              defaultTargetPlatform == TargetPlatform.windows);
      if (isDesktopMediaKitPlatform) {
        JustAudioMediaKit.ensureInitialized();
      }

      FlutterError.onError = (details) {
        Logger.errorWithTag(
          'APP',
          'Flutter framework error',
          details.exception,
          details.stack,
        );
        FlutterError.presentError(details);
      };

      PlatformDispatcher.instance.onError = (error, stack) {
        Logger.errorWithTag('APP', 'Uncaught platform error', error, stack);
        return true;
      };

      runApp(const ProviderScope(child: App()));

      // 修复损坏的 SharedPreferences(备份 + 重建干净起点):进程被强杀时
      // prefs 文件可能半写损坏,导致所有设置/播放状态读默认值(表现为
      // 「关闭后全部清空」)。必须 runApp 之后异步执行——平台通道在 runner
      // OnCreate 阶段才注册,runApp 前 await 会永久挂起。
      unawaited(LocalStorage.repairCorruptPreferences());
    },
    (error, stackTrace) {
      Logger.errorWithTag('APP', 'Uncaught zone error', error, stackTrace);
    },
  );
}
