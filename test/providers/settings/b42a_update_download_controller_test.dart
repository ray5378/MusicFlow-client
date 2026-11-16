// b42a —— 安卓内置更新「下载编排」的行为测试。
//
// 覆盖 lib/providers/settings/update_download_provider.dart：
//   1) 拖掉浮层**不**取消下载（真实 UpdateDownloadSheet 卸载路径）；
//   2) 同版本重复 start() 不重下；
//   3) 前台完成立即唤装；
//   4) 后台完成不唤装，回前台才唤装；
//   5) 启动结算：completed + 有路径 → completed + installPending；
//   6/7) 启动结算：completed 但 apkPath 为 null / 空串 → 回落 idle；
//   8) 启动结算：running / discarded → idle；
//   9) 并发 installNow() 只拉起一次安装器（共享同一个在途 Future）；
//  10) cancel() 回 idle 且保留 version。
//
// 产品代码零改动：不新增/修改任何 @visibleForTesting 钩子，fake 全部用
// `extends` 覆盖（ApkDownloadService.download 不是抽象方法）。
import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:musicflow_client/core/services/apk_download_service.dart';
import 'package:musicflow_client/core/services/apk_installer.dart';
import 'package:musicflow_client/core/services/update_checker.dart';
import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/features/settings/widgets/update_download_sheet.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:musicflow_client/providers/settings/update_download_provider.dart';

const String _version = '1.2.3';
const String _apkPath = '/tmp/musicflow-1.2.3.apk';

const ReleaseAsset _asset = ReleaseAsset(
  name: 'musicflow-1.2.3.apk',
  downloadUrl: 'https://example.test/musicflow-1.2.3.apk',
  size: 100,
);

/// 安装器 fake：只统计调用次数 / 路径，可用 [gate] 卡住不放行以测并发。
class _FakeInstaller extends ApkInstaller {
  bool installResult = true;
  int installCalls = 0;
  int canInstallCalls = 0;
  int openSettingsCalls = 0;
  final List<String> installedPaths = <String>[];

  /// 非 null 时 [installApk] 先等它，用来复现「并发调用」。
  Completer<bool>? gate;

  @override
  Future<bool> installApk(
    String filePath, {
    TargetPlatform? platform,
    bool isWeb = kIsWeb,
  }) {
    installCalls += 1;
    installedPaths.add(filePath);
    final pending = gate;
    if (pending != null) return pending.future;
    return Future<bool>.value(installResult);
  }

  @override
  Future<bool> canRequestPackageInstalls({
    TargetPlatform? platform,
    bool isWeb = kIsWeb,
  }) async {
    canInstallCalls += 1;
    return true;
  }

  @override
  Future<bool> openUnknownSourcesSettings({
    TargetPlatform? platform,
    bool isWeb = kIsWeb,
  }) async {
    openSettingsCalls += 1;
    return false;
  }
}

/// 下载服务 fake：`download()` 由测试决定何时完成，并抓取 cancelToken。
class _FakeDownloadService extends ApkDownloadService {
  int downloadCalls = 0;
  CancelToken? lastCancelToken;
  String? lastVersion;
  void Function(ApkDownloadProgress progress)? lastOnProgress;

  final Completer<File> _completer = Completer<File>();

  @override
  Future<File> download(
    ReleaseAsset asset, {
    void Function(ApkDownloadProgress progress)? onProgress,
    CancelToken? cancelToken,
    String? version,
    String? notificationTitle,
    String? notificationDescription,
    Directory? overrideDir,
  }) async {
    downloadCalls += 1;
    lastCancelToken = cancelToken;
    lastVersion = version;
    lastOnProgress = onProgress;
    return _completer.future;
  }

  /// 让「下载」成功结束，并先推一次进度回调（验证 percent 口径）。
  void complete(String path) {
    lastOnProgress?.call(const ApkDownloadProgress(received: 100, total: 100));
    if (!_completer.isCompleted) {
      _completer.complete(File(path));
    }
  }
}

void _setLifecycle(AppLifecycleState state) {
  TestWidgetsFlutterBinding.ensureInitialized();
  WidgetsBinding.instance.handleAppLifecycleStateChanged(state);
}

/// 反复让出事件循环，把 start()/installNow() 的 await 链走完。
Future<void> _drain([int turns = 12]) async {
  for (var i = 0; i < turns; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

/// widget 用例里的等待：FakeAsync 下只能用 pump。
Future<void> _pumpFrames(WidgetTester tester, [int frames = 8]) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    // 默认前台：需要测「后台」的用例自己改成 inactive。
    _setLifecycle(AppLifecycleState.resumed);
  });

  tearDown(() {
    _setLifecycle(AppLifecycleState.resumed);
  });

  testWidgets('拖掉下载浮层不取消下载，下载照常完成', (tester) async {
    // 这条用例必须走**真实浮层**的 dispose 路径：回归点就在
    // `update_download_sheet.dart` 的 `dispose()`（改造前会 cancel）。
    final installer = _FakeInstaller();
    final service = _FakeDownloadService();
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final controller = container.read(
      updateDownloadControllerProvider.notifier,
    );

    unawaited(
      controller.start(
        asset: _asset,
        version: _version,
        installer: installer,
        downloadService: service,
      ),
    );
    await _pumpFrames(tester);
    expect(service.downloadCalls, 1);
    expect(service.lastVersion, _version);
    expect(service.lastCancelToken, isNotNull);
    expect(service.lastCancelToken!.isCancelled, isFalse);

    // 挂上浮层 → 记录「视图可见」。
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('zh'),
          theme: AppTheme.light(),
          home: Scaffold(
            body: UpdateDownloadSheet(
              asset: _asset,
              latestVersion: _version,
              currentVersion: '1.0.0',
              installer: installer,
              downloadService: service,
            ),
          ),
        ),
      ),
    );
    await _pumpFrames(tester);
    expect(
      container.read(updateDownloadControllerProvider).sheetVisible,
      isTrue,
      reason: '浮层 initState 后必须把 sheetVisible 置 true',
    );

    // —— 用户把浮层拖掉（卸载整个子树）——
    await tester.pumpWidget(const SizedBox.shrink());
    await _pumpFrames(tester);
    expect(
      container.read(updateDownloadControllerProvider).sheetVisible,
      isFalse,
      reason: '浮层卸载后只应报告视图已关闭',
    );
    expect(
      service.lastCancelToken!.isCancelled,
      isFalse,
      reason: '拖掉浮层绝不能取消下载（这正是改造前的 bug）',
    );
    expect(
      container.read(updateDownloadControllerProvider).isActive,
      isTrue,
      reason: '下载必须继续，状态仍是 downloading',
    );

    // 下载在「浮层已不在」的情况下完成。
    service.complete(_apkPath);
    await _pumpFrames(tester);
    final state = container.read(updateDownloadControllerProvider);
    expect(state.isReady, isTrue, reason: '无人接手也要把包落成 completed');
    expect(state.apkPath, _apkPath);
  });

  test('同版本重复 start() 只下载一次（重开浮层不重下）', () async {
    final installer = _FakeInstaller();
    final service = _FakeDownloadService();
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final controller = container.read(
      updateDownloadControllerProvider.notifier,
    );

    unawaited(
      controller.start(
        asset: _asset,
        version: _version,
        installer: installer,
        downloadService: service,
      ),
    );
    await _drain();
    expect(service.downloadCalls, 1);

    // 第二次（用户重新点「更新」/ 重开浮层）：必须命中 isBusyFor 去重分支。
    unawaited(
      controller.start(
        asset: _asset,
        version: _version,
        installer: installer,
        downloadService: service,
      ),
    );
    await _drain();
    expect(service.downloadCalls, 1, reason: '同版本在途时不得重复下载');
    expect(container.read(updateDownloadControllerProvider).isActive, isTrue);

    service.complete(_apkPath);
    await _drain();
    expect(container.read(updateDownloadControllerProvider).isReady, isTrue);
  });

  test('前台下载完成 → 立即唤起系统安装器一次', () async {
    _setLifecycle(AppLifecycleState.resumed);
    final installer = _FakeInstaller();
    final service = _FakeDownloadService();
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final controller = container.read(
      updateDownloadControllerProvider.notifier,
    );

    unawaited(
      controller.start(
        asset: _asset,
        version: _version,
        installer: installer,
        downloadService: service,
      ),
    );
    await _drain();
    expect(installer.installCalls, 0);

    service.complete(_apkPath);
    await _drain();

    final state = container.read(updateDownloadControllerProvider);
    expect(state.stage, UpdateDownloadStage.completed);
    expect(state.apkPath, _apkPath);
    expect(state.percent, 100);
    expect(installer.installCalls, 1, reason: '前台完成必须立刻唤装');
    expect(installer.installedPaths, <String>[_apkPath]);
    expect(state.installPending, isFalse, reason: '安装器已拉起，清除 pending');
  });

  test('后台下载完成不唤装，回到前台才唤装', () async {
    _setLifecycle(AppLifecycleState.inactive);
    final installer = _FakeInstaller();
    final service = _FakeDownloadService();
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final controller = container.read(
      updateDownloadControllerProvider.notifier,
    );

    unawaited(
      controller.start(
        asset: _asset,
        version: _version,
        installer: installer,
        downloadService: service,
      ),
    );
    await _drain();
    service.complete(_apkPath);
    await _drain();

    expect(container.read(updateDownloadControllerProvider).isReady, isTrue);
    expect(
      installer.installCalls,
      0,
      reason: '后台唤装会被 Android 10+ 静默丢弃，必须等回前台',
    );
    expect(
      container.read(updateDownloadControllerProvider).installPending,
      isTrue,
      reason: '还没唤装成功，installPending 必须保留',
    );

    _setLifecycle(AppLifecycleState.resumed);
    await _drain();

    expect(installer.installCalls, 1, reason: '回前台必须补上唤装');
    expect(
      container.read(updateDownloadControllerProvider).installPending,
      isFalse,
    );
  });

  test('启动结算：completed + 有 apkPath → completed + installPending', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final controller = container.read(
      updateDownloadControllerProvider.notifier,
    );

    controller.restoreFromSettlement(
      outcome: ApkPendingOutcome.completed,
      version: '2.0.0',
      apkPath: '/tmp/musicflow-2.0.0.apk',
    );

    final state = container.read(updateDownloadControllerProvider);
    expect(state.stage, UpdateDownloadStage.completed);
    expect(state.version, '2.0.0');
    expect(state.apkPath, '/tmp/musicflow-2.0.0.apk');
    // 不变式：completed 一定带非空 apkPath（UI 层不再重复判空）。
    expect(state.apkPath, isNotNull);
    expect(state.apkPath!.isNotEmpty, isTrue);
    expect(state.installPending, isTrue);
    expect(state.progress, isNull);
    expect(state.errorMessage, isNull);
  });

  test('启动结算：completed 但 apkPath 为 null → 回落 idle（保留 version）', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final controller = container.read(
      updateDownloadControllerProvider.notifier,
    );

    controller.restoreFromSettlement(
      outcome: ApkPendingOutcome.completed,
      version: '2.0.0',
      apkPath: null,
    );

    final state = container.read(updateDownloadControllerProvider);
    expect(
      state.stage,
      UpdateDownloadStage.idle,
      reason: '扫不到包就绝不能显示「下载完成」，否则点了必然失败',
    );
    expect(state.apkPath, isNull);
    expect(state.installPending, isFalse);
    expect(state.version, '2.0.0', reason: 'version 保留，方便重新检查更新');
  });

  test('启动结算：completed 但 apkPath 为空串 → 回落 idle', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final controller = container.read(
      updateDownloadControllerProvider.notifier,
    );

    controller.restoreFromSettlement(
      outcome: ApkPendingOutcome.completed,
      version: '2.0.0',
      apkPath: '',
    );

    final state = container.read(updateDownloadControllerProvider);
    expect(state.stage, UpdateDownloadStage.idle);
    expect(state.apkPath, isNull);
    expect(state.installPending, isFalse);
    expect(state.version, '2.0.0');
  });

  test('启动结算：running / discarded → idle 且清干净', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final controller = container.read(
      updateDownloadControllerProvider.notifier,
    );

    controller.restoreFromSettlement(
      outcome: ApkPendingOutcome.running,
      version: '3.0.0',
    );
    var state = container.read(updateDownloadControllerProvider);
    expect(
      state.stage,
      UpdateDownloadStage.idle,
      reason: '本进程没有在途任务，硬标 downloading 会出现永远不动的进度条',
    );
    expect(state.isActive, isFalse);
    expect(state.apkPath, isNull);
    expect(state.progress, isNull);
    expect(state.installPending, isFalse);
    expect(state.version, '3.0.0');

    controller.restoreFromSettlement(
      outcome: ApkPendingOutcome.discarded,
      version: '3.0.1',
    );
    state = container.read(updateDownloadControllerProvider);
    expect(state.stage, UpdateDownloadStage.idle);
    expect(state.apkPath, isNull);
    expect(state.progress, isNull);
    expect(state.installPending, isFalse);
    expect(state.version, '3.0.1');
  });

  test('并发 installNow() 只拉起一次安装器，两次都拿到同一结果', () async {
    // 后台：让 start() 的去重分支只注册「等回前台」监听，不自己先装一次，
    // 这样下面两次显式并发调用才是唯一的唤装来源。
    _setLifecycle(AppLifecycleState.inactive);
    final installer = _FakeInstaller();
    final gate = Completer<bool>();
    installer.gate = gate;
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final controller = container.read(
      updateDownloadControllerProvider.notifier,
    );

    // 先把注入的 installer 交给控制器（走 completed 去重分支，不产生下载），
    // 再用启动结算灌入 apkPath —— 模拟「App 被杀后回来点已下载完成」。
    controller.restoreFromSettlement(
      outcome: ApkPendingOutcome.completed,
      version: _version,
      apkPath: _apkPath,
    );
    unawaited(
      controller.start(
        asset: _asset,
        version: _version,
        installer: installer,
        downloadService: _FakeDownloadService(),
      ),
    );
    await _drain(4);
    expect(
      container.read(updateDownloadControllerProvider).apkPath,
      _apkPath,
      reason: '去重分支不得清掉已就绪的包路径',
    );
    expect(
      installer.installCalls,
      0,
      reason: '后台时自动唤装应等到回前台，不得抢先装',
    );

    final first = controller.installNow();
    final second = controller.installNow();
    expect(
      identical(first, second),
      isTrue,
      reason: '并发调用必须共享同一个在途 Future',
    );
    await _drain(4);
    expect(installer.installCalls, 1, reason: '系统安装器只能被拉起一次');

    gate.complete(true);
    expect(await first, isTrue);
    expect(await second, isTrue);
    await _drain(4);
    expect(
      container.read(updateDownloadControllerProvider).installPending,
      isFalse,
    );
  });

  test('cancel() 回到 idle 并保留 version，之后完成也不再复活', () async {
    final installer = _FakeInstaller();
    final service = _FakeDownloadService();
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final controller = container.read(
      updateDownloadControllerProvider.notifier,
    );

    unawaited(
      controller.start(
        asset: _asset,
        version: _version,
        installer: installer,
        downloadService: service,
      ),
    );
    await _drain();
    expect(container.read(updateDownloadControllerProvider).isActive, isTrue);
    final token = service.lastCancelToken!;

    controller.cancel();

    var state = container.read(updateDownloadControllerProvider);
    expect(token.isCancelled, isTrue, reason: 'cancel() 必须真打断下载');
    expect(state.stage, UpdateDownloadStage.idle);
    expect(state.version, _version, reason: 'version 保留，方便重试');
    expect(state.apkPath, isNull);
    expect(state.progress, isNull);
    expect(state.installPending, isFalse);

    // 取消后下载层仍可能回一次结果：不得把状态拉回 completed。
    service.complete(_apkPath);
    await _drain();
    state = container.read(updateDownloadControllerProvider);
    expect(state.stage, UpdateDownloadStage.idle);
    expect(state.apkPath, isNull);
    expect(installer.installCalls, 0);
  });
}
