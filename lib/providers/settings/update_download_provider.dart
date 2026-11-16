import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:musicflow_client/core/services/apk_download_service.dart';
import 'package:musicflow_client/core/services/apk_installer.dart';
import 'package:musicflow_client/core/services/app_update_installer.dart';
import 'package:musicflow_client/core/services/update_checker.dart';
import 'package:musicflow_client/core/utils/logger.dart';

/// 日志 tag（与 `APP_UPDATE` / `APK_SHEET` 区分开，方便单独 grep 下载编排）。
const String _logTag = 'UPDATE_DL';

/// 「下完了但还没在后台唤装成功」时等待 App 回到前台的超时。
///
/// 超时后**不再**尝试唤装，但保留 `installPending`：用户回到设置页仍能点
/// 「立即安装」，浮层里也仍能点「再次安装」。
const Duration kUpdateAutoInstallResumeTimeout = Duration(seconds: 60);

/// 内置更新下载的生命周期阶段。
///
/// - [idle]        ：没有下载任务（含「用户主动取消」后的状态）；
/// - [downloading] ：正在下（进度见 [UpdateDownloadState.progress]）；
/// - [completed]   ：包已落盘并校验通过，只剩「唤起系统安装器」这一步；
/// - [failed]      ：下载失败（可重试，包已被下载层删干净）。
enum UpdateDownloadStage { idle, downloading, completed, failed }

/// 内置更新下载的状态快照。
///
/// 这是**唯一**的下载状态真源：浮层、设置页行、启动结算回灌都读写它，
/// 谁也不许再各自持有一份进度字段。
@immutable
class UpdateDownloadState {
  const UpdateDownloadState({
    this.stage = UpdateDownloadStage.idle,
    this.progress,
    this.version,
    this.apkPath,
    this.errorMessage,
    this.installPending = false,
    this.sheetVisible = false,
    this.notificationGranted = true,
  });

  /// 当前阶段。
  final UpdateDownloadStage stage;

  /// 最近一次进度快照（[UpdateDownloadStage.idle] / 失败后为 null）。
  final ApkDownloadProgress? progress;

  /// 本次下载对应的**目标**版本号（用于跨次点击的去重比较）。
  final String? version;

  /// 下载完成后的绝对路径（[UpdateDownloadStage.completed] 才有值）。
  final String? apkPath;

  /// 失败原因（已精简，原始日志在 log 里）。
  final String? errorMessage;

  /// 包已下好，但还没成功唤起系统安装器（后台被系统静默丢弃 / 缺授权）。
  final bool installPending;

  /// 下载浮层当前是否在屏上。
  ///
  /// **只用于表达"视图是否可见"**：拖掉浮层（置 false）绝不会取消下载，
  /// 下载是后台任务，与视图生死无关。
  final bool sheetVisible;

  /// 通知权限是否已授予（未授予仍会下载，只是通知栏看不到进度）。
  final bool notificationGranted;

  /// 是否正在下载。
  bool get isActive => stage == UpdateDownloadStage.downloading;

  /// 是否已下好（可以唤装）。
  bool get isReady => stage == UpdateDownloadStage.completed;

  /// 0~100 的整数完成度。
  int get percent => ((progress?.fraction ?? 0) * 100).round();

  /// 逐字段复制；可空字段用 `clearXxx` 开关显式清空（`null` 表示"不改"）。
  UpdateDownloadState copyWith({
    UpdateDownloadStage? stage,
    ApkDownloadProgress? progress,
    bool clearProgress = false,
    String? version,
    String? apkPath,
    bool clearApkPath = false,
    String? errorMessage,
    bool clearError = false,
    bool? installPending,
    bool? sheetVisible,
    bool? notificationGranted,
  }) {
    return UpdateDownloadState(
      stage: stage ?? this.stage,
      progress: clearProgress ? null : (progress ?? this.progress),
      version: version ?? this.version,
      apkPath: clearApkPath ? null : (apkPath ?? this.apkPath),
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
      installPending: installPending ?? this.installPending,
      sheetVisible: sheetVisible ?? this.sheetVisible,
      notificationGranted: notificationGranted ?? this.notificationGranted,
    );
  }

  @override
  String toString() =>
      'UpdateDownloadState(${stage.name}, v=$version, '
      'percent=$percent, pending=$installPending, sheet=$sheetVisible)';
}

/// 内置更新下载的编排层（**下载的唯一入口**）。
///
/// ## 为什么要有这一层
///
/// 改造前的下载生命周期是**绑在浮层上**的：`_UpdateDownloadSheetState`
/// 自己 `new CancelToken()`、自己 `await download(...)`、`dispose()` 里
/// `cancel()`。于是"用户把浮层拖掉" == "取消下载 + 删包"，几十 MB 白下，
/// 且下载完成那一刻若浮层已不在，结果无人接手 —— 自动唤装自然也不会发生。
///
/// 本类把下载搬出视图层：
///
/// - 下载任务归属 **Provider**，生命周期与 App 进程一致；
/// - 浮层只是 `ref.watch` 的**纯展示**，开/关只影响 [UpdateDownloadState.sheetVisible]；
/// - 下载完成后由 [start] 内部触发 `_autoInstallWhenForeground()`，
///   回到前台立刻唤起系统安装器。
///
/// ## 自动唤装的判定顺序（易踩坑，务必按此顺序）
///
/// 1. **先**看 `WidgetsBinding.instance.lifecycleState` 是否 `resumed`；
/// 2. 在后台 → 注册 `AppLifecycleListener(onResume:)` + 60s 超时兜底；
/// 3. 真正调用 `installApk`。
///
/// ⚠️ **绝不能靠 `installApk` 的返回值判断"App 是否在后台"**：Android 10+
/// 后台启动 Activity 会被系统**静默丢弃**，但 `startActivity` 不抛异常，
/// 原生侧照样回 `true`。"在不在前台"必须在**调用前**用生命周期判断。
class UpdateDownloadController extends Notifier<UpdateDownloadState> {
  /// 本 Provider 是否还活着（Riverpod 2.6 的 [Notifier] 不透出 `mounted`，
  /// 这里用 `ref.onDispose` 自己维护）。
  bool _mounted = false;

  /// 本次（或最近一次）下载用的安装器 —— [installNow] 复用。
  ApkInstaller? _installer;

  /// 本次（或最近一次）下载用的下载服务 —— [retry] 复用。
  ApkDownloadService? _downloadService;

  /// 当前在途下载的取消令牌（null = 没有在途下载）。
  CancelToken? _cancelToken;

  /// [retry] 用的「上次参数」。
  ReleaseAsset? _lastAsset;
  String? _lastVersion;
  String? _lastNotificationTitle;
  String? _lastNotificationDescription;
  bool _lastNotificationGranted = true;

  /// 等待回前台的监听器 / 超时定时器（**必须**在回调后或超时后释放）。
  AppLifecycleListener? _resumeListener;
  Timer? _resumeTimer;

  /// 正在进行的那次唤装。**不是 bool**：并发的第二次调用直接等这一次的
  /// 结果，既保证系统安装器只被拉起一次，又不会把「已经在装了」误报成
  /// 「装不了」（调用方把 false 统一映射成「无法打开系统安装器」）。
  Future<bool>? _installing;

  @override
  UpdateDownloadState build() {
    _mounted = true;
    ref.onDispose(() {
      _mounted = false;
      // 只是清掉监听资源：**不取消下载、不删包** —— Provider 销毁发生在
      // 整个 ProviderScope 拆除（App 退出）时，此时取消没有意义，而误取消
      // 正是本类要根治的 bug。
      _disposeResumeWatcher();
    });
    return const UpdateDownloadState();
  }

  /// [version] 是否正在下载（供上层去重，避免重复下几十 MB）。
  bool isBusyFor(String version) =>
      state.isActive && state.version == version;

  /// [version] 是否已经下好（供上层去重，直接唤装即可）。
  bool isReadyFor(String version) =>
      state.isReady &&
      state.version == version &&
      (state.apkPath?.isNotEmpty ?? false);

  /// 启动下载（或复用在途 / 已完成的下载）。
  ///
  /// **本方法自身绝不抛异常**：所有失败都收进 [UpdateDownloadState]。
  Future<void> start({
    required ReleaseAsset asset,
    required String version,
    required ApkInstaller installer,
    required ApkDownloadService downloadService,
    bool notificationGranted = true,
    String? notificationTitle,
    String? notificationDescription,
  }) async {
    // 1) 先记住"上次参数"：去重返回时也要保证 installNow/retry 用的是最新依赖。
    _installer = installer;
    _downloadService = downloadService;
    _lastAsset = asset;
    _lastVersion = version;
    _lastNotificationTitle = notificationTitle;
    _lastNotificationDescription = notificationDescription;
    _lastNotificationGranted = notificationGranted;

    // 2) 去重：同一版本已在下载 → 什么都不做（浮层直接显示进度）。
    if (isBusyFor(version)) {
      Logger.infoWithTag(_logTag, 'reuse in-flight download for $version');
      _notifySheetState(notificationGranted: notificationGranted);
      return;
    }

    // 3) 去重：同一版本已下好 → 不重下，直接走自动唤装。
    if (isReadyFor(version)) {
      Logger.infoWithTag(_logTag, 'reuse downloaded apk for $version');
      _notifySheetState(notificationGranted: notificationGranted);
      unawaited(_autoInstallWhenForeground());
      return;
    }

    // 4) 真正开下。
    final token = CancelToken();
    _cancelToken = token;
    if (!_mounted) {
      return;
    }
    state = UpdateDownloadState(
      stage: UpdateDownloadStage.downloading,
      version: version,
      sheetVisible: state.sheetVisible,
      notificationGranted: notificationGranted,
    );

    try {
      final file = await downloadService.download(
        asset,
        cancelToken: token,
        version: version,
        notificationTitle: notificationTitle,
        notificationDescription: notificationDescription,
        onProgress: (progress) {
          if (!_mounted) return;
          // 取消之后可能还会有最后一两个回调，别把界面又拉回"下载中"。
          if (!state.isActive) return;
          state = state.copyWith(progress: progress);
        },
      );
      if (!_mounted) return;
      if (token.isCancelled) {
        _applyCancelledState(version);
        return;
      }
      state = state.copyWith(
        stage: UpdateDownloadStage.completed,
        version: version,
        apkPath: file.path,
        installPending: true,
        progress: _fullProgress(asset),
        clearError: true,
      );
      Logger.infoWithTag(_logTag, 'apk ready: ${file.path}');
      // 下载完成 → 立刻尝试唤装（在后台就等回前台）。
      unawaited(_autoInstallWhenForeground());
    } on ApkDownloadException catch (e) {
      if (!_mounted) return;
      if (token.isCancelled) {
        // 用户主动取消：回到 idle，**保留 version** 方便"重试"。
        _applyCancelledState(version);
        return;
      }
      Logger.warnWithTag(_logTag, 'apk download failed: ${e.message}');
      state = state.copyWith(
        stage: UpdateDownloadStage.failed,
        version: version,
        errorMessage: e.message,
        clearProgress: true,
        clearApkPath: true,
        installPending: false,
      );
    } catch (e) {
      if (!_mounted) return;
      if (token.isCancelled) {
        _applyCancelledState(version);
        return;
      }
      Logger.errorWithTag(_logTag, 'apk download threw', e);
      state = state.copyWith(
        stage: UpdateDownloadStage.failed,
        version: version,
        errorMessage: '$e',
        clearProgress: true,
        clearApkPath: true,
        installPending: false,
      );
    } finally {
      if (identical(_cancelToken, token)) {
        _cancelToken = null;
      }
    }
  }

  /// 用上次的参数重下一遍（浮层"重试"按钮用）。
  ///
  /// 之所以放在控制器里：浮层只需 `ref.read(...notifier).retry()`，
  /// 不必自己持有 `asset` / `installer` / `downloadService` 三件套。
  Future<void> retry() async {
    final asset = _lastAsset;
    final version = _lastVersion;
    final installer = _installer;
    final downloadService = _downloadService;
    if (asset == null ||
        version == null ||
        installer == null ||
        downloadService == null) {
      Logger.warnWithTag(_logTag, 'retry ignored: no previous parameters');
      return;
    }
    await start(
      asset: asset,
      version: version,
      installer: installer,
      downloadService: downloadService,
      notificationGranted: _lastNotificationGranted,
      notificationTitle: _lastNotificationTitle,
      notificationDescription: _lastNotificationDescription,
    );
  }

  /// 真取消：打断下载 → 下载层自己删半截包 + 清持久化的 pending id。
  ///
  /// ⚠️ **只有用户点「取消下载」才调它**。拖掉浮层走 [setSheetVisible]，
  /// 语义完全不同。
  void cancel() {
    final token = _cancelToken;
    if (token == null) {
      // 没有在途下载（例如"已下好"阶段）：不做任何事，包必须留着。
      Logger.debugWithTag(_logTag, 'cancel ignored: no in-flight download');
      return;
    }
    if (!token.isCancelled) {
      token.cancel();
    }
    _cancelToken = null;
    Logger.infoWithTag(_logTag, 'apk download cancelled by user');
    // 半截文件 / pending id 由 ApkDownloadService 在同一次 `download()`
    // 的取消分支里清掉（`_cancelAndCleanup` / dio 的 deleteApkWithMeta），
    // 这里不重复动文件，避免和下载层的清理互相打断。
    _applyCancelledState(state.version);
  }

  /// 浮层 `initState` 传 `true`、`dispose` 传 `false`。
  ///
  /// 只记录"视图是否可见"，**绝不**影响下载。
  void setSheetVisible(bool visible) {
    if (!_mounted) return;
    if (state.sheetVisible == visible) return;
    state = state.copyWith(sheetVisible: visible);
    // 浮层刚被打开、且包已下好但还没唤装成功（例如"同一版本再点一次更新"
    // 走的是去重分支，不会重新 start）→ 借这次可见性变化补一次唤装。
    if (visible && state.installPending && state.isReady) {
      unawaited(_autoInstallWhenForeground());
    }
  }

  /// 唤起系统安装器（设置页「立即安装」/ 浮层「再次安装」都走它）。
  ///
  /// 返回 `true` 只代表**安装器界面被拉起**（包是否真装上由系统安装器决定）。
  ///
  /// 并发调用（用户连点两下 / `start()` 与浮层 `initState` 几乎同时触发）
  /// **共享同一个在途 Future**：第二次调用直接拿到第一次的真实结果，
  /// 既不会重复拉安装器，也不会返回假的 `false` 让 UI 误报「安装器打开失败」。
  /// 方法签名（`Future<bool>`）保持不变。
  ///
  /// 刻意**不是 `async`**：同步返回 Future，并发的第二次调用才能立刻拿到
  /// 同一个对象，不必额外 await 一层。
  Future<bool> installNow() {
    final inFlight = _installing;
    if (inFlight != null) {
      Logger.debugWithTag(_logTag, 'installNow joined in-flight attempt');
      return inFlight;
    }
    final attempt = _installOnce();
    _installing = attempt;
    // 无论成功/失败/抛异常都要清掉，否则后续唤装全被挡；
    // identical 判断防止「新一轮已经覆盖了字段，旧 future 完成时误清」。
    unawaited(
      attempt.whenComplete(() {
        if (identical(_installing, attempt)) {
          _installing = null;
        }
      }),
    );
    return attempt;
  }

  Future<bool> _installOnce() async {
    // `ApkInstaller` 是无状态的 MethodChannel 封装：启动结算经
    // [restoreFromSettlement] 灌进来的 completed 态，本进程**从没调过
    // start()**，`_installer` 必为 null。这里懒创建默认实例，否则
    // 「App 被杀后回来点已下载完成」永远装不了。测试注入的实例仍然优先。
    final installer = _installer ?? ApkInstaller();
    final path = state.apkPath;
    if (path == null || path.isEmpty) {
      Logger.debugWithTag(_logTag, 'installNow skipped: no apk ready');
      return false;
    }
    try {
      final opened = await installer.installApk(path);
      if (opened) {
        Logger.infoWithTag(_logTag, 'installer launched');
        if (_mounted) {
          state = state.copyWith(installPending: false);
        }
        return true;
      }
      Logger.warnWithTag(_logTag, 'installApk rejected, try permission recovery');
      final recovered = await _installAfterPermissionRecovery(installer, path);
      if (_mounted) {
        // 没拉起就**保留** installPending：用户可以再来一次。
        state = state.copyWith(installPending: !recovered);
      }
      return recovered;
    } catch (e) {
      Logger.errorWithTag(_logTag, 'installNow threw', e);
      if (_mounted) {
        state = state.copyWith(installPending: true);
      }
      return false;
    }
  }

  /// 启动结算结果灌入（由启动阶段的 `settlePendingDownload` 接线）。
  ///
  /// - [ApkPendingOutcome.running]   ：系统还在下 → 保持 idle（本进程没有在途
  ///   任务，硬标成 downloading 只会给用户一个永远动不了的进度条）；
  /// - [ApkPendingOutcome.completed] ：包已校验好 → 直接进 completed，
  ///   并把 `installPending` 置 true，等用户/前台触发唤装；
  ///   **但 `apkPath` 为空时回落 idle**（见该分支内的注释）。
  /// - [ApkPendingOutcome.discarded] / [ApkPendingOutcome.none]：清干净。
  void restoreFromSettlement({
    required ApkPendingOutcome outcome,
    String? version,
    String? apkPath,
  }) {
    if (!_mounted) return;
    // 本进程有在途下载时，它才是权威状态，别被启动结算覆盖。
    if (state.isActive) {
      Logger.debugWithTag(_logTag, 'settlement ignored: download in progress');
      return;
    }
    switch (outcome) {
      case ApkPendingOutcome.none:
        return;
      case ApkPendingOutcome.running:
        state = state.copyWith(
          stage: UpdateDownloadStage.idle,
          version: version,
          clearProgress: true,
          clearError: true,
          clearApkPath: true,
          installPending: false,
        );
      case ApkPendingOutcome.completed:
        // 结算说「下完了」，但 apkPath 可能为空：接线侧的
        // `_findLatestSettledApk` 扫不到文件时只能回 null（它读不到
        // `status.localPath` 时没有别的选择，也不能抛）。此时绝不能置
        // completed —— UI 会显示「已下载完成 / vX.Y.Z」，用户一点
        // `installNow()` 必然 false，只留一句「安装器打开失败」，
        // 比什么都不显示更糟。回落 idle，让用户重新检查更新。
        final hasApk = apkPath != null && apkPath.isNotEmpty;
        if (!hasApk) {
          Logger.warnWithTag(
            _logTag,
            'settlement completed but apk path missing, fall back to idle',
          );
          state = state.copyWith(
            stage: UpdateDownloadStage.idle,
            version: version,
            clearProgress: true,
            clearError: true,
            clearApkPath: true,
            installPending: false,
          );
          return;
        }
        state = state.copyWith(
          stage: UpdateDownloadStage.completed,
          version: version,
          apkPath: apkPath,
          clearProgress: true,
          clearError: true,
          // hasApk 已保证路径非空，包就在那儿等唤装。
          installPending: true,
        );
        Logger.infoWithTag(
          _logTag,
          'restored completed apk from settlement: $apkPath',
        );
      case ApkPendingOutcome.discarded:
        state = state.copyWith(
          stage: UpdateDownloadStage.idle,
          version: version,
          clearProgress: true,
          clearError: true,
          clearApkPath: true,
          installPending: false,
        );
        Logger.infoWithTag(_logTag, 'settlement discarded, state reset');
    }
  }

  // ────────────────────────────── 内部实现 ──────────────────────────────

  /// 下载完成 → 尽可能立刻唤起系统安装器。
  ///
  /// 严格三分支：
  /// 1. 当前就在前台 → 立即唤装；
  /// 2. 在后台 → 注册一次性 `onResume`，回到前台立刻唤装；
  /// 3. 兜底 → 60s 还没回来就放弃（释放监听，保留 `installPending`）。
  Future<void> _autoInstallWhenForeground() async {
    try {
      _disposeResumeWatcher();
      // 分支 1：判断"在不在前台"只能在**调用前**做。
      if (WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) {
        await installNow();
        return;
      }
      // 分支 2：在后台（或被系统丢进后台）→ 等下一次回前台。
      _resumeListener = AppLifecycleListener(
        onResume: () {
          _disposeResumeWatcher();
          unawaited(installNow());
        },
      );
      // 分支 3：超时兜底，避免监听器永久挂着。
      _resumeTimer = Timer(kUpdateAutoInstallResumeTimeout, () {
        Logger.infoWithTag(
          _logTag,
          'no resume in ${kUpdateAutoInstallResumeTimeout.inSeconds}s, '
          'keep installPending for manual retry',
        );
        _disposeResumeWatcher();
      });
    } catch (e) {
      // 拿不到 binding（纯 Dart 单测）等极端情况：按前台尽力试一次，
      // 保证 start() 永远不向上抛。
      Logger.errorWithTag(_logTag, 'auto install scheduling failed', e);
      await installNow();
    }
  }

  /// `installApk` 被拒（大概率是「安装未知应用」授权被撤）时：
  /// 跳系统设置页 → 等回前台 → 复查授权 → **自动重试一次**。
  Future<bool> _installAfterPermissionRecovery(
    ApkInstaller installer,
    String path,
  ) async {
    final granted = await installer.canRequestPackageInstalls();
    if (granted) {
      // 授权还在，纯粹是拉起失败 —— 留给用户手动点「再次安装」。
      return false;
    }
    final openedSettings = await installer.openUnknownSourcesSettings();
    if (!openedSettings) return false;
    // 从设置页回来是**异步**的：先等 resumed，再复查授权。
    await AppUpdateInstaller.waitForAppResume();
    final nowGranted = await installer.canRequestPackageInstalls();
    if (!nowGranted) {
      Logger.infoWithTag(_logTag, 'install permission still missing');
      return false;
    }
    final opened = await installer.installApk(path);
    Logger.infoWithTag(_logTag, 'install retried after permission: $opened');
    return opened;
  }

  void _applyCancelledState(String? version) {
    if (!_mounted) return;
    state = UpdateDownloadState(
      stage: UpdateDownloadStage.idle,
      version: version,
      sheetVisible: state.sheetVisible,
      notificationGranted: state.notificationGranted,
    );
  }

  /// 状态里一直挂着的 `notificationGranted` 有可能是上次的，这里顺手按本次
  /// 实参纠正一次（去重分支不做下载，只同步这一个字段）。
  void _notifySheetState({required bool notificationGranted}) {
    if (!_mounted) return;
    if (state.notificationGranted == notificationGranted) return;
    state = state.copyWith(notificationGranted: notificationGranted);
  }

  /// 完成态固定给一个 100% 的进度快照（`percent` 与进度条才对得上）。
  ApkDownloadProgress _fullProgress(ReleaseAsset asset) {
    final last = state.progress;
    final total = asset.size > 0 ? asset.size : (last?.total ?? 0);
    if (total > 0) {
      return ApkDownloadProgress(received: total, total: total);
    }
    // 总量未知（asset.size == 0 且没有进度回调）：用 1/1 表达"已完成"。
    return const ApkDownloadProgress(received: 1, total: 1);
  }

  void _disposeResumeWatcher() {
    _resumeListener?.dispose();
    _resumeListener = null;
    _resumeTimer?.cancel();
    _resumeTimer = null;
  }
}

/// 内置更新下载状态（全局单例）。
final updateDownloadControllerProvider =
    NotifierProvider<UpdateDownloadController, UpdateDownloadState>(
      UpdateDownloadController.new,
    );
