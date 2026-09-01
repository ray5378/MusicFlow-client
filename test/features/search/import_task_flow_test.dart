import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:musicflow_client/core/utils/toast_notifier.dart';
import 'package:musicflow_client/data/models/playlist.dart';
import 'package:musicflow_client/data/models/search.dart';
import 'package:musicflow_client/data/repositories/search_repository.dart';
import 'package:musicflow_client/data/sources/subsonic_api_client.dart';
import 'package:musicflow_client/features/search/search_actions.dart';
import 'package:musicflow_client/providers/playlist_provider.dart';
import 'package:musicflow_client/providers/search_provider.dart';

import '../../helpers/mocks.dart';

/// 入库触发即返回契约(§入库不阻塞):
/// 提交 POST 秒回 → 立即 Toast,不弹任何阻塞遮罩;
/// 后台轮询任务,完成后经全局 ToastNotifier 通知成功/失败。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MockSubsonicApiClient api;
  late SearchRepository repo;
  final playlist = SearchPlaylist(
    id: 'p-1',
    source: 'douyin',
    name: '抖音热歌精选',
    providerId: 'douyin',
    trackCount: '100',
  );

  setUp(() {
    api = MockSubsonicApiClient();
    repo = SearchRepository(api);
    registerFallbackValue(<String, dynamic>{});
  });

  Future<void> pumpHost(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [searchRepositoryProvider.overrideWithValue(repo)],
        child: MaterialApp(
          navigatorKey: rootNavigatorKey,
          home: Scaffold(
            body: Center(
              child: Consumer(
                builder: (context, ref, _) => FilledButton(
                  onPressed: () => importSearchPlaylist(context, ref, playlist),
                  child: const Text('trigger-import'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  void stubSubmit({Object? response}) {
    when(
      () => api.postRaw(
        any(),
        data: any(named: 'data'),
        queryParameters: any(named: 'queryParameters'),
      ),
    ).thenAnswer((_) async => response ?? {'success': true, 'taskId': 't-1'});
  }

  void stubTaskPoll(List<Map<String, dynamic>> states) {
    var index = 0;
    when(
      () => api.getRaw(
        any(),
        queryParameters: any(named: 'queryParameters'),
      ),
    ).thenAnswer((_) async {
      if (index < states.length) return states[index++];
      return states.last;
    });
  }

  testWidgets('歌单入库:提交即返回,无阻塞遮罩,后台完成后 Toast 通知', (tester) async {
    stubSubmit();
    // 真实后端响应结构:任务状态嵌套在 task 字段下
    // (GET /v1/tasks/:id → { success, task: { status, result } })。
    stubTaskPoll([
      {'success': true, 'task': {'status': 'running'}},
      {
        'success': true,
        'task': {
          'status': 'ok',
          'result': {'playlistId': 'pl-1'},
        },
      },
    ]);
    await pumpHost(tester);

    await tester.tap(find.text('trigger-import'));
    await tester.pump();

    // 提交成功立即 Toast,且没有任何阻塞遮罩/加载弹窗
    expect(find.textContaining('入库任务已提交'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.byType(AlertDialog), findsNothing);
    // UI 未被锁死:按钮仍在树上,可继续交互
    expect(find.text('trigger-import'), findsOneWidget);

    // 推进后台轮询:第一次 running,第二次 ok
    await tester.pump(const Duration(milliseconds: 800));
    await tester.pump(const Duration(milliseconds: 800));
    expect(find.textContaining('入库完成'), findsOneWidget);
  });

  testWidgets('歌单入库:后台任务失败 → 错误 Toast 通知', (tester) async {
    stubSubmit();
    stubTaskPoll([
      {'success': true, 'task': {'status': 'running'}},
      {
        'success': true,
        'task': {'status': 'error', 'error': '子进程拉歌失败'},
      },
    ]);
    await pumpHost(tester);

    await tester.tap(find.text('trigger-import'));
    await tester.pump();
    expect(find.textContaining('入库任务已提交'), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 800));
    await tester.pump(const Duration(milliseconds: 800));
    expect(find.textContaining('入库失败'), findsOneWidget);
  });

  testWidgets('歌单入库:提交被拒(任务进行中)→ 立即错误 Toast,不启动后台监听', (tester) async {
    stubSubmit(response: {'success': false, 'error': '导入任务进行中'});
    await pumpHost(tester);

    await tester.tap(find.text('trigger-import'));
    await tester.pump();

    expect(find.textContaining('入库失败'), findsOneWidget);
    expect(find.textContaining('入库任务已提交'), findsNothing);
  });

  testWidgets('歌单入库:同歌单任务已在运行 → 复用 taskId 继续监听,完成仍 Toast', (
    tester,
  ) async {
    // 后端对同 sourceUrl 的去重响应:success=false 但带 taskId(已在跑)。
    stubSubmit(response: {'success': false, 'alreadyRunning': true, 'taskId': 't-9'});
    stubTaskPoll([
      {'success': true, 'task': {'status': 'running'}},
      {
        'success': true,
        'task': {
          'status': 'ok',
          'result': {'playlistId': 'pl-9'},
        },
      },
    ]);
    await pumpHost(tester);

    await tester.tap(find.text('trigger-import'));
    await tester.pump();

    // 不报错,提示已提交(复用已有任务),继续后台监听
    expect(find.textContaining('入库任务已提交'), findsOneWidget);
    expect(find.textContaining('入库失败'), findsNothing);

    await tester.pump(const Duration(milliseconds: 800));
    await tester.pump(const Duration(milliseconds: 800));
    expect(find.textContaining('入库完成'), findsOneWidget);
  });

  testWidgets(
    '歌单入库成功后自动刷新最近更新的歌单(invalidate recentPlaylistsProvider)',
    (tester) async {
      stubSubmit();
      stubTaskPoll([
        {'success': true, 'task': {'status': 'running'}},
        {
          'success': true,
          'task': {
            'status': 'ok',
            'result': {'playlistId': 'pl-1'},
          },
        },
      ]);

      // 计数:第一次是 build 时初始加载,invalidate 后应再次加载。
      var recentLoads = 0;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            searchRepositoryProvider.overrideWithValue(repo),
            recentPlaylistsProvider.overrideWith((ref) async {
              recentLoads += 1;
              return <Playlist>[
                Playlist(
                  id: 'pl-initial',
                  name: '初始最近歌单',
                  songCount: 0,
                  duration: 0,
                ),
              ];
            }),
          ],
          child: MaterialApp(
            navigatorKey: rootNavigatorKey,
            home: Scaffold(
              body: Center(
                child: Consumer(
                  builder: (context, ref, _) {
                    // watch 让 provider 进入活跃态:override 的 body 会被
                    // 执行(invalidate 后自动重拉,计数器会递增)。
                    ref.watch(recentPlaylistsProvider);
                    return FilledButton(
                      onPressed: () =>
                          importSearchPlaylist(context, ref, playlist),
                      child: const Text('trigger-import'),
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      );
      // 让初始 ProviderScope build 触发一次 recentPlaylistsProvider 加载。
      await tester.pump();
      expect(recentLoads, 1);

      await tester.tap(find.text('trigger-import'));
      await tester.pump();
      // 提交完成,后台监听尚未 ok,recentPlaylistsProvider 不应被刷新。
      expect(recentLoads, 1);

      // 推进后台轮询:第一次 running,第二次 ok → 触发 onSuccess → invalidate。
      await tester.pump(const Duration(milliseconds: 800));
      await tester.pump(const Duration(milliseconds: 800));

      expect(find.textContaining('入库完成'), findsOneWidget);
      expect(recentLoads, 2,
          reason: '入库成功回调应 invalidate recentPlaylistsProvider,触发重拉');
    },
  );
}
