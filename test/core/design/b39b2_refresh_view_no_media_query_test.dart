// b39b2 —— Route B：music_flow_refresh_view 剩余缺口补测。
//
// 覆盖 lcov 未命中行：
//   * music_flow_refresh_view.dart:264-267  _RefreshFeedbackIcon 在无 MediaQuery
//     祖先时回退 platformDispatcher.disableAnimations（?? 右侧首次被执行）
//
// 其余未命中行经源码核查不可达，逐行结论见文件末尾注释。
//
// 产品代码零改动；仅新增 test/。

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:musicflow_client/core/design/components/music_flow_refresh_view.dart';
import 'package:musicflow_client/core/theme/app_icons.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';

void main() {
  testWidgets('无 MediaQuery 祖先时刷新图标回退读 platformDispatcher（line 264-267）',
      (tester) async {
    // 锁定非安卓平台：安卓触屏端不渲染文字气泡（isAndroidTouch 恒为真时
    // _RefreshFeedbackIcon 所在子树不会被构建）。
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    try {
      // 刻意不用 MaterialApp：Widget 树根上只有 Directionality + Localizations，
      // 不注入 MediaQuery —— _RefreshFeedbackIcon.build 里 MediaQuery.maybeOf
      // 返回 null，?? 右侧的 platformDispatcher 兜底被执行。
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Localizations(
            locale: const Locale('zh'),
            delegates: AppLocalizations.localizationsDelegates,
            child: MusicFlowRefreshView(
              onRefresh: () async {},
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                children: const <Widget>[SizedBox(height: 900)],
              ),
            ),
          ),
        ),
      );

      expect(tester.takeException(), isNull,
          reason: '无 MediaQuery 时 RefreshView 应正常构建');

      // 下拉触发 drag → pulling 阶段 → 文字气泡里的 _RefreshFeedbackIcon 被构建
      // （visible 只影响位移/透明度，子树恒被构建）→ 执行 262-267 的解析。
      await tester.fling(find.byType(ListView), const Offset(0, 300), 1000);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      // pulling 档位是 chevronDown；armed 是 refresh；refreshing 是
      // CircularProgressIndicator（无 MediaQuery 时 platformDispatcher 默认
      // 未开启 disableAnimations → 渲染进度圈）——任一出现都证明
      // _RefreshFeedbackIcon.build 在无 MediaQuery 下成功解析（264-267 执行）。
      final hasIcon =
          find.byIcon(AppIcons.chevronDown).evaluate().isNotEmpty ||
              find.byIcon(AppIcons.refresh).evaluate().isNotEmpty ||
              find.byType(CircularProgressIndicator).evaluate().isNotEmpty;
      expect(hasIcon, isTrue,
          reason: '下拉阶段应渲染反馈图标（其 build 内执行 platformDispatcher 回退）');
      expect(tester.takeException(), isNull);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}

/*
 * 其余未命中行的可达性结论（源码核查，flutter test 环境下均不可达，不虚设用例）：
 *
 * - 48 / 51-52（_handleStatusChange 的 `case null:` 分支）：Flutter SDK
 *   refresh_indicator.dart 中全部 4 处 `widget.onStatusChange?.call(_status)`
 *   （428/527/540/568 行）都在调用前刚把 _status 赋成非空枚举值 —— 当前
 *   Flutter 恒传非空 status，null 分支只是针对未来 SDK 行为变化的防御。
 */
