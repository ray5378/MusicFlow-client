// b38c3 —— Route C 补测：编辑音乐库页剩余缺口。
//   * edit_library_page.dart：275/276/278/280（地址列表 ReorderableListView 的
//     proxyDecorator：拖拽上屏时包 AnimatedBuilder + MusicFlowSurface(floating)）；
//     405（校验失败提示 sheet 里「知道了」按钮的 pop 闭包）。
//
// 手法：librariesProvider 用 Stream.value 覆写注入固定库；libraryRepositoryProvider
// 用 mocktail 桩（拖拽落位会 updateAddress）；authRepositoryProvider 用 AuthRepository
// 子类把 verifyServerIdentity 固定为 false，驱动校验失败分支。
//
// 只写 test/，只读 lib/（产品代码零改动）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:musicflow_client/core/design/music_flow_design.dart';
import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/data/models/music_library.dart';
import 'package:musicflow_client/data/models/server_address.dart';
import 'package:musicflow_client/data/repositories/auth_repository.dart';
import 'package:musicflow_client/data/repositories/library_repository.dart';
import 'package:musicflow_client/features/library/pages/edit_library_page.dart';
import 'package:musicflow_client/features/library/widgets/address_dialog.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:musicflow_client/providers/auth/auth_provider.dart';
import 'package:musicflow_client/providers/library/library_provider.dart';

class _StubLibraryRepo extends Mock implements LibraryRepository {}

class _FailingAuthRepo extends AuthRepository {
  @override
  Future<bool> verifyServerIdentity(
    ServerAddress newAddress,
    MusicLibrary existingLibrary,
  ) async =>
      false;
}

late AppLocalizations loc;

ServerAddress _addr(String id, int priority) => ServerAddress(
      id: id,
      libraryId: 'lib-1',
      label: '地址$id',
      url: 'https://s$id.example.com',
      priority: priority,
      status: ServerAddressStatus.ok,
    );

MusicLibrary _library({int addressCount = 3}) => MusicLibrary(
      id: 'lib-1',
      name: '我的库',
      username: 'u',
      password: 'p',
      isActive: true,
      addresses: <ServerAddress>[
        for (var i = 0; i < addressCount; i++) _addr('a$i', i),
      ],
      createdAt: DateTime(2024),
      updatedAt: DateTime(2024),
    );

class _Harness {
  _Harness({this.addressCount = 3, _FailingAuthRepo? auth})
      : auth = auth ?? _FailingAuthRepo();

  final int addressCount;
  final _FailingAuthRepo auth;
  final _StubLibraryRepo repo = _StubLibraryRepo();

  late ProviderContainer container;

  Widget build(WidgetTester tester) {
    when(() => repo.updateAddress(any())).thenAnswer((_) async {});
    when(() => repo.addAddress(any())).thenAnswer((_) async {});
    when(() => repo.deleteAddress(any())).thenAnswer((_) async {});
    container = ProviderContainer(
      overrides: <Override>[
        librariesProvider.overrideWith(
          (ref) => Stream<List<MusicLibrary>>.value(
            <MusicLibrary>[_library(addressCount: addressCount)],
          ),
        ),
        libraryRepositoryProvider.overrideWithValue(repo),
        authRepositoryProvider.overrideWithValue(auth),
      ],
    );
    tester.view.physicalSize = const Size(900, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(container.dispose);
    return UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
        theme: AppTheme.light(),
        builder: (context, child) {
          loc = AppLocalizations.of(context);
          return child!;
        },
        home: const EditLibraryPage(libraryId: 'lib-1'),
      ),
    );
  }
}

Future<void> settle(WidgetTester tester, {int frames = 12}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}

void main() {
  setUpAll(() {
    registerFallbackValue(_addr('fallback', 0));
  });

  testWidgets('edit_library：拖拽地址把手触发 proxyDecorator（275/276/278/280）',
      (tester) async {
    final h = _Harness();
    await tester.pumpWidget(h.build(tester));
    await settle(tester);

    expect(find.text('地址a0'), findsOneWidget);
    expect(find.byIcon(AppIcons.dragHandle), findsNWidgets(3));

    // 拖起前：没有 floating 级 surface（proxy 未创建）。
    Finder floating() => find.byWidgetPredicate(
          (w) => w is MusicFlowSurface &&
              w.level == MusicFlowSurfaceLevel.floating,
        );
    expect(floating(), findsNothing);

    // ReorderableDelayedDragStartListener：长按后进入拖拽。
    final handle = find.byIcon(AppIcons.dragHandle).first;
    final gesture = await tester.startGesture(tester.getCenter(handle));
    await tester.pump(const Duration(milliseconds: 700));
    await gesture.moveBy(const Offset(0, 120));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    // 拖拽期：proxy 的 MusicFlowSurface(floating) 已上屏。
    expect(floating(), findsWidgets,
        reason: 'proxyDecorator 应在拖拽期构建 floating 级 MusicFlowSurface');

    await gesture.up();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('edit_library：地址校验失败 → 点「知道了」关闭（405）', (tester) async {
    final h = _Harness(addressCount: 1);
    await tester.pumpWidget(h.build(tester));
    await settle(tester);

    // 打开新增地址 sheet。
    await tester.tap(find.byIcon(AppIcons.addCircle));
    await tester.pumpAndSettle();
    expect(find.byType(AddressDialog), findsOneWidget);

    // 填写标签 + https 地址（避开不安全 http 二次确认）。
    final fields = find.descendant(
      of: find.byType(AddressDialog),
      matching: find.byType(TextField),
    );
    expect(fields, findsNWidgets(2));
    await tester.enterText(fields.at(0), '新地址');
    await tester.enterText(fields.at(1), 'https://new.example.com');
    await tester.pumpAndSettle();

    await tester.tap(find.text(loc.library_save_address));
    await tester.pumpAndSettle();

    // verifyServerIdentity=false → 校验失败 sheet。
    expect(find.text(loc.library_edit_verify_failed), findsOneWidget);

    // 点「知道了」→ 触发 onPressed 闭包（405）。
    await tester.tap(find.text(loc.library_got_it));
    await tester.pumpAndSettle();
    expect(find.text(loc.library_edit_verify_failed), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
