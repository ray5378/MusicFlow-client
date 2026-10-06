// b39b —— Route B：core 纯逻辑剩余缺口补测。
//
// 覆盖 lcov 未命中行：
//   * address_pool.dart:58            waitForActiveAddress 无活跃地址 → 新建就绪信号
//   * network_error_notifier.dart:55  启动宽限期内的延迟确认定时器到点弹提示
//   * playlist.dart:116               _parseDate 对「带空格但非 ISO」串的二次解析尝试
//
// 产品代码零改动；仅新增 test/。

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:musicflow_client/core/network/address_pool.dart';
import 'package:musicflow_client/core/utils/network_error_notifier.dart';
import 'package:musicflow_client/data/models/playlist.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('AddressPool.waitForActiveAddress：无活跃地址时新建信号并超时兜底（line 58）',
      () async {
    final pool = AddressPool(Dio());
    final result =
        await pool.waitForActiveAddress(const Duration(milliseconds: 5));
    expect(result, isNull, reason: '无活跃地址时应超时返回 null 而非抛出');
    expect(pool.activeAddress, isNull);
  });

  testWidgets('NetworkErrorNotifier 启动宽限期内延迟确认，定时器到点弹提示（line 55）',
      (tester) async {
    // 首个调用 markAppStarted 的用例：_startedAt 由 null 置为 now，进入宽限期。
    NetworkErrorNotifier.markAppStarted();
    NetworkErrorNotifier.show('网络异常');

    // 推进到宽限期结束，触发 _schedulePending 里的定时器回调（line 55）。
    await tester.pump(const Duration(seconds: 31));

    NetworkErrorNotifier.cancelPending();
    expect(tester.takeException(), isNull);
  });

  test('Playlist.fromJson 对「带空格非 ISO」时间串走二次解析（line 116）', () {
    final playlist = Playlist.fromJson(<String, dynamic>{
      'id': 'p-1',
      'name': '测试歌单',
      'songCount': 0,
      'duration': 0,
      'created': '01/02/2024 03:04:05',
    });

    expect(playlist.id, 'p-1');
    // 该串既非 ISO 也无法在补 T 后解析 → 容错返回 null（不抛 FormatException）。
    expect(playlist.created, isNull);
  });
}
