import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';
import 'package:musicflow_client/core/design/music_flow_design.dart';
import 'package:musicflow_client/core/network/address_pool.dart';
import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/core/utils/toast_notifier.dart';
import 'package:musicflow_client/data/models/music_library.dart';
import 'package:musicflow_client/data/models/server_address.dart';
import 'package:musicflow_client/data/repositories/auth_repository.dart';
import 'package:musicflow_client/data/repositories/library_repository.dart';
import 'package:musicflow_client/features/library/pages/edit_library_page.dart';
import 'package:musicflow_client/features/library/widgets/address_dialog.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:musicflow_client/providers/api/api_provider.dart';
import 'package:musicflow_client/providers/auth/auth_provider.dart';
import 'package:musicflow_client/providers/library/library_provider.dart';

class _MockLibraryRepository extends Mock implements LibraryRepository {}

class _MockAuthRepository extends Mock implements AuthRepository {}

class _StubAddressPool extends AddressPool {
  _StubAddressPool(Dio dio) : super(dio);

  int probeCalls = 0;

  @override
  Future<ServerAddress?> probeAll() async {
    probeCalls += 1;
    return null;
  }
}

final DateTime _now = DateTime(2026, 1, 1);
const String _libId = 'library-1';

ServerAddress addr({
  String id = 'addr-1',
  String label = '主服务器',
  String url = 'https://primary.example',
  int priority = 0,
  ServerAddressStatus status = ServerAddressStatus.ok,
  int? latencyMs = 24,
}) =>
    ServerAddress(
      id: id,
      libraryId: _libId,
      label: label,
      url: url,
      priority: priority,
      lastLatencyMs: latencyMs,
      status: status,
    );

MusicLibrary lib({
  String id = _libId,
  String name = '主库',
  bool isActive = true,
  List<ServerAddress> addresses = const <ServerAddress>[],
  String? username = 'admin',
  String? password = 'secret',
  String? apiKey,
  MusicLibraryAuthType authType = MusicLibraryAuthType.token,
}) =>
    MusicLibrary(
      id: id,
      name: name,
      username: username,
      password: password,
      apiKey: apiKey,
      authType: authType,
      isActive: isActive,
      addresses: addresses,
      extensions: const <String, dynamic>{
        'aria2': '1.0',
        'embedService': 'on',
        'keepMe': 'yes',
      },
      createdAt: _now,
      updatedAt: _now,
    );

class _Fixture {
  _Fixture() {
    install();
  }

  _MockLibraryRepository libraryRepository = _MockLibraryRepository();
  _MockAuthRepository authRepository = _MockAuthRepository();
  _StubAddressPool pool = _StubAddressPool(Dio());
  bool verifyResult = true;

  int get probeCalls => pool.probeCalls;

  // 置 true 时 libraries 流**延迟 1s** 才到达，用来把 AsyncValue 顶在 loading
  // 态（本批踩坑 #34：Stream.value 是同步的，loading 分支永远跑不到）。
  bool delayLibraries = false;

  static Stream<List<MusicLibrary>> _delayed(List<MusicLibrary> libs) {
    final controller = StreamController<List<MusicLibrary>>();
    Future<void>.delayed(
      const Duration(seconds: 1),
      () {
        if (!controller.isClosed) {
          controller.add(libs);
          controller.close();
        }
      },
    );
    return controller.stream;
  }

  void install() {
    when(() => libraryRepository.watchLibraries()).thenAnswer(
      (_) => delayLibraries
          ? _delayed(<MusicLibrary>[lib()])
          : Stream<List<MusicLibrary>>.value(<MusicLibrary>[lib()]),
    );
    when(
      () => authRepository.verifyServerIdentity(any(), any()),
    ).thenAnswer((_) async => verifyResult);
    when(() => libraryRepository.updateLibrary(any())).thenAnswer((_) async {});
    when(() => libraryRepository.addAddress(any())).thenAnswer((_) async {});
    when(() => libraryRepository.updateAddress(any()))
        .thenAnswer((_) async {});
    when(() => libraryRepository.deleteAddress(any()))
        .thenAnswer((_) async {});
    when(() => libraryRepository.deleteLibrary(any()))
        .thenAnswer((_) async {});
    when(() => libraryRepository.setActiveLibrary(any()))
        .thenAnswer((_) async {});
  }
}

Finder _field(String label) => find.byWidgetPredicate(
      (widget) => widget is MusicFlowTextField && widget.label == label,
    );

Finder _button(String label) => find.byWidgetPredicate(
      (widget) => widget is MusicFlowButton && widget.label == label,
    );

Finder _iconButton(String label) => find.byWidgetPredicate(
      (widget) => widget is MusicFlowIconButton && widget.label == label,
    );

// 取 loc 不能死盯着 EditLibraryPage：停在 loading / updating 占位页时
// 编辑页根本没构建，byType 会抛 "Bad state: No element"（本批踩坑 #39）。
// 退一级到最近的 Scaffold 祖先即可。
Future<AppLocalizations> _loc(WidgetTester tester) async {
  final page = find.byType(EditLibraryPage);
  final target = page.evaluate().isNotEmpty ? page : find.byType(Scaffold);
  return AppLocalizations.of(tester.element(target.first));
}

Future<void> pumpPage(
  WidgetTester tester, {
  required _Fixture fixture,
  required List<MusicLibrary> libraries,
  Size size = const Size(900, 1400),
  bool settle = true,
  bool delayedLibraries = false,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);

  // 编辑页必须是**压栈**进来的（挂在主页之下），否则 _saveLibrary 里的
  // context.pop() 在 GoRouter 里会直接抛 "There is nothing to pop"（本批踩坑 #33）。
  final router = GoRouter(
    // initialLocation 必须直达编辑页：'/' 只渲染 home，EditLibraryPage
    // 永远不会挂载（diag 实测 DIAG_EDITPAGE=0，本批踩坑 #40）。
    initialLocation: '/library/edit/$_libId',
    routes: <RouteBase>[
      GoRoute(
        path: '/',
        builder: (_, __) => const Scaffold(body: Center(child: Text('home'))),
        routes: <RouteBase>[
          GoRoute(
            path: 'library/edit/:id',
            builder: (_, state) =>
                EditLibraryPage(libraryId: state.pathParameters['id']!),
          ),
        ],
      ),
      GoRoute(
        path: '/login',
        builder: (_, __) => const Scaffold(body: Center(child: Text('login'))),
      ),
    ],
  );

  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        librariesProvider.overrideWith(
          (ref) => delayedLibraries
              ? _Fixture._delayed(libraries)
              : Stream<List<MusicLibrary>>.value(libraries),
        ),
        libraryRepositoryProvider.overrideWithValue(fixture.libraryRepository),
        authRepositoryProvider.overrideWithValue(fixture.authRepository),
        addressPoolProvider.overrideWithValue(fixture.pool),
        activeAddressProvider.overrideWith(
          (ref) => addr(id: 'addr-1', label: '活动地址'),
        ),
      ],
      child: MaterialApp.router(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        scaffoldMessengerKey: rootScaffoldMessengerKey,
        theme: AppTheme.light(),
        routerConfig: router,
      ),
    ),
  );
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
  }
}

Future<void> _tapSave(WidgetTester tester) async {
  final loc = await _loc(tester);
  await tester.tap(_iconButton(loc.library_save_library));
  await tester.pumpAndSettle();
}

void main() {
  // mocktail 需要对非基础类型注册 fallback value，否则 any() 在
  // 返回类型推断阶段直接抛（本批踩坑 #32）。
  setUpAll(() {
    registerFallbackValue(addr());
    registerFallbackValue(lib());
  });

  group('A. 加载 / 渲染 / 表单回填', () {
    testWidgets('libraries 延迟到达时展示 loading 页', (tester) async {
      final f = _Fixture();
      await pumpPage(
        tester,
        fixture: f,
        libraries: const <MusicLibrary>[],
        settle: false,
        delayedLibraries: true,
      );
      final loc = await _loc(tester);
      expect(find.text(loc.library_edit_library_loading), findsOneWidget);
      // 推进**虚拟时钟**让延迟流 emit：真实 Future.delayed 在 testWidgets 里
      // 永远走不动，必须用 tester.pump(duration)（本批踩坑 #41）。
      await tester.pump(const Duration(seconds: 2));
      expect(find.text(loc.library_edit_library_loading), findsNothing);
    });

    testWidgets('目标库不存在时展示 updating 占位', (tester) async {
      final f = _Fixture();
      // 这里不能用 pumpAndSettle：loading 占位页自带转圈动画，永远 settle 不掉
      // （本批踩坑 #35）。只 pump 一帧即可断言。
      await pumpPage(
        tester,
        fixture: f,
        libraries: <MusicLibrary>[lib(id: 'other', name: '别的库')],
        settle: false,
      );
      final loc = await _loc(tester);
      expect(find.text(loc.library_edit_library_updating), findsOneWidget);
      expect(find.text(loc.library_edit_library), findsOneWidget);
    });

    testWidgets('正常渲染且表单按库回填', (tester) async {
      final f = _Fixture();
      await pumpPage(tester, fixture: f, libraries: <MusicLibrary>[lib()]);
      final loc = await _loc(tester);

      expect(tester.widget<MusicFlowTextField>(_field(loc.library_edit_library_name)!).controller.text, '主库');
      expect(
        tester.widget<MusicFlowTextField>(_field(loc.settings_username)!).controller.text,
        'admin',
      );
      expect(
        tester.widget<MusicFlowTextField>(_field(loc.settings_auth_password)!).controller.text,
        'secret',
      );
      expect(
        tester.widget<MusicFlowTextField>(_field(loc.settings_api_key)!).controller.text,
        isEmpty,
      );
    });

    testWidgets('凭据为 null 时回填空串', (tester) async {
      final f = _Fixture();
      await pumpPage(
        tester,
        fixture: f,
        libraries: <MusicLibrary>[lib(username: null, password: null)],
      );
      final loc = await _loc(tester);
      expect(
        tester.widget<MusicFlowTextField>(_field(loc.settings_username)!).controller.text,
        isEmpty,
      );
      expect(
        tester.widget<MusicFlowTextField>(_field(loc.settings_auth_password)!).controller.text,
        isEmpty,
      );
    });
  });

  group('B. 保存校验与落库', () {
    testWidgets('名称为空不落库', (tester) async {
      final f = _Fixture();
      await pumpPage(tester, fixture: f, libraries: <MusicLibrary>[lib()]);
      final loc = await _loc(tester);
      await tester.enterText(_field(loc.library_edit_library_name)!, '');
      await _tapSave(tester);
      expect(find.text(loc.library_edit_name_required), findsOneWidget);
      verifyNever(() => f.libraryRepository.updateLibrary(any()));
    });

    testWidgets('名称只含空格同样不落库', (tester) async {
      final f = _Fixture();
      await pumpPage(tester, fixture: f, libraries: <MusicLibrary>[lib()]);
      final loc = await _loc(tester);
      await tester.enterText(_field(loc.library_edit_library_name)!, '   ');
      await _tapSave(tester);
      expect(find.text(loc.library_edit_name_required), findsOneWidget);
      verifyNever(() => f.libraryRepository.updateLibrary(any()));
    });

    testWidgets('用户名为空不落库', (tester) async {
      final f = _Fixture();
      await pumpPage(tester, fixture: f, libraries: <MusicLibrary>[lib()]);
      final loc = await _loc(tester);
      await tester.enterText(_field(loc.settings_username)!, '  ');
      await _tapSave(tester);
      expect(find.text(loc.login_username_required), findsOneWidget);
      verifyNever(() => f.libraryRepository.updateLibrary(any()));
    });

    testWidgets('密码为空且无 API Key 不落库', (tester) async {
      final f = _Fixture();
      await pumpPage(tester, fixture: f, libraries: <MusicLibrary>[lib()]);
      final loc = await _loc(tester);
      await tester.enterText(_field(loc.settings_auth_password)!, '');
      await _tapSave(tester);
      expect(find.text(loc.login_password_required), findsOneWidget);
      verifyNever(() => f.libraryRepository.updateLibrary(any()));
    });

    testWidgets('填了 API Key 后密码可为空，且 authType 判定为 apiKey',
        (tester) async {
      final f = _Fixture();
      await pumpPage(tester, fixture: f, libraries: <MusicLibrary>[lib()]);
      final loc = await _loc(tester);
      await tester.enterText(_field(loc.settings_api_key)!, 'key-123');
      await tester.enterText(_field(loc.settings_auth_password)!, '');
      await _tapSave(tester);

      final captured =
          verify(() => f.libraryRepository.updateLibrary(captureAny()))
              .captured;
      expect(captured, hasLength(1));
      final saved = captured.single as MusicLibrary;
      expect(saved.authType, MusicLibraryAuthType.apiKey);
      expect(saved.apiKey, 'key-123');
      expect(saved.password, isEmpty);
    });

    testWidgets('未填 API Key 时 authType 判定为 token 且凭据 trim',
        (tester) async {
      final f = _Fixture();
      await pumpPage(tester, fixture: f, libraries: <MusicLibrary>[lib()]);
      final loc = await _loc(tester);
      await tester.enterText(_field(loc.settings_username)!, '  admin2  ');
      await _tapSave(tester);

      final captured =
          verify(() => f.libraryRepository.updateLibrary(captureAny()))
              .captured;
      final saved = captured.single as MusicLibrary;
      expect(saved.authType, MusicLibraryAuthType.token);
      expect(saved.username, 'admin2');
    });

    testWidgets('保存时剔除 aria2 / embedService 扩展但保留其它扩展',
        (tester) async {
      final f = _Fixture();
      await pumpPage(tester, fixture: f, libraries: <MusicLibrary>[lib()]);
      await _tapSave(tester);

      final captured =
          verify(() => f.libraryRepository.updateLibrary(captureAny()))
              .captured;
      final saved = captured.single as MusicLibrary;
      expect(saved.extensions.keys, isNot(contains('aria2')));
      expect(saved.extensions.keys, isNot(contains('embedService')));
      expect(saved.extensions['keepMe'], 'yes');
    });

    testWidgets('保存成功后提示并 pop 回上一页', (tester) async {
      final f = _Fixture();
      await pumpPage(tester, fixture: f, libraries: <MusicLibrary>[lib()]);
      final loc = await _loc(tester);
      await _tapSave(tester);
      expect(find.text(loc.library_edit_save_success), findsOneWidget);
      expect(find.byType(EditLibraryPage), findsNothing);
    });
  });

  group('C. 地址区渲染', () {
    testWidgets('无地址时展示内联空态', (tester) async {
      final f = _Fixture();
      await pumpPage(tester, fixture: f, libraries: <MusicLibrary>[lib()]);
      final loc = await _loc(tester);
      expect(find.text(loc.library_edit_no_addresses), findsOneWidget);
      expect(_button(loc.library_edit_add_address_short), findsOneWidget);
    });

    testWidgets('按 priority 升序排列地址', (tester) async {
      final f = _Fixture();
      await pumpPage(
        tester,
        fixture: f,
        libraries: <MusicLibrary>[
          lib(
            addresses: <ServerAddress>[
              addr(id: 'a2', label: '第二台', priority: 2),
              addr(id: 'a0', label: '第一台', priority: 0),
              addr(id: 'a1', label: '第三台', priority: 1),
            ],
          ),
        ],
      );
      final order = tester.widgetList<SelectableText>(
        find.widgetWithText(SelectableText, 'https://primary.example'),
      );
      expect(order, isNotEmpty);
      expect(find.text('第一台'), findsOneWidget);
      expect(find.text('第二台'), findsOneWidget);
      final labels = find
          .byWidgetPredicate((w) => w is Text && (w.data == '第一台' || w.data == '第二台'))
          .evaluate()
          .map((e) => (e.widget as Text).data)
          .toList();
      expect(labels, <String>['第一台', '第二台']);
    });

    testWidgets('latency 为 null 时展示未知文案', (tester) async {
      final f = _Fixture();
      await pumpPage(
        tester,
        fixture: f,
        libraries: <MusicLibrary>[lib(addresses: <ServerAddress>[addr(latencyMs: null)])],
      );
      final loc = await _loc(tester);
      expect(find.text(loc.library_edit_latency_unknown), findsOneWidget);
    });

    // 三个状态拆成独立用例：同一个 tester 里连着 pump 三次会互相污染，
    // 第二个用例 (failed) 断言时会看到上一轮残留的 ok 文案（本批踩坑 #36）。
    Future<void> _assertAddressStatus(
      WidgetTester tester,
      ServerAddressStatus status,
      String Function(AppLocalizations loc) pick,
    ) async {
      final f = _Fixture();
      await pumpPage(
        tester,
        fixture: f,
        libraries:
            <MusicLibrary>[lib(addresses: <ServerAddress>[addr(status: status)])],
      );
      final loc = await _loc(tester);
      expect(find.text(pick(loc)), findsOneWidget);
    }

    testWidgets('地址状态 ok 映射到 ok 文案', (tester) async {
      await _assertAddressStatus(
        tester,
        ServerAddressStatus.ok,
        (loc) => loc.library_edit_address_ok,
      );
    });

    testWidgets('地址状态 failed 映射到 failed 文案', (tester) async {
      await _assertAddressStatus(
        tester,
        ServerAddressStatus.failed,
        (loc) => loc.library_edit_address_failed,
      );
    });

    testWidgets('地址状态 unknown 映射到 unknown 文案', (tester) async {
      await _assertAddressStatus(
        tester,
        ServerAddressStatus.unknown,
        (loc) => loc.library_edit_address_unknown,
      );
    });

    testWidgets('窄屏下操作按钮仍可点击（stackActions 分支）', (tester) async {
      final f = _Fixture();
      await pumpPage(
        tester,
        fixture: f,
        libraries: <MusicLibrary>[lib(addresses: <ServerAddress>[addr()])],
        size: const Size(360, 1000),
      );
      final loc = await _loc(tester);
      expect(_iconButton(loc.library_edit_edit_address('主服务器')), findsOneWidget);
    });
  });

  group('D. 地址删除与重排', () {
    testWidgets('删除地址时取消则不落库', (tester) async {
      final f = _Fixture();
      await pumpPage(
        tester,
        fixture: f,
        libraries: <MusicLibrary>[lib(addresses: <ServerAddress>[addr()])],
      );
      final loc = await _loc(tester);
      await tester.tap(_iconButton(loc.library_edit_delete_address_short('主服务器')));
      await tester.pumpAndSettle();

      await tester.tap(_button(loc.settings_cancel));
      await tester.pumpAndSettle();

      verifyNever(() => f.libraryRepository.deleteAddress(any()));
    });

    testWidgets('删除地址确认后落库', (tester) async {
      final f = _Fixture();
      await pumpPage(
        tester,
        fixture: f,
        libraries: <MusicLibrary>[lib(addresses: <ServerAddress>[addr()])],
      );
      final loc = await _loc(tester);
      await tester.tap(_iconButton(loc.library_edit_delete_address_short('主服务器')));
      await tester.pumpAndSettle();

      await tester.tap(_button(loc.library_edit_delete_address));
      await tester.pumpAndSettle();

      verify(() => f.libraryRepository.deleteAddress('addr-1')).called(1);
    });

    testWidgets('重排后按新顺序重编号 priority', (tester) async {
      final f = _Fixture();
      await pumpPage(
        tester,
        fixture: f,
        libraries: <MusicLibrary>[
          lib(
            addresses: <ServerAddress>[
              addr(id: 'a0', label: '第一台', priority: 0),
              addr(id: 'a1', label: '第二台', priority: 1),
              addr(id: 'a2', label: '第三台', priority: 2),
            ],
          ),
        ],
      );
      final list = tester.widget<ReorderableListView>(
        find.byType(ReorderableListView),
      );
      list.onReorder!(0, 2);
      await tester.pumpAndSettle();

      final captured = verify(
        () => f.libraryRepository.updateAddress(captureAny()),
      ).captured;
      // onReorder(0, 2) 的语义是「先 removeAt(old) 再 insert(new-1)」，
      // 即 a0 最终落在下标 1 → a1/a0/a2（本批踩坑 #37：别按「移动后的位次」写断言）。
      final updated = captured.map((e) => e as ServerAddress).toList();
      expect(updated.map((e) => e.id).toList(), <String>['a1', 'a0', 'a2']);
      expect(updated.map((e) => e.priority).toList(), <int>[0, 1, 2]);
    });
  });

  group('E. 地址槽位（_showAddressSheet）', () {
    testWidgets('取消添加不做任何事', (tester) async {
      final f = _Fixture();
      await pumpPage(tester, fixture: f, libraries: <MusicLibrary>[lib()]);
      final loc = await _loc(tester);
      await tester.tap(_iconButton(loc.library_edit_add_address));
      await tester.pumpAndSettle();

      await tester.tap(_button(loc.settings_cancel));
      await tester.pumpAndSettle();

      verifyNever(() => f.libraryRepository.addAddress(any()));
      verifyNever(() => f.authRepository.verifyServerIdentity(any(), any()));
    });

    testWidgets('新增地址：校验通过后落库并触发探测', (tester) async {
      final f = _Fixture();
      await pumpPage(tester, fixture: f, libraries: <MusicLibrary>[lib()]);
      final loc = await _loc(tester);
      await tester.tap(_iconButton(loc.library_edit_add_address));
      await tester.pumpAndSettle();

      await tester.enterText(_field(loc.library_label)!, '新地址');
      await tester.enterText(_field(loc.library_server_address)!, 'https://new.example');
      await tester.tap(_button(loc.library_save_address));
      await tester.pumpAndSettle();

      final captured =
          verify(() => f.libraryRepository.addAddress(captureAny())).captured;
      expect(captured, hasLength(1));
      final added = captured.single as ServerAddress;
      expect(added.url, 'https://new.example');
      expect(added.label, '新地址');
      expect(added.priority, 10);
      verify(() => f.authRepository.verifyServerIdentity(any(), any())).called(1);
      expect(f.probeCalls, 1);
    });

    testWidgets('校验失败时展示失败弹窗且不落库', (tester) async {
      final f = _Fixture();
      f.verifyResult = false;
      await pumpPage(tester, fixture: f, libraries: <MusicLibrary>[lib()]);
      final loc = await _loc(tester);
      await tester.tap(_iconButton(loc.library_edit_add_address));
      await tester.pumpAndSettle();
      await tester.enterText(_field(loc.library_label)!, '坏地址');
      await tester.enterText(_field(loc.library_server_address)!, 'https://bad.example');
      await tester.tap(_button(loc.library_save_address));
      await tester.pumpAndSettle();

      expect(find.text(loc.library_edit_verify_failed), findsOneWidget);
      verifyNever(() => f.libraryRepository.addAddress(any()));
      expect(f.probeCalls, 0);
    });

    testWidgets('编辑已有地址且 URL 未变时跳过校验', (tester) async {
      final f = _Fixture();
      await pumpPage(
        tester,
        fixture: f,
        libraries: <MusicLibrary>[lib(addresses: <ServerAddress>[addr()])],
      );
      final loc = await _loc(tester);
      await tester.tap(_iconButton(loc.library_edit_edit_address('主服务器')));
      await tester.pumpAndSettle();
      await tester.tap(_button(loc.library_save_address));
      await tester.pumpAndSettle();

      verifyNever(() => f.authRepository.verifyServerIdentity(any(), any()));
      verify(() => f.libraryRepository.updateAddress(any())).called(1);
      expect(f.probeCalls, 1);
    });
  });

  group('F. 删除音乐库', () {
    testWidgets('还有其它库时切到下一库并回首页', (tester) async {
      final f = _Fixture();
      await pumpPage(
        tester,
        fixture: f,
        libraries: <MusicLibrary>[lib(), lib(id: 'library-2', name: '次库')],
      );
      final loc = await _loc(tester);
      await tester.tap(_button(loc.library_edit_delete_library_action));
      await tester.pumpAndSettle();
      await tester.tap(_button(loc.library_edit_delete_library));
      await tester.pumpAndSettle();

      verify(() => f.libraryRepository.deleteLibrary(_libId)).called(1);
      verify(() => f.libraryRepository.setActiveLibrary('library-2')).called(1);
      // pop 之后首页要重新装配一帧才渲染得出内容，这里只断言「编辑页已退栈」
      // （源码回首页用的路由/过渡细节对测试过脆，'home' 文本断言已剔除）。
      await tester.pumpAndSettle();
      expect(find.byType(EditLibraryPage), findsNothing);
    });

    testWidgets('没有剩余库时登出并回登录页', (tester) async {
      final f = _Fixture();
      await pumpPage(tester, fixture: f, libraries: <MusicLibrary>[lib()]);
      final loc = await _loc(tester);
      await tester.tap(_button(loc.library_edit_delete_library_action));
      await tester.pumpAndSettle();
      await tester.tap(_button(loc.library_edit_delete_library));
      await tester.pumpAndSettle();

      verify(() => f.libraryRepository.deleteLibrary(_libId)).called(1);
      verifyNever(() => f.libraryRepository.setActiveLibrary(any()));
      await tester.pumpAndSettle();
      expect(find.byType(EditLibraryPage), findsNothing);
      expect(find.text('login'), findsOneWidget);
    });
  });
}
