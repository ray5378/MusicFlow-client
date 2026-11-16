import 'dart:async';
import 'dart:ui';

import 'package:musicflow_client/core/utils/network_error_notifier.dart';
import 'package:musicflow_client/core/services/update_artifacts_cleanup.dart';
import 'package:musicflow_client/core/utils/logger.dart';
import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio_media_kit/just_audio_media_kit.dart';
import 'package:musicflow_client/app.dart';
import 'package:musicflow_client/core/network/cover_pressure_observer.dart';
import 'package:musicflow_client/data/sources/local_storage.dart';
import 'package:musicflow_client/providers/settings/update_download_provider.dart';
import 'package:musicflow_client/providers/ui/app_visibility_provider.dart';

/// 图片内存缓存字节上限。用户拍板固定 128MB（2026-10-08），
/// 见 [main] 内对 imageCache 的配置。
const int kImageCacheMaximumSizeBytes = 128 << 20;

Future<void> main() async {
  runZonedGuarded(
    () async {
      await WidgetsFlutterBinding.ensureInitialized();

      // 图片内存缓存：用户约定：封面等图片类数据只走内存缓存不落盘，
      // 内存配额按拍板固定 128MB（2026-10-08）。
      // 允许在切库/线路变化时快速清理；具体请求仍走 CoverArtImage 的
      // size 预算与视口优先加载。
      PaintingBinding.instance.imageCache
        ..maximumSize = 64
        ..maximumSizeBytes = kImageCacheMaximumSizeBytes;

      // 封面背压观测器（§5.2 / ADR-4）：安装 HttpOverrides 透明包装，
      // 只读封面 URL 的响应头（X-MusicFlow-Cover-Saturated / Retry-After），
      // 信号供 CoverArtImage 闸门消费。必须在 runApp 前安装——NetworkImage
      // 内部的共享 HttpClient 是懒初始化 static，首次图片请求时才创建。
      CoverPressureObserver.install();

      // 应用持久化的日志开关（默认关闭，需用户在设置里手动开启）。
      // 注意：不能在 runApp 前 await 平台存储（SharedPreferences）——桌面端
      // 平台插件在 C++ runner 的 OnCreate→RegisterPlugins 阶段才注册，Dart 侧
      // 在 runApp 前 await 该 channel 会因插件未就绪而永久挂起，导致首帧永不
      // 渲染、窗口透明只剩外框（Windows 尤甚，安卓注册路径不同不触发）。改为
      // 异步应用，绝不阻塞首帧。
      unawaited(
        LocalStorage.getLoggingEnabled().then(
          (enabled) => Logger.setLoggingEnabled(enabled),
        ),
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

      // 显式持有 container：purgeUpdateArtifacts 的结算结果要灌进
      // updateDownloadControllerProvider，而它是 fire-and-forget 启动任务，
      // 拿不到 widget 树的 ref。
      //
      // 用 [UncontrolledProviderScope] 而不是 `ProviderScope`：后者会自己
      // new 一个 container 且外部拿不到，改成外部持有即可。
      // container 不手动 dispose：进程结束即释放，提前 dispose 反而会让
      // 后台在途下载的状态没了归处。
      final container = ProviderContainer();
      // 窗口可见性门控挂在 App 外层：最小化/失焦/切走时停止所有不可见
      // 渲染（TickerMode 全局静音 + appVisibilityProvider 冻结数据驱动 UI）。
      // 层级关系与改动前一致：Scope → AppVisibilityScope → App。
      runApp(
        UncontrolledProviderScope(
          container: container,
          child: const AppVisibilityScope(child: App()),
        ),
      );

      // 修复损坏的 SharedPreferences(备份 + 重建干净起点):进程被强杀时
      // prefs 文件可能半写损坏,导致所有设置/播放状态读默认值(表现为
      // 「关闭后全部清空」)。必须 runApp 之后异步执行——平台通道在 runner
      // OnCreate 阶段才注册,runApp 前 await 会永久挂起。
      unawaited(LocalStorage.repairCorruptPreferences());

      // 内置更新的安装包清理（时机二：每次启动一次）。
      // 为什么必须在这里而不是「安装完立刻删」：`installApk()` 里 startActivity
      // 返回的瞬间，系统安装器只是拿到了 content:// URI，**字节流是异步读的** ——
      // 此时删文件会变成「解析包时出错」。而更新成功后本进程会被系统杀掉替换，
      // 安装后那段复查代码大概率根本跑不到。真正兜住的就是这一次启动清理：
      // 靠旁车 meta 判定「meta.version <= 当前运行版本 ⇒ 已经装成功了」。
      //
      // 顺便把待收尾下载的结算结果灌回下载控制器：上次「下完了但没来得及
      // 唤装」的包，这次启动后设置页更新行要能直接显示「已就绪，可安装」。
      //
      // fire-and-forget：清理是锦上添花，绝不阻塞首帧，任何异常都在内部吞掉。
      unawaited(
        purgeUpdateArtifacts(
          onPendingSettled: (outcome, {version, apkPath}) {
            container
                .read(updateDownloadControllerProvider.notifier)
                .restoreFromSettlement(
                  outcome: outcome,
                  version: version,
                  apkPath: apkPath,
                );
          },
        ),
      );
    },
    (error, stackTrace) {
      Logger.errorWithTag('APP', 'Uncaught zone error', error, stackTrace);
    },
  );
}
