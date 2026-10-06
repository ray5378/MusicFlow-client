// b39c —— Route C 补测：`lib/features/discover/widgets/section_shift.dart` 剩余缺口。
//
// 覆盖点：
//   * 64：`performLayout` 在「父给的高度无界」（hasInfiniteHeight）时直接沿用
//     原约束 `constraints`（例如被放进 SingleChildScrollView → Column 的链路）。
//
// 报告为**不可达**（见文末）：58 `size = constraints.smallest;` —— `SectionShift`
// 构造器 `required Widget child`，RenderObject 的 `child` 永不为 null，此分支不可达。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/features/discover/widgets/section_shift.dart';

void main() {
  testWidgets('无界高度下 performLayout 沿用原约束（64）', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(600, 800);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: SingleChildScrollView(
            child: Column(
              children: <Widget>[
                SectionShift(
                  top: -12,
                  bottom: -12,
                  child: const SizedBox(
                    width: 200,
                    height: 60,
                    child: Text('shifted'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('shifted'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
