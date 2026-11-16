// b43a —— 更新通道偏好：存储默认值与 Provider 持久化行为。
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:musicflow_client/core/services/update_checker.dart';
import 'package:musicflow_client/data/sources/local_storage.dart';
import 'package:musicflow_client/data/sources/prefs_gate.dart';
import 'package:musicflow_client/providers/settings/update_channel_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  Future<void> settle() async {
    // Notifier 构造时异步加载偏好：链路是 mock prefs 的 MethodChannel 往返，
    // 需要若干个事件轮转才能完成；固定给足等待。
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }

  test('LocalStorage.getUpdateChannel 未设置返回 null（默认 gitee 由上层定）',
      () async {
    expect(await LocalStorage.getUpdateChannel(), isNull);
    await LocalStorage.setUpdateChannel('github');
    expect(await LocalStorage.getUpdateChannel(), 'github');
  });

  test('默认通道是 gitee（用户确认的默认值，首次安装无记录也成立）', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    // 先读一次触发 Notifier 惰性构造，再等异步 _load 完成。
    expect(container.read(updateChannelProvider), UpdateChannel.gitee);
    await settle();
    expect(container.read(updateChannelProvider), UpdateChannel.gitee);
  });

  test('setChannel 即时生效并持久化到 prefs', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await settle();

    await container
        .read(updateChannelProvider.notifier)
        .setChannel(UpdateChannel.github);
    expect(container.read(updateChannelProvider), UpdateChannel.github);

    final prefs = await getPrefs();
    expect(prefs.getString('update_channel'), 'github');
  });

  test('已保存 github 的老用户 → 加载后为 github', () async {
    // 注意：同一 isolate 里 SharedPreferences.getInstance() 会缓存实例，
    // 后续 setMockInitialValues 不会生效 —— 直接写缓存实例来准备数据。
    final prefs = await getPrefs();
    await prefs.setString('update_channel', 'github');
    final container = ProviderContainer();
    addTearDown(container.dispose);
    // 先读一次触发 Notifier 惰性构造（此时还是默认 gitee），
    // 再等异步 _load 从 prefs 读回 github。
    expect(container.read(updateChannelProvider), UpdateChannel.gitee);
    await settle();
    expect(container.read(updateChannelProvider), UpdateChannel.github);
  });

  test('同值 setChannel 为 no-op，prefs 值不变', () async {
    final prefs = await getPrefs();
    await prefs.setString('update_channel', 'gitee');
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await settle();

    await container
        .read(updateChannelProvider.notifier)
        .setChannel(UpdateChannel.gitee);

    expect(prefs.getString('update_channel'), 'gitee');
    expect(container.read(updateChannelProvider), UpdateChannel.gitee);
  });
}
