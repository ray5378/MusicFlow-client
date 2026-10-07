// [D-025] DlnaDevicesState.copyWith 显式清空语义 —— batch41 E2 补测。
//
// 用户拍板（2026-10-07）：可空字段改「哨兵参数」语义 ——
// 省略参数 = 保持现状，显式传 null = 清空，与 DlnaCastState.clearDevice 对齐。
// 本文件两条用例分别钉住「清空」与「保持」两个方向。
import 'package:flutter_test/flutter_test.dart';
import 'package:musicflow_client/core/dlna/dlna_models.dart';
import 'package:musicflow_client/providers/cast/dlna_provider.dart';

DlnaDevice _device(String id, String name) => DlnaDevice(
      id: id,
      name: name,
      location: 'http://192.168.1.10:8000/desc.xml',
      lastSeen: DateTime(2024, 1, 1),
      avTransportUrl: 'http://192.168.1.10:8000/AVTransport/control',
      renderingControlUrl: 'http://192.168.1.10:8000/RenderingControl/control',
    );

void main() {
  test('[D-025] copyWith 显式传 null 清空 devices / isScanning', () {
    final base = DlnaDevicesState(
      devices: <DlnaDevice>[_device('u1', '电视')],
      isScanning: true,
    );
    final cleared = base.copyWith(devices: null, isScanning: null);
    expect(cleared.devices, isEmpty, reason: '显式 null 要真正清空设备列表');
    expect(cleared.isScanning, isFalse, reason: '显式 null 要真正结束扫描态');
  });

  test('[D-025] copyWith 省略参数保持现状（哨兵语义，调用点零改动）', () {
    final base = DlnaDevicesState(
      devices: <DlnaDevice>[_device('u1', '电视')],
      isScanning: true,
    );
    final kept = base.copyWith();
    expect(kept.devices.length, 1);
    expect(kept.devices.first.id, 'u1');
    expect(kept.isScanning, isTrue);
  });
}
