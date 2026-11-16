// b43a —— 启动更新检查的「通道注入」行为测试。
//
// 覆盖 lib/features/settings/services/startup_update_checker.dart：
//   - 未注入 checker（生产路径）→ 按 channelReader 提供的通道检查；
//     channelReader 被调用一次且拿到的是 scope 的 context；
//   - 注入 checker（全部存量测试路径）→ channelReader **不**被调用，
//     存量注入行为一个字节不变；
//   - StartupUpdateCheckScope 把 channelReader 透传给 runStartupUpdateCheck。
//
// 测试环境 PackageInfo 平台通道缺失 → UpdateChecker.check 抛
// MissingPluginException → runStartupUpdateCheck 静默吞掉返回 false
// （更新检查是锦上添花），正好验证「失败不影响启动」契约，全程无网络。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:musicflow_client/core/services/update_checker.dart';
import 'package:musicflow_client/features/settings/services/startup_update_checker.dart';

BuildContext? capturedContext;

/// 捞一份挂在 ProviderScope / MaterialApp 之下的 context。
class _ContextProbe extends StatelessWidget {
  const _ContextProbe({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    capturedContext = context;
    return child;
  }
}

Future<void> _pumpProbe(WidgetTester tester) async {
  await tester.pumpWidget(
    MaterialApp(
      home: _ContextProbe(child: const SizedBox.shrink()),
    ),
  );
  await tester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    capturedContext = null;
  });

  testWidgets('未注入 checker → channelReader 被调用一次并拿到 context',
      (tester) async {
    await _pumpProbe(tester);

    final contexts = <BuildContext>[];
    final channels = <UpdateChannel>[];
    // runAsync：生产路径最终会走到 UpdateChecker.check（静态、不可注入），
    // 其内部 PackageInfo/网络是真实异步 —— FakeAsync 下会永久挂起，必须放行。
    final result = await tester.runAsync(() async {
      return runStartupUpdateCheck(
        capturedContext!,
        // 生产路径：checker 为空 → 走 channelReader + UpdateChecker.check。
        // 测试环境 PackageInfo 缺平台通道 → check 抛错 → 静默返回 false。
        platform: TargetPlatform.windows,
        delay: Duration.zero,
        channelReader: (context) async {
          contexts.add(context);
          final channel = UpdateChannel.github;
          channels.add(channel);
          return channel;
        },
      );
    });

    expect(contexts.length, 1);
    expect(contexts.single, same(capturedContext));
    expect(channels.single, UpdateChannel.github);
    // 检查失败被静默兜底：不抛错、不弹窗、返回 false。
    expect(result, isFalse);
  });

  testWidgets('注入 checker → channelReader 不被调用（存量行为不变）',
      (tester) async {
    await _pumpProbe(tester);

    var channelReaderCalled = false;
    var checkerCalled = false;
    final result = await runStartupUpdateCheck(
      capturedContext!,
      checker: () async {
        checkerCalled = true;
        return const UpdateCheckResult(
          hasUpdate: false,
          currentVersion: '1.0.0',
          latestVersion: '1.0.0',
        );
      },
      platform: TargetPlatform.windows,
      delay: Duration.zero,
      channelReader: (context) async {
        channelReaderCalled = true;
        return UpdateChannel.gitee;
      },
    );

    expect(checkerCalled, isTrue);
    // checker 已注入 → channelReader 整条路径短路，一次都不该被碰。
    expect(channelReaderCalled, isFalse);
    expect(result, isFalse);
  });

  testWidgets('StartupUpdateCheckScope 把 channelReader 透传给检查',
      (tester) async {
    await _pumpProbe(tester);

    final contexts = <BuildContext>[];
    await tester.pumpWidget(
      MaterialApp(
        home: StartupUpdateCheckScope(
          delay: Duration.zero,
          channelReader: (context) async {
            contexts.add(context);
            return UpdateChannel.github;
          },
          child: _ContextProbe(child: const SizedBox.shrink()),
        ),
      ),
    );
    // delay == Duration.zero：didChangeDependencies 排的 Timer 在下一帧触发；
    // 之后检查失败静默兜底，只断言 channelReader 被调用。
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 10));

    // 注意：channelReader 拿到的是 scope 自己的 context（probe 是它的
    // 子节点，不是同一个 context），这里只断言「被调用一次且已挂载」。
    expect(contexts.length, 1);
    expect(contexts.single.mounted, isTrue);
  });

  testWidgets('平台不支持（如 macOS）→ 直接返回 false，channelReader 不被碰',
      (tester) async {
    await _pumpProbe(tester);

    var channelReaderCalled = false;
    final result = await runStartupUpdateCheck(
      capturedContext!,
      platform: TargetPlatform.macOS,
      delay: Duration.zero,
      channelReader: (context) async {
        channelReaderCalled = true;
        return UpdateChannel.gitee;
      },
    );

    expect(result, isFalse);
    expect(channelReaderCalled, isFalse);
  });
}
