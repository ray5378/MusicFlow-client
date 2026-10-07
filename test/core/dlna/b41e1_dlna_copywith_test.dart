// batch41 E1 —— D-022 行为变更验证：DlnaDevice.copyWith 显式清空语义。
//
// 修复前：可空字段一律 `x ?? this.x`，显式传 null 被吃掉（清空失效）。
// 修复后：可空字段（alias / manufacturer / model / avTransportUrl /
// renderingControlUrl）用哨兵区分「省略=保持」与「显式 null=清空」；
// 非可空字段（id / name / location / lastSeen / available / disabled）保持原语义。
import 'package:flutter_test/flutter_test.dart';
import 'package:musicflow_client/core/dlna/dlna_models.dart';

DlnaDevice _device() => DlnaDevice(
      id: 'udn-1',
      name: '客厅设备',
      alias: '旧别名',
      location: 'http://192.168.1.10/desc.xml',
      manufacturer: 'Foo',
      model: 'Bar-100',
      avTransportUrl: 'http://192.168.1.10/avt',
      renderingControlUrl: 'http://192.168.1.10/rc',
      lastSeen: DateTime(2026, 1, 1, 12, 0, 0),
    );

void main() {
  group('DlnaDevice.copyWith [D-022] 显式清空语义', () {
    test('显式传 null 清空 alias 与 renderingControlUrl', () {
      final cleared = _device().copyWith(alias: null, renderingControlUrl: null);
      expect(cleared.alias, isNull,
          reason: '[D-022] 显式 null 应清空 alias（旧实现被 ?? 兜底吃掉）');
      expect(cleared.renderingControlUrl, isNull,
          reason: '[D-022] 显式 null 应清空 renderingControlUrl，'
              '让「设备无 RenderingControl → setVolume/toggleMute 早退」分支可达');
      // 其余字段不受影响
      expect(cleared.id, 'udn-1');
      expect(cleared.avTransportUrl, 'http://192.168.1.10/avt');
    });

    test('显式传 null 清空 manufacturer / model / avTransportUrl', () {
      final cleared = _device().copyWith(
        manufacturer: null,
        model: null,
        avTransportUrl: null,
      );
      expect(cleared.manufacturer, isNull);
      expect(cleared.model, isNull);
      expect(cleared.avTransportUrl, isNull);
      expect(cleared.alias, '旧别名', reason: '未涉及的字段保持原值');
    });

    test('省略可空参数保持原值（源兼容）', () {
      final kept = _device().copyWith(available: false);
      expect(kept.alias, '旧别名');
      expect(kept.manufacturer, 'Foo');
      expect(kept.model, 'Bar-100');
      expect(kept.avTransportUrl, 'http://192.168.1.10/avt');
      expect(kept.renderingControlUrl, 'http://192.168.1.10/rc');
      expect(kept.available, isFalse);
      expect(kept.disabled, isFalse);
    });

    test('显式传新值照常覆盖；非可空字段不受哨兵影响', () {
      final t2 = DateTime(2026, 1, 2);
      final updated = _device().copyWith(
        name: '新名字',
        alias: '新别名',
        avTransportUrl: 'http://10.0.0.2/avt',
        lastSeen: t2,
        disabled: true,
      );
      expect(updated.name, '新名字');
      expect(updated.alias, '新别名');
      expect(updated.avTransportUrl, 'http://10.0.0.2/avt');
      expect(updated.lastSeen, t2);
      expect(updated.disabled, isTrue);
      expect(updated.id, 'udn-1');
      expect(updated.location, 'http://192.168.1.10/desc.xml');
    });
  });
}
